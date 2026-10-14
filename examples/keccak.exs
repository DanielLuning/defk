# keccak: Keccak-256 (Ethereum) and SHA3-256 (FIPS 202) written from scratch
# as kernels, against ex_keccak (tiny-keccak via Rustler) and :crypto
#
# Why people reach for a NIF here: Ethereum clients and wallets hash
# addresses, transactions and trie nodes with Keccak-256 (the original 0x01
# padding), which :crypto does not provide (it has only the FIPS SHA-3
# variants). The Hex answer is ex_keccak, a Rustler wrapper of tiny-keccak.
# Expected verdict: good for Keccak-256 (vs pure Elixir); poor for SHA3-256,
# which :crypto already does in C.
#
#   elixir examples/keccak.exs                     # agreement + two reports
#   KECCAK_VARIANTS=1 elixir examples/keccak.exs   # also every Elixir variant
#
# DEFK_RESULT lines, in this order (mix defk.examples reads the first):
#   1. keccak          Keccak-256, 10k x 32 B per call: defk batch kernel vs
#                      the best pure Elixir; ex_keccak reported as `native`
#   2. keccak_sha3_256 SHA3-256, same batch: defk vs :crypto.hash(:sha3_256, _)
#                      (the Elixir answer for this variant; pure Elixir in the
#                      sweep)
#
# The kernel: a sponge with rate 136 bytes over 25 lanes, each lane a u64 bit
# pattern in an i64. The lanes live in `for ... reduce:` tuple accumulators
# (registers), not an array. Keccak-f[1600] is 24 rounds of theta, rho, pi,
# chi, iota, unrolled per round; the round body was generated from the FIPS
# 202 definitions (rotation offsets from the t loop, pi as (x, y) -> (y, 2x +
# 3y)). A rotate is `bor(wrap64(bsl(x, n)), band(bsr(x, 64 - n), 2^n - 1))`:
# wrap64 keeps the bits shifted past bit 63 from raising, and the mask clears
# the sign bits that bsr (arithmetic) fills in; clang turns it into one `ror`.
# The 24 round constants are a 192-byte binary attribute read with u64_le.
# Absorb loads lanes with u64_le; the last block's lanes (tail bytes, the
# padding byte 0x01 or 0x06, and 0x80 in byte 135) come from `tail_lane/5`.
# Squeeze writes lanes 0-3 byte by byte with band(bsr(lane, 8 * j), 255).
# keccak256/1 and sha3_256/1 hash one message; keccak256_batch/2 and
# sha3_256_batch/2 hash k messages packed in one binary with k + 1 offsets
# (`[i64]`) and return k * 32 bytes.
#
# The round is written row by row (five rotated lanes, then their five chi
# outputs). The order no longer matters (defk-zep): before, every safepoint
# spilled every local of the kernel, so each round temporary stayed alive
# out of the round loop into the block loop's safepoint, and clang spilled
# 26-51 values per round depending on statement order and on whether a
# rotate operand was named (`e = bxor(a6, d1)`) or written inline: 27 to
# 42 ms for 16 MB. A safepoint now spills only the locals live where it
# resumes: all four orderings compile to 9-11 stack stores per round and
# take ~21 ms (0 spills and ~18 ms with `yield: false` on keccak256, which
# blocks the scheduler; `yield: false` on sponge alone does nothing, since
# keccak256 inlines it with its safepoints).
#
# Agreement, checked on every run: the FIPS 202 SHA3-256 vectors ("", "abc",
# the 448-bit message, a million "a") and Keccak-256 of "" and "abc"
# (Ethereum's 4e03657a...); 611 random messages (every length 0..410, which
# covers each padding position over three blocks, plus 200 up to 5000 bytes)
# against ex_keccak and :crypto.hash(:sha3_256, _), for the kernel and both
# Elixir versions; the batch kernels against the per-message digests; and
# Elixir mode, compiled from the same quoted kernels under a throwaway Mix
# project in :test (a Mix.install script has no Mix env), on 161 messages and
# a batch, and a decreasing offset raises ArgumentError in the kernel.
#
# Elixir baseline: optimised. No pure Elixir/Erlang Keccak on Hex builds on
# OTP 29 except ex_sha3: `sha3` 2.0.0 and `keccakf1600` 3.0.0 are C NIFs
# whose rebar builds link erl_interface, removed in OTP 23+, and fail. Per
# 32-byte message (10k, M-series Mac, OTP 29, Elixir 1.20):
#
#   ex_sha3 0.1.5 (pure Elixir, Hex)                 ~128 us
#   Keccak.Elixir64: 25 lanes as unsigned 64-bit     ~50-62 us  (first pass)
#     integers, unrolled, recursion over rounds
#   Keccak.Elixir: each lane as two 32-bit halves    ~2.6-2.9 us
#     (every value stays a small integer below 2^59,
#     so no lane op allocates a bignum)
#   defk, one kernel call per message                ~0.55 us
#   defk batch kernel (pack + call + split)          ~0.33-0.35 us
#   ex_keccak, one NIF call per message              ~0.21 us
#
# The 32-bit halves are the one big step (about 20x): lanes above 2^59 are
# bignums on the BEAM, so the first pass allocated on almost every operation.
# Not tried: bit interleaving (rotates become two 32-bit rotates; it saves
# no operations on the BEAM), lane complementing (only saves the bnot).
#
# Native: ex_keccak 0.7.8 (precompiled tiny-keccak NIF) is about 1.7x
# faster than the kernel on the 10k x 32 B batch (per-message overhead) and
# about the same at 16 MB (19.1 vs 20.7 ms, under load); it also blocks its
# scheduler for the whole 16 MB message (~20 ms gap) where the kernel yields
# (~2 ms, the ticker's own floor). :crypto's SHA3-256 (OpenSSL) is ~1.7x
# faster than the kernel. Per-call cost (the tiny-calls lesson): one kernel
# call per 32-byte message costs ~0.1-0.2 us more than the batch; both are
# far below pure Elixir, so per-call use is fine here.

Mix.install([
  {:defk, path: Path.expand("..", __DIR__)},
  {:ex_keccak, "~> 0.7"},
  {:ex_sha3, "~> 0.1"}
])

defmodule Keccak.Constants do
  import Bitwise

  @doc "The 24 Keccak-f[1600] round constants (FIPS 202, 3.2.5: rc(t) from an LFSR)."
  def round_constants do
    {rcs, _} =
      Enum.map_reduce(0..23, 1, fn _round, lfsr ->
        Enum.reduce(0..6, {0, lfsr}, fn j, {rc, r} ->
          rc = if band(r, 1) == 1, do: bor(rc, bsl(1, bsl(1, j) - 1)), else: rc
          r = if band(r, 0x80) != 0, do: bxor(band(bsl(r, 1), 0xFF), 0x71), else: bsl(r, 1)
          {rc, r}
        end)
      end)

    rcs
  end
end

