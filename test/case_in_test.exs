# `in` in case guards (defk-gid): `x when x in [1, 2, 3]`, `x when x in 1..10`,
# `x when x in a..b//s`, and `not in`. Every kernel is written once by `twin`,
# which defines the kernel and the same body as a plain Elixir function
# (`ex_`), so results (and CaseClauseError) are compared with Elixir itself,
# and, for ranges, with Enum.member?/2.

defmodule Defk.CaseInTest.Twin do
  @min -0x8000000000000000
  @max 0x7FFFFFFFFFFFFFFF

  defmacro twin(head, do: body) do
    {:"::", _, [{name, _, params}, _ret]} = head
    vars = for {:"::", _, [v, _t]} <- params, do: v

    quote do
      defk(unquote(head), do: unquote(body))
      def unquote(:"ex_#{name}")(unquote_splicing(vars)), do: unquote(body)
    end
  end

  # one `range_<i>(x)` kernel per {first, last, step | nil} spec: 1 when x is
  # in the literal range, else 0 (the range is parsed from its source text, so
  # negative literals are written as in a kernel)
  defmacro range_kernels do
    specs = specs()

    for {{first, last, step}, i} <- Enum.with_index(specs) do
      range = Code.string_to_quoted!(range_src(first, last, step))
      name = :"range_#{i}"

      quote do
        defk unquote(name)(x :: i64) :: i64 do
          case x do
            n when n in unquote(range) -> 1
            _ -> 0
          end
        end
      end
    end
  end

  # hand-picked ranges: ascending and descending, with and without a step,
  # negative steps, empty ranges (1..0//1 contains nothing), single elements,
  # a step beyond the span, and the i64 edges
  @specs [
    {1, 10, nil},
    {10, 1, nil},
    {-5, 5, nil},
    {5, 5, nil},
    {1, 10, 3},
    {1, 10, 1},
    {10, 1, -3},
    {10, 1, -1},
    {0, -10, -2},
    {-9, 9, 4},
    {9, -9, -4},
    {7, 7, 5},
    {7, 7, -5},
    {1, 0, 1},
    {0, 1, -1},
    {5, 1, 1},
    {1, 5, -1},
    {1, 5, 100},
    {5, 1, -100},
    {-7, 20, 6},
    {@min, @max, 4_611_686_018_427_387_903},
    {@min, @max, -4_611_686_018_427_387_903},
    {@max, @min, -4_611_686_018_427_387_903},
    {@min, @min + 10, 3},
    {@max - 10, @max, 3},
    {@max, @max - 10, -3},
    {@min, @max, nil},
    {@min, @max, 1}
  ]

  # more, drawn from a fixed seed: small bounds and steps of either sign, so
  # most are stepped, and many are empty
  @random_specs (
                  :rand.seed(:exsss, {11, 22, 33})
                  r = fn -> :rand.uniform(41) - 21 end

                  for _ <- 1..60 do
                    {r.(), r.(),
                     Enum.random([nil, r.(), r.() * 2]) |> then(&if(&1 == 0, do: 3, else: &1))}
                  end
                )

  @all_specs @specs ++ @random_specs
  def specs, do: @all_specs

  def range_src(first, last, nil), do: "(#{first})..(#{last})"
  def range_src(first, last, step), do: "(#{first})..(#{last})//(#{step})"
end

