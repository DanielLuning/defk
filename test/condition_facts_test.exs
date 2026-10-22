# Facts from conditions (ADR-0007, step 3): a comparison of exact i64
# values narrows the facts of its newest atom where it holds, in an
# if/cond/case arm (and the negations of the conditions before it), a for
# filter, the right side of an `and`, and the body of a non-empty range.
# After a raising guard (`if c, do: raise ...`) the rest of the block sees
# `not c`. Two rules keep it sound: an arm whose own condition dropped a
# check is never a select (a select computes every arm), and a condition
# narrows only from operands computed without a check, which a flagged
# strip computes on past.
#
# The kernels below are the acceptance cases (a rolling difference at a
# window w, a block shifted by m) and the report's hint when the fact is
# missing. The soundness property compiles generated kernels with random
# guards, conditions and linear indices (no clang: the C is read) and checks
# every dropped bounds and overflow check where the condition holds.

defmodule Defk.ConditionFactsTest.K do
  # the report names the fact that would drop a kept check only under
  # report: :full, and the tests below read those hints
  use Defk, report: :full

  # x[i - w] under i >= w, after a raise when w < 1: 0 <= i - w from the
  # arm, i - w < length(x) from i <= length(x) - 1 and w >= 1
  defk rolling_diff(x :: [f64], w :: i64) :: [f64] do
    if w < 1, do: raise(ArgumentError, "w must be at least 1")
    out = alloc(f64, length(x))

    for i <- 0..(length(x) - 1)//1 do
      old = if i >= w, do: x[i - w], else: 0.0
      out[i] = x[i] - old
    end

    out
  end

  # the same without the guard: i - w < length(x) needs w >= 0
  defk rolling_diff_unguarded(x :: [f64], w :: i64) :: [f64] do
    out = alloc(f64, length(x))

    for i <- 0..(length(x) - 1)//1 do
      old = if i >= w, do: x[i - w], else: 0.0
      out[i] = x[i] - old
    end

    out
  end

  # acc[i - m] for i <- m..: the range start bounds i below, and m >= 0
  # (the guard) keeps i - m below length(acc) and i at least 0
  defk shift_add(acc :: [i64], bufs :: [i64], m :: i64) :: [i64] do
    if m < 0, do: raise(ArgumentError, "m must not be negative")

    for i <- m..(min(length(acc), length(bufs)) - 1)//1 do
      acc[i] = acc[i - m] + bufs[i]
    end

    acc
  end

  defk shift_add_unguarded(acc :: [i64], bufs :: [i64], m :: i64) :: [i64] do
    for i <- m..(min(length(acc), length(bufs)) - 1)//1 do
      acc[i] = acc[i - m] + bufs[i]
    end

    acc
  end

  # i - w cannot overflow where i >= w and w >= 0: the arm relies on its
  # condition, so it is a branch, never a select
  defk guarded_sub(i :: i64, w :: i64) :: i64 do
    if i >= w and w >= 0, do: i - w, else: 0
  end

  # i - w may overflow (w unbounded): the arm keeps its check and stays a
  # select
  defk plain_sub(i :: i64, w :: i64) :: i64 do
    if i >= w, do: i - w, else: 0
  end

  # each later arm sees the negations of the conditions before it
  defk clamped_get(x :: [i64], k :: i64) :: i64 do
    cond do
      k < 0 -> 0
      k >= length(x) -> -1
      true -> x[k]
    end
  end

  # filters narrow the rest of the loop
  defk filtered(x :: [i64], w :: i64) :: i64 do
    for i <- 0..(length(x) - 1)//1, i >= w, w >= 0, reduce: 0 do
      acc -> acc + x[i - w]
    end
  end

  # the right side of an `and` runs where the left holds
  defk positive_at(x :: [i64], k :: i64) :: bool do
    k >= 0 and k < length(x) and x[k] > 0
  end

  # a guard whose else arm raises: the rest sees the condition
  defk checked_get(x :: [i64], k :: i64) :: i64 do
    if k >= 0 and k < length(x) do
      0
    else
      raise ArgumentError, "k out of range"
    end

    x[k]
  end

  # a non-empty 0..(n - 1) gives n >= 1 in its body: out[0] is in bounds
  defk first_sum(n :: i64) :: [i64] do
    out = alloc(i64, max(n, 0))

    for i <- 0..(n - 1)//1 do
      out[0] = out[0] + i
    end

    out
  end

  # j = i + k is computed with a check (k unbounded), which a flagged run
  # computes on past: the guard that proves x[j] in bounds names j, so the
  # access is not fixed and the strip stays checked
  defk guarded_shift(x :: [f64], k :: i64) :: f64 do
    for i <- 0..(length(x) - 1)//1, reduce: 0.0 do
      acc ->
        j = i + k
        if j >= 0 and j < length(x), do: acc + x[j], else: acc
    end
  end

  # i + k in the condition is computed with a check: it narrows nothing, so
  # x[i + k] keeps its bounds check, and the strip runs flagged
  defk guarded_offset(x :: [f64], k :: i64) :: f64 do
    for i <- 0..(length(x) - 1)//1, reduce: 0.0 do
      acc -> if i + k >= 0 and i + k < length(x), do: acc + x[i + k], else: acc
    end
  end

  # A guard between two parameters states its fact on the one declared
  # later, whatever their names: base <= length(x) bounds base (declared
  # after x), so base + idx[i], an i32 element, fits i64 with no check. The
  # gather x[base + idx[i]] keeps its bounds check: it depends on the
  # array's contents.
  defk gather(idx :: [i32], x :: [f32], base :: i64) :: f64 do
    if not (base >= 0 and base <= length(x)), do: raise(ArgumentError, "base")

    for i <- 0..(length(idx) - 1)//1, reduce: 0.0 do
      acc -> acc + x[base + idx[i]]
    end
  end

  # the same with the offset's name sorting after the array's: the same
  # proof (a guard bounds the parameter declared later, never the earlier
  # one: declared before the array, `off` would keep its check)
  defk gather_named(ia :: [i32], as :: [f32], off :: i64) :: f64 do
    if not (off >= 0 and off <= length(as)), do: raise(ArgumentError, "off")

    for i <- 0..(length(ia) - 1)//1, reduce: 0.0 do
      acc -> acc + as[off + ia[i]]
    end
  end