# The kernels, quoted once and compiled twice: as Keccak.Kernels (native, the
# one measured) and as Keccak.ElixirMode (with Elixir mode, for the agreement
# check; see the end of the file).
kernels =
  quote do
    use Defk

    # 24 round constants, 8 bytes each, little-endian: read with u64_le(@rc, 8 * r)
    @rc for c <- Keccak.Constants.round_constants(), into: <<>>, do: <<c::little-64>>

    defk keccak256(msg :: [u8]) :: [u8] do
      offsets = alloc(i64, 2)
      offsets[1] = length(msg)
      sponge(msg, offsets, 1)
    end

    defk sha3_256(msg :: [u8]) :: [u8] do
      offsets = alloc(i64, 2)
      offsets[1] = length(msg)
      sponge(msg, offsets, 6)
    end

    # k messages packed in `blob`, message m is bytes offsets[m]..offsets[m + 1] - 1;
    # the result is k digests of 32 bytes
    defk keccak256_batch(blob :: [u8], offsets :: [i64]) :: [u8] do
      sponge(blob, offsets, 1)
    end

    defk sha3_256_batch(blob :: [u8], offsets :: [i64]) :: [u8] do
      sponge(blob, offsets, 6)
    end

    # Lane i of the last (padded) block: the tail bytes that fall in it, the
    # padding byte (0x01 Keccak, 0x06 SHA-3) at byte `tail`, and 0x80 at byte 135.
    defk tail_lane(msg :: [u8], off :: i64, i :: i64, tail :: i64, pad :: i64) :: i64 do
      lo = 8 * i

      v =
        cond do
          lo + 8 <= tail ->
            u64_le(msg, off + lo)

          lo >= tail ->
            0

          true ->
            for k <- (tail - 1)..lo//-1, reduce: 0 do
              v -> v * 256 + msg[off + k]
            end
        end

      v = if tail >= lo and tail < lo + 8, do: bxor(v, bsl(pad, 8 * (tail - lo))), else: v
      if i == 16, do: bxor(v, -9_223_372_036_854_775_807 - 1), else: v
    end

    # The sponge: rate 136 bytes (17 lanes), capacity 512 bits, 256-bit output.
    # The 25 lanes are u64 bit patterns in i64 and live in the accumulator
    # tuples (registers), not in an array.
    defk sponge(blob :: [u8], offsets :: [i64], pad :: i64) :: [u8] do
      k = length(offsets) - 1
      out = alloc(u8, 32 * k)

      for m <- 0..(k - 1)//1 do
        start = offsets[m]
        n = offsets[m + 1] - start
        # offsets must not decrease: a negative length raises ArgumentError here
        _ = alloc(u8, min(n, 0))
        nb = div(n, 136)
        tail = n - 136 * nb

        {a0, a1, a2, a3, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _} =
          for blk <- 0..nb//1,
              reduce: {0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0} do
            {a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13, a14, a15, a16, a17, a18,
             a19, a20, a21, a22, a23, a24} ->
              off = start + 136 * blk
              full = blk < nb

              x0 =
                bxor(
                  a0,
                  if(full, do: u64_le(blob, off + 0), else: tail_lane(blob, off, 0, tail, pad))
                )

              x1 =
                bxor(
                  a1,
                  if(full, do: u64_le(blob, off + 8), else: tail_lane(blob, off, 1, tail, pad))
                )

              x2 =
                bxor(
                  a2,
                  if(full, do: u64_le(blob, off + 16), else: tail_lane(blob, off, 2, tail, pad))
                )

              x3 =
                bxor(
                  a3,
                  if(full, do: u64_le(blob, off + 24), else: tail_lane(blob, off, 3, tail, pad))
                )

              x4 =
                bxor(
                  a4,
                  if(full, do: u64_le(blob, off + 32), else: tail_lane(blob, off, 4, tail, pad))
                )

              x5 =
                bxor(
                  a5,
                  if(full, do: u64_le(blob, off + 40), else: tail_lane(blob, off, 5, tail, pad))
                )

              x6 =
                bxor(
                  a6,
                  if(full, do: u64_le(blob, off + 48), else: tail_lane(blob, off, 6, tail, pad))
                )

              x7 =
                bxor(
                  a7,
                  if(full, do: u64_le(blob, off + 56), else: tail_lane(blob, off, 7, tail, pad))
                )

              x8 =
                bxor(
                  a8,
                  if(full, do: u64_le(blob, off + 64), else: tail_lane(blob, off, 8, tail, pad))
                )

              x9 =
                bxor(
                  a9,
                  if(full, do: u64_le(blob, off + 72), else: tail_lane(blob, off, 9, tail, pad))
                )

              x10 =
                bxor(
                  a10,
                  if(full, do: u64_le(blob, off + 80), else: tail_lane(blob, off, 10, tail, pad))
                )

              x11 =
                bxor(
                  a11,
                  if(full, do: u64_le(blob, off + 88), else: tail_lane(blob, off, 11, tail, pad))
                )

              x12 =
                bxor(
                  a12,
                  if(full, do: u64_le(blob, off + 96), else: tail_lane(blob, off, 12, tail, pad))
                )

              x13 =
                bxor(
                  a13,
                  if(full, do: u64_le(blob, off + 104), else: tail_lane(blob, off, 13, tail, pad))
                )

              x14 =
                bxor(
                  a14,
                  if(full, do: u64_le(blob, off + 112), else: tail_lane(blob, off, 14, tail, pad))
                )

              x15 =
                bxor(
                  a15,
                  if(full, do: u64_le(blob, off + 120), else: tail_lane(blob, off, 15, tail, pad))
                )

              x16 =
                bxor(
                  a16,
                  if(full, do: u64_le(blob, off + 128), else: tail_lane(blob, off, 16, tail, pad))
                )

              for r <- 0..23//1,
                  reduce:
                    {x0, x1, x2, x3, x4, x5, x6, x7, x8, x9, x10, x11, x12, x13, x14, x15, x16,
                     a17, a18, a19, a20, a21, a22, a23, a24} do
                {a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13, a14, a15, a16, a17,
                 a18, a19, a20, a21, a22, a23, a24} ->
                  c0 = bxor(bxor(bxor(bxor(a0, a5), a10), a15), a20)
                  c1 = bxor(bxor(bxor(bxor(a1, a6), a11), a16), a21)
                  c2 = bxor(bxor(bxor(bxor(a2, a7), a12), a17), a22)
                  c3 = bxor(bxor(bxor(bxor(a3, a8), a13), a18), a23)
                  c4 = bxor(bxor(bxor(bxor(a4, a9), a14), a19), a24)
                  d0 = bxor(c4, bor(wrap64(bsl(c1, 1)), band(bsr(c1, 63), 0x1)))
                  d1 = bxor(c0, bor(wrap64(bsl(c2, 1)), band(bsr(c2, 63), 0x1)))
                  d2 = bxor(c1, bor(wrap64(bsl(c3, 1)), band(bsr(c3, 63), 0x1)))
                  d3 = bxor(c2, bor(wrap64(bsl(c4, 1)), band(bsr(c4, 63), 0x1)))
                  d4 = bxor(c3, bor(wrap64(bsl(c0, 1)), band(bsr(c0, 63), 0x1)))
                  b0 = bxor(a0, d0)

                  b1 =
                    bor(wrap64(bsl(bxor(a6, d1), 44)), band(bsr(bxor(a6, d1), 20), 0xFFFFFFFFFFF))

                  b2 =
                    bor(
                      wrap64(bsl(bxor(a12, d2), 43)),
                      band(bsr(bxor(a12, d2), 21), 0x7FFFFFFFFFF)
                    )

                  b3 = bor(wrap64(bsl(bxor(a18, d3), 21)), band(bsr(bxor(a18, d3), 43), 0x1FFFFF))
                  b4 = bor(wrap64(bsl(bxor(a24, d4), 14)), band(bsr(bxor(a24, d4), 50), 0x3FFF))
                  n0 = bxor(bxor(b0, band(bnot(b1), b2)), u64_le(@rc, 8 * r))
                  n1 = bxor(b1, band(bnot(b2), b3))
                  n2 = bxor(b2, band(bnot(b3), b4))
                  n3 = bxor(b3, band(bnot(b4), b0))
                  n4 = bxor(b4, band(bnot(b0), b1))
                  b0 = bor(wrap64(bsl(bxor(a3, d3), 28)), band(bsr(bxor(a3, d3), 36), 0xFFFFFFF))
                  b1 = bor(wrap64(bsl(bxor(a9, d4), 20)), band(bsr(bxor(a9, d4), 44), 0xFFFFF))
                  b2 = bor(wrap64(bsl(bxor(a10, d0), 3)), band(bsr(bxor(a10, d0), 61), 0x7))

                  b3 =
                    bor(
                      wrap64(bsl(bxor(a16, d1), 45)),
                      band(bsr(bxor(a16, d1), 19), 0x1FFFFFFFFFFF)
                    )

                  b4 =
                    bor(
                      wrap64(bsl(bxor(a22, d2), 61)),
                      band(bsr(bxor(a22, d2), 3), 0x1FFFFFFFFFFFFFFF)
                    )

                  n5 = bxor(b0, band(bnot(b1), b2))
                  n6 = bxor(b1, band(bnot(b2), b3))
                  n7 = bxor(b2, band(bnot(b3), b4))
                  n8 = bxor(b3, band(bnot(b4), b0))
                  n9 = bxor(b4, band(bnot(b0), b1))
                  b0 = bor(wrap64(bsl(bxor(a1, d1), 1)), band(bsr(bxor(a1, d1), 63), 0x1))
                  b1 = bor(wrap64(bsl(bxor(a7, d2), 6)), band(bsr(bxor(a7, d2), 58), 0x3F))

                  b2 =
                    bor(wrap64(bsl(bxor(a13, d3), 25)), band(bsr(bxor(a13, d3), 39), 0x1FFFFFF))

                  b3 = bor(wrap64(bsl(bxor(a19, d4), 8)), band(bsr(bxor(a19, d4), 56), 0xFF))
                  b4 = bor(wrap64(bsl(bxor(a20, d0), 18)), band(bsr(bxor(a20, d0), 46), 0x3FFFF))
                  n10 = bxor(b0, band(bnot(b1), b2))
                  n11 = bxor(b1, band(bnot(b2), b3))
                  n12 = bxor(b2, band(bnot(b3), b4))
                  n13 = bxor(b3, band(bnot(b4), b0))
                  n14 = bxor(b4, band(bnot(b0), b1))
                  b0 = bor(wrap64(bsl(bxor(a4, d4), 27)), band(bsr(bxor(a4, d4), 37), 0x7FFFFFF))

                  b1 =
                    bor(wrap64(bsl(bxor(a5, d0), 36)), band(bsr(bxor(a5, d0), 28), 0xFFFFFFFFF))

                  b2 = bor(wrap64(bsl(bxor(a11, d1), 10)), band(bsr(bxor(a11, d1), 54), 0x3FF))
                  b3 = bor(wrap64(bsl(bxor(a17, d2), 15)), band(bsr(bxor(a17, d2), 49), 0x7FFF))

                  b4 =
                    bor(
                      wrap64(bsl(bxor(a23, d3), 56)),
                      band(bsr(bxor(a23, d3), 8), 0xFFFFFFFFFFFFFF)
                    )

                  n15 = bxor(b0, band(bnot(b1), b2))
                  n16 = bxor(b1, band(bnot(b2), b3))
                  n17 = bxor(b2, band(bnot(b3), b4))
                  n18 = bxor(b3, band(bnot(b4), b0))
                  n19 = bxor(b4, band(bnot(b0), b1))

                  b0 =
                    bor(
                      wrap64(bsl(bxor(a2, d2), 62)),
                      band(bsr(bxor(a2, d2), 2), 0x3FFFFFFFFFFFFFFF)
                    )

                  b1 =
                    bor(
                      wrap64(bsl(bxor(a8, d3), 55)),
                      band(bsr(bxor(a8, d3), 9), 0x7FFFFFFFFFFFFF)
                    )

                  b2 =
                    bor(
                      wrap64(bsl(bxor(a14, d4), 39)),
                      band(bsr(bxor(a14, d4), 25), 0x7FFFFFFFFF)
                    )

                  b3 =
                    bor(
                      wrap64(bsl(bxor(a15, d0), 41)),
                      band(bsr(bxor(a15, d0), 23), 0x1FFFFFFFFFF)
                    )

                  b4 = bor(wrap64(bsl(bxor(a21, d1), 2)), band(bsr(bxor(a21, d1), 62), 0x3))
                  n20 = bxor(b0, band(bnot(b1), b2))
                  n21 = bxor(b1, band(bnot(b2), b3))
                  n22 = bxor(b2, band(bnot(b3), b4))
                  n23 = bxor(b3, band(bnot(b4), b0))
                  n24 = bxor(b4, band(bnot(b0), b1))

                  {n0, n1, n2, n3, n4, n5, n6, n7, n8, n9, n10, n11, n12, n13, n14, n15, n16, n17,
                   n18, n19, n20, n21, n22, n23, n24}
              end
          end

        o = 32 * m

        for j <- 0..7//1 do
          out[o + j] = band(bsr(a0, 8 * j), 255)
          out[o + 8 + j] = band(bsr(a1, 8 * j), 255)
          out[o + 16 + j] = band(bsr(a2, 8 * j), 255)
          out[o + 24 + j] = band(bsr(a3, 8 * j), 255)
        end
      end

      out
    end
  end