defmodule Defk.CaseInTest.K do
  use Defk
  import Defk.CaseInTest.Twin

  def specs, do: Defk.CaseInTest.Twin.specs()

  range_kernels()

  # ------------------------------------------------------------------ lists --

  twin in_list(x :: i64) :: i64 do
    case x do
      n when n in [1, 2, 3] -> 10
      n when n in [-5, 7, 7, 9_223_372_036_854_775_807] -> 20
      _ -> 0
    end
  end

  twin not_in_list(x :: i64) :: i64 do
    case x do
      n when n not in [1, 2, 3] -> 1
      _ -> 2
    end
  end

  # no twin: Elixir warns that the guard never succeeds
  defk in_empty_list(x :: i64) :: i64 do
    case x do
      _ when x in [] -> 1
      _ when x not in [] -> 2
    end
  end

  twin in_list_bool(b :: bool) :: i64 do
    case b do
      c when c in [true] -> 1
      c when c not in [true] -> 2
    end
  end

  twin in_list_bool2(b :: bool) :: i64 do
    case b do
      c when c in [false, true] -> 1
    end
  end

  # no clause matches for some x: CaseClauseError
  twin in_partial(x :: i64) :: i64 do
    case x do
      n when n in [1, 2] -> 10
      n when n in 5..7 -> 20
    end
  end

  # the guard variable need not be the pattern: any guard-safe expression
  twin in_expr(x :: i64) :: i64 do
    case x do
      _ when rem(x, 5) in [0, 1] -> 1
      _ when (x + 1) in 10..20//2 -> 2
      _ when (x * 2) not in -4..4 -> 3
      _ -> 4
    end
  end

  # with other guard operators, a pin and a binding in the body
  twin in_combined(x :: i64, y :: i64) :: i64 do
    case x do
      ^y -> 0
      n when n in 1..10 and rem(n, 2) == 0 -> n * 2
      n when n in [11, 13] or n in 20..30//5 -> n + 1
      n when n not in -3..3 and n > y -> n - y
      _ -> -1
    end
  end

  # as a statement, in a loop
  twin in_loop(n :: i64) :: i64 do
    for i <- 1..n//1, reduce: 0 do
      acc ->
        case rem(i, 9) do
          r when r in [0, 4] -> acc + 3
          r when r in 6..8 -> acc * 2 - 1
          r when r not in 1..5 -> acc + 100
          _ -> acc - 1
        end
    end
  end

  # ------------------------------------------------------- variable bounds --

  # variable bounds need the explicit step 1 or -1, as Elixir requires
  twin in_var_up(x :: i64, a :: i64, b :: i64) :: i64 do
    case x do
      n when n in a..b//1 -> 1
      _ -> 0
    end
  end

  twin in_var_down(x :: i64, a :: i64, b :: i64) :: i64 do
    case x do
      n when n in a..b//-1 -> 1
      _ -> 0
    end
  end

  twin not_in_var(x :: i64, a :: i64) :: i64 do
    case x do
      n when n not in (a - 2)..(a + 2)//1 -> 1
      _ -> 0
    end
  end
end

