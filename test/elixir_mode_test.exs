# Elixir mode (defk-v5d): every test and catalog kernel compiled to plain
# Elixir, checked against the native kernel on the existing tests' inputs.
# Two kernels agree when both return identical values (===, bit-exact
# floats) or both raise the same exception (here also the same message,
# except where noted).

Code.require_file("../examples/fuzzy_search/lib/fuzzy_search/kernels.ex", __DIR__)

# The catalog's kernel modules (Geo.Kernels, Rolling.Kernels, ...) are
# loaded by test_helper.exs (Defk.Catalog).

defmodule Defk.ElixirModeTest.Agree do
  # This file's agreement default: exact message equality, through
  # Defk.Test.assert_agrees (defk-0ha; the near-verbatim second
  # implementation that lived here is gone). `message: false` falls back to
  # the reason taxonomy, for raises whose messages carry formatted values.
  def agree(mod, fun, args, opts \\ []) do
    opts = if opts[:message] == false, do: [], else: [message: :exact]
    Defk.Test.assert_agrees(mod, fun, args, opts)
  end

  def i64s(list), do: for(x <- list, into: <<>>, do: <<x::64-signed-native>>)
  def f64s(list), do: for(x <- list, into: <<>>, do: <<x::float-64-native>>)
end

# Kernels for what the existing tests don't cover: arrays written inside
# every construct (threaded out in Elixir mode), limits, and debugging.
defmodule Defk.ElixirModeTest.K do
  use Defk

  defk w_if(n :: i64, c :: bool) :: [i64] do
    out = alloc(i64, 4)

    if c do
      out[0] = n
    else
      out[1] = n
    end

    if n > 2, do: out[2] = 7
    out[3] = out[0] + out[1] + out[2]
    out
  end

  # a value `if` whose arm writes, as a reduce body (geo_nearest's shape)
  defk w_value_if(a :: [i64]) :: [i64] do
    best = alloc(i64, 1)
    best[0] = -1

    _ =
      for i <- 0..(len(a) - 1)//1, reduce: 0 do
        top ->
          if a[i] > top do
            best[0] = i
            a[i]
          else
            top
          end
      end

    best
  end

  defk w_cond_case(n :: i64) :: [i64] do
    out = alloc(i64, 3)

    for i <- 0..n//1 do
      case rem(i, 3) do
        0 -> out[0] = out[0] + i
        1 -> out[1] = out[1] + 1
        _ -> out[2] = out[2] - 1
      end
    end

    k =
      cond do
        n < 0 ->
          0

        n > 10 ->
          out[0] = 100
          1

        true ->
          2
      end

    out[2] = out[2] * 10 + k
    out
  end

  # a nested generator and a filter see the array as written so far
  defk w_nested(n :: i64) :: [i64] do
    out = alloc(i64, 2)
    out[0] = 1

    for i <- 1..n//1, out[1] < 50, j <- 1..out[0]//1 do
      out[1] = out[1] + i * j
      out[0] = min(out[0] + 1, 5)
    end

    out
  end

  defk w_reduce(a :: [f64]) :: {f64, i64} do
    seen = alloc(u8, 4)

    {s, c} =
      for x <- a, reduce: {0.0, 0} do
        {s, c} ->
          seen[c - 4 * div(c, 4)] = 1
          {s + x, c + 1}
      end

    {s, c + seen[0] + seen[3]}
  end

  defk w_reduce_while(n :: i64, stop :: i64) :: [i64] do
    out = alloc(i64, n + 1)

    k =
      Enum.reduce_while(0..n//1, 0, fn i, acc ->
        out[i] = acc

        case rem(i, 2) do
          0 when i >= stop ->
            {:halt, acc}

          0 ->
            out[i] = -acc
            {:cont, acc + i}

          _ ->
            {:cont, acc + 1}
        end
      end)

    out[n] = k
    out
  end

  defk w_any(n :: i64) :: {bool, i64} do
    hits = alloc(i64, n + 1)

    found =
      Enum.any?(0..n//1, fn i ->
        hits[i] = 1
        i * i > n
      end)

    {found, for(h <- hits, reduce: 0, do: (acc -> acc + h))}
  end

  defk w_and(c :: bool) :: {bool, i64} do
    out = alloc(i64, 1)

    b =
      c and
        (
          out[0] = 5
          true
        )

    {b, out[0]}
  end

  defk read(a :: [f64], i :: i64) :: f64 do
    a[i]
  end

  defk put_u8(n :: i64, i :: i64, v :: i64) :: [u8] do
    out = alloc(u8, n)
    out[i] = v
    out
  end

  defk put_f64(i :: i64, v :: i64) :: [f64] do
    out = alloc(f64, 2)
    out[i] = v
    out
  end

  defk mk(e :: i64, n :: i64) :: i64 do
    case e do
      0 -> len(alloc(u8, n))
      _ -> len(alloc(f64, n))
    end
  end

  defk arith(op :: i64, a :: i64, b :: i64) :: i64 do
    case op do
      0 -> a + b
      1 -> a - b
      2 -> a * b
      3 -> -a
      4 -> abs(a)
      5 -> div(a, b)
      _ -> rem(a, b)
    end
  end

  defk fl(op :: i64, x :: f64, y :: f64) :: f64 do
    case op do
      0 -> x / y
      1 -> sqrt(x)
      2 -> log(x)
      3 -> exp(x)
      4 -> pow(x, y)
      5 -> x * y
      _ -> float(trunc(x) + round(y))
    end
  end

  defk mixed(n :: i64, x :: f64) :: f64 do
    for i <- 1..n//1, reduce: x do
      acc -> if rem(i, 2) == 0, do: acc + i, else: acc * 0.5
    end
  end

  defk coerced(n :: i64) :: f64 do
    for i <- 1..n//1, reduce: 0.5 do
      _acc -> i * 3
    end
  end

  defk count(a :: [f64], b :: [u8], n :: i64, x :: f64, flag :: bool) :: f64 do
    if flag, do: len(a) + len(b) + n + x, else: x
  end

  # snapshot: b keeps what it had when out is written (value semantics)
  defk snapshot(v :: f64) :: f64 do
    out = alloc(f64, 1)
    b = out
    out[0] = v
    b[0] + out[0]
  end

  defk inf_inside(x :: f64) :: i64 do
    if x * 1.0e308 > 0.0, do: 1, else: 0
  end

  defk sum(a :: [f64]) :: f64 do
    for x <- a, reduce: 0.0 do
      acc -> acc + x
    end
  end

  defk debug(x :: i64, a :: [f64]) :: f64 do
    # dbg and IO.inspect must compile and run in Elixir mode: exercising them
    # here, deliberately.
    # credo:disable-for-next-line Credo.Check.Warning.Dbg
    y = dbg(x * 2)

    s =
      for v <- a, reduce: 0.0 do
        # credo:disable-for-next-line Credo.Check.Warning.IoInspect
        acc -> IO.inspect(acc + v, label: "acc")
      end

    s + y
  end
