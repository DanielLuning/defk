# Bit builtins (defk-52v.6): mulhi, clz, ctz, popcount, rotl and rotr act
# on the u64 bit patterns of i64 operands and agree with their plain Elixir
# meaning in Defk.Bits.

defmodule Defk.BitBuiltinsTest.K do
  use Defk

  defk(mulhi_f(a :: i64, b :: i64) :: i64, do: mulhi(a, b))
  defk(clz_f(a :: i64) :: i64, do: clz(a))
  defk(ctz_f(a :: i64) :: i64, do: ctz(a))
  defk(popcount_f(a :: i64) :: i64, do: popcount(a))
  defk(rotl_f(a :: i64, n :: i64) :: i64, do: rotl(a, n))
  defk(rotr_f(a :: i64, n :: i64) :: i64, do: rotr(a, n))

  # a count has a range: it indexes a 65-element table without a bounds check
  defk(count_at(t :: [i64], a :: i64) :: i64, do: t[popcount(a)] + t[clz(a)] + t[ctz(a)])

  # a typical use: xxh3-style 128-bit fold and a rotate-xor mix
  defk(fold(a :: i64, b :: i64) :: i64, do: bxor(mulhi(a, b), a))
  defk(mix(h :: i64, n :: i64) :: i64, do: bxor(rotl(h, 13), rotr(h, n)))
end

# Module aliases are lexical (defk-kwl): `Bits.clz(x)` under `alias Defk.Bits`
# (or `as: B`) is the same call as `Defk.Bits.clz(x)`, in native and Elixir mode.
defmodule Defk.BitBuiltinsTest.AliasK do
  use Defk, elixir_mode: true

  alias Defk.Bits
  alias Defk.Bits, as: B

  defk(full(a :: i64) :: i64, do: Defk.Bits.clz(a))
  defk(plain(a :: i64) :: i64, do: Bits.clz(a))
  defk(renamed(a :: i64) :: i64, do: B.clz(a) + B.popcount(a))
  defk(renamed_full(a :: i64) :: i64, do: Defk.Bits.clz(a) + Defk.Bits.popcount(a))
end

defmodule Defk.BitBuiltinsTest.AliasTest do
  use ExUnit.Case, async: true

  alias Defk.BitBuiltinsTest.AliasK, as: A

  test "an aliased Defk.Bits call agrees with the qualified one, native and Elixir mode" do
    assert A.plain(1) == 63

    for a <- [0, 1, -1, 12_345, -2 ** 63] do
      assert Defk.Test.assert_agrees(A, :plain, [a]) == Defk.Test.assert_agrees(A, :full, [a])
      assert A.plain(a) == A.__defk_elixir__(:full, [a])

      assert Defk.Test.assert_agrees(A, :renamed, [a]) ==
               Defk.Test.assert_agrees(A, :renamed_full, [a])
    end
  end
end

defmodule Defk.BitBuiltinsTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Defk.TestKit, only: [kernel: 3, reject: 2]

  alias Defk.BitBuiltinsTest.K
  alias Defk.Generators, as: G

  @min -0x8000000000000000
  @max 0x7FFFFFFFFFFFFFFF
  @edges [0, 1, -1, @min, @max, 2 ** 32, 2 ** 63 - 1, 63, 64, 65, -64]
  @rands for _ <- 1..20, do: :rand.uniform(2 ** 64) - 1 - 2 ** 63

  defp ops, do: @edges ++ @rands

  test "one-operand builtins agree at edges and random values" do
    for f <- [:clz_f, :ctz_f, :popcount_f], a <- ops() do
      Defk.Test.assert_agrees(K, f, [a])
    end
  end

  test "two-operand builtins agree at edges and random values" do
    for f <- [:mulhi_f, :rotl_f, :rotr_f], a <- ops(), b <- Enum.take(ops(), 12) do
      Defk.Test.assert_agrees(K, f, [a, b])
    end
  end

  test "known values" do
    assert K.mulhi_f(-1, -1) == -2
    assert K.mulhi_f(@max, 4) == 1
    assert K.mulhi_f(@min, 2) == 1
    assert K.mulhi_f(-1, 2) == 1
    assert {K.clz_f(0), K.clz_f(1), K.clz_f(-1)} == {64, 63, 0}
    assert {K.ctz_f(0), K.ctz_f(1), K.ctz_f(@min)} == {64, 0, 63}
    assert {K.popcount_f(0), K.popcount_f(-1), K.popcount_f(@min)} == {0, 64, 1}
    assert K.rotl_f(1, 63) == @min
    assert K.rotl_f(@min, 1) == 1
    assert K.rotl_f(0x0123456789ABCDEF, 64) == 0x0123456789ABCDEF
    assert K.rotl_f(1, -1) == @min
    assert K.rotr_f(1, 1) == @min
    assert K.rotr_f(1, 65) == @min
  end

  test "rotl with the top bit set equals the Bitwise rotate on the unsigned value" do
    for x <- [@min, -1, @min + 12_345, -0x123456789ABCDEF], n <- 0..63 do
      u = Bitwise.band(x, 0xFFFFFFFFFFFFFFFF)

      rot =
        Bitwise.band(
          Bitwise.bor(Bitwise.bsl(u, n), Bitwise.bsr(u, 64 - n)),
          0xFFFFFFFFFFFFFFFF
        )

      expected = if rot >= 2 ** 63, do: rot - 2 ** 64, else: rot
      assert K.rotl_f(x, n) == expected
      assert Defk.Bits.rotl(x, n) == expected
      assert K.rotr_f(K.rotl_f(x, n), n) == x
    end
  end

  test "counts index a 65-element table" do
    t = for i <- 0..64, into: <<>>, do: <<i::signed-64-native>>
    for a <- ops(), do: Defk.Test.assert_agrees(K, :count_at, [t, a])
  end

  test "kernels using the builtins agree" do
    for h <- ops(), n <- [0, 1, 7, 63, 64, -3] do
      Defk.Test.assert_agrees(K, :mix, [h, n])
      Defk.Test.assert_agrees(K, :fold, [h, n])
    end
  end

  property "every builtin agrees with Elixir mode on i64 edges" do
    check all(a <- G.i64(), b <- G.i64()) do
      for f <- [:mulhi_f, :rotl_f, :rotr_f], do: Defk.Test.assert_agrees(K, f, [a, b])
      for f <- [:clz_f, :ctz_f, :popcount_f], do: Defk.Test.assert_agrees(K, f, [a])
    end
  end

  defp rejection(body, sig), do: reject(__MODULE__, kernel(sig, "i64", body))

  test "operands must be integers" do
    for {body, sig, takes} <- [
          {"clz(a)", "a :: f64", "clz/1 takes an integer, and is called here with (f64)"},
          {"popcount(a)", "a :: bool",
           "popcount/1 takes an integer, and is called here with (bool)"},
          {"rotl(a, b)", "a :: i64, b :: f64",
           "rotl/2 takes two i64 values, and is called here with (i64, f64)"},
          {"mulhi(a)", "a :: i64", "mulhi/2 takes two i64 values, and is called here with (i64)"}
        ] do
      msg = rejection(body, sig)
      assert msg =~ "(defk builtin-arguments"
      assert msg =~ takes
    end
  end
end
