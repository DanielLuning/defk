# hashes: xxHash64, Murmur3 x64_128, SipHash-2-4 and CRC32C of binaries that
# must match other systems (Kafka record CRCs, shard routing, dedup indexes)
#
# Why people reach for a NIF: a 64-bit hash in Elixir runs on bignums. Every
# u64 above 2^59 is a heap integer and every multiply makes a 128-bit one
# before the mask, so the pure packages run at 0.01-0.12 GB/s. murmur (2.4M
# downloads) and xxhash (205k) stay pure Elixir, xxhash's README suggests a
# NIF "if you require a high performance version", siphash (224k) ships 108
# lines of C beside an Elixir fallback, and crc32cer (48.5M) wraps Google's
# crc32c. :erlang.phash2/1 (not portable across OTP versions) and
# :erlang.crc32/1 (a different polynomial) are fast BIFs but different hashes;
# they are measured as the ceiling, not as baselines.
#
#   elixir examples/hashes.exs                    # agreement, table, 4 reports
#   MIX_ENV=test mix run examples/hashes.exs      # native vs Elixir mode only
#
# Four reports, four DEFK_RESULT lines, in this order: hashes_xxh64 (good),
# hashes_murmur3 (good), hashes_siphash24 (good), hashes_crc32c (marginal).
# run_all.exs reads only the first (xxh64); the script checks the other three
# itself and exits 1 when one is incorrect or measures another verdict.
#
# Kernels: xxh64(bytes, seed) :: i64, murmur3_128(bytes, seed) :: {i64, i64}
# (h1, h2), siphash24(bytes, k0, k1) :: i64 and crc32c(bytes) :: i64, plus
# *_batch(blob, offsets, ...) :: [i64] that hash every key [offsets[k],
# offsets[k + 1]) of one packed blob in one call. A u64 hash comes back as
# its i64 bit pattern; an Elixir caller wanting the unsigned value writes
# `<<u::unsigned-64>> = <<h::signed-64>>` (Hashes.Data.u64/1). SipHash's
# 16-byte key is passed as its two little-endian words
# (`<<k0::little-signed-64, k1::little-signed-64>> = key`). Masked
# arithmetic: every multiply and add is under wrap64/1, word loads are
# u64_le/u32_le, the constants are module attributes, and the CRC32C
# slicing-by-8 tables are an 8 KB binary attribute computed at compile time.
# Rotates are not builtins yet: 14 helper kernels rotl1..rotl33 write
# bor(wrap64(bsl(x, n)), band(bsr(x, 64 - n), 2^n - 1)), one per count,
# because a bsl by a variable count is checked (defk-52v.6 would make them a
# builtin). murmur3_128 is a batch of one (a kernel that returns a tuple
# cannot be called from another kernel), which costs an alloc per call.
#
# Agreement, checked on every run: the reference vectors (xxhsum's sanity
# buffer at lengths 0/1/14/222 with seeds 0 and PRIME32; SMHasher's
# verification value 0x6384BA69 for MurmurHash3_x64_128; the SipHash paper's
# key 00..0f with message 00..0e, and the empty message; CRC32C "123456789"
# = 0xE3069283) for the kernels and the Elixir versions; 301 random binaries
# (0-200 bytes and 100 up to 5000) against xxhash xxh64/3, murmur
# hash_x64_128, siphash's NIF and its Elixir fallback, crc32cer and this
# file's Elixir versions; the batch kernels against the single ones; and the
# 4 MB message per report. Elixir mode cannot be compiled in a Mix.install
# script, so `MIX_ENV=test mix run examples/hashes.exs` checks native ===
# Elixir mode for all eight kernels on 76 random inputs and the vectors.
#
# The xxhash package is off-spec in two ways: xxh64/2 and xxh32/2 pass
# String.length/1 (graphemes) as the length, so they give wrong hashes or
# raise on 263 of 300 random binaries (any non-ASCII input); and the empty
# input returns the seed-0 hash whatever the seed. Its xxh64/3 with
# byte_size/1 is correct and is what is measured.
#
# Elixir baselines: optimised. Each hash measured three ways where there was
# room: the package, a rewrite for the BEAM, and the faster is the baseline.
#   xxHash64  xxhash 0.3.1 xxh64/3 reads every word big-endian and byte-swaps
#             it through a new binary, and builds a 4-tuple per stripe; the
#             rewrite (little-endian matches, one mask per step, inlined
#             helpers) is 1.4x faster and is the baseline.
#   Murmur3   murmur 2.0.2 is already the shape a rewrite would have
#             (little-endian matches, inlined helpers, a mask per step); it
#             is the baseline.
#   SipHash   siphash 3.2.0's fallback keeps the state in a record; the
#             rewrite keeps it in four variables and is 1.1x faster at 4 MB
#             and 1.1-2x on the batch; it is the baseline.
#   CRC32C    no pure package: byte-at-a-time from a literal tuple, and
#             slicing-by-8 (eight lookups per 8 bytes from one 2048-tuple).
#             CRC32C values are 32-bit, so they stay small integers, and the
#             JIT runs slicing-by-8 at 1.6 GB/s, 5x byte-at-a-time; it is
#             the baseline, and the kernel uses the same algorithm.
# Not tried: 64-bit arithmetic in 16-bit limbs to stay in small integers
# (four times the operations; unlikely to close a 90x gap); parallel
# hashing of the batch across processes (the kernel is single-threaded).
#
# Measured (M-series Mac, OTP 29, Elixir 1.20), best of 5, three runs:
#   xxHash64 4 MB: rewrite 35.5-41.1 ms (xxhash 51.6-53.9 ms), kernel
#     0.35-0.40 ms (10-12 GB/s): 90-101x, good. 1k keys 21-25x.
#   Murmur3 4 MB: murmur 70.0-79.4 ms, kernel 0.52-0.55 ms (8 GB/s):
#     133-145x, good. 1k keys 19x.
#   SipHash 1k 32-byte keys: rewrite 4.24-4.29 ms (fallback 4.8-8.8 ms),
#     kernel batch 0.048-0.055 ms: 77-89x, good. siphash's C NIF, one call
#     per key, 0.048-0.053 ms: the kernel is level with the C (0.96-1.0x),
#     as expected; at 4 MB the kernel is 1.36x faster (1.33 vs 1.82 ms).
#     One kernel call per key is 0.085 ms: a kernel call costs ~35 ns more
#     than siphash's NIF call.
#   CRC32C 4 MB: Elixir slicing-by-8 2.54-3.05 ms, kernel 1.78-1.89 ms
#     (2.3 GB/s): 1.39-1.65x, marginal. On the 1k-key batch Elixir wins
#     (0.03 vs 0.06 ms, packing included). crc32cer (hardware CRC32C
#     instructions) 0.12-0.14 ms: the kernel is 0.07-0.08x of it, poor, as
#     expected. An in-kernel alloc'd table instead of the binary attribute
#     measured 1.6 ms (still marginal), byte-at-a-time 7.7 ms.
#   BIF ceiling, 4 MB: :erlang.phash2 1.64-1.79 ms (2.4-2.6 GB/s),
#     :erlang.crc32 0.10-0.11 ms (~40 GB/s); on 1k keys 0.02 and 0.03 ms.
#
# Recommendation: for xxHash64, Murmur3 and SipHash a kernel is the right
# tool (77-145x over the best pure Elixir, level with or ahead of siphash's
# hand-written C, and no C to ship). For CRC32C use crc32cer: it is 14x
# faster than the kernel, and without it Elixir slicing-by-8 is within 1.7x
# of the kernel; the kernel cannot use the CRC32C instructions.