Module.create(Keccak.Kernels, kernels, Macro.Env.location(__ENV__))

defmodule Keccak.Elixir64 do
  @moduledoc "Pure Elixir, first pass: lanes as unsigned 64-bit integers (bignums above 2^59)."
  import Bitwise

  @rc List.to_tuple(Keccak.Constants.round_constants())

  def keccak256(msg),
    do: absorb(msg, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)

  def sha3_256(msg),
    do: absorb(msg, 6, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)

  defp absorb(
         <<x0::little-64, x1::little-64, x2::little-64, x3::little-64, x4::little-64,
           x5::little-64, x6::little-64, x7::little-64, x8::little-64, x9::little-64,
           x10::little-64, x11::little-64, x12::little-64, x13::little-64, x14::little-64,
           x15::little-64, x16::little-64, rest::binary>>,
         pad,
         a0,
         a1,
         a2,
         a3,
         a4,
         a5,
         a6,
         a7,
         a8,
         a9,
         a10,
         a11,
         a12,
         a13,
         a14,
         a15,
         a16,
         a17,
         a18,
         a19,
         a20,
         a21,
         a22,
         a23,
         a24
       ) do
    {a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13, a14, a15, a16, a17, a18, a19,
     a20, a21, a22, a23, a24} =
      rounds(
        0,
        bxor(a0, x0),
        bxor(a1, x1),
        bxor(a2, x2),
        bxor(a3, x3),
        bxor(a4, x4),
        bxor(a5, x5),
        bxor(a6, x6),
        bxor(a7, x7),
        bxor(a8, x8),
        bxor(a9, x9),
        bxor(a10, x10),
        bxor(a11, x11),
        bxor(a12, x12),
        bxor(a13, x13),
        bxor(a14, x14),
        bxor(a15, x15),
        bxor(a16, x16),
        a17,
        a18,
        a19,
        a20,
        a21,
        a22,
        a23,
        a24
      )

    absorb(
      rest,
      pad,
      a0,
      a1,
      a2,
      a3,
      a4,
      a5,
      a6,
      a7,
      a8,
      a9,
      a10,
      a11,
      a12,
      a13,
      a14,
      a15,
      a16,
      a17,
      a18,
      a19,
      a20,
      a21,
      a22,
      a23,
      a24
    )
  end

  defp absorb(
         tail,
         pad,
         a0,
         a1,
         a2,
         a3,
         a4,
         a5,
         a6,
         a7,
         a8,
         a9,
         a10,
         a11,
         a12,
         a13,
         a14,
         a15,
         a16,
         a17,
         a18,
         a19,
         a20,
         a21,
         a22,
         a23,
         a24
       ) do
    <<x0::little-64, x1::little-64, x2::little-64, x3::little-64, x4::little-64, x5::little-64,
      x6::little-64, x7::little-64, x8::little-64, x9::little-64, x10::little-64, x11::little-64,
      x12::little-64, x13::little-64, x14::little-64, x15::little-64, x16::little-64>> =
      Keccak.Elixir.pad(tail, pad)

    {a0, a1, a2, a3, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _} =
      rounds(
        0,
        bxor(a0, x0),
        bxor(a1, x1),
        bxor(a2, x2),
        bxor(a3, x3),
        bxor(a4, x4),
        bxor(a5, x5),
        bxor(a6, x6),
        bxor(a7, x7),
        bxor(a8, x8),
        bxor(a9, x9),
        bxor(a10, x10),
        bxor(a11, x11),
        bxor(a12, x12),
        bxor(a13, x13),
        bxor(a14, x14),
        bxor(a15, x15),
        bxor(a16, x16),
        a17,
        a18,
        a19,
        a20,
        a21,
        a22,
        a23,
        a24
      )

    <<a0::little-64, a1::little-64, a2::little-64, a3::little-64>>
  end

  defp rounds(
         24,
         a0,
         a1,
         a2,
         a3,
         a4,
         a5,
         a6,
         a7,
         a8,
         a9,
         a10,
         a11,
         a12,
         a13,
         a14,
         a15,
         a16,
         a17,
         a18,
         a19,
         a20,
         a21,
         a22,
         a23,
         a24
       ),
       do:
         {a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13, a14, a15, a16, a17, a18,
          a19, a20, a21, a22, a23, a24}

  defp rounds(
         r,
         a0,
         a1,
         a2,
         a3,
         a4,
         a5,
         a6,
         a7,
         a8,
         a9,
         a10,
         a11,
         a12,
         a13,
         a14,
         a15,
         a16,
         a17,
         a18,
         a19,
         a20,
         a21,
         a22,
         a23,
         a24
       ) do
    c0 = bxor(bxor(bxor(bxor(a0, a5), a10), a15), a20)
    c1 = bxor(bxor(bxor(bxor(a1, a6), a11), a16), a21)
    c2 = bxor(bxor(bxor(bxor(a2, a7), a12), a17), a22)
    c3 = bxor(bxor(bxor(bxor(a3, a8), a13), a18), a23)
    c4 = bxor(bxor(bxor(bxor(a4, a9), a14), a19), a24)
    d0 = bxor(c4, bor(band(bsl(c1, 1), 0xFFFFFFFFFFFFFFFF), bsr(c1, 63)))
    d1 = bxor(c0, bor(band(bsl(c2, 1), 0xFFFFFFFFFFFFFFFF), bsr(c2, 63)))
    d2 = bxor(c1, bor(band(bsl(c3, 1), 0xFFFFFFFFFFFFFFFF), bsr(c3, 63)))
    d3 = bxor(c2, bor(band(bsl(c4, 1), 0xFFFFFFFFFFFFFFFF), bsr(c4, 63)))
    d4 = bxor(c3, bor(band(bsl(c0, 1), 0xFFFFFFFFFFFFFFFF), bsr(c0, 63)))
    e0 = bxor(a0, d0)
    e6 = bxor(a6, d1)
    e12 = bxor(a12, d2)
    e18 = bxor(a18, d3)
    e24 = bxor(a24, d4)
    e3 = bxor(a3, d3)
    e9 = bxor(a9, d4)
    e10 = bxor(a10, d0)
    e16 = bxor(a16, d1)
    e22 = bxor(a22, d2)
    e1 = bxor(a1, d1)
    e7 = bxor(a7, d2)
    e13 = bxor(a13, d3)
    e19 = bxor(a19, d4)
    e20 = bxor(a20, d0)
    e4 = bxor(a4, d4)
    e5 = bxor(a5, d0)
    e11 = bxor(a11, d1)
    e17 = bxor(a17, d2)
    e23 = bxor(a23, d3)
    e2 = bxor(a2, d2)
    e8 = bxor(a8, d3)
    e14 = bxor(a14, d4)
    e15 = bxor(a15, d0)
    e21 = bxor(a21, d1)
    b0 = e0
    b1 = bor(band(bsl(e6, 44), 0xFFFFFFFFFFFFFFFF), bsr(e6, 20))
    b2 = bor(band(bsl(e12, 43), 0xFFFFFFFFFFFFFFFF), bsr(e12, 21))
    b3 = bor(band(bsl(e18, 21), 0xFFFFFFFFFFFFFFFF), bsr(e18, 43))
    b4 = bor(band(bsl(e24, 14), 0xFFFFFFFFFFFFFFFF), bsr(e24, 50))
    b5 = bor(band(bsl(e3, 28), 0xFFFFFFFFFFFFFFFF), bsr(e3, 36))
    b6 = bor(band(bsl(e9, 20), 0xFFFFFFFFFFFFFFFF), bsr(e9, 44))
    b7 = bor(band(bsl(e10, 3), 0xFFFFFFFFFFFFFFFF), bsr(e10, 61))
    b8 = bor(band(bsl(e16, 45), 0xFFFFFFFFFFFFFFFF), bsr(e16, 19))
    b9 = bor(band(bsl(e22, 61), 0xFFFFFFFFFFFFFFFF), bsr(e22, 3))
    b10 = bor(band(bsl(e1, 1), 0xFFFFFFFFFFFFFFFF), bsr(e1, 63))
    b11 = bor(band(bsl(e7, 6), 0xFFFFFFFFFFFFFFFF), bsr(e7, 58))
    b12 = bor(band(bsl(e13, 25), 0xFFFFFFFFFFFFFFFF), bsr(e13, 39))
    b13 = bor(band(bsl(e19, 8), 0xFFFFFFFFFFFFFFFF), bsr(e19, 56))
    b14 = bor(band(bsl(e20, 18), 0xFFFFFFFFFFFFFFFF), bsr(e20, 46))
    b15 = bor(band(bsl(e4, 27), 0xFFFFFFFFFFFFFFFF), bsr(e4, 37))
    b16 = bor(band(bsl(e5, 36), 0xFFFFFFFFFFFFFFFF), bsr(e5, 28))
    b17 = bor(band(bsl(e11, 10), 0xFFFFFFFFFFFFFFFF), bsr(e11, 54))
    b18 = bor(band(bsl(e17, 15), 0xFFFFFFFFFFFFFFFF), bsr(e17, 49))
    b19 = bor(band(bsl(e23, 56), 0xFFFFFFFFFFFFFFFF), bsr(e23, 8))
    b20 = bor(band(bsl(e2, 62), 0xFFFFFFFFFFFFFFFF), bsr(e2, 2))
    b21 = bor(band(bsl(e8, 55), 0xFFFFFFFFFFFFFFFF), bsr(e8, 9))
    b22 = bor(band(bsl(e14, 39), 0xFFFFFFFFFFFFFFFF), bsr(e14, 25))
    b23 = bor(band(bsl(e15, 41), 0xFFFFFFFFFFFFFFFF), bsr(e15, 23))
    b24 = bor(band(bsl(e21, 2), 0xFFFFFFFFFFFFFFFF), bsr(e21, 62))

    rounds(
      r + 1,
      bxor(bxor(b0, band(bxor(b1, 0xFFFFFFFFFFFFFFFF), b2)), elem(@rc, r)),
      bxor(b1, band(bxor(b2, 0xFFFFFFFFFFFFFFFF), b3)),
      bxor(b2, band(bxor(b3, 0xFFFFFFFFFFFFFFFF), b4)),
      bxor(b3, band(bxor(b4, 0xFFFFFFFFFFFFFFFF), b0)),
      bxor(b4, band(bxor(b0, 0xFFFFFFFFFFFFFFFF), b1)),
      bxor(b5, band(bxor(b6, 0xFFFFFFFFFFFFFFFF), b7)),
      bxor(b6, band(bxor(b7, 0xFFFFFFFFFFFFFFFF), b8)),
      bxor(b7, band(bxor(b8, 0xFFFFFFFFFFFFFFFF), b9)),
      bxor(b8, band(bxor(b9, 0xFFFFFFFFFFFFFFFF), b5)),
      bxor(b9, band(bxor(b5, 0xFFFFFFFFFFFFFFFF), b6)),
      bxor(b10, band(bxor(b11, 0xFFFFFFFFFFFFFFFF), b12)),
      bxor(b11, band(bxor(b12, 0xFFFFFFFFFFFFFFFF), b13)),
      bxor(b12, band(bxor(b13, 0xFFFFFFFFFFFFFFFF), b14)),
      bxor(b13, band(bxor(b14, 0xFFFFFFFFFFFFFFFF), b10)),
      bxor(b14, band(bxor(b10, 0xFFFFFFFFFFFFFFFF), b11)),
      bxor(b15, band(bxor(b16, 0xFFFFFFFFFFFFFFFF), b17)),
      bxor(b16, band(bxor(b17, 0xFFFFFFFFFFFFFFFF), b18)),
      bxor(b17, band(bxor(b18, 0xFFFFFFFFFFFFFFFF), b19)),
      bxor(b18, band(bxor(b19, 0xFFFFFFFFFFFFFFFF), b15)),
      bxor(b19, band(bxor(b15, 0xFFFFFFFFFFFFFFFF), b16)),
      bxor(b20, band(bxor(b21, 0xFFFFFFFFFFFFFFFF), b22)),
      bxor(b21, band(bxor(b22, 0xFFFFFFFFFFFFFFFF), b23)),
      bxor(b22, band(bxor(b23, 0xFFFFFFFFFFFFFFFF), b24)),
      bxor(b23, band(bxor(b24, 0xFFFFFFFFFFFFFFFF), b20)),
      bxor(b24, band(bxor(b20, 0xFFFFFFFFFFFFFFFF), b21))
    )
  end
