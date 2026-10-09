# An `if` or `cond` value whose arms are pure arithmetic is compiled as a
# select: every arm is computed, overflow is flagged instead of raised, and
# only an overflow in the taken arm (or a reached condition) raises
# (defk-jp3, defk-7q5).

defmodule Defk.SelectTest.K do
  use Defk

  defk count_if(n :: i64, step :: i64) :: i64 do
    for i <- 1..n//1, reduce: 0 do
      acc -> if rem(i, 3) == 0, do: acc + step, else: acc - 1
    end
  end

  defk square_unless(keep :: bool, x :: i64) :: i64 do
    if keep, do: x, else: x * x
  end

  defk next_or_neg(c :: bool, x :: i64) :: i64 do
    if c, do: x + 1, else: -x
  end

  defk cmp_arms(c :: bool, x :: i64, y :: i64) :: bool do
    if c, do: x + 1 > y, else: x * 2 < y
  end

  defk cond_count(n :: i64, step :: i64) :: i64 do
    for i <- 1..n//1, reduce: 0 do
      acc ->
        cond do
          rem(i, 3) == 0 -> acc + step
          rem(i, 5) == 0 -> acc * 2
          true -> acc - 1
        end
    end
  end

  defk cond_square(keep :: bool, x :: i64) :: i64 do
    cond do
      keep -> x
      true -> x * x
    end
  end

  # the second condition overflows only when it is reached
  defk cond_later(c :: bool, x :: i64) :: i64 do
    cond do
      c -> x
      x * x > 0 -> x + 1
      true -> -x
    end
  end

  defk odd?(x :: i64) :: bool do
    rem(x, 2) == 1
  end

  # first condition calls a kernel; a later one does too and stays a branch
  defk cond_calls(x :: i64) :: i64 do
    cond do
      odd?(x) -> x * x
      odd?(x + 1) and x > 0 -> x + 1
      true -> -x
    end
  end
end

defmodule Defk.SelectTest do
  use ExUnit.Case, async: true

  alias Defk.SelectTest.K

  @big 1_099_511_627_776
  @min -9_223_372_036_854_775_808

  test "matches Elixir" do
    expect =
      Enum.reduce(1..10_000, 0, fn i, acc -> if rem(i, 3) == 0, do: acc + 7, else: acc - 1 end)

    assert K.count_if(10_000, 7) == expect
    assert K.cmp_arms(true, 3, 3) and not K.cmp_arms(false, 3, 3)
  end

  test "overflow in the untaken arm does not raise" do
    assert K.square_unless(true, @big) == @big
    assert K.next_or_neg(true, @min) == @min + 1
  end

  test "overflow in the taken arm raises the checked error" do
    assert_raise ArithmeticError, "i64 overflow in #{@big} * #{@big}", fn ->
      K.square_unless(false, @big)
    end

    assert_raise ArithmeticError, "i64 overflow in 0 - #{@min}", fn ->
      K.next_or_neg(false, @min)
    end

    assert_raise ArithmeticError, ~r/i64 overflow in -?\d+ \+ \d+/, fn ->
      K.count_if(10, 9_223_372_036_854_775_000)
    end
  end

  test "cond matches Elixir" do
    expect =
      Enum.reduce(1..200, 0, fn i, acc ->
        cond do
          rem(i, 3) == 0 -> acc + 7
          rem(i, 5) == 0 -> acc * 2
          true -> acc - 1
        end
      end)

    assert K.cond_count(200, 7) == expect
    assert K.cond_later(false, 3) == 4 and K.cond_later(false, 0) == 0
    assert Enum.map([3, 4, 0, -4], &K.cond_calls/1) == [9, 5, 0, 4]
  end

  test "cond: overflow in an untaken arm or unreached condition does not raise" do
    assert K.cond_square(true, @big) == @big
    assert K.cond_later(true, @big) == @big
    assert K.cond_later(true, @min) == @min
  end

  test "cond: overflow in the taken arm or a reached condition raises the checked error" do
    assert_raise ArithmeticError, "i64 overflow in #{@big} * #{@big}", fn ->
      K.cond_square(false, @big)
    end

    assert_raise ArithmeticError, "i64 overflow in #{@big} * #{@big}", fn ->
      K.cond_later(false, @big)
    end

    assert_raise ArithmeticError, ~r/i64 overflow in -?\d+ [+*] \d+/, fn ->
      K.cond_count(10, 9_223_372_036_854_775_000)
    end
  end

  test "pure arithmetic arms compile to a select" do
    c = File.read!(String.replace_suffix(K.__defk_lib__(), ".so", ".c"))
    assert c =~ "defk_add_i64_s(&"
  end
end