anchors = [
  {:murmur, "2.0.2"},
  {:xxhash, "0.3.1"},
  {:siphash, "3.2.0"},
  {:crc32cer, "1.1.4"}
]

elixir_mode? = Process.whereis(Mix.ProjectStack) != nil and Mix.Project.get() != nil

unless elixir_mode? do
  Mix.install([{:defk, path: Path.expand("..", __DIR__)} | anchors])
end

# CRC32C slicing-by-8 tables (reflected polynomial 0x82F63B78), shared by
# the kernel (as a binary attribute) and the Elixir version (as a tuple)
defmodule Hashes.CRC32CTables do
  import Bitwise

  def flat do
    t0 =
      for n <- 0..255 do
        Enum.reduce(1..8, n, fn _, c ->
          if band(c, 1) == 1, do: bxor(c >>> 1, 0x82F63B78), else: c >>> 1
        end)
      end

    t0t = List.to_tuple(t0)

    rows =
      Enum.scan(1..7, t0, fn _, prev ->
        Enum.map(prev, &bxor(&1 >>> 8, elem(t0t, band(&1, 255))))
      end)

    t0 ++ List.flatten(rows)
  end
end

defmodule Hashes.Kernels do
  use Defk

  # u64 constants as their i64 bit patterns
  @xp1 Defk.Bits.wrap64(0x9E3779B185EBCA87)
  @xp2 Defk.Bits.wrap64(0xC2B2AE3D27D4EB4F)
  @xp3 0x165667B19E3779F9
  @xp4 Defk.Bits.wrap64(0x85EBCA77C2B2AE63)
  @xp5 0x27D4EB2F165667C5

  # rotl(x, n) on the 64-bit pattern: the bsl wraps (wrap64), the bsr is
  # arithmetic so its sign fill is masked off
  defk(rotl1(x :: i64) :: i64, do: bor(wrap64(bsl(x, 1)), band(bsr(x, 63), 0x1)))
  defk(rotl7(x :: i64) :: i64, do: bor(wrap64(bsl(x, 7)), band(bsr(x, 57), 0x7F)))
  defk(rotl11(x :: i64) :: i64, do: bor(wrap64(bsl(x, 11)), band(bsr(x, 53), 0x7FF)))
  defk(rotl12(x :: i64) :: i64, do: bor(wrap64(bsl(x, 12)), band(bsr(x, 52), 0xFFF)))
  defk(rotl18(x :: i64) :: i64, do: bor(wrap64(bsl(x, 18)), band(bsr(x, 46), 0x3FFFF)))
  defk(rotl23(x :: i64) :: i64, do: bor(wrap64(bsl(x, 23)), band(bsr(x, 41), 0x7FFFFF)))
  defk(rotl27(x :: i64) :: i64, do: bor(wrap64(bsl(x, 27)), band(bsr(x, 37), 0x7FFFFFF)))
  defk(rotl31(x :: i64) :: i64, do: bor(wrap64(bsl(x, 31)), band(bsr(x, 33), 0x7FFFFFFF)))
  defk(rotl13(x :: i64) :: i64, do: bor(wrap64(bsl(x, 13)), band(bsr(x, 51), 0x1FFF)))
  defk(rotl16(x :: i64) :: i64, do: bor(wrap64(bsl(x, 16)), band(bsr(x, 48), 0xFFFF)))
  defk(rotl17(x :: i64) :: i64, do: bor(wrap64(bsl(x, 17)), band(bsr(x, 47), 0x1FFFF)))
  defk(rotl21(x :: i64) :: i64, do: bor(wrap64(bsl(x, 21)), band(bsr(x, 43), 0x1FFFFF)))
  defk(rotl32(x :: i64) :: i64, do: bor(wrap64(bsl(x, 32)), band(bsr(x, 32), 0xFFFFFFFF)))
  defk(rotl33(x :: i64) :: i64, do: bor(wrap64(bsl(x, 33)), band(bsr(x, 31), 0x1FFFFFFFF)))

  # logical shift right (bsr is arithmetic)
  defk(shr33(x :: i64) :: i64, do: band(bsr(x, 33), 0x7FFFFFFF))
  defk(shr29(x :: i64) :: i64, do: band(bsr(x, 29), 0x7FFFFFFFF))
  defk(shr32(x :: i64) :: i64, do: band(bsr(x, 32), 0xFFFFFFFF))

  defk(xround(acc :: i64, lane :: i64) :: i64,
    do: wrap64(rotl31(wrap64(acc + lane * @xp2)) * @xp1)
  )

  defk(xmerge(h :: i64, v :: i64) :: i64, do: wrap64(bxor(h, xround(0, v)) * @xp1 + @xp4))

  defk xxh64_at(b :: [u8], off :: i64, n :: i64, seed :: i64) :: i64 do
    stop = off + n
    body = off + n - rem(n, 32)

    h =
      if n >= 32 do
        {v1, v2, v3, v4} =
          for i <- off..(body - 32)//32,
              reduce: {wrap64(seed + @xp1 + @xp2), wrap64(seed + @xp2), seed, wrap64(seed - @xp1)} do
            {v1, v2, v3, v4} ->
              {xround(v1, u64_le(b, i)), xround(v2, u64_le(b, i + 8)),
               xround(v3, u64_le(b, i + 16)), xround(v4, u64_le(b, i + 24))}
          end

        h = wrap64(rotl1(v1) + rotl7(v2) + rotl12(v3) + rotl18(v4))
        xmerge(xmerge(xmerge(xmerge(h, v1), v2), v3), v4)
      else
        wrap64(seed + @xp5)
      end

    h = wrap64(h + n)
    words = stop - rem(stop - body, 8)

    h =
      for i <- body..(words - 8)//8, reduce: h do
        h -> wrap64(rotl27(bxor(h, xround(0, u64_le(b, i)))) * @xp1 + @xp4)
      end

    tail4 = stop - words >= 4

    h =
      if tail4,
        do: wrap64(rotl23(bxor(h, wrap64(u32_le(b, words) * @xp1))) * @xp2 + @xp3),
        else: h

    p = if tail4, do: words + 4, else: words

    h =
      for i <- p..(stop - 1)//1, reduce: h do
        h -> wrap64(rotl11(bxor(h, wrap64(b[i] * @xp5))) * @xp1)
      end

    h = wrap64(bxor(h, shr33(h)) * @xp2)
    h = wrap64(bxor(h, shr29(h)) * @xp3)
    bxor(h, shr32(h))
  end

  defk(xxh64(bytes :: [u8], seed :: i64) :: i64, do: xxh64_at(bytes, 0, len(bytes), seed))

  defk xxh64_batch(blob :: [u8], offsets :: [i64], seed :: i64) :: [i64] do
    n = len(offsets) - 1
    out = alloc(i64, n)

    for k <- 0..(n - 1)//1 do
      out[k] = xxh64_at(blob, offsets[k], offsets[k + 1] - offsets[k], seed)
    end

    out
  end

  # ---------------------------------------------------------------- Murmur3 --

  @mc1 Defk.Bits.wrap64(0x87C37B91114253D5)
  @mc2 0x4CF5AD432745937F
  @mf1 Defk.Bits.wrap64(0xFF51AFD7ED558CCD)
  @mf2 Defk.Bits.wrap64(0xC4CEB9FE1A85EC53)

  defk fmix64(k :: i64) :: i64 do
    k = wrap64(bxor(k, shr33(k)) * @mf1)
    k = wrap64(bxor(k, shr33(k)) * @mf2)
    bxor(k, shr33(k))
  end

  # the little-endian integer of bytes [from, to) of b, at most 7 bytes
  defk le_bytes(b :: [u8], from :: i64, to :: i64) :: i64 do
    for i <- from..(to - 1)//1, reduce: 0 do
      k -> bor(k, bsl(b[i], 8 * (i - from)))
    end
  end

  # Murmur3 x64_128 of each key [offsets[k], offsets[k + 1]) of blob: h1 at
  # out[2k], h2 at out[2k + 1]
  defk murmur3_batch(blob :: [u8], offsets :: [i64], seed :: i64) :: [i64] do
    n = len(offsets) - 1
    out = alloc(i64, 2 * n)

    for k <- 0..(n - 1)//1 do
      off = offsets[k]
      len = offsets[k + 1] - off
      body = off + len - rem(len, 16)

      {h1, h2} =
        for i <- off..(body - 16)//16, reduce: {seed, seed} do
          {h1, h2} ->
            k1 = wrap64(rotl31(wrap64(u64_le(blob, i) * @mc1)) * @mc2)
            h1 = wrap64(rotl27(bxor(h1, k1)) + h2)
            h1 = wrap64(h1 * 5 + 0x52DCE729)
            k2 = wrap64(rotl33(wrap64(u64_le(blob, i + 8) * @mc2)) * @mc1)
            h2 = wrap64(rotl31(bxor(h2, k2)) + h1)
            {h1, wrap64(h2 * 5 + 0x38495AB5)}
        end

      tail = len - (body - off)
      k1 = if tail >= 8, do: u64_le(blob, body), else: le_bytes(blob, body, body + tail)
      k2 = if tail > 8, do: le_bytes(blob, body + 8, body + tail), else: 0
      h1 = bxor(bxor(h1, wrap64(rotl31(wrap64(k1 * @mc1)) * @mc2)), len)
      h2 = bxor(bxor(h2, wrap64(rotl33(wrap64(k2 * @mc2)) * @mc1)), len)
      h1 = wrap64(h1 + h2)
      h2 = wrap64(h2 + h1)
      h1 = fmix64(h1)
      h2 = fmix64(h2)
      h1 = wrap64(h1 + h2)
      out[2 * k] = h1
      out[2 * k + 1] = wrap64(h2 + h1)
    end

    out
  end

  defk murmur3_128(bytes :: [u8], seed :: i64) :: {i64, i64} do
    offsets = alloc(i64, 2)
    offsets[1] = len(bytes)
    out = murmur3_batch(bytes, offsets, seed)
    {out[0], out[1]}
  end

  # ---------------------------------------------------------- SipHash-2-4 --

  # SipHash-2-4 of bytes [off, off + n) of b with the key words k0, k1
  defk siphash24_at(b :: [u8], off :: i64, n :: i64, k0 :: i64, k1 :: i64) :: i64 do
    words = off + n - rem(n, 8)
    last = bor(wrap64(bsl(band(n, 255), 56)), le_bytes(b, words, off + n))

    {v0, v1, v2, v3} =
      for i <- off..words//8,
          reduce:
            {bxor(k0, 0x736F6D6570736575), bxor(k1, 0x646F72616E646F6D),
             bxor(k0, 0x6C7967656E657261), bxor(k1, 0x7465646279746573)} do
        {v0, v1, v2, v3} ->
          m = if i < words, do: u64_le(b, i), else: last
          v3 = bxor(v3, m)
          # two SipRounds
          v0 = wrap64(v0 + v1)
          v1 = bxor(rotl13(v1), v0)
          v0 = rotl32(v0)
          v2 = wrap64(v2 + v3)
          v3 = bxor(rotl16(v3), v2)
          v0 = wrap64(v0 + v3)
          v3 = bxor(rotl21(v3), v0)
          v2 = wrap64(v2 + v1)
          v1 = bxor(rotl17(v1), v2)
          v2 = rotl32(v2)
          v0 = wrap64(v0 + v1)
          v1 = bxor(rotl13(v1), v0)
          v0 = rotl32(v0)
          v2 = wrap64(v2 + v3)
          v3 = bxor(rotl16(v3), v2)
          v0 = wrap64(v0 + v3)
          v3 = bxor(rotl21(v3), v0)
          v2 = wrap64(v2 + v1)
          v1 = bxor(rotl17(v1), v2)
          v2 = rotl32(v2)
          {bxor(v0, m), v1, v2, v3}
      end

    # four finalisation SipRounds
    {v0, v1, v2, v3} =
      for _ <- 1..4, reduce: {v0, v1, bxor(v2, 0xFF), v3} do
        {v0, v1, v2, v3} ->
          v0 = wrap64(v0 + v1)
          v1 = bxor(rotl13(v1), v0)
          v0 = rotl32(v0)
          v2 = wrap64(v2 + v3)
          v3 = bxor(rotl16(v3), v2)
          v0 = wrap64(v0 + v3)
          v3 = bxor(rotl21(v3), v0)
          v2 = wrap64(v2 + v1)
          v1 = bxor(rotl17(v1), v2)
          {v0, v1, rotl32(v2), v3}
      end

    bxor(bxor(v0, v1), bxor(v2, v3))
  end

  defk(siphash24(bytes :: [u8], k0 :: i64, k1 :: i64) :: i64,
    do: siphash24_at(bytes, 0, len(bytes), k0, k1)
  )

  defk siphash24_batch(blob :: [u8], offsets :: [i64], k0 :: i64, k1 :: i64) :: [i64] do
    n = len(offsets) - 1
    out = alloc(i64, n)

    for k <- 0..(n - 1)//1 do
      out[k] = siphash24_at(blob, offsets[k], offsets[k + 1] - offsets[k], k0, k1)
    end

    out
  end

  # ---------------------------------------------------------------- CRC32C --

  # slicing-by-8 tables for the reflected Castagnoli polynomial 0x82F63B78:
  # 8 x 256 u32 little endian, table k at byte 1024 * k, computed when the
  # module compiles (Hashes.Elixir.CRC32C uses the same tables as a tuple)
  @crc_tables for v <- Hashes.CRC32CTables.flat(), into: <<>>, do: <<v::little-32>>

  defk(crc_t(k :: i64, x :: i64) :: i64, do: u32_le(@crc_tables, bsl(256 * k + band(x, 255), 2)))

  defk crc32c_at(b :: [u8], off :: i64, n :: i64) :: i64 do
    words = off + n - rem(n, 8)

    crc =
      for i <- off..(words - 8)//8, reduce: 0xFFFFFFFF do
        crc ->
          lo = bxor(crc, u32_le(b, i))
          hi = u32_le(b, i + 4)

          bxor(
            bxor(
              bxor(crc_t(7, lo), crc_t(6, bsr(lo, 8))),
              bxor(crc_t(5, bsr(lo, 16)), crc_t(4, bsr(lo, 24)))
            ),
            bxor(
              bxor(crc_t(3, hi), crc_t(2, bsr(hi, 8))),
              bxor(crc_t(1, bsr(hi, 16)), crc_t(0, bsr(hi, 24)))
            )
          )
      end

    crc =
      for i <- words..(off + n - 1)//1, reduce: crc do
        crc -> bxor(crc_t(0, bxor(crc, b[i])), bsr(crc, 8))
      end

    bxor(crc, 0xFFFFFFFF)
  end

  defk(crc32c(bytes :: [u8]) :: i64, do: crc32c_at(bytes, 0, len(bytes)))

  defk crc32c_batch(blob :: [u8], offsets :: [i64]) :: [i64] do
    n = len(offsets) - 1
    out = alloc(i64, n)

    for k <- 0..(n - 1)//1 do
      out[k] = crc32c_at(blob, offsets[k], offsets[k + 1] - offsets[k])
    end

    out
  end