end

defmodule Keccak.Elixir do
  @moduledoc """
  Pure Elixir, optimised: each lane as two 32-bit halves (h high, l low), so
  every intermediate stays a small integer (below 2^59) and nothing allocates
  a bignum.
  """
  import Bitwise

  @rc32 Keccak.Constants.round_constants()
        |> Enum.map(&{bsr(&1, 32), band(&1, 0xFFFFFFFF)})
        |> List.to_tuple()

  def keccak256(msg),
    do:
      absorb(
        msg,
        1,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0
      )

  def sha3_256(msg),
    do:
      absorb(
        msg,
        6,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0
      )

  @doc "The last block: the tail, the padding byte, zeros, and 0x80 in byte 135."
  def pad(tail, pad) do
    case 135 - byte_size(tail) do
      0 -> <<tail::binary, bor(pad, 0x80)>>
      z -> <<tail::binary, pad, 0::size(8 * (z - 1)), 0x80>>
    end
  end

  defp absorb(
         <<xl0::little-32, xh0::little-32, xl1::little-32, xh1::little-32, xl2::little-32,
           xh2::little-32, xl3::little-32, xh3::little-32, xl4::little-32, xh4::little-32,
           xl5::little-32, xh5::little-32, xl6::little-32, xh6::little-32, xl7::little-32,
           xh7::little-32, xl8::little-32, xh8::little-32, xl9::little-32, xh9::little-32,
           xl10::little-32, xh10::little-32, xl11::little-32, xh11::little-32, xl12::little-32,
           xh12::little-32, xl13::little-32, xh13::little-32, xl14::little-32, xh14::little-32,
           xl15::little-32, xh15::little-32, xl16::little-32, xh16::little-32, rest::binary>>,
         pad,
         h0,
         l0,
         h1,
         l1,
         h2,
         l2,
         h3,
         l3,
         h4,
         l4,
         h5,
         l5,
         h6,
         l6,
         h7,
         l7,
         h8,
         l8,
         h9,
         l9,
         h10,
         l10,
         h11,
         l11,
         h12,
         l12,
         h13,
         l13,
         h14,
         l14,
         h15,
         l15,
         h16,
         l16,
         h17,
         l17,
         h18,
         l18,
         h19,
         l19,
         h20,
         l20,
         h21,
         l21,
         h22,
         l22,
         h23,
         l23,
         h24,
         l24
       ) do
    {h0, l0, h1, l1, h2, l2, h3, l3, h4, l4, h5, l5, h6, l6, h7, l7, h8, l8, h9, l9, h10, l10,
     h11, l11, h12, l12, h13, l13, h14, l14, h15, l15, h16, l16, h17, l17, h18, l18, h19, l19,
     h20, l20, h21, l21, h22, l22, h23, l23, h24, l24} =
      rounds(
        0,
        bxor(h0, xh0),
        bxor(l0, xl0),
        bxor(h1, xh1),
        bxor(l1, xl1),
        bxor(h2, xh2),
        bxor(l2, xl2),
        bxor(h3, xh3),
        bxor(l3, xl3),
        bxor(h4, xh4),
        bxor(l4, xl4),
        bxor(h5, xh5),
        bxor(l5, xl5),
        bxor(h6, xh6),
        bxor(l6, xl6),
        bxor(h7, xh7),
        bxor(l7, xl7),
        bxor(h8, xh8),
        bxor(l8, xl8),
        bxor(h9, xh9),
        bxor(l9, xl9),
        bxor(h10, xh10),
        bxor(l10, xl10),
        bxor(h11, xh11),
        bxor(l11, xl11),
        bxor(h12, xh12),
        bxor(l12, xl12),
        bxor(h13, xh13),
        bxor(l13, xl13),
        bxor(h14, xh14),
        bxor(l14, xl14),
        bxor(h15, xh15),
        bxor(l15, xl15),
        bxor(h16, xh16),
        bxor(l16, xl16),
        h17,
        l17,
        h18,
        l18,
        h19,
        l19,
        h20,
        l20,
        h21,
        l21,
        h22,
        l22,
        h23,
        l23,
        h24,
        l24
      )

    absorb(
      rest,
      pad,
      h0,
      l0,
      h1,
      l1,
      h2,
      l2,
      h3,
      l3,
      h4,
      l4,
      h5,
      l5,
      h6,
      l6,
      h7,
      l7,
      h8,
      l8,
      h9,
      l9,
      h10,
      l10,
      h11,
      l11,
      h12,
      l12,
      h13,
      l13,
      h14,
      l14,
      h15,
      l15,
      h16,
      l16,
      h17,
      l17,
      h18,
      l18,
      h19,
      l19,
      h20,
      l20,
      h21,
      l21,
      h22,
      l22,
      h23,
      l23,
      h24,
      l24
    )
  end

  defp absorb(
         tail,
         pad,
         h0,
         l0,
         h1,
         l1,
         h2,
         l2,
         h3,
         l3,
         h4,
         l4,
         h5,
         l5,
         h6,
         l6,
         h7,
         l7,
         h8,
         l8,
         h9,
         l9,
         h10,
         l10,
         h11,
         l11,
         h12,
         l12,
         h13,
         l13,
         h14,
         l14,
         h15,
         l15,
         h16,
         l16,
         h17,
         l17,
         h18,
         l18,
         h19,
         l19,
         h20,
         l20,
         h21,
         l21,
         h22,
         l22,
         h23,
         l23,
         h24,
         l24
       ) do
    <<xl0::little-32, xh0::little-32, xl1::little-32, xh1::little-32, xl2::little-32,
      xh2::little-32, xl3::little-32, xh3::little-32, xl4::little-32, xh4::little-32,
      xl5::little-32, xh5::little-32, xl6::little-32, xh6::little-32, xl7::little-32,
      xh7::little-32, xl8::little-32, xh8::little-32, xl9::little-32, xh9::little-32,
      xl10::little-32, xh10::little-32, xl11::little-32, xh11::little-32, xl12::little-32,
      xh12::little-32, xl13::little-32, xh13::little-32, xl14::little-32, xh14::little-32,
      xl15::little-32, xh15::little-32, xl16::little-32, xh16::little-32>> = pad(tail, pad)

    {h0, l0, h1, l1, h2, l2, h3, l3, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _,
     _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _} =
      rounds(
        0,
        bxor(h0, xh0),
        bxor(l0, xl0),
        bxor(h1, xh1),
        bxor(l1, xl1),
        bxor(h2, xh2),
        bxor(l2, xl2),
        bxor(h3, xh3),
        bxor(l3, xl3),
        bxor(h4, xh4),
        bxor(l4, xl4),
        bxor(h5, xh5),
        bxor(l5, xl5),
        bxor(h6, xh6),
        bxor(l6, xl6),
        bxor(h7, xh7),
        bxor(l7, xl7),
        bxor(h8, xh8),
        bxor(l8, xl8),
        bxor(h9, xh9),
        bxor(l9, xl9),
        bxor(h10, xh10),
        bxor(l10, xl10),
        bxor(h11, xh11),
        bxor(l11, xl11),
        bxor(h12, xh12),
        bxor(l12, xl12),
        bxor(h13, xh13),
        bxor(l13, xl13),
        bxor(h14, xh14),
        bxor(l14, xl14),
        bxor(h15, xh15),
        bxor(l15, xl15),
        bxor(h16, xh16),
        bxor(l16, xl16),
        h17,
        l17,
        h18,
        l18,
        h19,
        l19,
        h20,
        l20,
        h21,
        l21,
        h22,
        l22,
        h23,
        l23,
        h24,
        l24
      )

    <<l0::little-32, h0::little-32, l1::little-32, h1::little-32, l2::little-32, h2::little-32,
      l3::little-32, h3::little-32>>
  end

  defp rounds(
         24,
         h0,
         l0,
         h1,
         l1,
         h2,
         l2,
         h3,
         l3,
         h4,
         l4,
         h5,
         l5,
         h6,
         l6,
         h7,
         l7,
         h8,
         l8,
         h9,
         l9,
         h10,
         l10,
         h11,
         l11,
         h12,
         l12,
         h13,
         l13,
         h14,
         l14,
         h15,
         l15,
         h16,
         l16,
         h17,
         l17,
         h18,
         l18,
         h19,
         l19,
         h20,
         l20,
         h21,
         l21,
         h22,
         l22,
         h23,
         l23,
         h24,
         l24
       ),
       do:
         {h0, l0, h1, l1, h2, l2, h3, l3, h4, l4, h5, l5, h6, l6, h7, l7, h8, l8, h9, l9, h10,
          l10, h11, l11, h12, l12, h13, l13, h14, l14, h15, l15, h16, l16, h17, l17, h18, l18,
          h19, l19, h20, l20, h21, l21, h22, l22, h23, l23, h24, l24}

  defp rounds(
         r,
         h0,
         l0,
         h1,
         l1,
         h2,
         l2,
         h3,
         l3,
         h4,
         l4,
         h5,
         l5,
         h6,
         l6,
         h7,
         l7,
         h8,
         l8,
         h9,
         l9,
         h10,
         l10,
         h11,
         l11,
         h12,
         l12,
         h13,
         l13,
         h14,
         l14,
         h15,
         l15,
         h16,
         l16,
         h17,
         l17,
         h18,
         l18,
         h19,
         l19,
         h20,
         l20,
         h21,
         l21,
         h22,
         l22,
         h23,
         l23,
         h24,
         l24
       ) do
    ch0 = bxor(bxor(bxor(bxor(h0, h5), h10), h15), h20)
    cl0 = bxor(bxor(bxor(bxor(l0, l5), l10), l15), l20)
    ch1 = bxor(bxor(bxor(bxor(h1, h6), h11), h16), h21)
    cl1 = bxor(bxor(bxor(bxor(l1, l6), l11), l16), l21)
    ch2 = bxor(bxor(bxor(bxor(h2, h7), h12), h17), h22)
    cl2 = bxor(bxor(bxor(bxor(l2, l7), l12), l17), l22)
    ch3 = bxor(bxor(bxor(bxor(h3, h8), h13), h18), h23)
    cl3 = bxor(bxor(bxor(bxor(l3, l8), l13), l18), l23)
    ch4 = bxor(bxor(bxor(bxor(h4, h9), h14), h19), h24)
    cl4 = bxor(bxor(bxor(bxor(l4, l9), l14), l19), l24)
    dh0 = bxor(ch4, bor(bsl(band(ch1, 0x7FFFFFFF), 1), bsr(cl1, 31)))
    dl0 = bxor(cl4, bor(bsl(band(cl1, 0x7FFFFFFF), 1), bsr(ch1, 31)))
    dh1 = bxor(ch0, bor(bsl(band(ch2, 0x7FFFFFFF), 1), bsr(cl2, 31)))
    dl1 = bxor(cl0, bor(bsl(band(cl2, 0x7FFFFFFF), 1), bsr(ch2, 31)))
    dh2 = bxor(ch1, bor(bsl(band(ch3, 0x7FFFFFFF), 1), bsr(cl3, 31)))
    dl2 = bxor(cl1, bor(bsl(band(cl3, 0x7FFFFFFF), 1), bsr(ch3, 31)))
    dh3 = bxor(ch2, bor(bsl(band(ch4, 0x7FFFFFFF), 1), bsr(cl4, 31)))
    dl3 = bxor(cl2, bor(bsl(band(cl4, 0x7FFFFFFF), 1), bsr(ch4, 31)))
    dh4 = bxor(ch3, bor(bsl(band(ch0, 0x7FFFFFFF), 1), bsr(cl0, 31)))
    dl4 = bxor(cl3, bor(bsl(band(cl0, 0x7FFFFFFF), 1), bsr(ch0, 31)))
    eh0 = bxor(h0, dh0)
    el0 = bxor(l0, dl0)
    eh6 = bxor(h6, dh1)
    el6 = bxor(l6, dl1)
    eh12 = bxor(h12, dh2)
    el12 = bxor(l12, dl2)
    eh18 = bxor(h18, dh3)
    el18 = bxor(l18, dl3)
    eh24 = bxor(h24, dh4)
    el24 = bxor(l24, dl4)
    eh3 = bxor(h3, dh3)
    el3 = bxor(l3, dl3)
    eh9 = bxor(h9, dh4)
    el9 = bxor(l9, dl4)
    eh10 = bxor(h10, dh0)
    el10 = bxor(l10, dl0)
    eh16 = bxor(h16, dh1)
    el16 = bxor(l16, dl1)
    eh22 = bxor(h22, dh2)
    el22 = bxor(l22, dl2)
    eh1 = bxor(h1, dh1)
    el1 = bxor(l1, dl1)
    eh7 = bxor(h7, dh2)
    el7 = bxor(l7, dl2)
    eh13 = bxor(h13, dh3)
    el13 = bxor(l13, dl3)
    eh19 = bxor(h19, dh4)
    el19 = bxor(l19, dl4)
    eh20 = bxor(h20, dh0)
    el20 = bxor(l20, dl0)
    eh4 = bxor(h4, dh4)
    el4 = bxor(l4, dl4)
    eh5 = bxor(h5, dh0)
    el5 = bxor(l5, dl0)
    eh11 = bxor(h11, dh1)
    el11 = bxor(l11, dl1)
    eh17 = bxor(h17, dh2)
    el17 = bxor(l17, dl2)
    eh23 = bxor(h23, dh3)
    el23 = bxor(l23, dl3)
    eh2 = bxor(h2, dh2)
    el2 = bxor(l2, dl2)
    eh8 = bxor(h8, dh3)
    el8 = bxor(l8, dl3)
    eh14 = bxor(h14, dh4)
    el14 = bxor(l14, dl4)
    eh15 = bxor(h15, dh0)
    el15 = bxor(l15, dl0)
    eh21 = bxor(h21, dh1)
    el21 = bxor(l21, dl1)
    bh0 = eh0
    bl0 = el0
    bh1 = bor(bsl(band(el6, 0xFFFFF), 12), bsr(eh6, 20))
    bl1 = bor(bsl(band(eh6, 0xFFFFF), 12), bsr(el6, 20))
    bh2 = bor(bsl(band(el12, 0x1FFFFF), 11), bsr(eh12, 21))
    bl2 = bor(bsl(band(eh12, 0x1FFFFF), 11), bsr(el12, 21))
    bh3 = bor(bsl(band(eh18, 0x7FF), 21), bsr(el18, 11))
    bl3 = bor(bsl(band(el18, 0x7FF), 21), bsr(eh18, 11))
    bh4 = bor(bsl(band(eh24, 0x3FFFF), 14), bsr(el24, 18))
    bl4 = bor(bsl(band(el24, 0x3FFFF), 14), bsr(eh24, 18))
    bh5 = bor(bsl(band(eh3, 0xF), 28), bsr(el3, 4))
    bl5 = bor(bsl(band(el3, 0xF), 28), bsr(eh3, 4))
    bh6 = bor(bsl(band(eh9, 0xFFF), 20), bsr(el9, 12))
    bl6 = bor(bsl(band(el9, 0xFFF), 20), bsr(eh9, 12))
    bh7 = bor(bsl(band(eh10, 0x1FFFFFFF), 3), bsr(el10, 29))
    bl7 = bor(bsl(band(el10, 0x1FFFFFFF), 3), bsr(eh10, 29))
    bh8 = bor(bsl(band(el16, 0x7FFFF), 13), bsr(eh16, 19))
    bl8 = bor(bsl(band(eh16, 0x7FFFF), 13), bsr(el16, 19))
    bh9 = bor(bsl(band(el22, 0x7), 29), bsr(eh22, 3))
    bl9 = bor(bsl(band(eh22, 0x7), 29), bsr(el22, 3))
    bh10 = bor(bsl(band(eh1, 0x7FFFFFFF), 1), bsr(el1, 31))
    bl10 = bor(bsl(band(el1, 0x7FFFFFFF), 1), bsr(eh1, 31))
    bh11 = bor(bsl(band(eh7, 0x3FFFFFF), 6), bsr(el7, 26))
    bl11 = bor(bsl(band(el7, 0x3FFFFFF), 6), bsr(eh7, 26))
    bh12 = bor(bsl(band(eh13, 0x7F), 25), bsr(el13, 7))
    bl12 = bor(bsl(band(el13, 0x7F), 25), bsr(eh13, 7))
    bh13 = bor(bsl(band(eh19, 0xFFFFFF), 8), bsr(el19, 24))
    bl13 = bor(bsl(band(el19, 0xFFFFFF), 8), bsr(eh19, 24))
    bh14 = bor(bsl(band(eh20, 0x3FFF), 18), bsr(el20, 14))
    bl14 = bor(bsl(band(el20, 0x3FFF), 18), bsr(eh20, 14))
    bh15 = bor(bsl(band(eh4, 0x1F), 27), bsr(el4, 5))
    bl15 = bor(bsl(band(el4, 0x1F), 27), bsr(eh4, 5))
    bh16 = bor(bsl(band(el5, 0xFFFFFFF), 4), bsr(eh5, 28))
    bl16 = bor(bsl(band(eh5, 0xFFFFFFF), 4), bsr(el5, 28))
    bh17 = bor(bsl(band(eh11, 0x3FFFFF), 10), bsr(el11, 22))
    bl17 = bor(bsl(band(el11, 0x3FFFFF), 10), bsr(eh11, 22))
    bh18 = bor(bsl(band(eh17, 0x1FFFF), 15), bsr(el17, 17))
    bl18 = bor(bsl(band(el17, 0x1FFFF), 15), bsr(eh17, 17))
    bh19 = bor(bsl(band(el23, 0xFF), 24), bsr(eh23, 8))
    bl19 = bor(bsl(band(eh23, 0xFF), 24), bsr(el23, 8))
    bh20 = bor(bsl(band(el2, 0x3), 30), bsr(eh2, 2))
    bl20 = bor(bsl(band(eh2, 0x3), 30), bsr(el2, 2))
    bh21 = bor(bsl(band(el8, 0x1FF), 23), bsr(eh8, 9))
    bl21 = bor(bsl(band(eh8, 0x1FF), 23), bsr(el8, 9))
    bh22 = bor(bsl(band(el14, 0x1FFFFFF), 7), bsr(eh14, 25))
    bl22 = bor(bsl(band(eh14, 0x1FFFFFF), 7), bsr(el14, 25))
    bh23 = bor(bsl(band(el15, 0x7FFFFF), 9), bsr(eh15, 23))
    bl23 = bor(bsl(band(eh15, 0x7FFFFF), 9), bsr(el15, 23))
    bh24 = bor(bsl(band(eh21, 0x3FFFFFFF), 2), bsr(el21, 30))
    bl24 = bor(bsl(band(el21, 0x3FFFFFFF), 2), bsr(eh21, 30))
    {rh, rl} = elem(@rc32, r)

    rounds(
      r + 1,
      bxor(bxor(bh0, band(bxor(bh1, 0xFFFFFFFF), bh2)), rh),
      bxor(bxor(bl0, band(bxor(bl1, 0xFFFFFFFF), bl2)), rl),
      bxor(bh1, band(bxor(bh2, 0xFFFFFFFF), bh3)),
      bxor(bl1, band(bxor(bl2, 0xFFFFFFFF), bl3)),
      bxor(bh2, band(bxor(bh3, 0xFFFFFFFF), bh4)),
      bxor(bl2, band(bxor(bl3, 0xFFFFFFFF), bl4)),
      bxor(bh3, band(bxor(bh4, 0xFFFFFFFF), bh0)),
      bxor(bl3, band(bxor(bl4, 0xFFFFFFFF), bl0)),
      bxor(bh4, band(bxor(bh0, 0xFFFFFFFF), bh1)),
      bxor(bl4, band(bxor(bl0, 0xFFFFFFFF), bl1)),
      bxor(bh5, band(bxor(bh6, 0xFFFFFFFF), bh7)),
      bxor(bl5, band(bxor(bl6, 0xFFFFFFFF), bl7)),
      bxor(bh6, band(bxor(bh7, 0xFFFFFFFF), bh8)),
      bxor(bl6, band(bxor(bl7, 0xFFFFFFFF), bl8)),
      bxor(bh7, band(bxor(bh8, 0xFFFFFFFF), bh9)),
      bxor(bl7, band(bxor(bl8, 0xFFFFFFFF), bl9)),
      bxor(bh8, band(bxor(bh9, 0xFFFFFFFF), bh5)),
      bxor(bl8, band(bxor(bl9, 0xFFFFFFFF), bl5)),
      bxor(bh9, band(bxor(bh5, 0xFFFFFFFF), bh6)),
      bxor(bl9, band(bxor(bl5, 0xFFFFFFFF), bl6)),
      bxor(bh10, band(bxor(bh11, 0xFFFFFFFF), bh12)),
      bxor(bl10, band(bxor(bl11, 0xFFFFFFFF), bl12)),
      bxor(bh11, band(bxor(bh12, 0xFFFFFFFF), bh13)),
      bxor(bl11, band(bxor(bl12, 0xFFFFFFFF), bl13)),
      bxor(bh12, band(bxor(bh13, 0xFFFFFFFF), bh14)),
      bxor(bl12, band(bxor(bl13, 0xFFFFFFFF), bl14)),
      bxor(bh13, band(bxor(bh14, 0xFFFFFFFF), bh10)),
      bxor(bl13, band(bxor(bl14, 0xFFFFFFFF), bl10)),
      bxor(bh14, band(bxor(bh10, 0xFFFFFFFF), bh11)),
      bxor(bl14, band(bxor(bl10, 0xFFFFFFFF), bl11)),
      bxor(bh15, band(bxor(bh16, 0xFFFFFFFF), bh17)),
      bxor(bl15, band(bxor(bl16, 0xFFFFFFFF), bl17)),
      bxor(bh16, band(bxor(bh17, 0xFFFFFFFF), bh18)),
      bxor(bl16, band(bxor(bl17, 0xFFFFFFFF), bl18)),
      bxor(bh17, band(bxor(bh18, 0xFFFFFFFF), bh19)),
      bxor(bl17, band(bxor(bl18, 0xFFFFFFFF), bl19)),
      bxor(bh18, band(bxor(bh19, 0xFFFFFFFF), bh15)),
      bxor(bl18, band(bxor(bl19, 0xFFFFFFFF), bl15)),
      bxor(bh19, band(bxor(bh15, 0xFFFFFFFF), bh16)),
      bxor(bl19, band(bxor(bl15, 0xFFFFFFFF), bl16)),
      bxor(bh20, band(bxor(bh21, 0xFFFFFFFF), bh22)),
      bxor(bl20, band(bxor(bl21, 0xFFFFFFFF), bl22)),
      bxor(bh21, band(bxor(bh22, 0xFFFFFFFF), bh23)),
      bxor(bl21, band(bxor(bl22, 0xFFFFFFFF), bl23)),
      bxor(bh22, band(bxor(bh23, 0xFFFFFFFF), bh24)),
      bxor(bl22, band(bxor(bl23, 0xFFFFFFFF), bl24)),
      bxor(bh23, band(bxor(bh24, 0xFFFFFFFF), bh20)),
      bxor(bl23, band(bxor(bl24, 0xFFFFFFFF), bl20)),
      bxor(bh24, band(bxor(bh20, 0xFFFFFFFF), bh21)),
      bxor(bl24, band(bxor(bl20, 0xFFFFFFFF), bl21))
    )
  end