end

defmodule Defk.ElixirModeTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO
  import Defk.ElixirModeTest.Agree

  alias Defk.EarlyExitTest.K, as: E
  alias Defk.ElixirModeTest.K
  alias Defk.ResumeTest.K, as: R
  alias Defk.SelectTest.K, as: S

  @moduletag timeout: 300_000

  # the existing tests' modules, when this file runs on its own (a sync
  # test runs after every test file is loaded, so this is no-op in a full run)
  setup_all do
    for {mod, file} <- [
          {Defk.EarlyExitTest, "early_exit_test.exs"},
          {Defk.SelectTest, "select_test.exs"},
          {Defk.ResumeTest, "resume_test.exs"}
        ],
        not Code.ensure_loaded?(mod),
        do: Code.require_file(file, __DIR__)

    :ok
  end

  @min -9_223_372_036_854_775_808
  @max 9_223_372_036_854_775_807

  describe "existing tests run in Elixir mode" do
    # yields, frames and reloads don't exist in Elixir mode: their inputs are
    # checked for agreement below instead
    @native_only [
      "test early exit halt at every point, including right after a forced yield",
      "test early exit halt in an inlined callee, flat and natural/forced yields",
      "test early exit flat loop exits on the short and the strip path, with forced yields",
      "test early exit out of bounds raises only when reached before the halt (natural and forced yields)"
    ]

    for mod <- [Defk.EarlyExitTest, Defk.SelectTest] do
      test "every #{inspect(mod)} test body passes with its kernels in Elixir mode" do
        tests =
          for {f, 1} <- unquote(mod).__info__(:functions),
              name = Atom.to_string(f),
              String.starts_with?(name, "test "),
              name not in @native_only,
              do: f

        assert Enum.count_until(tests, 7) >= 6

        for t <- tests do
          Defk.ElixirMode.with_mode(:elixir, fn -> apply(unquote(mod), t, [%{}]) end)
        end
      end
    end
  end

  describe "agreement on the existing tests' inputs" do
    test "early exit kernels" do
      for stop <- [1, 2, 7, 50, 301, 699, 700, 701], do: agree(E, :nest3, [700, stop])
      for x <- 2..500, do: agree(E, :first_div, [x])
      agree(E, :sum_first_divs, [3_000])

      for {n, l} <- [{10, 5}, {100, 1_000}, {100, 1_000_000}, {0, 0}],
          do: agree(E, :abs_sum_until, [n, l])

      for n <- [1, 10, 96, 97, 98, 1_000], do: agree(E, :classify_until, [n])
      for n <- [0, 1, 5, 30], k <- [1, 2, 7, 9, 25, 31], do: agree(E, :all_any, [n, k])

      a = i64s(Enum.to_list(0..9_999))

      for t <- [-5, 0, 1, 2_046, 2_047, 2_048, 2_049, 4_096, 9_999, 10_000],
          f <- [:find_at_least, :find_at_least_nb],
          do: agree(E, f, [a, t])

      agree(E, :find_at_least, [<<>>, 1])
      agree(E, :find_many, [a, 300])

      for xs <- [[], [1.0, 2.0, -1.0, 5.0], [1.5, 2.5], [-1.0]],
          do: agree(E, :until_negative, [f64s(xs)])

      b = i64s(Enum.to_list(1..3_000))

      for stop <- [10, 3_000, 3_001],
          f <- [:sum_until, :sum_until_nb],
          do: agree(E, f, [b, stop, 3_050])

      for x <- [-3, -1, 0, 1, 2, 3, 100, 101, 102, 1_000, 1_001],
          do: agree(E, :case_val, [x]) && agree(E, :case_partial, [x])

      for b <- [true, false],
          do:
            agree(E, :case_partial_bool, [b]) &&
              agree(E, :case_stmt, [i64s([3, 4, 5, 6, 7, 9, 10]), b])

      big = 1_099_511_627_776
      for k <- [0, 1], do: agree(E, :case_sel, [big, k])
      agree(E, :case_loop, [120, 7])
    end

    test "select kernels, including the overflow in the taken arm" do
      big = 1_099_511_627_776
      agree(S, :count_if, [10_000, 7])
      agree(S, :count_if, [10, 9_223_372_036_854_775_000])
      agree(S, :cond_count, [10, 9_223_372_036_854_775_000])

      for c <- [true, false] do
        agree(S, :square_unless, [c, big])
        agree(S, :next_or_neg, [c, @min])
        agree(S, :cmp_arms, [c, 3, 3])
        agree(S, :cond_square, [c, big])
        agree(S, :cond_later, [c, big])
        agree(S, :cond_later, [c, @min])
      end

      for x <- [3, 4, 0, -4], do: agree(S, :cond_calls, [x])
    end

    test "resume shapes and their callees (the forced-yield inputs, smaller where slow)" do
      a = i64s(for i <- 1..2_000, do: rem(i * 7919, 100_003))
      c = i64s(for i <- 1..200, do: rem(i * 7919, 100_003))
      f = f64s(for i <- 1..20_000, do: i / 3)

      for s <- ["", "_nb"] do
        agree(R, :"mix#{s}", [a, 6])
        agree(R, :"deep#{s}", [60])
        agree(R, :"flat#{s}", [f, 3])
        agree(R, :"calls#{s}", [c, 3])
        agree(R, :"calls_raise#{s}", [300, 299])
        agree(R, :"calls_raise#{s}", [300, 301])
      end
    end

    test "fuzzy_search" do
      :rand.seed(:exsss, {7, 8, 9})

      words =
        for _ <- 1..2_000,
            do: for(_ <- 1..Enum.random(3..12), into: "", do: <<Enum.random(?a..?z)>>)

      {offs, total} = Enum.map_reduce(words, 0, fn w, at -> {at, at + byte_size(w)} end)
      {blob, offs} = {IO.iodata_to_binary(words), i64s(offs ++ [total])}

      for q <- ["elixir", "a", ""], k <- [10, 1, 0], f <- [:search, :search_blocking] do
        agree(FuzzySearch.Kernels, f, [q, blob, offs, k])
      end
    end
  end

  describe "catalog kernels" do
    test "test/support/examples.ex" do
      x = f64s([1.0, 2.5, -3.0, 0.125])
      agree(Examples.Kernels, :add, [1, 2])
      agree(Examples.Kernels, :add, [@max, 1])
      # float division by zero: Elixir's own message in Elixir mode
      for f <- [:sum, :mean_var, :oob],
          a <- [x, <<>>],
          do: agree(Examples.Kernels, f, [a], message: false)

      agree(Examples.Kernels, :dot, [x, f64s([2.0, 3.0])])
      agree(Examples.Kernels, :scale, [x, 3])

      agree(Examples.Kernels, :histogram, [
        :binary.list_to_bin(for i <- 1..3_000, do: rem(i * 31, 256))
      ])

      for f <- [
            :count_primes,
            :count_primes_noyield,
            :count_primes_via_call,
            :count_primes_early,
            :count_primes_early_noyield
          ],
          do: agree(Examples.Kernels, f, [10_000])

      for n <- [-1, 0, 1, 2, 97, 1_000_003],
          f <- [:prime?, :prime_early?],
          do: agree(Examples.Kernels, f, [n], message: false)

      agree(Examples.Kernels, :overflow, [3_037_000_500])
      agree(Examples.Kernels, :overflow, [3_037_000_499])
    end

    test "geo_nearest, also against its Elixir version" do
      rad = &(&1 * :math.pi() / 180)

      points =
        for i <- 1..3_000 do
          lat = rad.(36 + rem(i * 7919, 3400) / 100)
          {lat, rad.(-10 + rem(i * 104_729, 4000) / 100), :math.cos(lat)}
        end

      pack = fn f -> f64s(Enum.map(points, f)) end
      {lat, lon, coslat} = {pack.(&elem(&1, 0)), pack.(&elem(&1, 1)), pack.(&elem(&1, 2))}

      rec =
        for {la, lo, c} <- points,
            into: <<>>,
            do: <<la::float-64-native, lo::float-64-native, c::float-64-native>>

      for {k, q} <- [{10, {59.3293, 18.0686}}, {1, {40.0, 0.0}}, {3_000, {50.0, 5.0}}] do
        {qlat, qlon} = {rad.(elem(q, 0)), rad.(elem(q, 1))}
        {:ok, got} = agree(Geo.Kernels, :nearest, [lat, lon, coslat, qlat, qlon, k])
        idx = for <<i::64-signed-native <- got>>, do: i
        assert Enum.sort(idx) == Enum.sort(Geo.Elixir.nearest(rec, qlat, qlon, k))
      end

      agree(Geo.Kernels, :nearest, [lat, lon, coslat, 0.0, 0.0, 0])
    end

    test "rolling_stats, also against its Elixir version" do
      x = f64s(for i <- 1..5_000, do: 20.0 + 5 * :math.sin(i / 500) + rem(i * 7919, 13) / 10)

      for w <- [1, 2, 60, 5_000] do
        # one chunk runs the kernel's exact arithmetic; several chunks re-seed
        # their window sums, so those agree only within a tolerance (loose: the
        # sqrt of a cancelled variance, e.g. w = 1, amplifies 1e-13 to 1e-6)
        expect = Rolling.Elixir.mean_std(x, w, 1)
        assert Rolling.Kernels.__defk_elixir__(:mean_std, [x, w]) === expect

        # bit-exact natively too: kernels build with -ffp-contract=off (defk-jlk)
        assert Rolling.Kernels.mean_std(x, w) === expect

        chunked = Rolling.Elixir.mean_std(x, w, 7)
        assert byte_size(chunked) == byte_size(expect)

        for {<<a::float-64-native>>, <<b::float-64-native>>} <-
              Enum.zip(
                for(<<v::binary-8 <- chunked>>, do: v),
                for(<<v::binary-8 <- expect>>, do: v)
              ) do
          assert abs(a - b) < 1.0e-5
        end
      end

      for w <- [0, 5_001, 20_000], do: agree(Rolling.Kernels, :mean_std, [x, w], message: false)
    end

    test "image_blur, also against its Elixir version" do
      for {w, h} <- [{64, 48}, {1, 1}, {3, 2}] do
        rgb =
          for y <- 0..(h - 1),
              x <- 0..(w - 1),
              into: <<>>,
              do: <<rem(x * 7, 256), rem(y * 13, 256), rem(x * y, 256)>>

        {:ok, got} = agree(Blur.Kernels, :gray_blur, [rgb, w, h])
        assert got == Blur.Elixir.gray_blur(rgb, w, h)
      end

      agree(Blur.Kernels, :gray_blur, [<<1, 2, 3>>, 2, 2])
      agree(Blur.Kernels, :gray_blur, [<<>>, 0, 0])
    end

    test "poor_list_data, poor_tiny_calls and the template" do
      totals = f64s(for i <- 1..10_000, do: 5.0 + rem(i * 7919, 50_000) / 100)
      agree(Orders.Kernels, :sum, [totals])
      agree(Example.Kernels, :work, [totals])
      assert Example.Kernels.__defk_elixir__(:work, [totals]) === Example.Elixir.work(totals)

      for x <- [-50, -10.0, 0, 3.5, 90.0, 150.5],
          do: agree(Clamp.Kernels, :clamp, [x, -10.0, 90.0])
    end
  end

  describe "arrays written inside constructs" do
    test "if, value if, case, cond, nested generators, filters, tuple accumulators" do
      for n <- [-1, 0, 1, 2, 3, 20], c <- [true, false], do: agree(K, :w_if, [n, c])
      for xs <- [[], [3], [1, 5, 2, 9, 9, 0]], do: agree(K, :w_value_if, [i64s(xs)])
      for n <- [-1, 0, 5, 11, 40], do: agree(K, :w_cond_case, [n])
      for n <- [0, 1, 2, 3, 10], do: agree(K, :w_nested, [n])
      for xs <- [[], [1.5], [1.0, 2.0, 3.0, 4.0, 5.0]], do: agree(K, :w_reduce, [f64s(xs)])
      assert K.__defk_elixir__(:w_if, [5, true]) == i64s([5, 0, 7, 12])
      assert K.__defk_elixir__(:w_nested, [3]) == i64s([5, 37])
    end

    test "reduce_while, Enum.any? and `and` with writes" do
      for n <- [0, 1, 6, 9], stop <- [0, 3, 100], do: agree(K, :w_reduce_while, [n, stop])
      for n <- [0, 1, 5, 30], do: agree(K, :w_any, [n])
      for c <- [true, false], do: agree(K, :w_and, [c])
      assert K.__defk_elixir__(:w_any, [5]) == {true, 4}
    end
  end

  describe "limits and errors raise as the kernel does" do
    test "wrong-typed arguments" do
      a = f64s([1.0, 2.0])
      ok = [a, "abc", 3, 1.5, true]
      unaligned = binary_part(<<0>> <> a, 1, 16)
      assert agree(K, :count, ok) == {:ok, 9.5}
      agree(K, :count, [unaligned, "", 0, 0, true])

      bad = [
        {0, [:a, [1.0], <<1, 2, 3>>, <<1::3>>, 1.0, 7]},
        {1, [:a, [1], <<1::3>>, 5]},
        {2, [1.0, :a, @max + 1, @min - 1, "1", nil]},
        {3, [:a, @max + 1, "1.0", nil]},
        {4, [1, nil, :yes, "true"]}
      ]

      for {pos, vals} <- bad, v <- vals do
        assert {:raise, %ArgumentError{}} = agree(K, :count, List.replace_at(ok, pos, v))
      end

      # array arguments are checked before scalars, as in the kernel
      agree(K, :count, [a, :bad, :bad, :bad, :bad])
      agree(K, :count, [a, "x", :bad, :bad, :bad])
      for x <- [2, 2.0, -0.0, @max], do: agree(K, :count, [a, "", 0, x, true])
    end

    test "i64 range, division, indices, element fit and alloc" do
      for op <- 0..6,
          {a, b} <- [
            {@max, 1},
            {@min, 1},
            {@min, -1},
            {3_037_000_500, 3_037_000_500},
            {7, 0},
            {-7, 2},
            {@min, 0}
          ] do
        agree(K, :arith, [op, a, b])
      end

      a = f64s([1.0, 2.0, 3.0])
      for i <- [-1, 0, 2, 3, @max, @min], do: agree(K, :read, [a, i])

      for {n, i, v} <- [
            {2, 0, 255},
            {2, 1, 0},
            {2, 0, 256},
            {2, 0, -1},
            {2, 2, 1},
            {2, 2, 300},
            {0, 0, 0}
          ],
          do: agree(K, :put_u8, [n, i, v])

      for {i, v} <- [{0, 3}, {1, @max}, {2, 1}], do: agree(K, :put_f64, [i, v])
      for e <- [0, 1], n <- [0, 5, -1], do: agree(K, :mk, [e, n])
    end

    test "float operations" do
      for {op, x, y} <- [
            {0, 1.0, 0.0},
            {0, 1.0, -0.0},
            {0, 0.0, 0.0},
            {0, 7.0, 2.0},
            {1, -1.0, 0.0},
            {1, -0.0, 0.0},
            {1, 2.0, 0.0},
            {2, 0.0, 0.0},
            {2, -1.0, 0.0},
            {2, 10.0, 0.0},
            {3, 1.0, 0.0},
            {4, 2.0, 10.0},
            {5, 1.0e300, 1.0e300},
            {6, 2.5, -2.5},
            {6, 1.0e19, 0.0},
            {6, 1.0, 1.0e19}
          ] do
        # messages differ: Elixir's own for float arithmetic, %g in the kernel's for trunc/round
        agree(K, :fl, [op, x, y], message: false)
      end

      for n <- [0, 1, 2, 7], do: agree(K, :mixed, [n, 0.5]) && agree(K, :coerced, [n])
    end

    test "Elixir mode applies the decided semantics where the kernel still diverges" do
      # the kernel gives this until defk-auo lands; Elixir mode gives the decided result

      # value semantics: b is not changed by the write to out (native: 4.0)
      assert K.__defk_elixir__(:snapshot, [2.0]) == 2.0
    end

    test "inf or NaN raises at the operation or the read, in both modes (defk-i00)" do
      # inf inside a kernel raises at the operation, also when never returned
      agree(K, :inf_inside, [10.0], message: false)
      assert_raise ArithmeticError, fn -> K.__defk_elixir__(:inf_inside, [10.0]) end
      # non-finite input bits raise ArgumentError when read, and only when read
      nan = <<0x7FF8000000000001::64-native>>
      inf = <<0x7FF0000000000000::64-native>>

      for bits <- [nan, inf] do
        agree(K, :sum, [f64s([1.0]) <> bits])
        e = assert_raise ArgumentError, fn -> K.__defk_elixir__(:sum, [f64s([1.0]) <> bits]) end
        assert e.message =~ "non-finite float"
        agree(K, :read, [bits <> f64s([2.0]), 1])
        assert K.__defk_elixir__(:read, [bits <> f64s([2.0]), 1]) == 2.0
      end
    end

    test "alloc/2 sizes past what any allocator serves" do
      # wrapping n * 8, over 2^48 bytes, exactly 2^48 bytes (out of memory)
      for n <- [2 ** 61, @max, 2 ** 45 + 1, 2 ** 45, -1], do: agree(K, :mk, [1, n])
    end
  end

  describe "debugging" do
    test "dbg and IO.inspect print in Elixir mode; native code ignores them" do
      a = f64s([1.0, 2.0])
      out = capture_io(fn -> assert K.__defk_elixir__(:debug, [3, a]) === 9.0 end)
      plain = String.replace(out, ~r/\e\[[0-9;]*m/, "")
      assert plain =~ ~r/Ops.mul\(\s*x,\s*2\s*\) #=> 6/
      assert plain =~ "elixir_mode_test.exs:"
      assert out =~ "acc: 1.0\nacc: 3.0\n"
      assert capture_io(fn -> assert K.debug(3, a) === 9.0 end) == ""

      assert capture_io(fn -> Defk.ElixirMode.with_mode(:elixir, fn -> K.debug(3, a) end) end) ==
               out
    end

    test "the generated Elixir is readable source" do
      src = Examples.Kernels.__defk_elixir_source__()
      assert src =~ "defp __defk_elixir_dot__(a, b) do"
      assert src =~ "Ops.get_f64(a, i) * Ops.get_f64(b, i)"
    end
  end

  describe "mode selection" do
    test "Elixir mode is always compiled in :test; the configured mode is checked" do
      env = __ENV__
      assert Code.ensure_loaded?(Examples.Kernels)
      assert function_exported?(Examples.Kernels, :__defk_elixir__, 2)
      assert Defk.ElixirMode.setup!(:native, env) == {:native, true}
      assert Defk.ElixirMode.setup!(:elixir, env) == {:elixir, true}

      # apply, not a direct call: :fast is deliberately out of the tuple, the
      # compiler would type-warn against setup!'s inferred {native, elixir}
      # contract, and this test exists to prove the runtime rejection path.
      assert_raise CompileError, ~r/unknown mode :fast/, fn ->
        # credo:disable-for-next-line Credo.Check.Refactor.Apply
        apply(Defk.ElixirMode, :setup!, [:fast, env])
      end

      for {mix_env, expect} <- [dev: {:native, false}, prod: {:native, false}] do
        try do
          Mix.env(mix_env)
          assert Defk.ElixirMode.setup!(:native, env) == expect
          if mix_env == :dev, do: assert(Defk.ElixirMode.setup!(:elixir, env) == {:elixir, true})

          if mix_env == :prod do
            assert_raise CompileError,
                         ~r/needs a Mix project in :dev or :test \(found: the :prod environment\)/,
                         fn ->
                           Defk.ElixirMode.setup!(:elixir, env)
                         end
          end
        after
          Mix.env(:test)
        end
      end
    end

    test "config :defk, mode: :elixir makes kernel calls run in Elixir mode" do
      src = """
      defmodule Defk.ElixirModeTest.Configured do
        use Defk
        defk twice(x :: i64) :: i64 do
          IO.inspect(x * 2)
        end
      end
      """

      Application.put_env(:defk, :mode, :elixir)

      try do
        Code.compile_string(src)
      after
        Application.delete_env(:defk, :mode)
      end

      mod = Module.concat(__MODULE__, Configured)
      assert capture_io(fn -> assert mod.twice(4) == 8 end) == "8\n"

      assert capture_io(fn ->
               Defk.ElixirMode.with_mode(:native, fn -> assert mod.twice(4) == 8 end)
             end) == ""
    end

    test "with_mode/2 switches only the calling process" do
      x = f64s([1.0])

      assert capture_io(fn -> Defk.ElixirMode.with_mode(:elixir, fn -> K.debug(1, x) end) end) =~
               "acc: 1.0"

      Defk.ElixirMode.with_mode(:elixir, fn ->
        task = Task.async(fn -> capture_io(fn -> K.debug(1, x) end) end)
        assert Task.await(task) == ""
      end)

      assert Process.get(:defk_mode) == nil
    end
  end

  describe "use Defk, elixir_mode: true" do
    test "compiles __defk_elixir__/2 and agrees with native; default path stays native" do
      src = """
      defmodule Defk.ElixirModeTest.OptIn do
        use Defk, elixir_mode: true

        defk twice(n :: i64) :: i64 do
          n * 2
        end
      end
      """

      [{mod, _}] = Code.compile_string(src)
      assert function_exported?(mod, :__defk_elixir__, 2)
      assert 8 == Defk.Test.assert_agrees(mod, :twice, [4]) |> elem(1)
      assert capture_io(fn -> assert mod.twice(4) == 8 end) == ""
    end

    test "rejects unknown options" do
      assert_raise ArgumentError, ~r/elixir_mode/, fn ->
        Code.compile_string("defmodule Defk.ElixirModeTest.BadOpt do\n use Defk, nope: 1\nend")
      end
    end

    test "a Mix.install script (no Mix project) compiles Elixir mode on request" do
      dir = Path.join(System.tmp_dir!(), "defk_fzp_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      script = Path.join(dir, "script.exs")
      root = File.cwd!()

      File.write!(script, """
      Mix.install([{:defk, path: #{inspect(root)}}])

      defmodule Script.K do
        use Defk, elixir_mode: true

        defk twice(n :: i64) :: i64 do
          n * 2
        end
      end

      native = Script.K.twice(4)
      elixir = Script.K.__defk_elixir__(:twice, [4])
      IO.puts("RESULT \#{native} \#{elixir} \#{Mix.Project.get() == nil}")
      """)

      {out, status} =
        System.cmd("elixir", [script],
          env: [{"MIX_INSTALL_DIR", Path.join(dir, "mix_install")}, {"MIX_ENV", "dev"}],
          stderr_to_stdout: true
        )

      File.rm_rf!(dir)
      assert status == 0, out
      assert out =~ "RESULT 8 8 true"
    end
  end

  describe "setup!/3 without a Mix project" do
    @env %{file: "x.exs"}

    test "opt-in compiles Elixir mode and stays native by default" do
      # the test run has a Mix project in :test, so this checks the option's
      # contract; the child-process test above covers no project at all
      assert {:native, true} = Defk.ElixirMode.setup!(:native, true, @env)
    end

    test "the unsupported-environment error names the condition and the fix" do
      err =
        assert_raise CompileError, fn ->
          Defk.ElixirMode.setup!(:elixir, false, @env, nil)
        end

      assert err.description =~
               "`config :defk, mode: :elixir` needs a Mix project in :dev or :test (found: no Mix project)"

      assert err.description =~
               "use `use Defk, elixir_mode: true` and `Defk.ElixirMode.with_mode/2`"
    end

    test "no project and no opt-in is native without Elixir mode" do
      assert {:native, false} = Defk.ElixirMode.setup!(:native, false, @env, nil)
      assert {:native, true} = Defk.ElixirMode.setup!(:native, true, @env, nil)
    end
  end
end