end

defmodule Hashes.Data do
  import Bitwise

  # the unsigned value of a kernel's i64 bit pattern, and back
  def u64(h) do
    <<u::unsigned-64>> = <<h::signed-64>>
    u
  end

  def s64(u) do
    <<h::signed-64>> = <<u::64>>
    h
  end

  # a binary key as the two little-endian i64 words SipHash takes
  def key_words(<<k0::little-signed-64, k1::little-signed-64>>), do: {k0, k1}

  # keys -> {blob, offsets}: what the batch kernels take
  def pack(keys) do
    {offs, total} =
      Enum.map_reduce(keys, 0, fn k, o -> {<<o::signed-native-64>>, o + byte_size(k)} end)

    {IO.iodata_to_binary(keys), IO.iodata_to_binary([offs, <<total::signed-native-64>>])}
  end

  def unpack(out), do: for(<<h::signed-native-64 <- out>>, do: h)

  # the official sanity-check buffer of xxHash's xxhsum (byte i is the top
  # byte of PRIME32 * PRIME64^i mod 2^64)
  def xxh_sanity_buffer(n) do
    {bytes, _} =
      Enum.map_reduce(1..n//1, 2_654_435_761, fn _, g ->
        {g >>> 56, band(g * 11_400_714_785_074_694_797, 0xFFFFFFFFFFFFFFFF)}
      end)

    :binary.list_to_bin(bytes)
  end
