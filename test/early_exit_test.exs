# Early loop exit (Enum.reduce_while, Enum.all?/any?) and `case` (defk-9vl).
# Most kernels are written once by `twin`, which defines the kernel, its
# `yield: false` form (`_nb`) and the same body as a plain Elixir function
# (`ex_`), so every result and exit point is compared with Elixir itself.

defmodule Defk.EarlyExitTest.Twin do
  defmacro twin(head, do: body) do
    {:"::", hm, [{name, cm, params}, ret]} = head
    vars = for {:"::", _, [v, _t]} <- params, do: v
    nb_head = {:"::", hm, [{:"#{name}_nb", cm, params}, ret]}

    quote do
      defk(unquote(head), do: unquote(body))
      defk(unquote(nb_head), [yield: false], do: unquote(body))
      def unquote(:"ex_#{name}")(unquote_splicing(vars)), do: unquote(body)
    end
  end
end

defmodule Defk.EarlyExitTest.K do
  use Defk
  import Defk.EarlyExitTest.Twin

  # ------------------------------------------------------------ early exit --

  # three nested folds; every level halts at a data-dependent point, and the
  # outer two have a safepoint per iteration (they contain loops)
  twin nest3(n :: i64, stop :: i64) :: {i64, i64} do
    Enum.reduce_while(1..n//1, {0, 0}, fn i, {s, c} ->
      mid =
        Enum.reduce_while(1..(rem(i, 13) + 2)//1, 0, fn j, z ->
          w =
            Enum.reduce_while(0..(rem(i + j, 7) + 3)//1, 0, fn k, y ->
              if k * k > rem(i * j, 11) + 4, do: {:halt, y + 100}, else: {:cont, y + k * j}
            end)

          if rem(i * j, 17) == 3, do: {:halt, z + w}, else: {:cont, z + w + j}
        end)

      if i == stop do
        {:halt, {s, c}}
      else
        {:cont, {rem(s * 31 + mid, 1_000_000_007), c + 1}}
      end
    end)
  end

  # halt in an inlined callee exits only the callee's loop
  twin sum_first_divs(n :: i64) :: i64 do
    for i <- 2..n//1, reduce: 0 do
      acc -> acc + first_div(i)
    end
  end

  twin first_div(x :: i64) :: i64 do
    Enum.reduce_while(2..x//1, x, fn d, _ ->
      if rem(x, d) == 0, do: {:halt, d}, else: {:cont, x}
    end)
  end

  # a select (pure-arithmetic if) feeding the accumulator; statements before the tail
  twin abs_sum_until(n :: i64, limit :: i64) :: i64 do
    Enum.reduce_while(-n..n//1, 0, fn x, acc ->
      next = if x > 0, do: acc + x, else: acc - x
      if next > limit, do: {:halt, acc}, else: {:cont, next}
    end)
  end

  # case and cond as the tail; a counting-down range (no step)
  twin classify_until(n :: i64) :: {i64, i64} do
    Enum.reduce_while(n..1//-1, {0, 0}, fn i, {acc, seen} ->
      case rem(i * i, 97) do
        0 ->
          {:halt, {acc, seen}}

        r when r < 10 ->
          # one-branch cond as an early-exit sink; the shape is the fixture
          # credo:disable-for-next-line Credo.Check.Refactor.CondStatements
          cond do
            r == 1 -> {:cont, {acc + 1000, seen + 1}}
            true -> {:cont, {acc + r, seen + 1}}
          end

        _ ->
          {:cont, {acc + i, seen + 1}}
      end
    end)
  end

  twin all_any(n :: i64, k :: i64) :: {bool, bool} do
    {Enum.all?(1..n//1, fn x -> rem(x, k) != 0 end), Enum.any?(1..n//1, fn x -> x * x == k end)}
  end

  twin prime?(x :: i64) :: bool do
    Enum.all?(2..trunc(:math.sqrt(x))//1, fn d -> rem(x, d) != 0 end)
  end

  # flat loops: the early-exit loop has no nested loop, so it runs on the
  # strip path (one plain loop under DEFK_STRIP trips, else strips)
  defk find_at_least(a :: [i64], t :: i64) :: i64 do
    Enum.reduce_while(0..(len(a) - 1)//1, -1, fn i, _ ->
      if a[i] >= t, do: {:halt, i}, else: {:cont, -1}
    end)
  end

  defk find_at_least_nb(a :: [i64], t :: i64) :: i64, yield: false do
    find_at_least(a, t)
  end

  # many short and long early-exit flat loops inside a loop with a safepoint
  defk find_many(a :: [i64], reps :: i64) :: i64 do
    for r <- 1..reps//1, reduce: 0 do
      acc -> rem(acc * 7 + find_at_least(a, rem(r * 7919, len(a) + 50)), 1_000_000_007)
    end
  end

  defk find_many_nb(a :: [i64], reps :: i64) :: i64, yield: false do
    find_many(a, reps)
  end

  # over an array (as `for x <- a`): a tuple accumulator
  defk until_negative(a :: [f64]) :: {i64, f64} do
    Enum.reduce_while(a, {0, 0.0}, fn x, {n, s} ->
      if x < 0.0, do: {:halt, {n, s}}, else: {:cont, {n + 1, s + x}}
    end)
  end

  # a[i] is checked (n may exceed len(a)): out of bounds raises only if
  # reached before the halt; the inner fold gives the loop a safepoint
  defk sum_until(a :: [i64], stop :: i64, n :: i64) :: i64 do
    Enum.reduce_while(0..n//1, 0, fn i, acc ->
      extra =
        for k <- 0..rem(i, 3)//1, reduce: 0 do
          z -> z + k
        end

      if i == stop, do: {:halt, acc}, else: {:cont, acc + a[i] + extra}
    end)
  end

  defk sum_until_nb(a :: [i64], stop :: i64, n :: i64) :: i64, yield: false do
    sum_until(a, stop, n)
  end

  # ------------------------------------------------------------------ case --

  twin case_val(x :: i64) :: i64 do
    case x do
      0 ->
        10

      1 ->
        20

      -1 ->
        30

      n when n > 100 and rem(n, 2) == 0 ->
        n = n + 1
        n * 2

      _ ->
        40
    end
  end

  twin case_pin(x :: i64, y :: i64) :: i64 do
    case x do
      ^y -> 1
      z when z < y -> 2
      _ -> 3
    end
  end

  twin case_bool(b :: bool, x :: i64) :: i64 do
    case b do
      true -> x + 1
      false -> x - 1
    end
  end

  twin case_partial(x :: i64) :: i64 do
    case x do
      1 -> 10
      2 -> 20
    end
  end

  twin case_partial_bool(b :: bool) :: i64 do
    case b do
      true -> 1
    end
  end

  # pure-arithmetic arms in a loop: a select
  twin case_loop(n :: i64, step :: i64) :: i64 do
    for i <- 1..n//1, reduce: 0 do
      acc ->
        case rem(i, 4) do
          0 -> acc + step
          1 -> acc * 2
          _ -> acc - 1
        end
    end
  end

  twin case_sel(x :: i64, k :: i64) :: i64 do
    case k do
      0 -> x
      _ -> x * x
    end
  end

  # statement form: array writes in the arms, the last arm without a catch-all
  defk case_stmt(a :: [i64], strict :: bool) :: [i64] do
    out = alloc(i64, len(a))

    for i <- 0..(len(a) - 1)//1 do
      case rem(a[i], 3) do
        0 -> out[i] = 100
        1 -> out[i] = a[i] * 2
        _ when strict -> out[i] = -1
      end
    end

    out
  end
end

defmodule Defk.EarlyExitTest do
  use ExUnit.Case, async: false

  alias Defk.EarlyExitTest.K

  use Defk.Properties
  import Defk.TestKit

  @moduletag timeout: 120_000

  describe "early exit" do
    test "nested reduce_while: each halt ends only its own fold" do
      for stop <- [1, 2, 7, 50, 301, 2_000, 5_001] do
        expect = K.ex_nest3(5_000, stop)
        assert K.nest3(5_000, stop) == expect
        assert K.nest3_nb(5_000, stop) == expect
      end
    end

    test "halt at every point, including right after a forced yield" do
      n = 700

      {results, yields} =
        yields(K, fn -> forced(K, fn -> for stop <- 1..(n + 1), do: K.nest3(n, stop) end) end)

      assert yields > 0
      assert results == for(stop <- 1..(n + 1), do: K.ex_nest3(n, stop))
    end

    test "halt in an inlined callee, flat and natural/forced yields" do
      for x <- 2..500, do: assert(K.first_div(x) == K.ex_first_div(x))
      expect = K.ex_sum_first_divs(20_000)
      assert K.sum_first_divs(20_000) == expect
      assert K.sum_first_divs_nb(20_000) == expect
      {got, yields} = yields(K, fn -> forced(K, fn -> K.sum_first_divs(20_000) end) end)
      assert got == expect and yields > 0
    end

    test "select arms, statements before the tail, case/cond tails, counting down" do
      for {n, l} <- [{10, 5}, {100, 1_000}, {100, 1_000_000}, {0, 0}] do
        assert K.abs_sum_until(n, l) == K.ex_abs_sum_until(n, l)
      end

      for n <- [1, 10, 96, 97, 98, 1_000] do
        assert K.classify_until(n) == K.ex_classify_until(n)
      end
    end

    test "Enum.all? and Enum.any?" do
      for n <- [0, 1, 5, 30], k <- [1, 2, 7, 9, 25, 31] do
        assert K.all_any(n, k) == K.ex_all_any(n, k), "all_any(#{n}, #{k})"
      end

      for x <- 2..2_000 do
        assert K.prime?(x) == K.ex_prime?(x)
      end
    end

    test "flat loop exits on the short and the strip path, with forced yields" do
      a = i64s(Enum.to_list(0..9_999))

      for t <- [-5, 0, 1, 2_046, 2_047, 2_048, 2_049, 4_096, 9_999, 10_000] do
        expect = Enum.find_index(0..9_999, &(&1 >= t)) || -1
        assert K.find_at_least(a, t) == expect
        assert K.find_at_least_nb(a, t) == expect
        {got, yields} = yields(K, fn -> forced(K, fn -> K.find_at_least(a, t) end) end)
        assert got == expect
        if t > 2 * 2_048, do: assert(yields > 0, "strip path never yielded for t=#{t}")
      end

      assert K.find_at_least(<<>>, 1) == -1

      expect = K.find_many_nb(a, 300)
      assert K.find_many(a, 300) == expect
      {got, yields} = yields(K, fn -> forced(K, fn -> K.find_many(a, 300) end) end)
      assert got == expect and yields > 0
    end

    test "reduce_while over an array with a tuple accumulator" do
      for xs <- [[], [1.0, 2.0, -1.0, 5.0], [1.5, 2.5], [-1.0]] do
        expect =
          Enum.reduce_while(xs, {0, 0.0}, fn x, {n, s} ->
            if x < 0.0, do: {:halt, {n, s}}, else: {:cont, {n + 1, s + x}}
          end)

        assert K.until_negative(f64s(xs)) == expect
      end
    end

    test "out of bounds raises only when reached before the halt (natural and forced yields)" do
      len = 3_000
      a = i64s(Enum.to_list(1..len))

      ref = fn stop ->
        Enum.sum(1..stop//1) +
          Enum.sum(for i <- 0..(stop - 1)//1, do: div(rem(i, 3) * (rem(i, 3) + 1), 2))
      end

      for f <- [&K.sum_until/3, &K.sum_until_nb/3] do
        # halts before index len: no error
        assert f.(a, 10, len + 50) == ref.(10)
        assert f.(a, len, len + 50) == ref.(len)
        # index len is reached first
        e = assert_raise Enum.OutOfBoundsError, fn -> f.(a, len + 1, len + 50) end
        assert e.index == len
      end

      {got, y1} = yields(K, fn -> forced(K, fn -> K.sum_until(a, len, len + 50) end) end)
      assert got == ref.(len)

      {e, y2} =
        yields(K, fn ->
          forced(K, fn ->
            assert_raise(Enum.OutOfBoundsError, fn -> K.sum_until(a, len + 1, len + 50) end)
          end)
        end)

      assert e.index == len and y1 > 0 and y2 > 0
    end
  end

  describe "case" do
    test "value form with literals, negative literals, guards, binding and rebinding" do
      for x <- [-3, -1, 0, 1, 2, 100, 101, 102, 1_000, 1_001] do
        assert K.case_val(x) == K.ex_case_val(x), "case_val(#{x})"
      end

      for {x, y} <- [{1, 1}, {0, 1}, {2, 1}] do
        assert K.case_pin(x, y) == K.ex_case_pin(x, y)
      end

      for b <- [true, false], do: assert(K.case_bool(b, 5) == K.ex_case_bool(b, 5))
    end

    test "no matching clause raises CaseClauseError like Elixir" do
      assert K.case_partial(2) == 20
      e = assert_raise CaseClauseError, fn -> K.case_partial(3) end
      assert e == assert_raise(CaseClauseError, fn -> K.ex_case_partial(3) end)
      assert e == %CaseClauseError{term: 3}
      assert K.case_partial_bool(true) == 1
      e = assert_raise CaseClauseError, fn -> K.case_partial_bool(false) end
      assert e == assert_raise(CaseClauseError, fn -> K.ex_case_partial_bool(false) end)
    end

    test "pure arithmetic arms: a select, and only the taken arm's overflow raises" do
      assert K.case_loop(120, 7) == K.ex_case_loop(120, 7)
      big = 1_099_511_627_776
      assert K.case_sel(big, 0) == big

      assert_raise ArithmeticError, "i64 overflow in #{big} * #{big}", fn ->
        K.case_sel(big, 1)
      end

      c = File.read!(String.replace_suffix(K.__defk_lib__(), ".so", ".c"))
      assert c =~ "defk_mul_i64_s(&"
    end

    test "statement form" do
      xs = [3, 4, 5, 6, 7, 9, 10]
      out = for <<x::64-signed-native <- K.case_stmt(i64s(xs), true)>>, do: x

      assert out ==
               Enum.map(xs, fn x ->
                 case rem(x, 3) do
                   0 -> 100
                   1 -> x * 2
                   _ -> -1
                 end
               end)

      e = assert_raise CaseClauseError, fn -> K.case_stmt(i64s(xs), false) end
      assert e.term == 2
    end
  end

  describe "compile errors" do
    defp compile_error(body, ret \\ "i64"),
      do: reject(__MODULE__, kernel("x :: i64, f :: f64, b :: bool", ret, body, "bad"))

    test "reduce_while" do
      assert compile_error("Enum.reduce_while(1..x, 0, fn i, acc -> acc + i end)") =~
               "an Enum.reduce_while/3 fn returns acc + i, not {:cont, acc} or {:halt, acc}"

      assert compile_error(
               "Enum.reduce_while(1..x, 0, fn i, acc -> if(i > 2, do: {:halt, acc}) end)"
             ) =~
               "(defk reduce-while-tail"

      assert compile_error("Enum.reduce_while(1..x, {0, 0}, fn i, {a, c} -> {:cont, a} end)") =~
               "{:cont, acc} gives 1 value, the accumulator has 2"

      assert compile_error("Enum.reduce_while(1..x, 0, fn i, acc -> {:cont, f} end)") =~
               "the new value of acc f has type f64, expected i64"

      assert compile_error("Enum.reduce_while(1..x, 0, &foo/2)") =~
               "Enum.reduce_while/3 with &foo/2 is not in the kernel subset"

      assert compile_error("Enum.all?(1..x, &foo/1)", "bool") =~ "(defk fn-argument"

      assert compile_error("Enum.any?(1..x, fn i -> i end)", "bool") =~
               "a condition must be a boolean, and i is i64"
    end

    test "case" do
      assert compile_error("case f do\n_ -> 1\nend") =~
               "case on f, an f64 value, is not in the kernel subset"

      assert compile_error("case x do\n1.0 -> 1\n_ -> 2\nend") =~
               "the case pattern 1.0 is not in the kernel subset"

      assert compile_error("case x do\n{a, b} -> a\n_ -> 2\nend") =~
               "the case pattern {a, b} is not in the kernel subset"

      assert compile_error("case b do\n1 -> 1\n_ -> 2\nend") =~
               "the pattern 1 never matches a bool subject"

      assert compile_error("case x do\ny when bad(y, f, b) > 0 -> 1\n_ -> 2\nend") =~
               "bad(y, f, b) is not allowed in a case guard"

      assert compile_error("case x do\n1 -> 1\n_ -> 2.0\nend") =~
               "the branches of this case have different types: i64, f64"
    end
  end

  # ---------------------------------------------------- agreement properties --
  # Every kernel here against its Elixir mode (defk-ne6). Trip counts are
  # bounded, except where the loop stops early for every i64 (first_div,
  # prime?, classify_until stop within a few thousand steps on every edge
  # value); the i64 maximum stays in as an edge, since its range raises
  # before the loop starts.

  @min -0x8000000000000000
  @max 0x7FFFFFFFFFFFFFFF

  defp trips(n), do: G.i64(-5..n, [@min, @max])

  # [n, stop]: stop mostly inside the loop
  defp with_stop(n_gen) do
    bind(n_gen, fn n ->
      m = min(max(n, -5), 5_000)
      fixed_list([constant(n), frequency([{3, integer(-1..max(m + 1, -1))}, {1, G.i64()}])])
    end)
  end

  defp nest3, do: with_stop(trips(150))
  defp sum_first_divs, do: fixed_list([trips(400)])
  defp first_div, do: fixed_list([G.i64(-10..20_000, G.i64_edges())])
  defp abs_sum_until, do: fixed_list([trips(400), G.i64()])
  defp all_any, do: fixed_list([trips(1_000), G.i64()])
  defp primes, do: fixed_list([G.i64(-1_000..10_000_000_000, G.i64_edges())])
  defp find_many, do: fixed_list([G.array(:i64, max_length: 300), G.i64(-2..20, [@min, @max])])
  defp case_partial, do: fixed_list([one_of([member_of([1, 2]), G.i64()])])
  defp case_loop, do: fixed_list([trips(2_000), G.i64()])

  defp sum_until do
    bind(G.array(:i64, max_length: 300), fn a ->
      len = div(byte_size(a), 8)
      n = G.i64(-2..(len + 3), [@min, @max])

      bind(with_stop(n), fn [n, stop] ->
        fixed_list([constant(a), constant(stop), constant(n)])
      end)
    end)
  end

  agreement(K,
    nest3: [args: nest3()],
    nest3_nb: [args: nest3()],
    sum_first_divs: [args: sum_first_divs()],
    sum_first_divs_nb: [args: sum_first_divs()],
    first_div: [args: first_div()],
    first_div_nb: [args: first_div()],
    abs_sum_until: [args: abs_sum_until()],
    abs_sum_until_nb: [args: abs_sum_until()],
    classify_until: [],
    classify_until_nb: [],
    all_any: [args: all_any()],
    all_any_nb: [args: all_any()],
    prime?: [args: primes()],
    "prime?_nb": [args: primes()],
    find_at_least: [],
    find_at_least_nb: [],
    find_many: [args: find_many()],
    find_many_nb: [args: find_many()],
    until_negative: [],
    sum_until: [args: sum_until()],
    sum_until_nb: [args: sum_until()],
    case_val: [],
    case_val_nb: [],
    case_pin: [],
    case_pin_nb: [],
    case_bool: [],
    case_bool_nb: [],
    case_partial: [args: case_partial()],
    case_partial_nb: [args: case_partial()],
    case_partial_bool: [],
    case_partial_bool_nb: [],
    case_loop: [args: case_loop()],
    case_loop_nb: [args: case_loop()],
    case_sel: [],
    case_sel_nb: [],
    case_stmt: []
  )
end
