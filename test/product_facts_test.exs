# Products of two variables in the range facts (ADR-0007, step 4): a form
# may hold a monomial of two atoms (`r * dim`), so a row-major index with a
# runtime row length is proven. Sources: the exact form of `x * y`;
# `div(x, d)` for a divisor that is one variable or length, with x >= 0,
# gives `q * d <= x` (and 0 <= q <= x when d >= 0); a condition on a product
# narrows it, so a raising guard `length(m) == n * dim` states the shape.
# The prover replaces a product by its own bounds, or by a bound of its
# newer factor times the older one when that one's sign is known. The
# product's own overflow check is dropped where the same proof bounds it.
#
# The kernels below are the acceptance cases (a cosine score with a runtime
# dim, with the shape from div or from a guard, and the PCM mixer's sum
# loop) and the report's hint when the shape is missing. The soundness
# property compiles generated row-stride kernels (no clang: the C is read)
# and checks every dropped bounds and overflow check against the
# arithmetic.

defmodule Defk.ProductFactsTest.K do
  use Defk

  # the rows of m (dim = length(q) values each) scored against q: r * dim + j
  # is below n * dim <= length(m), from n = div(length(m), dim)
  defk scores(m :: [f32], q :: [f64]) :: [f64] do
    dim = length(q)
    n = div(length(m), dim)
    out = alloc(f64, n)

    for r <- 0..(n - 1)//1 do
      out[r] =
        for j <- 0..(dim - 1)//1, reduce: 0.0 do
          acc -> acc + m[r * dim + j] * q[j]
        end
    end

    out
  end

  # the same with the shape from a raising guard
  defk scores_guarded(m :: [f32], q :: [f64], n :: i64, dim :: i64) :: [f64] do
    if not (n > 0 and dim > 0 and length(m) == n * dim and length(q) == dim),
      do: raise(ArgumentError, "shape")

    out = alloc(f64, n)

    for r <- 0..(n - 1)//1 do
      out[r] =
        for j <- 0..(dim - 1)//1, reduce: 0.0 do
          acc -> acc + m[r * dim + j] * q[j]
        end
    end

    out
  end

  # the PCM mixer's sum loop: n blocks of m samples added into all
  defk sum_blocks(bufs :: [i64], n :: i64, held :: [i64]) :: [i64] do
    hl = length(held)
    m = div(length(bufs), n)
    all = alloc(i64, hl + m)

    for j <- 0..(n - 1)//1 do
      base = j * m

      for i <- 0..(m - 1)//1 do
        all[hl + i] = all[hl + i] + bufs[base + i]
      end
    end

    all
  end

  # a divisor of either sign: for d < 0, n <= 0 and no row runs
  defk row_sums(m :: [i64], d :: i64) :: i64 do
    n = div(length(m), d)

    for r <- 0..(n - 1)//1, j <- 0..(d - 1)//1, reduce: 0 do
      acc -> acc + m[r * d + j]
    end
  end

  # column-major: d >= 1 from the guard makes 0 <= n, so j * n + r is
  # bounded through the product j * n
  defk col_sums(m :: [i64], d :: i64) :: [i64] do
    if d < 1, do: raise(ArgumentError, "d must be at least 1")
    n = div(length(m), d)
    out = alloc(i64, d)

    for j <- 0..(d - 1)//1 do
      out[j] =
        for r <- 0..(n - 1)//1, reduce: 0 do
          acc -> acc + m[j * n + r]
        end
    end

    out
  end

  # nothing relates n * dim to length(m): the report names it
  defk unshaped(m :: [f64], n :: i64, dim :: i64) :: f64 do
    for r <- 0..(n - 1)//1, j <- 0..(dim - 1)//1, reduce: 0.0 do
      acc -> acc + m[r * dim + j]
    end
  end
end

