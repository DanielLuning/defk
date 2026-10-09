# Comparisons and min/max give Elixir's answer (defk-t11.2). Erlang compares
# an integer with a float by exact value (erts_cmp_compound in erts utils.c),
# never by rounding the integer to a double; =:= tells -0.0 from 0.0; and
# erlang:min/max return the first argument when the two compare equal.

defmodule Defk.ComparisonTest.K do
  use Defk

  defk cmp_if(a :: i64, b :: f64) :: {bool, bool, bool, bool, bool, bool, bool, bool} do
    {a === b, a !== b, a == b, a != b, a < b, a <= b, a > b, a >= b}
  end

  defk cmp_fi(a :: f64, b :: i64) :: {bool, bool, bool, bool, bool, bool, bool, bool} do
    {a === b, a !== b, a == b, a != b, a < b, a <= b, a > b, a >= b}
  end

  defk cmp_ff(a :: f64, b :: f64) :: {bool, bool, bool, bool, bool, bool, bool, bool} do
    {a === b, a !== b, a == b, a != b, a < b, a <= b, a > b, a >= b}
  end

  defk cmp_ii(a :: i64, b :: i64) :: {bool, bool, bool, bool, bool, bool, bool, bool} do
    {a === b, a !== b, a == b, a != b, a < b, a <= b, a > b, a >= b}
  end

  defk minmax_f(a :: f64, b :: f64) :: {f64, f64} do
    {min(a, b), max(a, b)}
  end

  defk minmax_i(a :: i64, b :: i64) :: {i64, i64} do
    {min(a, b), max(a, b)}
  end

  # a comparison inside a loop, where the compiler may vectorise
  defk count_below(xs :: [i64], t :: f64) :: i64 do
    for i <- 0..(len(xs) - 1)//1, reduce: 0 do
      acc -> if xs[i] < t, do: acc + 1, else: acc
    end
  end
end

defmodule Defk.ComparisonTest do
  use ExUnit.Case, async: true
  use Defk.Properties

  alias Defk.ComparisonTest.K

  @i64_min -0x8000000000000000
  @i64_max 0x7FFFFFFFFFFFFFFF
  @two53 9_007_199_254_740_992

  defp agree(fun, args) do
    native = Defk.ElixirMode.with_mode(:native, fn -> apply(K, fun, args) end)
    elixir = K.__defk_elixir__(fun, args)

    assert native === elixir,
           "#{fun}(#{Enum.map_join(args, ", ", &inspect/1)}): native #{inspect(native)}, Elixir mode #{inspect(elixir)}"

    native
  end

  # doubles next to x
  defp neighbours(x) when is_float(x) do
    <<bits::64>> = <<x::float-64>>

    for d <- [-1, 0, 1],
        b = bits + d,
        b >= 0,
        do:
          (
            <<f::float-64>> = <<b::64>>
            f
          )
  end

  defp ints,
    do: [
      0,
      1,
      -1,
      2,
      -3,
      @two53 - 1,
      @two53,
      @two53 + 1,
      -@two53 - 1,
      -@two53,
      -@two53 + 1,
      @two53 * 2 + 1,
      @i64_max,
      @i64_max - 1,
      @i64_min,
      @i64_min + 1,
      4_611_686_018_427_387_903,
      4_611_686_018_427_387_905
    ]

  defp floats do
    base = [
      0.0,
      -0.0,
      0.5,
      -0.5,
      1.0,
      -1.0,
      1.5,
      2.0,
      -2.5,
      9.007_199_254_740_992e15,
      -9.007_199_254_740_992e15,
      9.223_372_036_854_776e18,
      -9.223_372_036_854_776e18,
      4.611_686_018_427_388e18,
      1.0e300,
      -1.0e300
    ]

    Enum.uniq(
      Enum.flat_map(base, &neighbours(abs(&1))) ++
        Enum.flat_map(base, &Enum.map(neighbours(abs(&1)), fn f -> -f end))
    )
  end

  test "i64 against f64 compares exact values, as Elixir does" do
    for i <- ints(), f <- floats() ++ Enum.map(ints(), &(&1 * 1.0)) do
      agree(:cmp_if, [i, f])
      agree(:cmp_fi, [f, i])
    end
  end

  test "the cases that rounding the integer gets wrong" do
    # 2^53 + 1 rounds to 2^53 as a double
    assert K.cmp_if(@two53 + 1, @two53 * 1.0) ==
             {false, true, false, true, false, false, true, true}

    assert K.cmp_fi(@two53 * 1.0, @two53 + 1) ==
             {false, true, false, true, true, true, false, false}

    # i64_max rounds up to 2^63
    assert K.cmp_if(@i64_max, 9.223_372_036_854_776e18) ==
             {false, true, false, true, true, true, false, false}

    # i64_min is exactly -2^63
    assert K.cmp_if(@i64_min, -9.223_372_036_854_776e18) ==
             {false, true, true, false, false, true, false, true}

    assert K.cmp_if(0, -0.0) == {false, true, true, false, false, true, false, true}
  end

  test "same-type comparisons agree, including === on signed zeros" do
    for a <- floats(), b <- [0.0, -0.0, 1.0, a], do: agree(:cmp_ff, [a, b])
    assert K.cmp_ff(-0.0, 0.0) == {false, true, true, false, false, true, false, true}
    assert K.cmp_ff(0.0, 0.0) == {true, false, true, false, false, true, false, true}
    for a <- ints(), b <- [0, -1, @i64_max, a], do: agree(:cmp_ii, [a, b])
  end

  test "min and max return the first argument when both compare equal" do
    for {a, b} <- [{-0.0, 0.0}, {0.0, -0.0}, {0.0, 0.0}, {-0.0, -0.0}] do
      assert agree(:minmax_f, [a, b]) === {a, a}
    end

    for a <- floats(), b <- [0.0, -0.0, 1.0, -1.0e300], do: agree(:minmax_f, [a, b])
    for a <- ints(), b <- [0, -1, @i64_max, @i64_min], do: agree(:minmax_i, [a, b])
  end

  test "a mixed comparison in a loop" do
    xs = [@two53 - 1, @two53, @two53 + 1, @i64_max, @i64_min, 0, -1]
    bin = for x <- xs, into: <<>>, do: <<x::64-signed-native>>

    for t <- [@two53 * 1.0, 9.223_372_036_854_776e18, -9.223_372_036_854_776e18, 0.0, -0.0, 0.5] do
      assert agree(:count_below, [bin, t]) == Enum.count(xs, &(&1 < t))
    end
  end

  # ---------------------------------------------------- agreement properties --
  # Every kernel here against its Elixir mode (defk-ne6), on the i64 and f64
  # edge values: 2^53 and 2^63 and their neighbours, signed zeros.

  agreement(K, [:cmp_if, :cmp_fi, :cmp_ff, :cmp_ii, :minmax_f, :minmax_i, :count_below])
end