end

hex = &Base.encode16(&1, case: :lower)
alias Keccak.Kernels, as: K

# ---- agreement: vectors ------------------------------------------------------
vectors = [
  {:keccak256, "", "c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470"},
  {:keccak256, "abc", "4e03657aea45a94fc7d47ba826c8d667c0d1e6e33a64a036ec44f58fa12d6c45"},
  {:sha3_256, "", "a7ffc6f8bf1ed76651c14756a061d662f580ff4de43b49fa82d80a4b80f8434a"},
  {:sha3_256, "abc", "3a985da74fe225b2045c172d6bd390bd855f086e3e9d525b46bfe24511431532"},
  {:sha3_256, "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq",
   "41c0dba2a9d6240849100376a8235e2c82e1b9998a999e21db32dd97496d3376"},
  {:sha3_256, String.duplicate("a", 1_000_000),
   "5c8875ae474a3634ba4fd55ec85bffd661f32aca75c6d699d0cdcb6c115891c1"}
]

vectors_ok =
  Enum.all?(vectors, fn {f, msg, want} ->
    got = [apply(K, f, [msg]), apply(Keccak.Elixir, f, [msg]), apply(Keccak.Elixir64, f, [msg])]
    ok = Enum.all?(got, &(hex.(&1) == want))

    unless ok,
      do:
        IO.puts("vector #{f}(#{inspect(binary_part(msg, 0, min(8, byte_size(msg))))}...) FAILED")

    ok
  end)