defmodule Defk.CaseInTest do
  use ExUnit.Case, async: false
  use ExUnitProperties

  import Defk.TestKit

  alias Defk.CaseInTest.K
  alias Defk.CaseInTest.Twin
  alias Defk.Generators, as: G

  @moduletag timeout: 300_000

  @min -0x8000000000000000
  @max 0x7FFFFFFFFFFFFFFF
  @edges [@min, @min + 1, -1, 0, 1, @max - 1, @max]

  defp range_of(first, last, nil), do: Range.new(first, last, if(first <= last, do: 1, else: -1))
  defp range_of(first, last, step), do: Range.new(first, last, step)

  describe "literal lists" do
    test "in, not in, an empty list, bools, both modes agree with Elixir" do
      for x <- Enum.to_list(-8..12) ++ @edges do
        for fun <- [:in_list, :not_in_list, :in_partial, :in_expr] do
          if fun == :in_partial and x not in [1, 2, 5, 6, 7],
            do: assert_raise(CaseClauseError, fn -> apply(K, fun, [x]) end),
            else: Defk.Test.assert_agrees(K, fun, [x])
        end
      end

      assert K.in_empty_list(5) == 2
      assert K.in_list(2) == 10
      assert K.in_list(@max) == 20
      assert K.in_list(4) == 0
      assert K.not_in_list(2) == 2
      assert K.not_in_list(4) == 1

      for b <- [true, false] do
        Defk.Test.assert_agrees(K, :in_list_bool, [b])
        Defk.Test.assert_agrees(K, :in_list_bool2, [b])
      end
    end

    test "no clause matching raises CaseClauseError like Elixir" do
      e = assert_raise CaseClauseError, fn -> K.in_partial(3) end
      assert e == assert_raise(CaseClauseError, fn -> K.ex_in_partial(3) end)
      assert K.in_partial(6) == 20
      assert K.in_partial(2) == 10
    end
  end

  describe "ranges" do
    test "every range spec agrees with Enum.member?/2 and with Elixir mode" do
      for {{first, last, step}, i} <- Enum.with_index(K.specs()) do
        range = range_of(first, last, step)
        name = :"range_#{i}"

        xs =
          Enum.to_list(-45..45) ++
            @edges ++
            Enum.flat_map([first, last], &[&1 - 1, &1, &1 + 1]) ++
            if(is_integer(step), do: [first + step, last - step], else: [])

        for x <- Enum.uniq(xs), x in @min..@max do
          expect = if Enum.member?(range, x), do: 1, else: 0
          assert Defk.Test.assert_agrees(K, name, [x]) == {:ok, expect}, "#{inspect(range)}, #{x}"
        end
      end
    end

    property "random subjects, random specs: agree with Enum.member?/2" do
      specs = Enum.with_index(K.specs())

      check all(
              {{first, last, step}, i} <- member_of(specs),
              x <- one_of([G.i64(), integer(-45..45), G.i64(-1_000..1_000, @edges)]),
              max_runs: 400
            ) do
        expect = if Enum.member?(range_of(first, last, step), x), do: 1, else: 0

        assert Defk.Test.assert_agrees(K, :"range_#{i}", [x]) == {:ok, expect},
               "#{Twin.range_src(first, last, step)}, #{x}"
      end
    end

    test "negative steps, empty ranges and single elements, spelled out" do
      # 1..0//1 and 5..1//1 contain nothing; 10..1//-3 is 10, 7, 4, 1
      for x <- -2..12, do: assert(K.ex_in_expr(x) == K.in_expr(x))

      idx = fn spec -> Enum.find_index(K.specs(), &(&1 == spec)) end
      in_range? = fn spec, x -> apply(K, :"range_#{idx.(spec)}", [x]) == 1 end

      assert Enum.filter(-2..12, &in_range?.({10, 1, -3}, &1)) == [1, 4, 7, 10]
      assert Enum.filter(-2..12, &in_range?.({1, 0, 1}, &1)) == []
      assert Enum.filter(-2..12, &in_range?.({5, 1, 1}, &1)) == []
      assert Enum.filter(-2..12, &in_range?.({1, 5, -1}, &1)) == []
      assert Enum.filter(-2..12, &in_range?.({10, 1, nil}, &1)) == Enum.to_list(1..10)
      assert Enum.filter(-2..12, &in_range?.({7, 7, -5}, &1)) == [7]
      assert Enum.filter(-12..12, &in_range?.({-9, 9, 4}, &1)) == [-9, -5, -1, 3, 7]
    end

    test "combined with other guard operators, in loops, and with not in" do
      for x <- -6..35, y <- [-4, 0, 3, 12, 40] do
        Defk.Test.assert_agrees(K, :in_combined, [x, y])
      end

      for n <- [-3, 0, 1, 10, 50, 200], do: Defk.Test.assert_agrees(K, :in_loop, [n])
    end

    property "in_combined and in_loop agree over random arguments" do
      check all(
              x <- one_of([integer(-40..40), G.i64()]),
              y <- one_of([integer(-40..40), G.i64()]),
              max_runs: 300
            ) do
        Defk.Test.assert_agrees(K, :in_combined, [x, y])
      end

      check all(n <- integer(-5..400), max_runs: 50) do
        Defk.Test.assert_agrees(K, :in_loop, [n])
      end
    end
  end

  describe "variable bounds" do
    test "ranges with variable bounds and step 1 / -1 match Enum.member?/2" do
      bounds = [-3, 0, 4, @min, @max]

      for x <- [-4, -3, 0, 2, 4, 5] ++ @edges, a <- bounds, b <- bounds do
        assert Defk.Test.assert_agrees(K, :in_var_up, [x, a, b]) == {:ok, ite(x in a..b//1)}
        assert Defk.Test.assert_agrees(K, :in_var_down, [x, a, b]) == {:ok, ite(x in a..b//-1)}
      end
    end

    property "random bounds and subjects" do
      check all(
              x <- one_of([integer(-30..30), G.i64()]),
              a <- one_of([integer(-30..30), G.i64()]),
              b <- one_of([integer(-30..30), G.i64()]),
              max_runs: 300
            ) do
        assert Defk.Test.assert_agrees(K, :in_var_up, [x, a, b]) == {:ok, ite(x in a..b//1)}
        assert Defk.Test.assert_agrees(K, :in_var_down, [x, a, b]) == {:ok, ite(x in a..b//-1)}
        Defk.Test.assert_agrees(K, :not_in_var, [x, rem(a, 1_000)])
      end
    end
  end

  defp ite(true), do: 1
  defp ite(false), do: 0

  describe "compile errors" do
    defp compile_error(body, ret \\ "i64"),
      do: reject(__MODULE__, kernel("x :: i64, f :: f64, b :: bool", ret, body, "bad"))

    defp guard_error(guard) do
      compile_error("case x do\nn when #{guard} -> 1\n_ -> 2\nend")
    end

    test "an unsupported in form names the construct, as case-guard" do
      for g <- ["n in [1, x]", "n in [1, 2.5]", "n in [1, :a]", "n in x", "n in [1 | x]"] do
        msg = guard_error(g)
        assert msg =~ "(defk case-guard", g
        assert msg =~ "#{g} in a case guard needs a literal list of integers or booleans", g
      end

      assert guard_error("n in [true, 1]") =~ "needs a literal list"
    end

    test "range bounds: variables only with step 1 / -1; the step is a nonzero literal" do
      assert guard_error("n in 1..x") =~
               "the range 1..x in a case guard needs literal first and last, or an explicit step of 1 or -1"

      assert guard_error("n in 1..x//2") =~
               "the stepped range 1..x//2 in a case guard needs literal first, last and step"

      assert guard_error("n in x..10//-2") =~ "needs literal first, last and step"
      assert guard_error("n in 1..10//x") =~ "needs literal first, last and step"
      assert guard_error("n in 1..10//0") =~ "the step of 1..10//0 must not be zero"

      assert guard_error("n in 1..10//-9223372036854775808") =~
               "a step must be within -9223372036854775807..9223372036854775807"

      assert guard_error("n in 1..9223372036854775808") =~ "needs literals within the i64 range"
      assert guard_error("n in 1..1.5") =~ "needs literal first and last"

      assert guard_error("n in 1..f//1") =~
               "f is f64, an integer is needed as a bound of n in 1..f//1"
    end

    test "the left side must be an integer (a bool only with a list), as in Elixir" do
      assert guard_error("f in 1..3") =~ "f is f64, an integer is needed on the left of f in 1..3"
      assert guard_error("f in [1, 2]") =~ "f is f64, an integer or bool is needed"
      assert guard_error("b in 1..3") =~ "b is bool, an integer is needed"
      assert guard_error("b in [1, 2]") =~ "never matches: b is bool"
      assert guard_error("n in [true]") =~ "never matches: n is i64"

      assert guard_error("n in f..3//-1") =~
               "f is f64, an integer is needed as a bound of n in f..3//-1"
    end

    test "in outside a guard stays unsupported" do
      assert compile_error("if x in [1, 2], do: 1, else: 2") =~ "is not in the kernel subset"
    end
  end
end
