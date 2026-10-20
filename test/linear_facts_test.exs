# Linear range facts (ADR-0007, step 2): an i64 binding is an atom of the
# symbolic bounds, and values carry the form they are exactly through
# checked +, - and * by a literal. min/max bound by their operands, a range
# counter by its start and stop (either step sign), alloc(e, n) has length
# n, a copy its original's length, and an if/cond/case value the bounds
# every arm shares. The kernels below are the acceptance cases: two-input
# elementwise work into alloc(e, min(...)) and a block sum at a variable
# offset.
#
# The soundness properties compile generated kernels with random linear
# shapes over two lengths and an i64 argument (no clang: the C is read) and
# check every dropped bounds and overflow check against the arithmetic, on
# lengths and arguments at the edges of their ranges.

defmodule Defk.LinearFactsTest.K do
  use Defk

  # out = alloc(e, n) with n = min(length(a), length(b)): len(out) == n
  defk mix2(a :: [i16], b :: [i16]) :: [i16] do
    n = min(length(a), length(b))
    out = alloc(i16, n)

    for i <- 0..(n - 1)//1 do
      out[i] = div(a[i] + b[i], 2)
    end

    out
  end

  # n streams of m samples concatenated in bufs, summed: base + i is below
  # length(bufs) from i's bound min(..., length(bufs) - base) - 1
  defk add_blocks(bufs :: [i16], n :: i64) :: [i64] do
    m = div(length(bufs), n)
    sums = alloc(i64, m)

    for j <- 0..(n - 1)//1 do
      base = max(j * m, 0)

      for i <- 0..(min(length(sums), length(bufs) - base) - 1)//1 do
        sums[i] = sums[i] + bufs[base + i]
      end
    end

    sums
  end

  # counting down: n - 1 >= i >= 0
  defk reverse(a :: [i64]) :: [i64] do
    n = length(a)
    out = alloc(i64, n)

    for i <- (n - 1)..0//-1 do
      out[n - 1 - i] = a[i]
    end

    out
  end

  # a counting-down step of 2 from a start below a length
  defk odd_down(a :: [i64], k :: i64) :: i64 do
    s = min(k, length(a) - 1)

    for i <- s..0//-2, reduce: 0 do
      acc -> acc + a[i]
    end
  end

  # the branch's value has the bound both arms share: last <= m - 1
  defk head(a :: [i64], b :: [i64], flag :: i64) :: [i64] do
    m = min(length(a), length(b))
    out = alloc(i64, m)
    last = if flag == 0, do: m - 1, else: m - 2

    for i <- 0..last//1 do
      out[i] = a[i] - b[i]
    end

    out
  end

  # a copy has its original's length both ways: i < length(c) gives
  # i < length(a)
  defk bump_first(a :: [i64]) :: i64 do
    c = a
    c[0] = 1

    for i <- 0..(length(c) - 1)//1, reduce: 0 do
      acc -> acc + a[i] - c[i]
    end
  end

  # an offset argument: x + i < length(a) for i <= length(a) - x - 1, and
  # 0 <= x + i from x = max(x, 0)
  defk window(a :: [u8], x :: i64) :: i64 do
    x = max(x, 0)

    for i <- 0..(length(a) - x - 1)//1, reduce: 0 do
      acc -> acc + a[x + i]
    end
  end
end

