# crc32c(crc, x, w) (defk-ulk.4): one CRC32C step, the hardware instruction
# where the CPU has it and a slicing-by-8 table otherwise, picked at run time
# per kernel library. Both implementations agree with Defk.Bits.crc32c/3
# (Elixir mode) and with a bit-at-a-time reference written here.

defmodule Defk.Crc32cTest.K do
  use Defk

  defk(step(c :: i64, x :: i64, w :: i64) :: i64, do: crc32c(c, x, w))
  defk(step_u(c :: u64, x :: u64, w :: i64) :: i64, do: crc32c(c, x, w))
  defk(step_q(c :: i64, x :: u64, w :: i64) :: i64, do: Defk.Bits.crc32c(c, x, w))
  defk(step8(c :: i64, x :: i64) :: i64, do: crc32c(c, x, 8))
  defk(step64(c :: i64, x :: u64) :: i64, do: crc32c(c, x, 64))

  # the standard CRC-32C of a message: 64-bit words, then the tail bytes
  defk crc_msg(b :: [u8]) :: i64 do
    n = len(b)
    words = n - rem(n, 8)

    crc =
      for i <- 0..(words - 8)//8, reduce: 0xFFFFFFFF do
        crc -> crc32c(crc, band(u64_le(b, i), 0xFFFFFFFFFFFFFFFF), 64)
      end

    crc =
      for i <- words..(n - 1)//1, reduce: crc do
        crc -> crc32c(crc, b[i], 8)
      end

    bxor(crc, 0xFFFFFFFF)
  end

  # the same with 32- and 16-bit words, so every width runs in a loop
  defk crc_msg32(b :: [u8]) :: i64 do
    n = len(b)
    words = n - rem(n, 4)

    crc =
      for i <- 0..(words - 4)//4, reduce: 0xFFFFFFFF do
        crc -> crc32c(crc, u32_le(b, i), 32)
      end

    crc =
      if n - words >= 2,
        do: crc32c(crc, u16_le(b, words), 16),
        else: crc

    crc =
      for i <- (words + 2 * div(n - words, 2))..(n - 1)//1, reduce: crc do
        crc -> crc32c(crc, b[i], 8)
      end

    bxor(crc, 0xFFFFFFFF)
  end
end

# the same kernels in a second library, whose first call is made with
# DEFK_PORTABLE_BUILTINS=1, so it runs the table on every CPU
defmodule Defk.Crc32cTest.Portable do
  use Defk

  defk(step(c :: i64, x :: i64, w :: i64) :: i64, do: crc32c(c, x, w))

  defk crc_msg(b :: [u8]) :: i64 do
    n = len(b)
    words = n - rem(n, 8)

    crc =
      for i <- 0..(words - 8)//8, reduce: 0xFFFFFFFF do
        crc -> crc32c(crc, band(u64_le(b, i), 0xFFFFFFFFFFFFFFFF), 64)
      end

    crc =
      for i <- words..(n - 1)//1, reduce: crc do
        crc -> crc32c(crc, b[i], 8)
      end

    bxor(crc, 0xFFFFFFFF)
  end
end