IO.puts("FIPS 202 and Ethereum vectors (kernel and both Elixir versions): #{vectors_ok}")

# ---- agreement: random messages against ex_keccak, :crypto and ex_sha3 -------
:rand.seed(:exsss, {52, 1, 0})
# every length from 0 to 3 blocks (all padding positions), then longer ones
lengths = Enum.to_list(0..410) ++ for(_ <- 1..200, do: :rand.uniform(5000))
random_msgs = for n <- lengths, do: :crypto.strong_rand_bytes(n)

random_ok =
  Enum.all?(random_msgs, fn m ->
    k = ExKeccak.hash_256(m)
    s = :crypto.hash(:sha3_256, m)

    K.keccak256(m) == k and K.sha3_256(m) == s and Keccak.Elixir.keccak256(m) == k and
      Keccak.Elixir.sha3_256(m) == s and Keccak.Elixir64.keccak256(m) == k
  end) and
    Enum.all?(Enum.take(random_msgs, 300), &(ExSha3.keccak_256(&1) == ExKeccak.hash_256(&1)))

IO.puts(
  "#{length(random_msgs)} random messages (0..5000 bytes): kernel and Elixir equal ex_keccak and :crypto sha3_256: #{random_ok}"
)

pack = fn msgs ->
  {offs, _} = Enum.map_reduce(msgs, 0, fn m, o -> {<<o::signed-native-64>>, o + byte_size(m)} end)
  total = Enum.reduce(msgs, 0, &(byte_size(&1) + &2))
  {IO.iodata_to_binary(msgs), IO.iodata_to_binary([offs, <<total::signed-native-64>>])}
