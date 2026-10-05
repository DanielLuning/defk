# An `if` value whose arms are pure arithmetic is compiled as a select: both
# arms are computed, overflow is flagged instead of raised, and only an
# overflow in the taken arm raises (defk-jp3).

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
end

defmodule Defk.SelectTest do
  use ExUnit.Case, async: true

  alias Defk.SelectTest.K

  @big 1_099_511_627_776
  @min -9_223_372_036_854_775_808

  test "matches Elixir" do
    expect = Enum.reduce(1..10_000, 0, fn i, acc -> if rem(i, 3) == 0, do: acc + 7, else: acc - 1 end)
    assert K.count_if(10_000, 7) == expect
    assert K.cmp_arms(true, 3, 3) and not K.cmp_arms(false, 3, 3)
  end

  test "overflow in the untaken arm does not raise" do
    assert K.square_unless(true, @big) == @big
    assert K.next_or_neg(true, @min) == @min + 1
  end

  test "overflow in the taken arm raises the checked error" do
    assert_raise ArithmeticError, "i64 overflow in #{@big} * #{@big}", fn -> K.square_unless(false, @big) end
    assert_raise ArithmeticError, "i64 overflow in 0 - #{@min}", fn -> K.next_or_neg(false, @min) end
    assert_raise ArithmeticError, ~r/i64 overflow in -?\d+ \+ \d+/, fn -> K.count_if(10, 9_223_372_036_854_775_000) end
  end

  test "pure arithmetic arms compile to a select" do
    c = File.read!(String.replace_suffix(K.__defk_lib__(), ".so", ".c"))
    assert c =~ "defk_add_i64_s(&"
  end
end
