defmodule Defk.YieldFalseStripTest do
  use ExUnit.Case, async: true

  # Test that yield: false kernels with strip loops don't generate
  # "set but not used" warnings. The strip loop emits v_rem_N that is
  # assigned but used in DEFK_SHORT(v_rem_N). When DEFK_SHORT is defined
  # as ((void)(R), 1) for no-yield, the variable is marked as intentionally
  # unused and clang doesn't warn.

  defp i64s(list), do: for(x <- list, into: <<>>, do: <<x::64-signed-native>>)

  test "yield: false kernel with loop generates no 'set but not used' warning" do
    defmodule K do
      use Defk

      # A simple reduce over an array - this generates a strip loop
      defk sum_array_nb(a :: [i64]) :: i64, yield: false do
        for x <- a, reduce: 0 do
          acc -> acc + x
        end
      end
    end

    # Get the generated C source
    src = K.__defk_source__()

    # The generated code should contain the pattern for the no-yield DEFK_SHORT macro,
    # which marks the variable as intentionally unused: ((void)(v_rem_N), 1)
    assert src =~ "((void)",
           "Generated C should use ((void) to mark variable as intentionally unused"

    # Verify the kernel works (basic functionality test)
    assert K.sum_array_nb(i64s([1, 2, 3, 4, 5])) == 15
  end

  test "yield: false kernel with product reduction" do
    defmodule K2 do
      use Defk

      defk product_nb(a :: [i64]) :: i64, yield: false do
        for x <- a, reduce: 1 do
          acc -> acc * x
        end
      end
    end

    src = K2.__defk_source__()
    # Verify the macro expansion is in place
    assert src =~ "((void)", "Generated C should use ((void) macro"

    # Verify functionality
    assert K2.product_nb(i64s([1, 2, 3, 4, 5])) == 120
  end

  test "yield: false kernel with double-nested loops" do
    defmodule K3 do
      use Defk

      defk matrix_sum_nb(rows :: i64, cols :: i64) :: i64, yield: false do
        for i <- 1..rows//1, reduce: 0 do
          sum ->
            for j <- 1..cols//1, reduce: sum do
              inner_sum ->
                inner_sum + i + j
            end
        end
      end
    end

    src = K3.__defk_source__()
    # Both nested loops should have the macro expansion
    assert src =~ "((void)", "Generated C should use ((void) macro"

    # Verify functionality
    # Sum for 2x2: (1+1 + 1+2) + (2+1 + 2+2) = 2 + 3 + 3 + 4 = 12
    assert K3.matrix_sum_nb(2, 2) == 12
  end
end
