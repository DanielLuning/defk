# A value bound to `_` or `_name` is still evaluated for its effects, as in
# Elixir (defk-776): the raise lives in the expression, so dropping it made
# the native kernel continue where Elixir mode raised.

defmodule Defk.UnderscoreBindingTest.K do
  use Defk

  defk under_alloc(n :: i64) :: i64 do
    _ = alloc(f64, -1)
    n
  end

  defk under_oob(a :: [f64]) :: i64 do
    _ = a[length(a)]
    length(a)
  end

  defk under_mul(x :: i64) :: i64 do
    _ = x * x
    x
  end

  defk bad_loop(a :: [f64]) :: i64 do
    for i <- 0..length(a)//1, reduce: 0 do
      s -> s + trunc(a[i])
    end
  end

  defk under_call(a :: [f64]) :: i64 do
    _r = bad_loop(a)
    length(a)
  end

  defk bare_alloc(n :: i64) :: i64 do
    alloc(f64, -1)
    n
  end

  defk harmless(x :: i64) :: i64 do
    _ = x + 1
    x
  end

  defk last_value(x :: i64) :: i64 do
    _ = x + 1
  end
end

defmodule Defk.UnderscoreBindingTest do
  use ExUnit.Case, async: true

  alias Defk.UnderscoreBindingTest.K

  test "_ = alloc(f64, -1) raises ArgumentError" do
    assert {:raise, %ArgumentError{}} = Defk.Test.assert_agrees(K, :under_alloc, [1])
  end

  test "_ = a[length(a)] raises Enum.OutOfBoundsError" do
    assert {:raise, %Enum.OutOfBoundsError{}} =
             Defk.Test.assert_agrees(K, :under_oob, [
               <<1.0::float-native-64, 2.0::float-native-64>>
             ])
  end

  test "_ = x * x overflow raises ArithmeticError" do
    assert {:raise, %ArithmeticError{}} =
             Defk.Test.assert_agrees(K, :under_mul, [4_000_000_000])
  end

  test "_r = helper(a) runs the helper, whose loop raises" do
    assert {:raise, %Enum.OutOfBoundsError{}} =
             Defk.Test.assert_agrees(K, :under_call, [
               <<1.0::float-native-64, 2.0::float-native-64>>
             ])
  end

  test "a bare alloc(f64, -1) statement raises" do
    assert {:raise, %ArgumentError{}} = Defk.Test.assert_agrees(K, :bare_alloc, [1])
  end

  test "a harmless _ = x + 1 compiles and returns x" do
    assert {:ok, 7} = Defk.Test.assert_agrees(K, :harmless, [7])
  end

  test "_ = rhs as the last expression still yields rhs" do
    assert {:ok, 8} = Defk.Test.assert_agrees(K, :last_value, [7])
  end
end