end

split = fn out -> for <<h::binary-32 <- out>>, do: h end

{blob, offs} = pack.(random_msgs)

batch_ok =
  split.(K.keccak256_batch(blob, offs)) == Enum.map(random_msgs, &ExKeccak.hash_256/1) and
    split.(K.sha3_256_batch(blob, offs)) == Enum.map(random_msgs, &:crypto.hash(:sha3_256, &1)) and
    K.keccak256_batch(<<>>, <<0::signed-native-64>>) == <<>>

IO.puts("batch kernels equal the per-message digests: #{batch_ok}")

# ---- agreement: Elixir mode --------------------------------------------------
# Elixir mode is compiled only under a Mix project in :dev or :test, which a
# Mix.install script does not have: declare a throwaway project and compile
# the same quoted kernels again under :test.
defmodule KeccakExample.MixProject do
  use Mix.Project
  def project, do: [app: :keccak_example, version: "0.0.0"]
end

mix_env = Mix.env()
Mix.env(:test)
Module.create(Keccak.ElixirMode, kernels, Macro.Env.location(__ENV__))
Mix.env(mix_env)

mode_msgs = Enum.take(random_msgs, 160) ++ [String.duplicate("a", 1000)]
{mblob, moffs} = pack.(mode_msgs)

mode_ok =
  Enum.all?(mode_msgs, fn m ->
    Keccak.ElixirMode.__defk_elixir__(:keccak256, [m]) == K.keccak256(m) and
      Keccak.ElixirMode.__defk_elixir__(:sha3_256, [m]) == K.sha3_256(m)
  end) and
    Keccak.ElixirMode.__defk_elixir__(:keccak256_batch, [mblob, moffs]) ==
      K.keccak256_batch(mblob, moffs) and
    try do
      K.keccak256_batch(mblob, <<10::signed-native-64, 0::signed-native-64>>) && false
    rescue
      ArgumentError -> true
    end

