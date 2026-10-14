# Kernels build with -ffp-contract=off, so the C compiler never fuses a*b+c
# into one FMA (a single rounding). Float results stay bit-exact with Elixir,
# which rounds the product and the sum separately.

defmodule Defk.FpContractTest.K do
  use Defk

  defk mul_add(a :: f64, b :: f64, c :: f64) :: f64 do
    a * b + c
  end

  defk dot(a :: [f64], b :: [f64]) :: f64 do
    for i <- 0..(length(a) - 1)//1, reduce: 0.0 do
      acc -> acc + a[i] * b[i]
    end
  end
end

defmodule Defk.FpContractTest do
  use ExUnit.Case, async: true

  alias Defk.FpContractTest.K

  # a*b = 1 + 2^-29 + 2^-60 exactly; rounded, the 2^-60 is lost and a*b + c
  # is 0.0, where a fused multiply-add gives 2^-60.
  @a 1.0 + :math.pow(2, -30)
  @c -(1.0 + :math.pow(2, -29))

  test "a*b+c rounds the product, as Elixir does" do
    expect = @a * @a + @c
    assert expect === 0.0
    assert K.mul_add(@a, @a, @c) === expect
  end

  test "a dot product rounds every product, as Elixir does" do
    a = [1.0, @a]
    b = [@c, @a]
    expect = Enum.zip_reduce(a, b, 0.0, fn x, y, acc -> acc + x * y end)
    assert expect === 0.0
    assert K.dot(pack(a), pack(b)) === expect
  end

  defp pack(xs), do: for(x <- xs, into: <<>>, do: <<x::float-native-64>>)
end