defmodule Defk.LinearFactsTest do
  use ExUnit.Case, async: true
  use Defk.Properties

  import Defk.TestKit, only: [kernel_c: 2, bounds_check_free?: 2, bounds_proven?: 2]

  alias Defk.LinearFactsTest.K

  # lengths are below 2^61 (DEFK_ALLOC_MAX_BYTES, and the largest binary)
  @len_max 2 ** 61 - 1
  @i64_min -0x8000000000000000
  @i64_max 0x7FFFFFFFFFFFFFFF

  defp proven?(kernel), do: bounds_proven?(K, kernel)

  defp agrees(fun, args),
    do: Defk.Test.assert_agrees(K, fun, args, forced_yields: true)

  describe "alloc(e, n) has length n" do
    test "out[i], a[i] and b[i] keep no bounds check for n = min(length(a), length(b))" do
      assert proven?(:mix2)
      # end to end: the C calls no checked access
      assert bounds_check_free?(K, "mix2")

      for {a, b} <- [{[], []}, {[2], []}, {[1, 3, -5], [3, 1]}, {Enum.to_list(1..3000), [7]}] do
        {a, b} = {G.pack(:i16, a), G.pack(:i16, b)}
        assert {:ok, _} = agrees(:mix2, [a, b])
      end
    end
  end

  describe "a block at a variable offset" do
    test "bufs[base + i] and sums[i] keep no bounds check, and base + i no overflow check" do
      assert proven?(:add_blocks)
      refute kernel_c(K, "add_blocks") =~ ~r/defk_add_i64\([^;]*v_base_\d+ *,/
      assert kernel_c(K, "add_blocks") =~ ~r/\(v_base_\d+ \+ v_i_\d+\)/
    end

    test "sums the blocks as Elixir does, raising alike for n <= 0" do
      bufs = G.pack(:i16, Enum.to_list(1..12))

      for n <- [1, 2, 3, 4, 5, 12, 13] do
        assert {:ok, _} = agrees(:add_blocks, [bufs, n])
      end

      for n <- [0, -1, -3] do
        assert {:raise, _} = agrees(:add_blocks, [bufs, n])
      end

      assert {:ok, _} = agrees(:add_blocks, [<<>>, 3])
    end
  end

  describe "a range counting down" do
    test "out[n - 1 - i] and a[i] keep no bounds check" do
      assert proven?(:reverse)

      for a <- [[], [1], [1, 2, 3], Enum.to_list(1..3000)] do
        assert {:ok, _} = agrees(:reverse, [G.pack(:i64, a)])
      end
    end

    test "a step of -2 from min(k, length(a) - 1) keeps no bounds check" do
      assert proven?(:odd_down)
      a = G.pack(:i64, [1, 2, 3, 4, 5])

      for k <- [@i64_min, -1, 0, 1, 2, 4, 5, 100, @i64_max] do
        assert {:ok, _} = agrees(:odd_down, [a, k])
      end
    end
  end

  describe "the value of a branch" do
    test "keeps the bound every arm shares" do
      assert proven?(:head)

      for flag <- [0, 1], {a, b} <- [{[], []}, {[1, 2], [5]}, {[1, 2, 3], [4, 5, 6, 7]}] do
        assert {:ok, _} = agrees(:head, [G.pack(:i64, a), G.pack(:i64, b), flag])
      end
    end
  end

  describe "a copy" do
    test "has its original's length both ways" do
      # c[0] = 1 keeps its check (a is maybe empty); the reads drop theirs
      refute kernel_c(K, "bump_first") =~ ~r/defk_get_[a-z0-9]+\(ctx/
      assert {:raise, _} = agrees(:bump_first, [<<>>])

      for a <- [[5], [1, 2, 3]] do
        assert {:ok, _} = agrees(:bump_first, [G.pack(:i64, a)])
      end
    end
  end

  describe "an offset argument" do
    test "a[x + i] keeps no bounds check, and x + i no overflow check" do
      assert proven?(:window)
      refute kernel_c(K, "window") =~ "defk_add_i64(ctx, v_x"

      for x <- [@i64_min, -1, 0, 1, 3, 7, 8, @i64_max] do
        assert {:ok, _} = agrees(:window, [<<1, 2, 3, 4, 5, 6, 7>>, x])
      end
    end
  end

  agreement(K, [
    :mix2,
    :reverse,
    :odd_down,
    :head,
    :window,
    bump_first: [args: StreamData.fixed_list([G.array(:i64)])],
    add_blocks: [
      args: StreamData.fixed_list([G.array(:i16), G.i64(-3..20)])
    ]
  ])

  # ------------------------------------------------------ soundness --
  # A generated kernel over a :: [u8], b :: [u8] and x :: i64:
  #
  #   n = N; out = alloc(u8, SIZE); base = BASE
  #   for i <- S..E//K do out[IDX] = 1 end
  #
  # N is an expression of length(a), length(b) and x; SIZE of n, length(a)
  # and x; BASE of n, x and length(out); S and E of those and base; IDX a
  # linear expression of i, base, n and x. Each is drawn from +, -, min,
  # max and products by a literal (IDX: +, - and products only, so that its
  # extremes are at the ends of the range).

  defp kernel(n, size, base, s, e, k, idx) do
    body =
      quote do
        n = unquote(n)
        out = alloc(u8, unquote(size))
        base = unquote(base)

        for i <- unquote(s)..unquote(e)//unquote(k) do
          out[unquote(idx)] = 1
        end

        out
      end

    %{head: quote(do: f(a :: [u8], b :: [u8], x :: i64) :: [u8]), opts: [], body: body, line: 1}
  end

  defp c_of(kernel) do
    {c, _, _} = Defk.Compiler.compile(Defk.LinearFactsTest.Probe, [kernel], nil)
    c
  end

  defp v(name), do: {name, [], nil}

  defp len(name), do: quote(do: length(unquote(v(name))))

  defp expr(atoms, ops, depth) do
    leaf = StreamData.one_of([StreamData.member_of(atoms), StreamData.integer(-3..5)])

    if depth == 0 do
      leaf
    else
      sub = expr(atoms, ops, depth - 1)

      StreamData.frequency([
        {3, leaf},
        {3,
         StreamData.map(StreamData.tuple({StreamData.member_of(ops), sub, sub}), fn {op, a, b} ->
           {op, [], [a, b]}
         end)},
        {1,
         StreamData.map(StreamData.tuple({StreamData.integer(-3..4), sub}), fn {k, a} ->
           {:*, [], [k, a]}
         end)}
      ])
    end
  end

  @all [:+, :-, :min, :max]

  # the shapes real kernels use (`templates`, each with a small offset on
  # either side of the boundary), more often than a random tree of `atoms`
  defp pick(templates, atoms, ops, depth) do
    off = StreamData.integer(-2..2)

    shaped =
      StreamData.bind(StreamData.member_of(templates), fn t ->
        StreamData.map(off, fn c -> if c == 0, do: t, else: {:+, [], [t, c]} end)
      end)

    StreamData.frequency([{3, shaped}, {1, expr(atoms, ops, depth)}])
  end

  # a whole kernel of a real shape (pic, siy loop 1 and its shifted twin,
  # a reverse, a window at an offset argument), each part with a small
  # offset that is most often 0, or each part picked on its own
  defp probe, do: StreamData.frequency([{2, scenario()}, {1, independent()}])

  defp scenario do
    {a, b, x, n, base, out, i} = {len(:a), len(:b), v(:x), v(:n), v(:base), len(:out), v(:i)}
    pos = quote(do: max(unquote(x), 0))

    shapes = [
      [quote(do: min(unquote(a), unquote(b))), n, 0, 0, quote(do: unquote(n) - 1), 1, i],
      [
        a,
        n,
        pos,
        0,
        quote(do: min(unquote(out), unquote(a) - unquote(base)) - 1),
        1,
        quote(do: unquote(base) + unquote(i))
      ],
      [
        a,
        n,
        quote(do: max(min(unquote(x), unquote(n)), 0)),
        base,
        quote(do: unquote(out) - 1),
        1,
        quote(do: unquote(i) - unquote(base))
      ],
      [a, n, 0, quote(do: unquote(n) - 1), 0, -1, quote(do: unquote(n) - 1 - unquote(i))],
      [
        a,
        n,
        pos,
        0,
        quote(do: unquote(a) - unquote(base) - 1),
        1,
        quote(do: unquote(base) + unquote(i))
      ],
      [pos, n, 0, 0, quote(do: unquote(n) - 1), 2, i]
    ]

    off = StreamData.frequency([{4, StreamData.constant(0)}, {1, StreamData.integer(-2..2)}])

    StreamData.tuple({
      StreamData.member_of(shapes),
      StreamData.list_of(off, length: 7),
      StreamData.member_of([1, 2])
    })
    |> StreamData.map(fn {shape, offs, step} -> offset(shape, offs, step) end)
  end

  # each part with its offset, and the step (part 5) scaled
  defp offset(shape, offs, step) do
    shape
    |> Enum.zip(offs)
    |> Enum.with_index()
    |> Enum.map(fn
      {{k, _}, 5} -> k * step
      {{t, 0}, _} -> t
      {{t, c}, _} -> {:+, [], [t, c]}
    end)
  end

  defp independent do
    {a, b, x, n, base, out, i} = {len(:a), len(:b), v(:x), v(:n), v(:base), len(:out), v(:i)}

    StreamData.fixed_list([
      pick(
        [
          a,
          quote(do: min(unquote(a), unquote(b))),
          quote(do: min(unquote(a), unquote(x))),
          quote(do: max(unquote(x), 0)),
          quote(do: unquote(a) - unquote(x))
        ],
        [a, b, x],
        @all,
        2
      ),
      pick([n, a], [n, a, x], @all, 1),
      pick(
        [quote(do: max(unquote(x), 0)), quote(do: min(unquote(x), unquote(n))), x, 0],
        [n, x, out],
        @all,
        1
      ),
      pick([0, base, x, quote(do: unquote(n) - 1)], [n, base, out, a, x], @all, 2),
      pick(
        [
          quote(do: unquote(n) - 1),
          quote(do: unquote(out) - 1),
          quote(do: unquote(out) - unquote(base) - 1),
          quote(do: min(unquote(out), unquote(a) - unquote(base)) - 1),
          quote(do: min(unquote(out), unquote(n)) - 1),
          0
        ],
        [n, base, out, a, x],
        @all,
        3
      ),
      StreamData.member_of([1, 2, -1, -2]),
      pick(
        [
          i,
          quote(do: unquote(base) + unquote(i)),
          quote(do: unquote(i) - unquote(base)),
          quote(do: unquote(n) - 1 - unquote(i)),
          quote(do: unquote(x) + unquote(i)),
          quote(do: 2 * unquote(i))
        ],
        [i, base, n, x],
        [:+, :-],
        2
      )
    ])
  end

  # the value of an expression and the results of its arithmetic (each must
  # fit in i64, or the kernel raises at it)
  defp ev({:length, _, [{name, _, _}]}, env), do: {Map.fetch!(env, {:len, name}), []}

  defp ev({name, _, ctx}, env) when is_atom(name) and is_atom(ctx),
    do: {Map.fetch!(env, name), []}

  defp ev(k, _env) when is_integer(k), do: {k, []}

  defp ev({op, _, [a, b]}, env) do
    {{x, ox}, {y, oy}} = {ev(a, env), ev(b, env)}

    case op do
      :+ -> {x + y, ox ++ oy ++ [x + y]}
      :- -> {x - y, ox ++ oy ++ [x - y]}
      :* -> {x * y, ox ++ oy ++ [x * y]}
      :min -> {min(x, y), ox ++ oy}
      :max -> {max(x, y), ox ++ oy}
    end
  end

  defp fits?(ops), do: Enum.all?(ops, &(&1 >= @i64_min and &1 <= @i64_max))

  @lens [0, 1, 2, 3, 7, 2 ** 32, @len_max - 1, @len_max]
  @xs [
    @i64_min,
    @i64_min + 1,
    -(2 ** 62),
    -7,
    -1,
    0,
    1,
    2,
    5,
    2 ** 61,
    2 ** 62,
    @i64_max - 1,
    @i64_max
  ]

  # What the kernel computes for every input: {pre, loop}, the arithmetic
  # before the loop (all of it, the input raising or not) and, for a loop
  # that runs, {env, first, last}, else nil.
  defp runs(shape) do
    for la <- @lens,
        lb <- @lens,
        x <- @xs,
        do: run(shape, %{{:len, :a} => la, {:len, :b} => lb, x: x})
  end

  defp run([n, size, base, s, e, k, _idx], env) do
    {nv, on} = ev(n, env)
    env = Map.put(env, :n, nv)
    {sv, os} = ev(size, env)

    if fits?(on ++ os) and sv in 0..@len_max//1 do
      env = Map.put(env, {:len, :out}, sv)
      {bv, ob} = ev(base, env)
      env = Map.put(env, :base, bv)
      {first, o1} = ev(s, env)
      {stop, o2} = ev(e, env)
      pre = on ++ os ++ ob ++ o1 ++ o2
      {pre, if(fits?(pre), do: loop(env, first, stop, k))}
    else
      {on ++ os, nil}
    end
  end

  # the counter's first and last values, or nil when the loop does not run
  # (empty, or raising at the range limit: a stop within one step of i64's)
  defp loop(env, first, stop, k) do
    cond do
      k > 0 and stop > @i64_max - k -> nil
      k < 0 and stop < @i64_min - k -> nil
      k > 0 and first <= stop -> {env, first, first + k * div(stop - first, k)}
      k < 0 and first >= stop -> {env, first, first + k * div(first - stop, -k)}
      true -> nil
    end
  end

  defp shown([n, size, base, s, e, k, idx]) do
    "n = #{Macro.to_string(n)}; out = alloc(u8, #{Macro.to_string(size)}); " <>
      "base = #{Macro.to_string(base)}; for i <- #{Macro.to_string(s)}..#{Macro.to_string(e)}//#{k}, " <>
      "out[#{Macro.to_string(idx)}]"
  end

  # the index at the loop's two ends (IDX is linear in i, so its extremes
  # and those of each of its operations are there)
  defp ends({env, first, last}, idx) do
    for i <- Enum.uniq([first, last]) do
      {iv, ops} = ev(idx, Map.put(env, :i, i))
      {env, i, iv, ops}
    end
  end

  defp bounds_sound(shape) do
    [n, size, base, s, e, k, idx] = shape

    if not (c_of(kernel(n, size, base, s, e, k, idx)) =~ "defk_put_u8") do
      for {_pre, loop} <- runs(shape),
          loop != nil,
          {env, i, iv, ops} <- ends(loop, idx),
          fits?(ops) do
        size_v = env[{:len, :out}]

        if iv not in 0..(size_v - 1)//1 do
          flunk(
            "out[#{Macro.to_string(idx)}] is unchecked, but for length(a) = " <>
              "#{env[{:len, :a}]}, length(b) = #{env[{:len, :b}]}, x = #{env.x}, i = #{i} " <>
              "it is #{iv}, outside 0..#{size_v - 1} (#{shown(shape)})"
          )
        end
      end
    end
  end

  @checked ~r/defk_(add|sub|mul|neg)_i64\(/

  defp overflow_sound(shape) do
    [n, size, base, s, e, k, idx] = shape
    c = c_of(kernel(n, size, base, s, e, k, idx))

    store =
      c
      |> String.split("\n")
      |> Enum.filter(&(&1 =~ ~r/defk_put_u8\(|\.data\[/))
      |> Enum.join("\n")

    # nothing checked: no arithmetic the kernel reaches overflows
    if not (c =~ @checked) do
      for {pre, _loop} <- runs(shape), not fits?(pre) do
        flunk("#{shown(shape)} has no overflow check, but overflows before its loop")
      end
    end

    # the index's arithmetic unchecked: it never overflows where it runs
    if not (store =~ @checked) do
      for {_pre, loop} <- runs(shape),
          loop != nil,
          {env, i, _iv, ops} <- ends(loop, idx),
          not fits?(ops) do
        flunk(
          "#{Macro.to_string(idx)} has no overflow check, but overflows for length(a) = " <>
            "#{env[{:len, :a}]}, length(b) = #{env[{:len, :b}]}, x = #{env.x}, i = #{i} " <>
            "(#{shown(shape)})"
        )
      end
    end
  end

  # Each case compiles a kernel (C codegen, no clang) and walks ~800
  # inputs. The :deep twins run @deep_runs.
  @runs 300
  @deep_runs 3_000

  property "a dropped bounds check over linear shapes is never wrong" do
    check(all(shape <- probe(), max_runs: @runs, do: bounds_sound(shape)))
  end

  property "a dropped overflow check over linear shapes is never wrong" do
    check(all(shape <- probe(), max_runs: @runs, do: overflow_sound(shape)))
  end

  @tag deep: true, timeout: 600_000
  property "a dropped bounds check over linear shapes is never wrong (deep)" do
    check(all(shape <- probe(), max_runs: @deep_runs, do: bounds_sound(shape)))
  end

  @tag deep: true, timeout: 600_000
  property "a dropped overflow check over linear shapes is never wrong (deep)" do
    check(all(shape <- probe(), max_runs: @deep_runs, do: overflow_sound(shape)))
  end
end