end

# The xxHash, SMHasher, SipHash and CRC32C reference vectors, checked against
# a {xxh64, murmur3_128, siphash24, crc32c} implementation module. Returns
# a list of failures.
defmodule Hashes.Vectors do
  import Hashes.Data

  def failures(xxh64, murmur3_128, siphash24, crc32c) do
    buf = xxh_sanity_buffer(222)
    prime = 2_654_435_761

    xxh =
      for {n, seed, want} <- [
            {0, 0, 0xEF46DB3751D8E999},
            {0, prime, 0xAC75FDA2929B17EF},
            {1, 0, 0xE934A84ADB052768},
            {1, prime, 0x5014607643A9B4C3},
            {14, 0, 0x8282DCC4994E35C8},
            {14, prime, 0xC3BD6BF63DEB6DF0},
            {222, 0, 0xB641AE8CB691C174},
            {222, prime, 0x20CB8AB7AE10C14A}
          ],
          u64(xxh64.(binary_part(buf, 0, n), seed)) != want,
          do: {:xxh64, n, seed}

    # SMHasher's verification value for MurmurHash3_x64_128: hash the keys
    # <<0..i-1>> with seed 256 - i, hash the 256 results, take the low 32 bits
    hashes =
      for i <- 0..255, into: <<>> do
        {h1, h2} = murmur3_128.(:binary.list_to_bin(Enum.to_list(0..(i - 1)//1)), 256 - i)
        <<h1::little-64, h2::little-64>>
      end

    {h1, _} = murmur3_128.(hashes, 0)
    murmur = if Bitwise.band(h1, 0xFFFFFFFF) == 0x6384BA69, do: [], else: [{:murmur3, :smhasher}]

    # the SipHash paper (Appendix A): key 00..0f, message 00..0e; and the
    # empty message from the reference vectors.h
    {k0, k1} = key_words(:binary.list_to_bin(Enum.to_list(0..15)))

    sip =
      for {msg, want} <- [
            {:binary.list_to_bin(Enum.to_list(0..14)), 0xA129CA6149BE45E5},
            {<<>>, 0x726FDB47DD0E0E31}
          ],
          u64(siphash24.(msg, k0, k1)) != want,
          do: {:siphash24, byte_size(msg)}

    crc = if crc32c.("123456789") == 0xE3069283, do: [], else: [{:crc32c, "123456789"}]
    xxh ++ murmur ++ sip ++ crc
  end
end

alias Hashes.Kernels, as: K
alias Hashes.Data, as: D
import Bitwise

if elixir_mode? do
  # MIX_ENV=test mix run examples/hashes.exs: Elixir mode is compiled only
  # in a Mix project's :dev/:test, never in a Mix.install script, so this
  # run checks native === Elixir mode on random inputs and the vectors,
  # then stops (the anchors are not deps of defk).
  ex = fn name -> fn args -> K.__defk_elixir__(name, args) end end
  :rand.seed(:exsss, {11, 12, 13})

  inputs = for n <- Enum.to_list(0..70) ++ [127, 128, 129, 1000], do: :rand.bytes(n)

  bad =
    for bin <- inputs,
        seed = :rand.uniform(1 <<< 62) - (1 <<< 61),
        {k0, k1} = D.key_words(:rand.bytes(16)),
        {name, args} <- [
          {:xxh64, [bin, seed]},
          {:murmur3_128, [bin, seed]},
          {:siphash24, [bin, k0, k1]},
          {:crc32c, [bin]}
        ],
        apply(K, name, args) !== ex.(name).(args),
        do: {name, byte_size(bin)}

  {blob, offsets} = D.pack(Enum.take(inputs, 40))

  bad =
    bad ++
      for {name, args} <- [
            {:xxh64_batch, [blob, offsets, 7]},
            {:murmur3_batch, [blob, offsets, 7]},
            {:siphash24_batch, [blob, offsets, 1, 2]},
            {:crc32c_batch, [blob, offsets]}
          ],
          apply(K, name, args) !== ex.(name).(args),
          do: {name, :batch}

  vec =
    Defk.ElixirMode.with_mode(:elixir, fn ->
      Hashes.Vectors.failures(&K.xxh64/2, &K.murmur3_128/2, &K.siphash24/3, &K.crc32c/1)
    end)

  IO.puts(
    "Elixir mode: #{length(inputs) * 4 + 4} calls compared, mismatches #{inspect(bad)}; vectors in Elixir mode: #{inspect(vec)}"
  )

  System.halt(if bad == [] and vec == [], do: 0, else: 1)
end

# ------------------------------------------------- Elixir implementations --

# xxHash64 written for the BEAM: little-endian words matched straight out of
# the binary, every step one bignum op and one mask, all helpers inlined.
# (The xxhash package reads big-endian then byte-swaps through a new binary,
# and its xxh64/2 takes String.length/1 as the length; see the header.)
defmodule Hashes.Elixir.XXH64 do
  import Bitwise

  @m 0xFFFFFFFFFFFFFFFF
  @p1 0x9E3779B185EBCA87
  @p2 0xC2B2AE3D27D4EB4F
  @p3 0x165667B19E3779F9
  @p4 0x85EBCA77C2B2AE63
  @p5 0x27D4EB2F165667C5

  @compile {:inline, rotl: 2, round: 2, merge: 2}

  def hash(bin, seed) do
    seed = band(seed, @m)
    n = byte_size(bin)

    {h, rest} =
      if n >= 32 do
        stripes(bin, band(seed + @p1 + @p2, @m), band(seed + @p2, @m), seed, band(seed - @p1, @m))
      else
        {band(seed + @p5, @m), bin}
      end

    h = tail(band(h + n, @m), rest)
    h = band(bxor(h, h >>> 33) * @p2, @m)
    h = band(bxor(h, h >>> 29) * @p3, @m)
    bxor(h, h >>> 32)
  end

  defp stripes(
         <<a::little-64, b::little-64, c::little-64, d::little-64, rest::binary>>,
         v1,
         v2,
         v3,
         v4
       ),
       do: stripes(rest, round(v1, a), round(v2, b), round(v3, c), round(v4, d))

  defp stripes(rest, v1, v2, v3, v4) do
    h = band(rotl(v1, 1) + rotl(v2, 7) + rotl(v3, 12) + rotl(v4, 18), @m)
    {h |> merge(v1) |> merge(v2) |> merge(v3) |> merge(v4), rest}
  end

  defp tail(h, <<k::little-64, rest::binary>>),
    do: tail(band(rotl(bxor(h, round(0, k)), 27) * @p1 + @p4, @m), rest)

  defp tail(h, <<k::little-32, rest::binary>>),
    do: tail(band(rotl(bxor(h, band(k * @p1, @m)), 23) * @p2 + @p3, @m), rest)

  defp tail(h, <<k, rest::binary>>),
    do: tail(band(rotl(bxor(h, band(k * @p5, @m)), 11) * @p1, @m), rest)

  defp tail(h, <<>>), do: h

  defp rotl(x, r), do: bor(band(x <<< r, @m), x >>> (64 - r))
  defp round(acc, lane), do: band(rotl(band(acc + lane * @p2, @m), 31) * @p1, @m)
  defp merge(h, v), do: band(bxor(h, round(0, v)) * @p1 + @p4, @m)
end

# SipHash-2-4 with the state in four variables (the siphash fallback keeps
# it in a record and updates it field by field)
defmodule Hashes.Elixir.SipHash do
  import Bitwise

  @m 0xFFFFFFFFFFFFFFFF

  @compile {:inline, rotl: 2, sipround: 4}

  def hash(<<k0::little-64, k1::little-64>>, bin) do
    blocks(
      bin,
      byte_size(bin),
      bxor(k0, 0x736F6D6570736575),
      bxor(k1, 0x646F72616E646F6D),
      bxor(k0, 0x6C7967656E657261),
      bxor(k1, 0x7465646279746573)
    )
  end

  defp blocks(<<m::little-64, rest::binary>>, n, v0, v1, v2, v3) do
    {v0, v1, v2, v3} = sipround(v0, v1, v2, bxor(v3, m))
    {v0, v1, v2, v3} = sipround(v0, v1, v2, v3)
    blocks(rest, n, bxor(v0, m), v1, v2, v3)
  end

  defp blocks(tail, n, v0, v1, v2, v3) do
    m = bor(band(n, 255) <<< 56, :binary.decode_unsigned(tail, :little))
    {v0, v1, v2, v3} = sipround(v0, v1, v2, bxor(v3, m))
    {v0, v1, v2, v3} = sipround(v0, v1, v2, v3)
    {v0, v1, v2, v3} = sipround(bxor(v0, m), v1, bxor(v2, 0xFF), v3)
    {v0, v1, v2, v3} = sipround(v0, v1, v2, v3)
    {v0, v1, v2, v3} = sipround(v0, v1, v2, v3)
    {v0, v1, v2, v3} = sipround(v0, v1, v2, v3)
    bxor(bxor(v0, v1), bxor(v2, v3))
  end

  defp sipround(v0, v1, v2, v3) do
    v0 = band(v0 + v1, @m)
    v1 = bxor(rotl(v1, 13), v0)
    v0 = rotl(v0, 32)
    v2 = band(v2 + v3, @m)
    v3 = bxor(rotl(v3, 16), v2)
    v0 = band(v0 + v3, @m)
    v3 = bxor(rotl(v3, 21), v0)
    v2 = band(v2 + v1, @m)
    v1 = bxor(rotl(v1, 17), v2)
    {v0, v1, rotl(v2, 32), v3}
  end

  defp rotl(x, r), do: bor(band(x <<< r, @m), x >>> (64 - r))
end

# CRC32C, table-driven: slicing-by-8 (eight table lookups per 8 bytes, the
# same algorithm as the kernel) and one byte at a time, from a literal tuple
defmodule Hashes.Elixir.CRC32C do
  import Bitwise

  @t List.to_tuple(Hashes.CRC32CTables.flat())

  def hash(bin), do: bxor(s8(bin, 0xFFFFFFFF), 0xFFFFFFFF)
  def bytewise(bin), do: bxor(b1(bin, 0xFFFFFFFF), 0xFFFFFFFF)

  defp s8(<<lo::little-32, hi::little-32, rest::binary>>, crc) do
    lo = bxor(lo, crc)

    s8(
      rest,
      bxor(
        bxor(
          bxor(elem(@t, 1792 + band(lo, 255)), elem(@t, 1536 + band(lo >>> 8, 255))),
          bxor(elem(@t, 1280 + band(lo >>> 16, 255)), elem(@t, 1024 + (lo >>> 24)))
        ),
        bxor(
          bxor(elem(@t, 768 + band(hi, 255)), elem(@t, 512 + band(hi >>> 8, 255))),
          bxor(elem(@t, 256 + band(hi >>> 16, 255)), elem(@t, hi >>> 24))
        )
      )
    )
  end

  defp s8(rest, crc), do: b1(rest, crc)

  defp b1(<<b, rest::binary>>, crc),
    do: b1(rest, bxor(elem(@t, band(bxor(crc, b), 255)), crc >>> 8))

  defp b1(<<>>, crc), do: crc
end

# siphash 3.2.0's own Elixir fallback, compiled from the package source
# under another name: the package replaces SipHash.Digest.hash/5 with its C
# NIF when it loads, so the fallback and the NIF cannot share a module.
digest_src =
  Path.join(Mix.install_project_dir(), "deps/siphash/lib/siphash/digest.ex")
  |> File.read!()
  |> String.replace("defmodule SipHash.Digest", "defmodule SipHashFallback.Digest")
  |> String.replace("@on_load :init", "")

{_, _diagnostics} = Code.with_diagnostics(fn -> Code.compile_string(digest_src) end)
true = SipHash.nif_loaded?()

# ---------------------------------------------------------------- agreement --

sip_key = "0123456789ABCDEF"
{sk0, sk1} = D.key_words(sip_key)

impl = %{
  xxh_pkg: fn bin, seed -> XXHash.xxh64(bin, byte_size(bin), seed) end,
  xxh_ex: &Hashes.Elixir.XXH64.hash/2,
  xxh_k: fn bin, seed -> D.u64(K.xxh64(bin, D.s64(seed))) end,
  mur_pkg: &Murmur.hash_x64_128/2,
  mur_k: fn bin, seed ->
    {h1, h2} = K.murmur3_128(bin, seed)
    Bitwise.bor(Bitwise.bsl(D.u64(h2), 64), D.u64(h1))
  end,
  sip_nif: fn key, bin -> SipHash.hash!(key, bin) end,
  sip_fallback: fn key, bin -> SipHashFallback.Digest.hash(key, bin, 2, 4) end,
  sip_ex: &Hashes.Elixir.SipHash.hash/2,
  sip_k: fn key, bin ->
    {k0, k1} = D.key_words(key)
    D.u64(K.siphash24(bin, k0, k1))
  end,
  crc_nif: &:crc32cer.nif/1,
  crc_ex: &Hashes.Elixir.CRC32C.hash/1,
  crc_k: &K.crc32c/1
}

vector_failures =
  Hashes.Vectors.failures(&K.xxh64/2, &K.murmur3_128/2, &K.siphash24/3, &K.crc32c/1) ++
    Enum.map(
      Hashes.Vectors.failures(
        fn b, s -> D.s64(impl.xxh_ex.(b, s)) end,
        fn b, s ->
          h = Murmur.hash_x64_128(b, s)
          {D.s64(Bitwise.band(h, 0xFFFFFFFFFFFFFFFF)), D.s64(Bitwise.bsr(h, 64))}
        end,
        fn b, k0, k1 -> D.s64(impl.sip_ex.(<<k0::little-64, k1::little-64>>, b)) end,
        impl.crc_ex
      ),
      &{:elixir, &1}
    )

:rand.seed(:exsss, {1, 2, 3})

random_inputs =
  for n <- Enum.to_list(0..200) ++ Enum.map(1..100, fn _ -> :rand.uniform(5000) end),
      do: :rand.bytes(n)

mismatches =
  for bin <- random_inputs,
      seed = :rand.uniform(1 <<< 32) - 1,
      key = :rand.bytes(16),
      {label, got, want} <- [
        {:xxh64_pkg, impl.xxh_k.(bin, seed), impl.xxh_pkg.(bin, seed)},
        {:xxh64_ex, impl.xxh_k.(bin, seed), impl.xxh_ex.(bin, seed)},
        {:murmur, impl.mur_k.(bin, seed), impl.mur_pkg.(bin, seed)},
        {:sip_nif, impl.sip_k.(key, bin), impl.sip_nif.(key, bin)},
        {:sip_fallback, impl.sip_k.(key, bin), impl.sip_fallback.(key, bin)},
        {:sip_ex, impl.sip_k.(key, bin), impl.sip_ex.(key, bin)},
        {:crc_nif, impl.crc_k.(bin), impl.crc_nif.(bin)},
        {:crc_ex, impl.crc_k.(bin), impl.crc_ex.(bin)},
        {:crc_ex1, impl.crc_k.(bin), Hashes.Elixir.CRC32C.bytewise(bin)}
      ],
      bin != <<>> or label != :xxh64_pkg,
      got != want,
      do: {label, byte_size(bin)}

# the batch kernels against the single-message ones
{blob, offsets} = D.pack(random_inputs)

batch_ok =
  D.unpack(K.xxh64_batch(blob, offsets, 99)) == Enum.map(random_inputs, &K.xxh64(&1, 99)) and
    D.unpack(K.murmur3_batch(blob, offsets, 99)) ==
      Enum.flat_map(random_inputs, &Tuple.to_list(K.murmur3_128(&1, 99))) and
    D.unpack(K.siphash24_batch(blob, offsets, sk0, sk1)) ==
      Enum.map(random_inputs, &K.siphash24(&1, sk0, sk1)) and
    D.unpack(K.crc32c_batch(blob, offsets)) == Enum.map(random_inputs, &K.crc32c/1)

# the xxhash package's two documented entry points diverge from the spec:
# xxh64/2 hashes String.length/1 (graphemes) as the length, and the empty
# input returns the seed-0 hash whatever the seed
xxh_pkg_len_bug =
  Enum.count(random_inputs, fn bin ->
    byte_size(bin) > 0 and
      try do
        XXHash.xxh64(bin, 5) != impl.xxh_ex.(bin, 5)
      rescue
        _ -> true
      end
  end)

xxh_pkg_empty_bug = XXHash.xxh64(<<>>, 0, 5) != impl.xxh_ex.(<<>>, 5)

agree = vector_failures == [] and mismatches == [] and batch_ok

IO.puts(
  "agreement: reference vectors #{inspect(vector_failures)}, #{length(random_inputs)} random inputs x 9 comparisons mismatches #{inspect(Enum.take(mismatches, 5))}, batch kernels #{batch_ok}"
)

IO.puts(
  "xxhash 0.3.1 off-spec: xxh64/2 wrong or raising on #{xxh_pkg_len_bug} of #{length(random_inputs) - 1} random binaries (String.length), empty input with seed 5 #{if xxh_pkg_empty_bug, do: "wrong", else: "ok"}"
)

unless agree, do: raise("agreement failed")

# ------------------------------------------------------------- measurement --

# 1k random 32-byte keys (a list, as a caller has them) and one 4 MB message
:rand.seed(:exsss, {4, 5, 6})
keys = for _ <- 1..1000, do: :rand.bytes(32)
msg = :rand.bytes(4 * 1024 * 1024)
mid = binary_part(msg, 0, 65_536)
seed = 0x5EED

best = fn fun ->
  fun.()

  1..5
  |> Enum.map(fn _ ->
    :erlang.garbage_collect()
    elem(:timer.tc(fun), 0)
  end)
  |> Enum.min()
end

# the batch on the kernel side pays for packing the list and decoding the
# result back to a list of integers
batch = fn kernel ->
  fn ->
    {blob, offsets} = D.pack(keys)
    D.unpack(kernel.(blob, offsets))
  end
end

xxh_batch_k = batch.(&K.xxh64_batch(&1, &2, seed))
mur_batch_k = batch.(&K.murmur3_batch(&1, &2, seed))
sip_batch_k = batch.(&K.siphash24_batch(&1, &2, sk0, sk1))
crc_batch_k = batch.(&K.crc32c_batch/2)

rows = [
  {"xxHash64", "xxhash 0.3.1 xxh64/3", fn b -> impl.xxh_pkg.(b, seed) end},
  {"xxHash64", "Elixir rewrite", fn b -> impl.xxh_ex.(b, seed) end},
  {"xxHash64", "defk", fn b -> K.xxh64(b, seed) end},
  {"xxHash64", "defk, a call per key", fn b -> K.xxh64(b, seed) end},
  {"Murmur3", "murmur 2.0.2", fn b -> Murmur.hash_x64_128(b, seed) end},
  {"Murmur3", "defk", fn b -> K.murmur3_128(b, seed) end},
  {"Murmur3", "defk, a call per key", fn b -> K.murmur3_128(b, seed) end},
  {"SipHash", "siphash 3.2.0 fallback", fn b -> impl.sip_fallback.(sip_key, b) end},
  {"SipHash", "Elixir rewrite", fn b -> impl.sip_ex.(sip_key, b) end},
  {"SipHash", "defk", fn b -> K.siphash24(b, sk0, sk1) end},
  {"SipHash", "defk, a call per key", fn b -> K.siphash24(b, sk0, sk1) end},
  {"SipHash", "siphash 3.2.0 C NIF", fn b -> impl.sip_nif.(sip_key, b) end},
  {"CRC32C", "Elixir byte at a time", &Hashes.Elixir.CRC32C.bytewise/1},
  {"CRC32C", "Elixir slicing-by-8", impl.crc_ex},
  {"CRC32C", "defk", &K.crc32c/1},
  {"CRC32C", "defk, a call per key", &K.crc32c/1},
  {"CRC32C", "crc32cer 1.1.4 NIF", impl.crc_nif},
  {"BIF", ":erlang.phash2", &:erlang.phash2/1},
  {"BIF", ":erlang.crc32", &:erlang.crc32/1}
]

batch_kernels = %{
  "xxHash64" => xxh_batch_k,
  "Murmur3" => mur_batch_k,
  "SipHash" => sip_batch_k,
  "CRC32C" => crc_batch_k
}

ms = fn us -> Float.round(us / 1000, 3) end

IO.puts("\nbest of 5, ms     1k x 32 B keys   64 KB      4 MB     (4 MB GB/s)")

for {hash, label, f} <- rows do
  kb =
    if label == "defk",
      do: best.(batch_kernels[hash]),
      else: best.(fn -> Enum.map(keys, f) end)

  m = best.(fn -> f.(mid) end)
  big = best.(fn -> f.(msg) end)

  IO.puts(
    "  #{String.pad_trailing("#{hash} #{label}", 32)} #{String.pad_trailing(to_string(ms.(kb)), 9)} " <>
      "#{String.pad_trailing(to_string(ms.(m)), 10)} #{String.pad_trailing(to_string(ms.(big)), 9)}" <>
      "#{Float.round(4 * 1024 * 1024 / 1000 / max(big, 1), 2)}"
  )
end

pack_ms = ms.(best.(fn -> D.pack(keys) end))

IO.puts(
  "  (the defk rows' 1k column is one batch call, including #{pack_ms} ms to pack the key list and the decode of the result)\n"
)

# ----------------------------------------------------------------- reports --

# sweep rows per hash: the 1k-key batch (Elixir maps over the list, the
# kernel takes it packed), a 64 KB message and the 4 MB message
sweep = fn elixir_one, elixir_batch, defk_one, defk_batch ->
  [
    {"1k x 32 B", elixir_batch, defk_batch},
    {"64 KB", fn -> elixir_one.(mid) end, fn -> defk_one.(mid) end},
    {"4 MB", fn -> elixir_one.(msg) end, fn -> defk_one.(msg) end}
  ]
end

xxh_e = &Hashes.Elixir.XXH64.hash(&1, seed)
xxh_d = &K.xxh64(&1, seed)

r_xxh =
  Defk.Bench.report(
    name: "hashes_xxh64",
    expected: :good,
    baseline: :optimized,
    realistic_size: "one 4 MB message",
    elixir: fn -> xxh_e.(msg) end,
    defk: fn -> xxh_d.(msg) end,
    check: fn -> agree and D.s64(xxh_e.(msg)) == xxh_d.(msg) end,
    sweep: sweep.(xxh_e, fn -> Enum.map(keys, xxh_e) end, xxh_d, xxh_batch_k),
    reason:
      "64-bit multiplies and rotates are bignum work in Elixir; the kernel does them in registers at 10 GB/s"
  )

mur_e = &Murmur.hash_x64_128(&1, seed)
mur_d = &K.murmur3_128(&1, seed)

r_mur =
  Defk.Bench.report(
    name: "hashes_murmur3",
    expected: :good,
    baseline: :optimized,
    realistic_size: "one 4 MB message",
    elixir: fn -> mur_e.(msg) end,
    defk: fn -> mur_d.(msg) end,
    check: fn -> agree and impl.mur_k.(msg, seed) == mur_e.(msg) end,
    sweep: sweep.(mur_e, fn -> Enum.map(keys, mur_e) end, mur_d, mur_batch_k),
    reason:
      "the same bignum-versus-register gap as xxHash64; murmur is already a well-written pure version"
  )

sip_e = &Hashes.Elixir.SipHash.hash(sip_key, &1)
sip_d = &K.siphash24(&1, sk0, sk1)
sip_n = &SipHash.hash!(sip_key, &1)

r_sip =
  Defk.Bench.report(
    name: "hashes_siphash24",
    expected: :good,
    baseline: :optimized,
    realistic_size: "1k 32-byte keys",
    elixir: fn -> Enum.map(keys, sip_e) end,
    defk: sip_batch_k,
    native: {fn -> Enum.map(keys, sip_n) end, "siphash 3.2.0 C NIF, a call per key"},
    check: fn -> agree and Enum.map(keys, sip_e) == Enum.map(sip_batch_k.(), &D.u64/1) end,
    sweep: sweep.(sip_e, fn -> Enum.map(keys, sip_e) end, sip_d, sip_batch_k),
    reason:
      "bignum SipRounds in Elixir; the kernel batch is level with siphash's C NIF, so the C buys nothing"
  )

crc_e = impl.crc_ex
crc_d = &K.crc32c/1

r_crc =
  Defk.Bench.report(
    name: "hashes_crc32c",
    expected: :marginal,
    baseline: :optimized,
    realistic_size: "one 4 MB message",
    elixir: fn -> crc_e.(msg) end,
    defk: fn -> crc_d.(msg) end,
    native:
      {fn -> :crc32cer.nif(msg) end, "crc32cer 1.1.4 (Google crc32c, ARM64 CRC32C instructions)"},
    check: fn -> agree and crc_e.(msg) == crc_d.(msg) and crc_d.(msg) == :crc32cer.nif(msg) end,
    sweep: sweep.(crc_e, fn -> Enum.map(keys, crc_e) end, crc_d, crc_batch_k),
    reason:
      "CRC32C stays in small integers, so Elixir slicing-by-8 is within 1.7x; crc32cer's hardware CRC is 14x faster than the kernel"
  )

# run_all.exs reads only the first DEFK_RESULT line (xxh64); the other three
# claims are checked here
for r <- [r_xxh, r_mur, r_sip, r_crc], not r.correct or r.verdict != r.expected do
  IO.puts("#{r.example}: correct #{r.correct}, verdict #{r.verdict}, expected #{r.expected}")
  System.halt(1)
end
