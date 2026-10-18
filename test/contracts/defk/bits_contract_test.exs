defmodule Defk.Contract.BitsTest do
  # The meaning of Defk.Bits (public_api.obligations.md, I8): each function
  # against an independent reference written here bit by bit, over generated
  # values and widths with their edges. The references follow the function
  # docs, not the implementation, so a change of meaning fails here even when
  # the docs' own examples still hold. Like every contract test it calls only
  # defk's public API and Defk.ContractKit (test/contracts/README.md).
  use Covenant.Case, component: "defk.public_api", async: true
  use ExUnitProperties

  import Bitwise

  @two64 1 <<< 64
  @min -0x8000000000000000
  @max 0x7FFFFFFFFFFFFFFF

  # ------------------------------------------------------------ references --

  defp u64(x), do: Integer.mod(x, @two64)
  defp s64(u) when u >= 1 <<< 63, do: u - @two64
  defp s64(u), do: u

  # the bits of a width-bit value, most significant first
  defp bits(u, width), do: for(i <- (width - 1)..0//-1, do: u >>> i &&& 1)

  defp ref_clz(u, width), do: bits(u, width) |> Enum.take_while(&(&1 == 0)) |> length()

  defp ref_ctz(u, width),
    do: bits(u, width) |> Enum.reverse() |> Enum.take_while(&(&1 == 0)) |> length()

  defp ref_popcount(u), do: bits(u, 64) |> Enum.sum()

  # rotate left by k (0 <= k < width): bit i moves to (i + k) mod width
  defp ref_rotl(u, k, width) do
    for i <- 0..(width - 1), reduce: 0 do
      acc -> acc ||| (u >>> i &&& 1) <<< Integer.mod(i + k, width)
    end
  end

  # one CRC32C step, a bit at a time, bytes least significant first
  defp ref_crc32c(crc, x, width) do
    for byte <- 0..(div(width, 8) - 1), reduce: crc do
      acc ->
        acc = bxor(acc, x >>> (8 * byte) &&& 0xFF)

        for _ <- 1..8, reduce: acc do
          c -> if (c &&& 1) == 1, do: bxor(c >>> 1, 0x82F63B78), else: c >>> 1
        end
    end
  end

  # ------------------------------------------------------------ generators --

  # any integer, mostly i64 and u64 sized, with the edges
  defp int,
    do:
      one_of([
        integer(),
        integer(@min..(@two64 - 1)),
        integer(-(1 <<< 80)..(1 <<< 80)),
        member_of([0, 1, -1, @min, @max, @two64 - 1, @two64, @two64 + 5])
      ])

  defp width, do: one_of([integer(1..64), member_of([1, 8, 16, 32, 63, 64])])

  # a width and a value of that width, with its edges
  defp field do
    bind(width(), fn w ->
      top = (1 <<< w) - 1
      map(one_of([integer(0..top), member_of([0, 1, top, top >>> 1])]), &{&1, w})
    end)
  end

  # ------------------------------------------------------------------ tests --

  describe "I8: 64-bit pattern functions" do
    @tag obligation: "defk.public_api.I8"
    property "wrap64/1 is the low 64 bits as a signed value" do
      check(all(x <- int(), do: assert(Defk.Bits.wrap64(x) == s64(u64(x)))))
    end

    @tag obligation: "defk.public_api.I8"
    property "mulhi/2 is the high half of the unsigned 128-bit product, as an i64 pattern" do
      check all(a <- int(), b <- int()) do
        assert Defk.Bits.mulhi(a, b) == s64((u64(a) * u64(b)) >>> 64)
      end
    end

    @tag obligation: "defk.public_api.I8"
    property "clz/1, ctz/1 and popcount/1 count bits of the 64-bit pattern" do
      check all(x <- int()) do
        u = u64(x)
        assert Defk.Bits.clz(x) == ref_clz(u, 64)
        assert Defk.Bits.ctz(x) == ref_ctz(u, 64)
        assert Defk.Bits.popcount(x) == ref_popcount(u)
      end
    end

    @tag obligation: "defk.public_api.I8"
    property "rotl/2 and rotr/2 rotate the 64-bit pattern, n taken modulo 64" do
      check all(x <- int(), n <- integer(-200..200)) do
        left = s64(ref_rotl(u64(x), Integer.mod(n, 64), 64))
        right = s64(ref_rotl(u64(x), Integer.mod(-n, 64), 64))
        assert Defk.Bits.rotl(x, n) == left
        assert Defk.Bits.rotr(x, n) == right
      end
    end

    @tag obligation: "defk.public_api.I8"
    property "f64_bits/1 is the IEEE 754 bit pattern" do
      check all(x <- one_of([float(), integer(-(1 <<< 60)..(1 <<< 60))])) do
        <<b::64>> = <<x::float-64>>
        assert Defk.Bits.f64_bits(x) == b
      end

      assert Defk.Bits.f64_bits(-0.0) == 1 <<< 63
    end
  end

  describe "I8: width-bit functions" do
    @tag obligation: "defk.public_api.I8"
    property "clz/2 and ctz/2 count bits of a width-bit value, width for 0" do
      check all({x, w} <- field()) do
        assert Defk.Bits.clz(x, w) == ref_clz(x, w)
        assert Defk.Bits.ctz(x, w) == ref_ctz(x, w)
      end
    end

    @tag obligation: "defk.public_api.I8"
    property "rotl/3 and rotr/3 rotate a width-bit value, n taken modulo width" do
      check all({x, w} <- field(), n <- integer(-200..200)) do
        assert Defk.Bits.rotl(x, n, w) == ref_rotl(x, Integer.mod(n, w), w)
        assert Defk.Bits.rotr(x, n, w) == ref_rotl(x, Integer.mod(-n, w), w)
      end
    end

    @tag obligation: "defk.public_api.I8"
    property "crc32c/3 is the reflected Castagnoli step over width/8 bytes, without inversion" do
      check all(
              w <- member_of([8, 16, 32, 64]),
              crc <- integer(0..0xFFFFFFFF),
              x <- integer(0..((1 <<< w) - 1))
            ) do
        assert Defk.Bits.crc32c(crc, x, w) == ref_crc32c(crc, x, w)
      end

      # the standard check value of CRC-32C
      crc = Enum.reduce(~c"123456789", 0xFFFFFFFF, &Defk.Bits.crc32c(&2, &1, 8))
      assert bxor(crc, 0xFFFFFFFF) == 0xE3069283
    end

    @tag obligation: "defk.public_api.I8"
    test "a width or a value out of range raises ArgumentError" do
      for {f, args} <- [
            {:clz, [1, 0]},
            {:clz, [1, 65]},
            {:clz, [-1, 32]},
            {:ctz, [1 <<< 32, 32]},
            {:rotl, [16, 1, 4]},
            {:rotr, [-1, 1, 8]},
            {:crc32c, [0, 0, 12]},
            {:crc32c, [1 <<< 32, 0, 8]},
            {:crc32c, [0, 256, 8]}
          ] do
        assert_raise ArgumentError, fn -> apply(Defk.Bits, f, args) end
      end
    end
  end
end