defmodule Defk.ProductFactsTest do
  use ExUnit.Case, async: true
  use Defk.Properties

  import Defk.TestKit,
    only: [
      bounds_check_free?: 2,
      bounds_proven?: 2,
      eval_ops: 2,
      fits_i64?: 1,
      kernel_c: 2,
      kept_bounds: 2
    ]

  alias Defk.ProductFactsTest.K

  @i64_min -(2 ** 63)
  @i64_max 2 ** 63 - 1
  @len_max 2 ** 61 - 1

  defp agrees(fun, args), do: Defk.Test.assert_agrees(K, fun, args, forced_yields: true)
  defp kept(kernel), do: kept_bounds(K, kernel)

  defp f32s(xs), do: G.pack(:f32, Enum.map(xs, &(&1 * 1.0)))
  defp f64s(xs), do: G.pack(:f64, Enum.map(xs, &(&1 * 1.0)))

  # a row-major n x dim matrix of small values and a query of dim
  defp matrix(n, dim, extra \\ 0),
    do: {f32s(for k <- 1..(n * dim + extra)//1, do: rem(k, 7) - 3), f64s(Enum.to_list(1..dim//1))}

  describe "a row-major index with a runtime row length" do
    test "the shape from div: no bounds or overflow check on m[r * dim + j]" do
      assert bounds_proven?(K, :scores)
      # end to end: the C calls no checked access
      assert bounds_check_free?(K, "scores")
      refute kernel_c(K, "scores") =~ ~r/defk_(add|mul)_i64\(ctx, v_r_/

      for {n, dim, extra} <- [{0, 1, 0}, {1, 1, 0}, {3, 4, 0}, {3, 4, 3}, {50, 7, 6}, {0, 5, 4}] do
        {m, q} = matrix(n, dim, extra)
        assert {:ok, _} = agrees(:scores, [m, q])
      end

      # dim = 0: div by zero, in both modes
      assert {:raise, %ArithmeticError{}} = agrees(:scores, [f32s([1, 2]), <<>>])
    end

    test "the inner loop's indices stay fixed: its strip is flagged" do
      assert [{:flagged, _}] = Defk.TestKit.notes(K, :scores, :nonfinite)
    end

    test "the shape from a raising guard, length(m) == n * dim" do
      assert bounds_proven?(K, :scores_guarded)
      refute kernel_c(K, "scores_guarded") =~ ~r/defk_(add|mul)_i64\(ctx, v_r_/

      for {n, dim} <- [{1, 1}, {3, 4}, {40, 9}] do
        {m, q} = matrix(n, dim)
        assert {:ok, _} = agrees(:scores_guarded, [m, q, n, dim])
      end

      {m, q} = matrix(3, 4)

      for {n, dim} <- [{0, 4}, {3, 0}, {4, 3}, {2, 4}, {-3, -4}, {@i64_max, 2}] do
        assert {:raise, _} = agrees(:scores_guarded, [m, q, n, dim])
      end
    end

    test "the PCM mixer's sum loop: no bounds check" do
      assert bounds_proven?(K, :sum_blocks)

      for {n, m, held} <- [{1, 0, []}, {1, 3, [5]}, {4, 5, [1, 2]}, {3, 100, Enum.to_list(1..9)}],
          extra <- [0, 2] do
        bufs = G.pack(:i64, for(k <- 1..(n * m + extra)//1, do: k - 50))
        assert {:ok, _} = agrees(:sum_blocks, [bufs, n, G.pack(:i64, held)])
      end

      assert {:raise, %ArithmeticError{}} = agrees(:sum_blocks, [<<>>, 0, <<>>])
      # n < 0: m < 0, and alloc(i64, hl + m) raises
      assert {:raise, %ArgumentError{}} = agrees(:sum_blocks, [G.pack(:i64, [1, 2, 3]), -2, <<>>])
    end

    test "a divisor of either sign" do
      assert bounds_proven?(K, :row_sums)
      m = G.pack(:i64, Enum.to_list(1..12))

      for d <- [@i64_min, -13, -5, -1, 1, 2, 5, 12, 13, @i64_max] do
        assert {:ok, _} = agrees(:row_sums, [m, d])
      end

      assert {:raise, %ArithmeticError{}} = agrees(:row_sums, [m, 0])
    end

    test "column-major, through the product of the counter and the row count" do
      assert bounds_proven?(K, :col_sums)

      for len <- [0, 1, 11, 12], d <- [1, 2, 5, 12, 13, 1000] do
        assert {:ok, _} = agrees(:col_sums, [G.pack(:i64, Enum.to_list(1..len//1)), d])
      end
    end

    test "without the shape, the report names the product's bound" do
      assert kept(:unshaped) == [
               "m[r * dim + j]: bounds check kept; nothing proves r * dim + j < length(m) " <>
                 "(it would follow from dim * n <= length(m))"
             ]
    end
  end

  defp shaped_args do
    StreamData.bind(StreamData.tuple({G.i64(0..6), G.i64(0..6), G.i64(0..3)}), fn {n, dim, extra} ->
      {m, q} = matrix(n, dim, extra)
      StreamData.constant([m, q])
    end)
  end

  agreement(K,
    scores: [args: shaped_args()],
    scores_guarded: [
      args:
        StreamData.bind(StreamData.tuple({G.i64(-1..6), G.i64(-1..6), G.i64(0..1)}), fn {n, dim,
                                                                                         extra} ->
          {m, q} = matrix(max(n, 0), max(dim, 0), extra)
          StreamData.constant([m, q, n, dim])
        end)
    ],
    sum_blocks: [
      args: StreamData.fixed_list([G.array(:i64), G.i64(-3..9), G.array(:i64)])
    ],
    row_sums: [args: StreamData.fixed_list([G.array(:i64), G.i64(-20..20)])],
    col_sums: [args: StreamData.fixed_list([G.array(:i64), G.i64(-2..20)])],
    unshaped: [
      args: StreamData.fixed_list([G.array(:f64), G.i64(-2..9), G.i64(-2..9)])
    ]
  )

  # ------------------------------------------------------ soundness --
  # A generated kernel over a :: [u8], b :: [u8], x :: i64 and y :: i64:
  #
  #   d = D
  #   n = N
  #   if GUARD, do: raise(ArgumentError, "g")
  #   out = alloc(u8, SIZE)
  #   for r <- RS..RE//K1 do
  #     for j <- JS..JE//K2 do
  #       out[IDX] = 1
  #     end
  #   end
  #
  # D a stride (x, y, length(b), max(x, 1)), N a row count (div(length(a),
  # d) and variants, or an argument), GUARD comparisons that may name the
  # product n * d, IDX a row-stride index of r and j: a sum of products
  # whose factors are each linear in at most one of r and j. Every
  # operation in IDX is then linear in j for a fixed r, and its extremes over
  # a row are at the row's ends, which are linear in r: the first iteration
  # where an operation or the index changes side is found among the ends
  # and the roots of those linear functions (step-aligned).

  defp v(name), do: {name, [], nil}

  defp plus(t, 0), do: t
  defp plus(t, c), do: {:+, [], [t, c]}

  defp kernel({d, n, guard, size, {rs, re, k1}, {js, je, k2}, idx}) do
    body =
      quote do
        d = unquote(d)
        n = unquote(n)
        if unquote(guard), do: raise(ArgumentError, "g")
        out = alloc(u8, unquote(size))

        for r <- unquote(rs)..unquote(re)//unquote(k1) do
          for j <- unquote(js)..unquote(je)//unquote(k2) do
            out[unquote(idx)] = 1
          end
        end

        out
      end

    %{
      head: quote(do: f(a :: [u8], b :: [u8], x :: i64, y :: i64) :: [u8]),
      opts: [],
      body: body,
      line: 1
    }
  end

  defp c_of(kernel) do
    {c, _, _} = Defk.Compiler.compile(Defk.ProductFactsTest.Probe, [kernel], nil)
    c
  end

  defp off,
    do: StreamData.frequency([{4, StreamData.constant(0)}, {1, StreamData.integer(-2..2)}])

  defp probe,
    do:
      StreamData.frequency([
        {2, scenario()},
        {1, signed()},
        {1, quotient()},
        {1, independent()}
      ])

  # a quotient of a divisor of either sign used as an offset: div(x, d) is
  # in 0..x only where d >= 1
  defp quotient do
    len_a = quote(do: length(a))

    StreamData.tuple({
      StreamData.member_of([v(:x), v(:y), quote(do: length(b))]),
      StreamData.list_of(off(), length: 3),
      StreamData.member_of([false, quote(do: d < 1), quote(do: d < 0), quote(do: d > -1)]),
      StreamData.member_of([:up, :down, :fixed])
    })
    |> StreamData.map(fn {d, [o1, o2, o3], guard, dir} ->
      {cols, idx} =
        case dir do
          :up -> {{0, plus(quote(do: unquote(len_a) - n - 1), o2), 1}, plus(quote(do: n + j), o3)}
          :down -> {{0, plus(quote(do: n - 1), o2), 1}, plus(quote(do: n - 1 - j), o3)}
          :fixed -> {{0, 0, 1}, plus(quote(do: n + j), o3 - o2)}
        end

      {d, quote(do: div(unquote(plus(len_a, o1)), d)), guard, len_a, {0, 0, 1}, cols, idx}
    end)
  end

  # a stride of either sign from the arguments, its sign and the shape
  # length(a) == n * d from a guard: with d <= -1 and n <= -1 the rows
  # n..-1 of columns d..-1 are in bounds, and a product's bounds come from
  # its factor's opposite bounds
  defp signed do
    {d, n} = {v(:d), v(:n)}
    len_a = quote(do: length(a))
    shape = quote(do: unquote(len_a) != n * d)

    StreamData.tuple({
      StreamData.member_of([
        shape,
        quote(do: d > -1 or unquote(shape)),
        quote(do: d < 1 or unquote(shape)),
        quote(do: n > -1 or d > -1 or unquote(shape))
      ]),
      StreamData.list_of(off(), length: 4),
      StreamData.member_of([:neg, :pos]),
      StreamData.member_of([:row, :col, :reversed]),
      StreamData.member_of([
        v(:x),
        quote(do: div(length(a), d)),
        quote(do: div(length(a), d) + 1)
      ])
    })
    |> StreamData.map(fn {guard, [o1, o2, o3, o4], rows, idx, count} ->
      {rows, cols} =
        case rows do
          :neg -> {{plus(n, o1), plus(-1, o2), 1}, {plus(d, o3), -1, 1}}
          :pos -> {{0, plus(quote(do: n - 1), o1), 1}, {plus(quote(do: d - 1), o3), 0, -1}}
        end

      idx =
        case idx do
          :row -> plus(quote(do: r * d + j), o4)
          :col -> plus(quote(do: j * n + r), o4)
          :reversed -> plus(quote(do: r * d - j), o4)
        end

      {v(:y), count, guard, len_a, rows, cols, idx}
    end)
  end

  # a row-major (or column-major) walk of n rows of d values, each part with
  # a small offset that is most often 0
  defp scenario do
    x = v(:x)
    len_a = quote(do: length(a))

    StreamData.tuple({
      StreamData.member_of([x, quote(do: length(b)), quote(do: max(x, 1)), v(:y)]),
      StreamData.list_of(off(), length: 6),
      StreamData.member_of([:none, :d, :shape, :both]),
      StreamData.member_of([:len, :n, :nd]),
      StreamData.member_of([1, 2, -1]),
      StreamData.member_of([:row, :row_shift, :col, :reversed])
    })
    |> StreamData.map(fn {dd, [o1, o2, o3, o4, o5, o6], guard, size, k1, idx} ->
      nn = quote(do: div(unquote(plus(len_a, o1)), d))
      shape = quote(do: unquote(len_a) != n * d)

      guard =
        case guard do
          :none -> false
          :d -> quote(do: d < unquote(1 + o2))
          :shape -> shape
          :both -> quote(do: d < 1 or unquote(shape))
        end

      size =
        case size do
          :len -> plus(len_a, o3)
          :n -> quote(do: max(n, 0))
          :nd -> quote(do: max(n * d, 0))
        end

      rows =
        if k1 > 0,
          do: {0, plus(quote(do: n - 1), o4), k1},
          else: {plus(quote(do: n - 1), o4), 0, k1}

      cols = {0, plus(quote(do: d - 1), o5), 1}

      idx =
        case idx do
          :row -> plus(quote(do: r * d + j), o6)
          :row_shift -> quote(do: (r + unquote(o6)) * d + j)
          :col -> plus(quote(do: j * n + r), o6)
          :reversed -> plus(quote(do: r * d + (d - 1 - j)), o6)
        end

      {dd, nn, guard, size, rows, cols, idx}
    end)
  end

  # each part on its own
  defp independent do
    {d, n, r, j, x, y} = {v(:d), v(:n), v(:r), v(:j), v(:x), v(:y)}
    len_a = quote(do: length(a))

    count =
      StreamData.member_of([
        quote(do: div(unquote(len_a), d)),
        quote(do: div(unquote(len_a), d) + 1),
        quote(do: div(unquote(len_a) - 1, d)),
        quote(do: div(unquote(len_a), d) - 1),
        x,
        y
      ])

    guard =
      StreamData.member_of([
        false,
        quote(do: d < 1),
        quote(do: d < 0),
        quote(do: n < 0),
        quote(do: unquote(len_a) != n * d),
        quote(do: unquote(len_a) < n * d),
        quote(do: n * d > unquote(len_a) + 1),
        quote(do: not (n >= 0 and d >= 1 and n * d <= unquote(len_a))),
        quote(do: x > y or y < 0)
      ])

    size =
      StreamData.member_of([
        len_a,
        quote(do: unquote(len_a) - 1),
        quote(do: max(n, 0)),
        quote(do: max(d, 0)),
        quote(do: max(n * d, 0))
      ])

    ends = fn top -> StreamData.member_of([0, 1, quote(do: unquote(top) - 1), top, x, y]) end

    loop = fn top ->
      StreamData.bind(StreamData.member_of([1, 2, -1, -2]), fn k ->
        StreamData.map(StreamData.tuple({ends.(top), ends.(top)}), fn {s, e} -> {s, e, k} end)
      end)
    end

    # a sum of a few terms, each a factor linear in r times one linear in j
    # or in neither
    lin = fn vars ->
      StreamData.map(
        StreamData.tuple({StreamData.member_of(vars), StreamData.integer(-2..2)}),
        fn {t, c} -> plus(t, c) end
      )
    end

    term =
      StreamData.one_of([
        StreamData.map(StreamData.tuple({lin.([r]), lin.([d, n, x, j])}), fn {a, b} ->
          {:*, [], [a, b]}
        end),
        StreamData.map(StreamData.tuple({lin.([j]), lin.([d, n, y])}), fn {a, b} ->
          {:*, [], [a, b]}
        end),
        StreamData.member_of([r, j, d, n, x]),
        StreamData.integer(-2..2)
      ])

    idx =
      StreamData.frequency([
        {3,
         StreamData.member_of([
           quote(do: r * d + j),
           quote(do: d * r + j),
           quote(do: r * d - j),
           quote(do: j * n + r),
           quote(do: r * x + j),
           quote(do: r * j),
           quote(do: (r - 1) * d + j + 1),
           quote(do: r * (d + 1) + j)
         ])},
        {2,
         StreamData.map(StreamData.list_of(term, min_length: 1, max_length: 3), fn ts ->
           Enum.reduce(ts, fn t, acc -> {:+, [], [acc, t]} end)
         end)}
      ])

    StreamData.tuple({
      StreamData.member_of([x, y, quote(do: length(b)), quote(do: max(x, 1))]),
      count,
      guard,
      size,
      loop.(n),
      loop.(d),
      idx
    })
  end

  # an expression's value and its arithmetic's results, which must fit in
  # i64; a zero divisor throws :raise
  defp ev(ast, env), do: eval_ops(ast, env)
  defp fits?(ops), do: fits_i64?(ops)

  @lens_a [0, 1, 5, 6, 12, 2 ** 32, @len_max]
  @lens_b [0, 1, 3, 2 ** 31]
  @xs [@i64_min, -(2 ** 62), -3, -1, 0, 1, 2, 3, 2 ** 31, 2 ** 62, @i64_max]

  # the arguments a shape reads, each over its edge values only
  defp setups({d, n, guard, size, {rs, re, _} = rows, {js, je, _} = cols, idx}) do
    used = vars_of([d, n, guard, size, rs, re, js, je, idx])
    xs = if :x in used, do: @xs, else: [0]
    ys = if :y in used, do: @xs, else: [0]
    lbs = if :b in used, do: @lens_b, else: [0]

    for la <- @lens_a,
        lb <- lbs,
        x <- xs,
        y <- ys,
        setup = setup({d, n, guard, size, rows, cols}, la, lb, x, y),
        do: setup
  end

  # the variable names in a list of ASTs
  defp vars_of(asts) do
    for ast <- asts, node <- Macro.prewalker(ast), reduce: MapSet.new() do
      acc ->
        case node do
          {name, _, ctx} when is_atom(name) and is_atom(ctx) -> MapSet.put(acc, name)
          _ -> acc
        end
    end
  end

  # the env after the prologue, with each loop's first and last counter
  # values; false when the kernel raises before the loops or no store runs
  defp setup({d, n, guard, size, {rs, re, k1}, {js, je, k2}}, la, lb, x, y) do
    env = %{{:len, :a} => la, {:len, :b} => lb, x: x, y: y}

    try do
      {dv, od} = ev(d, env)
      true = fits?(od)
      env = Map.put(env, :d, dv)
      {nv, on} = ev(n, env)
      true = fits?(on)
      env = Map.put(env, :n, nv)
      {g, og} = ev(guard, env)
      true = fits?(og) and not g
      {sv, os} = ev(size, env)
      true = fits?(os) and sv in 0..@len_max//1
      env = Map.put(env, {:len, :out}, sv)
      {:ok, rf, rl} = range(rs, re, k1, env)
      {:ok, jf, jl} = range(js, je, k2, env)
      {env, {rf, rl, k1}, {jf, jl, k2}}
    rescue
      MatchError -> false
    catch
      :raise -> false
    end
  end

  defp range(s, e, k, env) do
    {first, o1} = ev(s, env)
    {stop, o2} = ev(e, env)

    cond do
      not fits?(o1 ++ o2) -> :raise
      k > 0 and stop > @i64_max - k -> :limit
      k < 0 and stop < @i64_min - k -> :limit
      k > 0 and first <= stop -> {:ok, first, first + k * div(stop - first, k)}
      k < 0 and first >= stop -> {:ok, first, first + k * div(first - stop, -k)}
      true -> :empty
    end
  end

  # every operation of an expression (its +, - and * nodes), itself included
  defp parts(ast) do
    {_, parts} =
      Macro.prewalk(ast, [], fn
        {op, _, [_, _]} = node, acc when op in [:+, :-, :*] -> {node, [node | acc]}
        node, acc -> {node, acc}
      end)

    [ast | parts]
  end

  # what goes wrong at one iteration: :overflow (an operation of the index
  # leaves i64), :out (the index is outside out), or nil
  defp trouble(idx, env) do
    {iv, ops} = ev(idx, env)

    cond do
      not fits?(ops) -> :overflow
      iv not in 0..(env[{:len, :out}] - 1)//1 -> :out
      true -> nil
    end
  end

  # the values of `var` in first..last//k where a linear function of it,
  # one of `fs` evaluated in `env`, may cross an i64 limit or the index's
  # bounds; the ends included, in loop order
  defp crossings(var, {first, last, k}, fs, env) do
    size = env[{:len, :out}]

    roots =
      for f <- fs,
          {f0, _} = ev(f, Map.put(env, var, 0)),
          {f1, _} = ev(f, Map.put(env, var, 1)),
          s = f1 - f0,
          s != 0,
          t <- [@i64_min, -1, 0, size - 1, size, @i64_max],
          r = div(t - f0, s),
          c <- [r - 1, r, r + 1],
          do: c

    {lo, hi} = {min(first, last), max(first, last)}

    is =
      for c <- [first, last | roots],
          c >= lo and c <= hi,
          m = Integer.floor_div(c - first, k),
          a <- [first + m * k, first + (m + 1) * k],
          a >= lo and a <= hi,
          uniq: true,
          do: a

    if k > 0, do: Enum.sort(is), else: Enum.sort(is, :desc)
  end

  # The first iteration, in loop order, where something goes wrong:
  # {r, j, :overflow | :out}, or nil. A row goes wrong when its ends do
  # (every operation is linear in j there); rows change only at the
  # crossings of the ends' linear functions of r.
  defp first_trouble({env, rows, {jf, jl, _} = cols}, idx) do
    fs = parts(idx)
    ends = for j <- [jf, jl], f <- fs, do: subst(f, :j, j)

    Enum.find_value(crossings(:r, rows, ends, env), fn r ->
      env = Map.put(env, :r, r)
      if Enum.any?([jf, jl], &trouble(idx, Map.put(env, :j, &1))), do: in_row(env, cols, fs, idx)
    end)
  end

  # the first iteration of row env.r that goes wrong
  defp in_row(env, cols, fs, idx) do
    Enum.find_value(crossings(:j, cols, fs, env), fn j ->
      if t = trouble(idx, Map.put(env, :j, j)), do: {env.r, j, t}
    end)
  end

  defp subst(ast, var, k) do
    Macro.prewalk(ast, fn
      {^var, _, ctx} when is_atom(ctx) -> k
      node -> node
    end)
  end

  defp shown({d, n, guard, size, {rs, re, k1}, {js, je, k2}, idx}) do
    s = &Macro.to_string/1

    "d = #{s.(d)}; n = #{s.(n)}; guard #{s.(guard)}; out = alloc(u8, #{s.(size)}); " <>
      "for r <- #{s.(rs)}..#{s.(re)}//#{k1}, j <- #{s.(js)}..#{s.(je)}//#{k2}: " <>
      "out[#{s.(idx)}]"
  end

  @checked ~r/defk_(add|sub|mul|neg)_i64\(/

  defp sound(shape) do
    idx = elem(shape, 6)
    c = c_of(kernel(shape))
    lines = String.split(c, "\n")
    # the store, and the temporaries the index may be computed into
    index_lines = Enum.filter(lines, &(&1 =~ ~r/defk_put_u8\(|\(v_out_\d+\)\.data\[|v_op_\d+ = /))
    unchecked? = not (c =~ "defk_put_u8")
    exact? = not Enum.any?(index_lines, &(&1 =~ @checked))

    if unchecked? or exact? do
      for {env, _, _} = setup <- setups(shape), t = first_trouble(setup, idx) do
        {r, j, what} = t

        where =
          "length(a) = #{env[{:len, :a}]}, length(b) = #{env[{:len, :b}]}, x = #{env.x}, " <>
            "y = #{env.y}, d = #{env.d}, n = #{env.n}, length(out) = #{env[{:len, :out}]}, " <>
            "r = #{r}, j = #{j} (#{shown(shape)})"

        refute what == :out and unchecked?,
               "out[...] is unchecked, but out of bounds for #{where}"

        refute what == :overflow and exact?,
               "the index has no overflow check, but overflows for #{where}"
      end
    end
  end

  # Each case compiles a kernel (C codegen, no clang) and walks a few
  # hundred inputs. The :deep twin runs @deep_runs.
  @runs 200
  @deep_runs 3_000

  property "a check dropped by a product is never wrong" do
    check(all(shape <- probe(), max_runs: @runs, do: sound(shape)))
  end

  @tag deep: true, timeout: 600_000
  property "a check dropped by a product is never wrong (deep)" do
    check(all(shape <- probe(), max_runs: @deep_runs, do: sound(shape)))
  end
end