IO.puts("Elixir mode equals the kernel (#{length(mode_msgs)} messages and a batch): #{mode_ok}")

# ---- timing ------------------------------------------------------------------
time_us = fn f, runs ->
  f.()

  Enum.map(1..runs, fn _ ->
    :erlang.garbage_collect()
    elem(:timer.tc(f), 0)
  end)
  |> Enum.min()
end

batch = for _ <- 1..10_000, do: :crypto.strong_rand_bytes(32)
batch_1k = for _ <- 1..10_000, do: :crypto.strong_rand_bytes(1024)
big = :crypto.strong_rand_bytes(16 * 1024 * 1024)

# the caller has a list of binaries and wants a list of digests: packing and
# splitting are part of the defk side
defk_batch = fn msgs, f ->
  {b, o} = pack.(msgs)
  split.(f.(b, o))
end

kb = &K.keccak256_batch/2
sb = &K.sha3_256_batch/2

if System.get_env("KECCAK_VARIANTS") do
  IO.puts("\nvariants, 10k x 32 B (best of 5):")

  for {name, f} <- [
        {"ex_sha3 0.1.5 (pure Elixir, Hex)", &ExSha3.keccak_256/1},
        {"Elixir, 64-bit lanes", &Keccak.Elixir64.keccak256/1},
        {"Elixir, 32-bit halves", &Keccak.Elixir.keccak256/1},
        {"defk, one call per message", &K.keccak256/1},
        {"ex_keccak, one call per message", &ExKeccak.hash_256/1}
      ] do
    us = time_us.(fn -> Enum.map(batch, f) end, 5)

    IO.puts(
      "  #{String.pad_trailing(name, 34)} #{Float.round(us / 1000, 2)} ms (#{Float.round(us / 10_000, 3)} us/msg)"
    )
  end

  us = time_us.(fn -> defk_batch.(batch, kb) end, 5)

  IO.puts(
    "  #{String.pad_trailing("defk batch kernel", 34)} #{Float.round(us / 1000, 2)} ms (#{Float.round(us / 10_000, 3)} us/msg)"
  )
end

# one 16 MB message, best of 3: the per-permutation cost against the NIFs
ms16 = fn f -> Float.round(time_us.(f, 3) / 1000, 1) end

IO.puts(
  "\n1 x 16 MB: defk keccak256 #{ms16.(fn -> K.keccak256(big) end)} ms, ex_keccak #{ms16.(fn -> ExKeccak.hash_256(big) end)} ms, " <>
    "defk sha3_256 #{ms16.(fn -> K.sha3_256(big) end)} ms, :crypto sha3_256 #{ms16.(fn -> :crypto.hash(:sha3_256, big) end)} ms"
)

Defk.Bench.report(
  name: "keccak",
  expected: :good,
  baseline: :optimized,
  realistic_size: "10k x 32 B messages per call",
  elixir: fn -> Enum.map(batch, &Keccak.Elixir.keccak256/1) end,
  defk: fn -> defk_batch.(batch, kb) end,
  native: {fn -> Enum.map(batch, &ExKeccak.hash_256/1) end, "ex_keccak 0.7.8 (tiny-keccak)"},
  check: fn ->
    vectors_ok and random_ok and batch_ok and mode_ok and
      defk_batch.(batch, kb) == Enum.map(batch, &Keccak.Elixir.keccak256/1)
  end,
  sweep: [
    {"10k x 32 B, one call each", fn -> Enum.map(batch, &Keccak.Elixir.keccak256/1) end,
     fn -> Enum.map(batch, &K.keccak256/1) end},
    {"10k x 1 KB", fn -> Enum.map(batch_1k, &Keccak.Elixir.keccak256/1) end,
     fn -> defk_batch.(batch_1k, kb) end},
    {"1 x 16 MB", fn -> Keccak.Elixir.keccak256(big) end, fn -> K.keccak256(big) end}
  ],
  responsiveness: [
    elixir: fn -> Keccak.Elixir.keccak256(big) end,
    defk: fn -> K.keccak256(big) end,
    native: fn -> ExKeccak.hash_256(big) end
  ],
  reason:
    "Keccak-256 is not in :crypto; a 24-round permutation of bxor/bic/rotates over 25 u64 lanes held in registers, where pure Elixir splits every lane in two to stay in small integers; ex_keccak (tiny-keccak) is still faster"
)

# SHA3-256 is in :crypto (OpenSSL), so for this twin the Elixir answer is
# :crypto.hash/2 and the pure Elixir version is only shown in the sweep.
Defk.Bench.report(
  name: "keccak_sha3_256",
  expected: :poor,
  baseline: :optimized,
  realistic_size: "10k x 32 B messages per call",
  elixir: fn -> Enum.map(batch, &:crypto.hash(:sha3_256, &1)) end,
  defk: fn -> defk_batch.(batch, sb) end,
  check: fn ->
    defk_batch.(batch, sb) == Enum.map(batch, &:crypto.hash(:sha3_256, &1))
  end,
  sweep: [
    {"10k x 32 B, one call each", fn -> Enum.map(batch, &:crypto.hash(:sha3_256, &1)) end,
     fn -> Enum.map(batch, &K.sha3_256/1) end},
    {"1 x 16 MB", fn -> :crypto.hash(:sha3_256, big) end, fn -> K.sha3_256(big) end},
    {"10k x 32 B, pure Elixir vs defk batch",
     fn -> Enum.map(batch, &Keccak.Elixir.sha3_256/1) end, fn -> defk_batch.(batch, sb) end}
  ],
  reason:
    "SHA3-256 ships in :crypto (OpenSSL, about 1.5-2x faster than the kernel): use :crypto.hash(:sha3_256, msg)"
)