defmodule Defk.Crc32cTest do
  # not async: the portable test sets an OS environment variable
  use ExUnit.Case
  use ExUnitProperties

  import Bitwise

  alias Defk.Crc32cTest.K
  alias Defk.Crc32cTest.Portable, as: P

  @widths [8, 16, 32, 64]

  # one bit at a time, straight from the definition
  defp ref(c, x, w) do
    Enum.reduce(0..(w - 1), c, fn i, c ->
      c = bxor(c, band(bsr(x, i), 1))
      bxor(bsr(c, 1), band(0x82F63B78, -band(c, 1)))
    end)
  end

  defp ref_msg(bin) do
    bxor(for(<<b <- bin>>, reduce: 0xFFFFFFFF, do: (c -> ref(c, b, 8))), 0xFFFFFFFF)
  end

  defp edges(w) do
    m = (1 <<< w) - 1
    [0, 1, m, m - 1, 1 <<< (w - 1), 0x5A5A5A5A5A5A5A5A &&& m]
  end

  @crcs [0, 1, 0xFFFFFFFF, 0x80000000, 0x7FFFFFFF, 0xE3069283]

  defp u64_to_i64(x) when x >= 1 <<< 63, do: x - (1 <<< 64)
  defp u64_to_i64(x), do: x

  test "known values: the CRC-32C check value and RFC 3720's" do
    assert K.crc_msg("123456789") == 0xE3069283
    assert K.crc_msg32("123456789") == 0xE3069283
    assert P.crc_msg("123456789") == 0xE3069283
    # iSCSI (RFC 3720, B.4): 32 bytes of zeros, of ones, ascending
    assert K.crc_msg(:binary.copy(<<0>>, 32)) == 0x8A9136AA
    assert K.crc_msg(:binary.copy(<<255>>, 32)) == 0x62A8AB43
    assert K.crc_msg(:binary.list_to_bin(Enum.to_list(0..31))) == 0x46DD794E
  end

  test "every width agrees with Defk.Bits, Elixir mode and the bitwise reference at edges" do
    for w <- @widths, c <- @crcs, x <- edges(w) do
      want = ref(c, x, w)
      assert Defk.Bits.crc32c(c, x, w) == want
      assert K.step_u(c, x, w) == want
      assert K.step_q(c, x, w) == want
      Defk.Test.assert_agrees(K, :step_u, [c, x, w])
      Defk.Test.assert_agrees(K, :step_q, [c, x, w])

      if x < 1 <<< 63 do
        assert K.step(c, x, w) == want
        Defk.Test.assert_agrees(K, :step, [c, x, w])
      end
    end
  end

  test "literal widths" do
    for c <- @crcs, x <- edges(8), do: assert(K.step8(c, x) == ref(c, x, 8))
    for c <- @crcs, x <- edges(64), do: assert(K.step64(c, x) == ref(c, x, 64))
  end

  property "agrees with Elixir mode and the reference on random values" do
    check all(
            w <- member_of(@widths),
            c <- integer(0..0xFFFFFFFF),
            x <- integer(0..((1 <<< w) - 1))
          ) do
      want = ref(c, x, w)
      assert K.step_u(c, x, w) == want
      Defk.Test.assert_agrees(K, :step_u, [c, x, w])
      Defk.Test.assert_agrees(K, :step64, [c, x])
    end
  end

  property "messages agree with Elixir mode and the reference" do
    check all(bin <- binary(max_length: 100)) do
      want = ref_msg(bin)
      assert K.crc_msg(bin) == want
      assert K.crc_msg32(bin) == want
      Defk.Test.assert_agrees(K, :crc_msg, [bin])
      Defk.Test.assert_agrees(K, :crc_msg32, [bin])
    end
  end

  test "out-of-range arguments raise ArgumentError, as Defk.Bits does" do
    for {c, x, w, msg} <- [
          {0, 0, 12, "Defk.Bits.crc32c/3: width 12 is not 8, 16, 32 or 64"},
          {0, 0, 0, "width 0 is not 8, 16, 32 or 64"},
          {1 <<< 32, 0, 8, "Defk.Bits.crc32c/3: 4294967296 does not fit in a 32-bit field"},
          {-1, 0, 8, "-1 does not fit in a 32-bit field"},
          {0, 256, 8, "256 does not fit in a 8-bit field"},
          {0, 1 <<< 16, 16, "65536 does not fit in a 16-bit field"},
          {0, -1, 64, "-1 does not fit in a 64-bit field"}
        ] do
      e = assert_raise ArgumentError, fn -> K.step(c, x, w) end
      assert Exception.message(e) =~ msg
      e = assert_raise ArgumentError, fn -> Defk.Bits.crc32c(c, x, w) end
      assert Exception.message(e) =~ msg
      Defk.Test.assert_agrees(K, :step, [c, x, w])
    end
  end

  test "the u64 word of a load: an i64 with the top bit set needs the mask" do
    b = <<0xFF, 0, 0, 0, 0, 0, 0, 0x80>>
    x = 0x80000000000000FF
    assert K.step64(0, x) == ref(0, x, 64)
    assert_raise ArgumentError, fn -> K.step(0, u64_to_i64(x), 64) end
    assert K.crc_msg(b) == ref_msg(b)
  end

  test "under forced yields" do
    :rand.seed(:exsss, {7, 8, 9})
    bins = for n <- [0, 9, 1000, 300_001, 2_000_003], do: :rand.bytes(n)
    expect = Enum.map(bins, &ref_msg/1)
    K.__defk_force_yields__(true)

    try do
      y0 = K.__defk_stats__().yields
      assert Enum.map(bins, &K.crc_msg/1) == expect
      assert Enum.map(bins, &K.crc_msg32/1) == expect
      for bin <- Enum.take(bins, 4), do: Defk.Test.assert_agrees(K, :crc_msg, [bin])
      assert K.__defk_stats__().yields - y0 > 0
    after
      K.__defk_force_yields__(false)
    end
  end

  test "the instruction on this CPU, the table with DEFK_PORTABLE_BUILTINS, the same values" do
    _ = K.step(0, 0, 8)
    hw = K.__defk_stats__().crc32c
    on_hw? = :erlang.system_info(:system_architecture) |> to_string() =~ ~r/aarch64|x86_64/
    if on_hw?, do: assert(hw == :instruction), else: assert(hw == :table)

    assert P.__defk_stats__().crc32c == :not_called
    System.put_env("DEFK_PORTABLE_BUILTINS", "1")

    try do
      _ = P.step(0, 0, 8)
    after
      System.delete_env("DEFK_PORTABLE_BUILTINS")
    end

    assert P.__defk_stats__().crc32c == :table

    :rand.seed(:exsss, {1, 2, 3})

    for _ <- 1..2000 do
      w = Enum.random(@widths)
      c = :rand.uniform(1 <<< 32) - 1
      x = :rand.uniform(1 <<< (w - 1)) - 1
      assert P.step(c, x, w) == K.step(c, x, w)
    end

    for n <- [0, 1, 7, 8, 9, 100, 4099] do
      bin = :rand.bytes(n)
      assert P.crc_msg(bin) == K.crc_msg(bin)
      assert P.crc_msg(bin) == ref_msg(bin)
    end

    P.__defk_force_yields__(true)

    try do
      bin = :rand.bytes(2_000_001)
      y0 = P.__defk_stats__().yields
      assert P.crc_msg(bin) == Defk.Crc32cTest.K.crc_msg(bin)
      assert P.__defk_stats__().yields - y0 > 0
    after
      P.__defk_force_yields__(false)
    end
  end
end
