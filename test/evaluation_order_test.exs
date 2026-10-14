# The operands of an operation are evaluated left to right, as in Elixir, so
# when two of them can raise, the leftmost error is the one raised
# (defk-wfi.8). C orders neither the arguments of a call nor the operands of
# most operators: gcc on x86-64 evaluated them right to left, and an
# operand's statements (a loop, an inlined kernel) ran before the checks of
# the operands left of it on every compiler.

defmodule Defk.EvaluationOrderTest.K do
  use Defk

  defk big(x :: f64) :: f64 do
    x * 1.0e308 * 10.0
  end

  # inline operands: an index read, a checked float expression
  defk read_then_float(a :: [f64], x :: f64) :: f64 do
    a[5] + x * 1.0e308 * 10.0
  end

  defk float_then_read(a :: [f64], x :: f64) :: f64 do
    x * 1.0e308 * 10.0 + a[5]
  end

  defk read_then_overflow(ix :: [i64], k :: i64) :: i64 do
    ix[5] + k * 9_223_372_036_854_775_807
  end

  defk overflow_then_overflow(a :: i64, b :: i64) :: i64 do
    a * b + b * a * 3
  end

  defk read_lt_float(a :: [f64], x :: f64) :: bool do
    a[5] < x * 1.0e308 * 10.0
  end

  defk min_of(a :: [f64], x :: f64) :: f64 do
    min(a[5], x * 1.0e308 * 10.0)
  end

  defk masked(ix :: [i64], k :: i64) :: i64 do
    band(ix[5] + k * 9_223_372_036_854_775_807, 0xFF)
  end

  # the index before the stored value
  defk store(a :: [f64], ix :: [i64], k :: i64) :: [f64] do
    out = alloc(f64, 4)
    out[ix[0] * k] = a[0] * 2.0
    out
  end

  # operands with statements
  defk read_then_loop(a :: [f64], b :: [f64]) :: f64 do
    a[5] +
      for x <- b, reduce: 0.0 do
        acc -> acc + x * 1.0e308 * 10.0
      end
  end

  defk read_then_kernel(a :: [f64], x :: f64) :: f64 do
    a[5] + big(x)
  end

  defk kernel_args(a :: [f64], x :: f64) :: f64 do
    big(a[5] + big(x))
  end

  defk tuple_items(a :: [f64], x :: f64) :: f64 do
    {p, q} = {a[5], big(x)}
    p + q
  end

  defk range_bounds(ix :: [i64], b :: [f64]) :: f64 do
    for i <- ix[5]..(length(b) - 1 + trunc(big(b[0])))//1, reduce: 0.0 do
      acc -> acc + float(i)
    end
  end
end

defmodule Defk.EvaluationOrderTest do
  use ExUnit.Case, async: true
  alias Defk.EvaluationOrderTest.K

  @max_i64 9_223_372_036_854_775_807

  defp f(xs), do: for(x <- xs, into: <<>>, do: <<x::float-native-64>>)
  defp i(xs), do: for(x <- xs, into: <<>>, do: <<x::signed-native-64>>)

  defp agrees(fun, args), do: Defk.Test.assert_agrees(K, fun, args, forced_yields: true)

  defp index_error(fun, args),
    do: assert({:raise, %Enum.OutOfBoundsError{}} = agrees(fun, args))

  test "an index error left of a float error is raised first" do
    index_error(:read_then_float, [f([1.0]), 1.0])
    index_error(:read_lt_float, [f([1.0]), 1.0])
    index_error(:min_of, [f([1.0]), 1.0])
  end

  test "a float error left of an index error is raised first" do
    assert {:raise, %ArithmeticError{}} = agrees(:float_then_read, [f([1.0]), 1.0])
  end

  test "an index error left of an overflow is raised first" do
    index_error(:read_then_overflow, [i([1]), 2])
    index_error(:masked, [i([1]), 2])
  end

  test "of two overflows, the left one is raised" do
    assert {:raise, %ArithmeticError{message: msg}} =
             agrees(:overflow_then_overflow, [@max_i64, 2])

    assert msg == "i64 overflow in #{@max_i64} * 2"
  end

  test "a store checks its index before the value it stores" do
    assert {:raise, %ArithmeticError{message: "i64 overflow in " <> _}} =
             agrees(:store, [f([1.0e308]), i([2 ** 62]), 4])

    assert {:raise, %ArithmeticError{}} = agrees(:store, [f([1.0e308]), i([1]), 2])
    assert {:ok, _} = agrees(:store, [f([1.0]), i([1]), 2])
  end

  test "an operand's statements run after the checks left of it" do
    index_error(:read_then_loop, [f([1.0]), f([1.0])])
    index_error(:read_then_kernel, [f([1.0]), 1.0])
    index_error(:kernel_args, [f([1.0]), 1.0])
    index_error(:tuple_items, [f([1.0]), 1.0])
    index_error(:range_bounds, [i([1]), f([1.0])])
    six = f([1.0, 2.0, 3.0, 4.0, 5.0, 6.0])
    assert {:ok, 6.0} = agrees(:read_then_loop, [six, f([0.0])])
    assert {:ok, 6.0} = agrees(:tuple_items, [six, 0.0])
  end
end