end

# the same unguarded kernel without report: :full: its note names no fact
defmodule Defk.ConditionFactsTest.Plain do
  use Defk

  defk rolling_diff_unguarded(x :: [f64], w :: i64) :: [f64] do
    out = alloc(f64, length(x))

    for i <- 0..(length(x) - 1)//1 do
      old = if i >= w, do: x[i - w], else: 0.0
      out[i] = x[i] - old
    end

    out
  end
end

defmodule Defk.ConditionFactsTest do
  use ExUnit.Case, async: true
  use Defk.Properties

  import Defk.TestKit,
    only: [
      kernel_c: 2,
      bounds_check_free?: 2,
      bounds_proven?: 2,
      kept_bounds: 2,
      eval_ops: 2,
      fits_i64?: 1
    ]

  alias Defk.ConditionFactsTest.K

  @len_max 2 ** 61 - 1
  @i64_min -0x8000000000000000
  @i64_max 0x7FFFFFFFFFFFFFFF

  defp agrees(fun, args),
    do: Defk.Test.assert_agrees(K, fun, args, forced_yields: true)

  defp notes(kernel, topic), do: Defk.TestKit.notes(K, kernel, topic)
  defp kept(kernel), do: kept_bounds(K, kernel)

  defp f64s(xs), do: G.pack(:f64, Enum.map(xs, &(&1 * 1.0)))
  defp f32s(xs), do: G.pack(:f32, Enum.map(xs, &(&1 * 1.0)))

  describe "a raising guard and an if arm: a rolling window" do
    test "x[i - w] keeps no bounds check after a raise when w < 1" do
      assert bounds_proven?(K, :rolling_diff)
      # end to end: the C calls no checked access
      assert bounds_check_free?(K, "rolling_diff")

      for x <- [[], [1], [1, 2, 3], Enum.to_list(1..3000)], w <- [1, 2, 3, 5000, @i64_max] do
        assert {:ok, _} = agrees(:rolling_diff, [f64s(x), w])
      end

      for w <- [0, -1, @i64_min] do
        assert {:raise, %ArgumentError{}} = agrees(:rolling_diff, [f64s([1, 2]), w])
      end
    end

    test "without the guard, the report names w >= 0" do
      assert kept(:rolling_diff_unguarded) == [
               "x[i - w]: bounds check kept; nothing proves i - w < length(x) (it would follow from w >= 0)"
             ]

      # the hint is searched for only under report: :full
      assert kept_bounds(Defk.ConditionFactsTest.Plain, :rolling_diff_unguarded) == [
               "x[i - w]: bounds check kept; nothing proves i - w < length(x)"
             ]

      for w <- [@i64_min, -3, -1, 0, 1, 2, @i64_max] do
        assert {_, _} = agrees(:rolling_diff_unguarded, [f64s([1, 2, 3]), w])
      end
    end
  end

  describe "a range start and a raising guard: a shifted block" do
    test "acc[i - m], acc[i] and bufs[i] keep no bounds check with m >= 0" do
      assert bounds_proven?(K, :shift_add)

      for {acc, bufs} <- [{[], []}, {[1, 2, 3], [4, 5]}, {Enum.to_list(1..3000), [7, 8, 9]}],
          m <- [0, 1, 2, 3, 4000, @i64_max] do
        assert {:ok, _} = agrees(:shift_add, [G.pack(:i64, acc), G.pack(:i64, bufs), m])
      end

      assert {:raise, %ArgumentError{}} = agrees(:shift_add, [<<>>, <<>>, -1])
    end

    test "without the guard, the report names m >= 0" do
      assert kept(:shift_add_unguarded) == [
               "acc[i - m]: bounds check kept; nothing proves i - m < length(acc) (it would follow from m >= 0)",
               "bufs[i]: bounds check kept; nothing proves 0 <= i (it would follow from m >= 0)",
               "acc[i]: bounds check kept; nothing proves 0 <= i (it would follow from m >= 0)"
             ]

      for m <- [-2, -1, 0, 1] do
        args = [G.pack(:i64, [1, 2, 3]), G.pack(:i64, [4, 5, 6]), m]
        assert {_, _} = agrees(:shift_add_unguarded, args)
      end
    end
  end

  describe "the select rule" do
    test "an arm that relies on its condition to drop a check is a branch" do
      refute kernel_c(K, "guarded_sub") =~ "defk_sub_i64"

      assert notes(:guarded_sub, :branch) == [
               {:branch,
                "if: a branch; not a select: arm 1 relies on its condition to drop a check"}
             ]

      for i <- [@i64_min, -1, 0, 5, @i64_max], w <- [@i64_min, -1, 0, 3, @i64_max] do
        assert {:ok, _} = agrees(:guarded_sub, [i, w])
      end
    end

    test "an arm that keeps its checks stays a select" do
      assert [{:select, _}] = notes(:plain_sub, :branch)

      for i <- [@i64_min, -1, 0, 5, @i64_max], w <- [@i64_min, -1, 0, 3, @i64_max] do
        assert {_, _} = agrees(:plain_sub, [i, w])
      end
    end
  end

  describe "conditions narrow" do
    test "the later arms of a cond, by the earlier conditions' negations" do
      assert bounds_proven?(K, :clamped_get)
      x = G.pack(:i64, [4, 5, 6])

      for k <- [@i64_min, -1, 0, 2, 3, @i64_max] do
        assert {:ok, _} = agrees(:clamped_get, [x, k])
      end
    end

    test "the rest of a for after its filters" do
      assert bounds_proven?(K, :filtered)
      x = G.pack(:i64, [1, 2, 3, 4])

      for w <- [@i64_min, -1, 0, 1, 4, 5, @i64_max] do
        assert {:ok, _} = agrees(:filtered, [x, w])
      end
    end

    test "the right side of an and" do
      assert bounds_proven?(K, :positive_at)
      x = G.pack(:i64, [1, -2])

      for k <- [@i64_min, -1, 0, 1, 2, @i64_max] do
        assert {:ok, _} = agrees(:positive_at, [x, k])
      end
    end

    test "the statements after an if whose else arm raises" do
      assert bounds_proven?(K, :checked_get)
      x = G.pack(:i64, [1, -2])

      for k <- [0, 1], do: assert({:ok, _} = agrees(:checked_get, [x, k]))

      for k <- [@i64_min, -1, 2, @i64_max] do
        assert {:raise, %ArgumentError{}} = agrees(:checked_get, [x, k])
      end
    end

    test "the body of a range that runs, by its start <= stop" do
      assert bounds_proven?(K, :first_sum)

      for n <- [-1, 0, 1, 2, 300] do
        assert {:ok, _} = agrees(:first_sum, [n])
      end

      # n - 1 overflows before the loop
      assert {:raise, %ArithmeticError{}} = agrees(:first_sum, [@i64_min])
    end
  end

  describe "a guard between two parameters" do
    @i32_max 0x7FFFFFFF
    @i32_min -0x80000000

    # the parameters rank in declaration order, so the guard's fact lands on
    # the later one whichever name sorts first
    for {kernel, sum} <- [{:gather, "base + idx[i]"}, {:gather_named, "off + ia[i]"}] do
      test "#{kernel}: the offset plus an i32 element needs no overflow check" do
        assert {:dropped, "#{unquote(sum)}: no overflow check"} in notes(unquote(kernel), :check)
        # the gather itself depends on the indices: its check stays
        assert [text] = kept(unquote(kernel))
        assert text =~ "bounds check kept; nothing proves 0 <= #{unquote(sum)}"

        x = f32s(Enum.to_list(1..8))

        for idx <- [[], [0], [7, 0, 3], [-1], [8]], base <- [0, 1, 8] do
          assert {_, _} = agrees(unquote(kernel), [G.pack(:i32, idx), x, base])
        end

        # the extremes of the dropped check: the sum fits, the access raises
        for idx <- [@i32_max, @i32_min], base <- [0, 8] do
          assert {:raise, %Enum.OutOfBoundsError{}} =
                   agrees(unquote(kernel), [G.pack(:i32, [idx]), x, base])
        end

        for base <- [-1, 9, @i64_min, @i64_max] do
          assert {:raise, %ArgumentError{}} =
                   agrees(unquote(kernel), [G.pack(:i32, [0]), x, base])
        end
      end
    end
  end

  describe "flagged strips" do
    test "a guard on a value the strip computes with a check makes no access fixed" do
      c = kernel_c(K, "guarded_shift")
      # x[j] is unchecked, its proof names j, and j is not fixed: checked
      assert c =~ ~r/\(p_x\)\.data\[v_j_\d+\]/
      refute c =~ "DEFK_NF_"
      assert [{:checked, _}] = notes(:guarded_shift, :nonfinite)

      x = f64s([1, 2, 3, 4])

      for k <- [@i64_min, -5, -1, 0, 1, 3, 4, @i64_max] do
        assert {_, _} = agrees(:guarded_shift, [x, k])
      end
    end

    test "a condition on a checked operand narrows nothing" do
      c = kernel_c(K, "guarded_offset")
      refute c =~ ~r/\(p_x\)\.data\[/
      assert c =~ "#define defk_get_in_f64 DEFK_NF_get_in_f64"
      assert [{:flagged, _}] = notes(:guarded_offset, :nonfinite)

      x = f64s([1, 2, 3, 4])

      for k <- [@i64_min, -5, -1, 0, 1, 3, 4, @i64_max] do
        assert {_, _} = agrees(:guarded_offset, [x, k])
      end
    end
  end

  agreement(K, [
    :rolling_diff,
    :rolling_diff_unguarded,
    :guarded_sub,
    :plain_sub,
    :clamped_get,
    :filtered,
    :positive_at,
    :checked_get,
    :guarded_shift,
    :guarded_offset,
    first_sum: [args: StreamData.fixed_list([G.i64(-3..40)])],
    shift_add: [args: StreamData.fixed_list([G.array(:i64), G.array(:i64), G.i64(-3..20)])],
    shift_add_unguarded: [
      args: StreamData.fixed_list([G.array(:i64), G.array(:i64), G.i64(-3..20)])
    ],
    gather: [args: StreamData.fixed_list([G.array(:i32), G.array(:f32), G.i64(-3..20)])],
    gather_named: [args: StreamData.fixed_list([G.array(:i32), G.array(:f32), G.i64(-3..20)])]
  ])

  # ------------------------------------------------------ soundness --
  # A generated kernel over a :: [u8], x :: i64 and y :: i64:
  #
  #   if GUARD, do: raise(ArgumentError, "g")
  #   n = length(a); out = alloc(u8, SIZE)
  #   for i <- S..E//K do BODY end
  #
  # with BODY one of
  #
  #   if COND do out[IDX] = 1 end            (an arm)
  #   (a filter: for i <- S..E//K, COND do out[IDX] = 1 end)
  #   if COND, do: raise(...); out[IDX] = 1  (a raising guard in the loop)
  #
  # GUARD and COND are comparisons of linear expressions (and, or, not of
  # them), IDX a linear expression of i, n, x and y. Everything in the loop
  # is linear in i, so where a condition, the index or an operation in them
  # changes side is a root of a linear function: the loop is checked at its
  # ends and at those roots (step-aligned), which is where a wrong fact
  # would first show.

  defp kernel({guard, size, s, e, k, form, cond, idx}) do
    store = quote(do: out[unquote(idx)] = 1)

    loop =
      case form do
        :arm ->
          quote do
            for i <- unquote(s)..unquote(e)//unquote(k) do
              if unquote(cond), do: unquote(store)
            end
          end

        :filter ->
          quote do
            for i <- unquote(s)..unquote(e)//unquote(k), unquote(cond), do: unquote(store)
          end

        :raise ->
          quote do
            for i <- unquote(s)..unquote(e)//unquote(k) do
              if unquote(cond), do: raise(ArgumentError, "c")
              unquote(store)
            end
          end
      end

    body =
      quote do
        if unquote(guard), do: raise(ArgumentError, "g")
        n = length(a)
        out = alloc(u8, unquote(size))
        unquote(loop)
        out
      end

    %{
      head: quote(do: f(a :: [u8], x :: i64, y :: i64) :: [u8]),
      opts: [],
      body: body,
      line: 1
    }
  end

  defp c_of(kernel) do
    {c, _, _} = Defk.Compiler.compile(Defk.ConditionFactsTest.Probe, [kernel], nil)
    c
  end

  defp v(name), do: {name, [], nil}

  # a linear expression over `atoms`: sums and differences, products by a
  # small literal, and small constants
  defp linear(atoms, depth) do
    leaf = StreamData.one_of([StreamData.member_of(atoms), StreamData.integer(-3..5)])

    if depth == 0 do
      leaf
    else
      sub = linear(atoms, depth - 1)

      StreamData.frequency([
        {3, leaf},
        {3,
         StreamData.map(StreamData.tuple({StreamData.member_of([:+, :-]), sub, sub}), fn {op, a,
                                                                                          b} ->
           {op, [], [a, b]}
         end)},
        {1,
         StreamData.map(StreamData.tuple({StreamData.integer(-2..3), sub}), fn {c, a} ->
           {:*, [], [c, a]}
         end)}
      ])
    end
  end

  # the shapes real conditions take, each with a small offset, more often
  # than a random comparison
  defp shaped(templates, atoms) do
    off = StreamData.frequency([{3, StreamData.constant(0)}, {1, StreamData.integer(-2..2)}])

    StreamData.frequency([
      {3,
       StreamData.bind(StreamData.member_of(templates), fn {op, l, r} ->
         StreamData.map(off, fn
           0 -> {op, [], [l, r]}
           c -> {op, [], [l, {:+, [], [r, c]}]}
         end)
       end)},
      {1,
       StreamData.map(
         StreamData.tuple({
           StreamData.member_of([:<, :<=, :==, :>=, :>, :!=]),
           linear(atoms, 1),
           linear(atoms, 1)
         }),
         fn {op, l, r} -> {op, [], [l, r]} end
       )}
    ])
  end

  # comparisons joined by and, or and not
  defp boolean(cmp, depth) do
    if depth == 0 do
      cmp
    else
      sub = boolean(cmp, depth - 1)

      StreamData.frequency([
        {4, cmp},
        {2,
         StreamData.map(StreamData.tuple({StreamData.member_of([:and, :or]), sub, sub}), fn {op,
                                                                                             a, b} ->
           {op, [], [a, b]}
         end)},
        {1, StreamData.map(sub, &{:not, [], [&1]})}
      ])
    end
  end

  # a whole kernel of a real shape, each part with a small offset that is
  # most often 0, or each part picked on its own
  defp probe, do: StreamData.frequency([{2, scenario()}, {1, independent()}])

  defp scenario do
    off = StreamData.frequency([{5, StreamData.constant(0)}, {1, StreamData.integer(-2..2)}])

    StreamData.tuple({
      StreamData.member_of([:window, :shift, :clamp, :pinned, :nonempty, :guarded]),
      StreamData.list_of(off, length: 4),
      StreamData.member_of([:arm, :filter]),
      StreamData.member_of([1, 2])
    })
    |> StreamData.map(fn {shape, offs, form, step} -> shape(shape, offs, form, step) end)
  end

  defp plus(t, 0), do: t
  defp plus(t, c), do: {:+, [], [t, c]}

  defp cmp(op, l, r, c), do: {op, [], [l, plus(r, c)]}

  defp shape(shape, [o1, o2, o3, o4], form, step) do
    {x, y, n, i, out} = {v(:x), v(:y), v(:n), v(:i), quote(do: length(out))}
    len_a = quote(do: length(a))
    last = plus(quote(do: unquote(out) - 1), o3)

    case shape do
      # a rolling window: i - x under i >= x, after a raise when x < 1
      :window ->
        {cmp(:<, x, 1, o1), len_a, 0, last, step, form, cmp(:>=, i, x, o2),
         plus(quote(do: unquote(i) - unquote(x)), o4)}

      # a shifted block: i <- x.., i - x, after a raise when x < 0
      :shift ->
        {cmp(:<, x, 0, o1), len_a, plus(x, o2), last, step, form, true,
         plus(quote(do: unquote(i) - unquote(x)), o4)}

      # an offset index clamped by a condition on both sides
      :clamp ->
        ix = quote(do: unquote(i) + unquote(x))

        {false, len_a, 0, last, step, form,
         {:and, [], [cmp(:>=, ix, 0, o1), cmp(:<, ix, out, o2)]}, plus(ix, o4)}

      # an argument index checked once, before the loop
      :pinned ->
        {{:or, [], [cmp(:<, y, 0, o1), cmp(:>=, y, len_a, o2)]}, len_a, 0, last, step, form, true,
         plus(y, o4)}

      # 0..(x - 1) runs only when x >= 1: out[x - 1 - i] and out[0]
      :nonempty ->
        {false, quote(do: max(unquote(x), 0)), 0, plus(quote(do: unquote(x) - 1), o3), step, form,
         true, plus(quote(do: unquote(x) - 1 - unquote(i)), o4 + o1 + o2)}

      # a raising guard inside the loop
      :guarded ->
        iy = quote(do: unquote(i) - unquote(y))

        {false, len_a, 0, plus(quote(do: unquote(n) - 1), o3), step, :raise,
         {:not, [], [{:and, [], [cmp(:>=, iy, 0, o1), cmp(:<, iy, out, o2)]}]}, plus(iy, o4)}
    end
  end

  defp independent do
    {x, y, n, i, out} = {v(:x), v(:y), v(:n), v(:i), quote(do: length(out))}
    len_a = quote(do: length(a))
    pos_x = quote(do: max(unquote(x), 0))

    guard =
      StreamData.frequency([
        {1, StreamData.constant(false)},
        {3,
         boolean(
           shaped(
             [
               {:<, x, 0},
               {:<, x, 1},
               {:<, y, 0},
               {:>, x, len_a},
               {:>, y, x},
               {:<, len_a, y}
             ],
             [x, y, len_a]
           ),
           1
         )}
      ])

    size = StreamData.member_of([len_a, pos_x, quote(do: min(unquote(len_a), unquote(pos_x)))])

    start =
      StreamData.member_of([0, x, y, quote(do: unquote(n) - 1), quote(do: unquote(out) - 1)])

    stop = StreamData.member_of([0, x, y, quote(do: unquote(n) - 1), quote(do: unquote(out) - 1)])

    cond =
      boolean(
        shaped(
          [
            {:>=, i, x},
            {:<, i, y},
            {:>=, i, 0},
            {:<, i, out},
            {:<, quote(do: unquote(i) + unquote(x)), out},
            {:>=, quote(do: unquote(i) - unquote(y)), 0},
            {:>, x, 0},
            {:<=, y, n}
          ],
          [i, x, y, n, out]
        ),
        2
      )

    idx =
      StreamData.frequency([
        {3,
         StreamData.member_of([
           i,
           quote(do: unquote(i) - unquote(x)),
           quote(do: unquote(i) + unquote(x)),
           quote(do: unquote(i) - unquote(y)),
           quote(do: unquote(n) - 1 - unquote(i)),
           x,
           y
         ])},
        {1, linear([i, x, y, n], 2)}
      ])

    StreamData.tuple({
      guard,
      size,
      start,
      stop,
      StreamData.member_of([1, 2, -1, -2]),
      StreamData.member_of([:arm, :filter, :raise]),
      cond,
      idx
    })
  end

  # the value of an expression and the results of its arithmetic, each of
  # which must fit in i64 or the kernel raises there (Defk.TestKit.eval_ops/2)
  defp ev(ast, env), do: eval_ops(ast, env)
  defp fits?(ops), do: fits_i64?(ops)

  @lens [0, 1, 2, 3, 7, 2 ** 32, @len_max]
  @xs [@i64_min, -(2 ** 62), -7, -1, 0, 1, 2, 5, 2 ** 32, 2 ** 62, @i64_max]

  # every linear function of i in the loop: the operands of each comparison
  # (their difference), the index and each operation's result
  defp linear_parts(ast) do
    {_, parts} =
      Macro.prewalk(ast, [], fn
        {op, _, [a, b]} = node, acc when op in [:<, :<=, :==, :>=, :>, :!=] ->
          {node, [{:-, [], [a, b]} | acc]}

        {op, _, [_, _]} = node, acc when op in [:+, :-, :*] ->
          {node, [node | acc]}

        node, acc ->
          {node, acc}
      end)

    parts
  end

  # The iterations where something may change: the ends, and around each
  # root of a linear function f(i) = f0 + d * i (and of f(i) = limit for
  # the i64 limits and the index's bounds), aligned to the step.
  defp interesting(env, first, last, k, fs) do
    lo = min(first, last)
    hi = max(first, last)

    size = env[{:len, :out}]

    roots =
      for f <- fs,
          {f0, _} = ev(f, Map.put(env, :i, 0)),
          {f1, _} = ev(f, Map.put(env, :i, 1)),
          d = f1 - f0,
          d != 0,
          t <- [@i64_min, -1, 0, size - 1, size, @i64_max],
          r = div(t - f0, d),
          c <- [r - 1, r, r + 1],
          do: c

    for c <- [first, last | roots],
        c >= lo and c <= hi,
        a <- align(c, first, k),
        a >= lo and a <= hi,
        uniq: true,
        do: a
  end

  # the iterations of first..//k next to c
  defp align(c, first, k) do
    m = Integer.floor_div(c - first, k)
    [first + m * k, first + (m + 1) * k]
  end

  # the iterations in the order the loop runs them
  defp in_order(is, k), do: if(k > 0, do: Enum.sort(is), else: Enum.sort(is, :desc))

  # every input: the env after the prologue and the loop's first and last
  # counter values, or :skip when the kernel raises before the loop or the
  # loop does not run
  defp setups({guard, size, s, e, k, _form, _cond, _idx}) do
    for la <- @lens, x <- @xs, y <- @xs, setup = setup(guard, size, s, e, k, la, x, y), do: setup
  end

  defp setup(guard, size, s, e, k, la, x, y) do
    env = %{{:len, :a} => la, x: x, y: y, n: la}
    {g, og} = ev(guard, env)
    {sv, os} = ev(size, env)

    with true <- fits?(og) and not g,
         true <- fits?(os) and sv in 0..@len_max//1,
         env = Map.put(env, {:len, :out}, sv),
         {first, o1} = ev(s, env),
         {stop, o2} = ev(e, env),
         true <- fits?(o1 ++ o2),
         {:ok, last} <- last(first, stop, k) do
      {env, first, last}
    else
      _ -> false
    end
  end

  defp last(first, stop, k) do
    cond do
      k > 0 and stop > @i64_max - k -> :limit
      k < 0 and stop < @i64_min - k -> :limit
      k > 0 and first <= stop -> {:ok, first + k * div(stop - first, k)}
      k < 0 and first >= stop -> {:ok, first + k * div(first - stop, -k)}
      true -> :empty
    end
  end

  # The kernel's run at the interesting iterations, in order, until one
  # raises: {i, index, the index's operations} for each store it reaches.
  defp stores({env, first, last}, k, form, cond, idx) do
    fs = linear_parts(cond) ++ linear_parts(idx) ++ [idx]

    env
    |> interesting(first, last, k, fs)
    |> in_order(k)
    |> Enum.reduce_while([], fn i, acc ->
      env = Map.put(env, :i, i)
      {c, oc} = ev(cond, env)
      {iv, oi} = ev(idx, env)

      cond do
        not fits?(oc) -> {:halt, acc}
        form == :raise and c -> {:halt, acc}
        form != :raise and not c -> {:cont, acc}
        not fits?(oi) -> {:halt, acc}
        true -> {:cont, [{i, iv, oi} | acc]}
      end
    end)
  end

  defp shown({guard, size, s, e, k, form, cond, idx}) do
    "guard #{Macro.to_string(guard)}; out = alloc(u8, #{Macro.to_string(size)}); " <>
      "for i <- #{Macro.to_string(s)}..#{Macro.to_string(e)}//#{k}, #{form} " <>
      "#{Macro.to_string(cond)}: out[#{Macro.to_string(idx)}]"
  end

  @checked ~r/defk_(add|sub|mul|neg)_i64\(/

  defp sound(shape) do
    {_guard, _size, _s, _e, k, form, cond, idx} = shape
    c = c_of(kernel(shape))
    store_line = c |> String.split("\n") |> Enum.filter(&(&1 =~ ~r/defk_put_u8\(|\.data\[/))
    unchecked? = not (c =~ "defk_put_u8")
    exact? = not Enum.any?(store_line, &(&1 =~ @checked))

    if unchecked? or exact? do
      for {env, _, _} = setup <- setups(shape),
          {i, iv, ops} <- stores(setup, k, form, cond, idx) do
        where =
          "length(a) = #{env[{:len, :a}]}, x = #{env.x}, y = #{env.y}, i = #{i} (#{shown(shape)})"

        size_v = env[{:len, :out}]

        unchecked? &&
          assert iv in 0..(size_v - 1)//1,
                 "out[...] is unchecked, but is #{iv}, outside 0..#{size_v - 1}, for #{where}"

        exact? && assert fits?(ops), "the index has no overflow check, but overflows for #{where}"
      end
    end
  end

  # Each case compiles a kernel (C codegen, no clang) and walks ~800
  # inputs. The :deep twin runs @deep_runs.
  @runs 200
  @deep_runs 3_000

  property "a check dropped by a condition is never wrong" do
    check(all(shape <- probe(), max_runs: @runs, do: sound(shape)))
  end

  @tag deep: true, timeout: 600_000
  property "a check dropped by a condition is never wrong (deep)" do
    check(all(shape <- probe(), max_runs: @deep_runs, do: sound(shape)))
  end
end
