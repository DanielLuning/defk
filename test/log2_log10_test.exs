# log2 and log10 call the libm function :math.log2/1 and :math.log10/1 call,
# so the bits are the same: checked at edge values against :math
# itself, and against Elixir mode by the properties in sincos_test.exs.

defmodule Defk.Log2Log10Test.K do
  use Defk

  defk l2(x :: f64) :: f64 do
    log2(x)
  end

  defk l10(x :: f64) :: f64 do
    log10(x)
  end

  defk m2(x :: f64) :: f64 do
    :math.log2(x)
  end

  defk m10(x :: f64) :: f64 do
    :math.log10(x)
  end
end

defmodule Defk.Log2Log10Test do
  use ExUnit.Case, async: true

  alias Defk.Log2Log10Test.K

  @max 1.797_693_134_862_315_7e308
  @edges [1.0, 2.0, 0.5, 10.0, 100.0, 0.1, 3.0, 1.0e-300, 4.9e-324, 2.2250738585072014e-308, @max] ++
           for(k <- -1074..1023//37, do: :math.pow(2.0, k)) ++
           for(k <- -300..300//13, do: String.to_float("1.0e#{k}"))

  defp bits(x), do: <<x::float-64>>

  test "the kernel's log2 and log10 are :math's, bit for bit, at edge values" do
    for x <- @edges do
      assert bits(K.l2(x)) == bits(:math.log2(x))
      assert bits(K.m2(x)) == bits(:math.log2(x))
      assert bits(K.l10(x)) == bits(:math.log10(x))
      assert bits(K.m10(x)) == bits(:math.log10(x))
      assert {:ok, _} = Defk.Test.assert_agrees(K, :l2, [x])
      assert {:ok, _} = Defk.Test.assert_agrees(K, :l10, [x])
    end
  end

  test "exact powers give exact results" do
    assert K.l2(1.0) === 0.0
    assert K.l2(1024.0) === 10.0
    assert K.l10(1000.0) === 3.0
  end

  test "x <= 0 raises ArithmeticError at the operation, in both modes" do
    for f <- [:l2, :l10, :m2, :m10], x <- [0.0, -0.0, -1.0, -1.0e308, -@max, -4.9e-324] do
      assert {:raise, %ArithmeticError{} = e} = Defk.Test.assert_agrees(K, f, [x])
      assert Defk.Test.agreement_reason(e) == :non_finite
      # raised by the log itself, never the strip's fallback message
      refute e.message == "float result is inf or NaN"
    end
  end
end
