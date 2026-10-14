# gorilla_encode: Gorilla compression of a {timestamp, float} series, as
# gorilla_stream encodes it, against its C++ NIF
#
# The job: a time-series store or metrics pipeline compresses each series'
# points with Facebook's Gorilla scheme: timestamps as deltas of deltas in
# variable-width buckets, values as the XOR with the previous value's bits,
# written as only the meaningful bits. gorilla_stream 3.0.3 is the Hex
# package: Encoder.encode_elixir/2 is its pure-Elixir path, and encode/2
# prefers NIF.nif_gorilla_encode/2 (C++ through fine, on a dirty CPU
# scheduler) whenever it loads, because the Elixir one is slow.
#
# Why people reach for a NIF here: a sequential bit-level loop over every
# point, with 64-bit float patterns (bignums on the BEAM for any value
# >= 2.0) and leading/trailing zero counts.
# Expected verdict: good (close to the 2x bar at the realistic size, see
# the results).
#
#   elixir examples/gorilla_encode.exs                    # agreement + reports
#   GORILLA_VARIANTS=1 elixir examples/gorilla_encode.exs # also every Elixir variant
#
# Realistic size (declared before any numbers): 100-point blocks. Gorilla
# compresses a series in blocks (two hours per block in the paper, 120
# samples per chunk in Prometheus' XOR chunks), so a store encodes many
# small blocks, one call each; the timed job is 1,000 series of 100 points,
# one encode call per series. The other size is one 1M-point series in one
# call. The sweep varies the block size from 100 to 1M points, each size
# timed over ~1M points (one block of that size encoded 1M / size times).
#
# DEFK_RESULT lines (mix defk.examples reads the first; the script checks both):
#   1. gorilla_encode     100-point blocks, the workload verdict, with the
#                         NIF as `native`, the sweep and responsiveness
#                         (1M points, one call per side)
#   2. gorilla_encode_1m  one 1M-point series
#
# What is reproduced, from gorilla_stream's source (encoder.ex,
# encoder/{delta_encoding,value_compression,bit_packing,metadata}.ex and
# c_src/gorilla_nif.cpp), byte for byte:
#   - the timestamp stream: the first timestamp in 64 bits, the first delta
#     and then each delta of deltas in 1, 9, 12, 16 or 36 bits. The buckets
#     are -63..64, -255..256 and -2047..2048, one more than the signed
#     field holds: the Elixir writes 64 as `64::7-signed`, which keeps the
#     low bits (-64), and so do the NIF and the kernel (masked); a delta of
#     deltas past 32 bits keeps its low 32;
#   - the value stream: the first value's bits, then '0' for a repeat,
#     '10' + the bits of the previous window, or '11' + 5 bits of leading
#     zeros (capped at 31) + 6 bits of length - 1 + the bits, the length
#     from the uncapped count (a quirk kept as written);
#   - the inner header (count, first timestamp, first value, first delta,
#     both stream lengths), the streams padded to a byte, and the 80-byte
#     outer header with the CRC32 of the inner part (:erlang.crc32/1), the
#     compression ratio and a creation time in seconds. The creation time
#     differs between two encodes, so agreement compares with it zeroed.
#   - integer values are encoded as floats, as both gorilla_stream paths do.
# The empty list is the one disagreement in gorilla_stream itself:
# encode_elixir returns an 80-byte header with count 0, the NIF <<>>; the
# Elixir and defk encoders here follow encode_elixir. The VictoriaMetrics
# options (scaled integers, counters) and Chimp are not reproduced.
#
# The split: the kernel builds both bit streams, timestamps then values,
# into one bitstring accumulator, pads it to a byte and returns
# it with the two stream lengths. Each delta-of-delta bucket is one clause
# of a helper that takes the accumulator. The caller
# has a list of {ts, float}, so packing it is part of defk's cost: one pass
# writes each point as a native i64 and a native f64 into one binary (the
# kernel reads the f64's 8 bytes as an i64: its bits), four points per
# append. Headers and the CRC32 are Elixir (Gorilla.Frame), shared by the
# Elixir and defk sides.
#
# Kernel notes (Defk.Report): no bounds check left in either loop. A 64-bit
# segment value must be an i64, so the XOR's bits are shifted as
# a u64 (`bsr(band(x, 0xFFFFFFFFFFFFFFFF), s)`, a logical shift) and the one
# case that keeps all 64 bits is written as `x::64-signed`. The kernel costs
# ~5-6 ns per point plus ~0.12 us per call for a bitstring result (a scalar
# kernel's call is ~0.02 us); packing costs ~6 ns per point. At 100-point
# blocks one encode is ~2.1 us: packing 0.64, the kernel 0.68, the headers
# and CRC32 0.27 (the same on the Elixir side), the rest glue.
#
# Agreement, checked on every run (a mismatch raises): encode_elixir, every
# Elixir variant below, the NIF and defk are byte-identical (creation time
# zeroed) on 53 series: realistic ones of 2 to 10k points (3 seeds each)
# and 1M points; every delta-of-delta bucket and its edges; first deltas
# and deltas of deltas past 32 bits; negative and decreasing timestamps;
# sign changes, -0.0, 1.0e308, 5.0e-324, random magnitudes (XORs with all
# 64 bits meaningful), steps of one ulp (32+ leading zeros), constant and
# integer series; one and two points. The kernel agrees with its Elixir
# mode (`elixir_mode: true`) on 36 packed series, including a delta that
# overflows i64 (ArithmeticError in both).
#
# Limits: a delta or delta of deltas outside i64 raises ArithmeticError in
# the kernel; gorilla_stream's Elixir computes it as a bignum and keeps the
# low bits, its NIF overflows int64_t. A timestamp outside i64 is cut to its
# low 64 bits by the packing (`::signed-64` in bit syntax), where the NIF
# raises. Neither occurs with real timestamps.
#
# Elixir baseline: optimised. encode_elixir is the first baseline. Best of
# 7 interleaved rounds (GORILLA_VARIANTS=1), under load, ms:
#
#                                                     1,000 x 100   1M points
#   encode_elixir (the anchor: separate lists,          23.6-23.9    330-353
#     BitWriter iodata for timestamps, an iolist of
#     pieces for values, bit-at-a-time zero counts)
#   one pass, 64-bit patterns (bignums), bit-loop       15.1-15.6    153-156
#     zero counts, appended bitstrings
#   one pass, 32-bit halves, table zero counts,         16.9-19.3    ~930
#     iolist of pieces (:erlang.list_to_bitstring/1)
#   two passes (timestamps, then values), halves,       4.7-4.8      40.7-42.6
#     tables, appended bitstrings
#   Gorilla.Elixir: one pass, halves, tables, both      4.8-4.9      41.6-43.4  <- baseline
#     streams appended to their own bitstrings
#   same, pending bits kept in a small integer (word    4.6-5.0      40.3-40.8
#     buffer, an append only every ~59 bits)
#   same, the list first packed to a binary as defk's   5.3-5.6      118-122
#     is, then <<t::64, h::32, l::32>> matched off it
#   NIF.nif_gorilla_encode                              6.0-6.2      32.4-32.9
#   defk                                                2.1-2.4      12.8-13.4
#
# The big steps are the float's bits as two 32-bit halves (small integers
# instead of a bignum XOR; zero counts from 256-entry tuples) and appending
# each stream to one bitstring instead of building iolists. The last three
# Elixir rows are within the noise of each other (<= 5%), and the verdict
# does not change with either of them as the baseline. Packing the list
# first does not help Elixir: the pack costs what matching saves, and at
# 1M points the 16 MB binary's growth triggers GCs. Not tried: encoding
# the two streams in two processes (the list is copied to each), and
# encoding many series in parallel (it scales both sides alike, and the
# kernel tasks stay on 2-3 schedulers).
#
# Results (PROVISIONAL: taken while two other agents' benchmarks loaded the
# machine; a quiet-machine run was recorded separately). M-series Mac, OTP 29,
# Elixir 1.20:
#   100-point blocks (verdict), 1,000 series: Elixir 4.6-5.1 ms, defk
#     2.1-2.45 ms: 1.96-2.38x, good in 8 of 8 runs under the 1.9x tie band (one 1.96x
#     read marginal before it, with best of 7; the script now takes best of 15). Close to the bar:
#     the headers and CRC32 (0.27 us per block) are the same on both sides,
#     and packing the list is a third of defk's time. The NIF 6.0-7.2 ms:
#     defk 2.75-2.9x faster (each NIF call hops to a dirty scheduler).
#   1M points, one call: Elixir 41.6-44.5 ms, defk 12.6-14.6 ms: 3.07-3.42x;
#     the NIF 31.5-33.3 ms: defk 2.3-2.5x faster. About half of defk's
#     time is packing the list, ~6 ms the kernel.
#   Sweep (block size 100, 630, 4k, 25k, 160k, 1M points, ~1M points
#     each): 2.25-2.5x, 3.9-4.1x, 4.5-4.7x, 3.5-3.8x, 3.1-3.4x, 2.7-3.3x;
#     crossover (first size >= 2x) at 100, the smallest. The middle sizes
#     gain most: below them the per-call costs weigh, above them the
#     packed binary and the output grow by reallocation (not profiled).
#   On the benchmark process's heap instead of :persistent_term, the
#     1M-point list doubled defk's time (~28-44 ms) and moved Elixir's
#     much less: every GC that the packed binary's growth triggers copies
#     the list (see the measurement section).
#
# Responsiveness (1 ms ticker, one scheduler, 1M points, one call per
# side): Elixir max 2.0-2.5 ms, defk 2.2-2.9 ms (the kernel yields; the
# packing is Elixir), the NIF 2.0-2.15 ms (it runs on a dirty scheduler).
# All three sit at the loaded machine's ticker floor (~2 ms); one run gives
# only 15-45 ticks, so p99 equals max.
#
# The NIF: gorilla_stream ships precompiled NIFs for NIF versions 2.16 and
# 2.17 only, so on OTP 29 (NIF 2.18) Mix.install builds it from source with
# elixir_make, the system clang++ and -O2 (no setup needed, the first
# install compiles; later runs hit the Mix.install cache). It parses the
# list into two std::vectors, writes bytes through a 64-bit bit buffer, and
# runs as a dirty CPU job, so each call pays the hop to a dirty scheduler.

Mix.install([
  {:defk, path: Path.expand("..", __DIR__)},
  {:gorilla_stream, "3.0.3"}
])

defmodule Gorilla.Kernels do
  use Defk, elixir_mode: true

  # One delta of deltas (also the first delta) in gorilla_stream's buckets.
  # The ranges are -63..64 for 7 bits (and so on), one more than a signed
  # 7-bit field holds: gorilla_stream writes `dod::7-signed`, which keeps the
  # low 7 bits, so 64 is written as -64. The masks write the same bits.
  defk(dod_bits(acc :: bitstring, dod :: i64) :: bitstring)
  defk(dod_bits(acc, 0), do: <<acc::bitstring, 0::1>>)

  defk(dod_bits(acc, dod) when dod >= -63 and dod <= 64,
    do: <<acc::bitstring, 0b10::2, band(dod, 0x7F)::7>>
  )

  defk(dod_bits(acc, dod) when dod >= -255 and dod <= 256,
    do: <<acc::bitstring, 0b110::3, band(dod, 0x1FF)::9>>
  )

  defk(dod_bits(acc, dod) when dod >= -2047 and dod <= 2048,
    do: <<acc::bitstring, 0b1110::4, band(dod, 0xFFF)::12>>
  )

  defk(dod_bits(acc, dod), do: <<acc::bitstring, 0b1111::4, band(dod, 0xFFFFFFFF)::32>>)

  # The k meaningful bits of the XOR x from bit s up (bits above s + k are
  # zero by construction). x is the u64 pattern in an i64: a pattern with
  # the top bit set is negative, so it is shifted as a u64 (logical shift),
  # and the one case that keeps all 64 bits is written as a signed segment
  # (a 64-bit segment value must be an i64).
  defk xor_bits(acc :: bitstring, x :: i64, s :: i64, k :: i64) :: bitstring do
    if k == 64 do
      <<acc::bitstring, x::64-signed>>
    else
      <<acc::bitstring, bsr(band(x, 0xFFFFFFFFFFFFFFFF), s)::size(k)>>
    end
  end

  # Both bit streams of one series, in one bitstring: the timestamp stream
  # (first timestamp, first delta, then a delta of deltas per point), then
  # the value stream (first value's bits, then gorilla_stream's XOR
  # encoding), then zero bits to a whole byte. p holds the points
  # interleaved: p[2i] is timestamp i, p[2i + 1] the bits of value i (the
  # f64 read as an i64). Returns {bits, ts_bit_len, val_bit_len}.
  defk streams(p :: [i64]) :: {bitstring, i64, i64} do
    n = div(length(p), 2)
    t0 = p[0]
    acc = <<>>
    acc = <<acc::bitstring, t0::64-signed>>

    acc =
      if n > 1 do
        d1 = p[2] - t0
        acc = dod_bits(acc, d1)

        {acc, _, _} =
          for i <- 2..(n - 1)//1, reduce: {acc, d1, p[2]} do
            {acc, prev_d, prev_t} ->
              t = p[2 * i]
              d = t - prev_t
              {dod_bits(acc, d - prev_d), d, t}
          end

        acc
      else
        acc
      end

    ts_len = bit_size(acc)
    v0 = p[1]
    acc = <<acc::bitstring, v0::64-signed>>

    {acc, _, _, _} =
      for i <- 1..(n - 1)//1, reduce: {acc, v0, 0, 0} do
        {acc, prev, plz, ptz} ->
          v = p[2 * i + 1]
          x = bxor(v, prev)

          if x == 0 do
            {<<acc::bitstring, 0::1>>, v, plz, ptz}
          else
            lz = clz(x)
            tz = ctz(x)

            if lz >= plz and tz >= ptz do
              # the previous window holds the meaningful bits
              acc = <<acc::bitstring, 0b10::2>>
              {xor_bits(acc, x, ptz, 64 - plz - ptz), v, plz, ptz}
            else
              # a new window; its leading-zero count is stored capped at 31
              # (5 bits) while the uncapped count sizes the bits, as
              # gorilla_stream does
              k = 64 - lz - tz
              acc = <<acc::bitstring, 0b11::2, min(lz, 31)::5, k - 1::6>>
              {xor_bits(acc, x, tz, k), v, min(lz, 31), tz}
            end
          end
      end

    val_len = bit_size(acc) - ts_len
    pad = rem(8 - rem(bit_size(acc), 8), 8)
    {<<acc::bitstring, 0::size(pad)>>, ts_len, val_len}
  end
end

defmodule Gorilla.Frame do
  # gorilla_stream's container around the two bit streams, as
  # Encoder.BitPacking.pack/2 and Encoder.Metadata.add_metadata/2 write it
  # (v1, 80 bytes; the VictoriaMetrics options are not used): an inner
  # 32-byte header, the streams padded to a byte, then an outer header with
  # the CRC32 of the inner part. `body` is the padded streams as iodata.
  @magic 0x474F52494C4C41

  def wrap(count, t0, d1, v0_bits, ts_len, val_len, body) do
    inner = <<count::32, t0::64, v0_bits::64, d1::32-signed, ts_len::32, val_len::32>>
    packed = [inner | body]
    size = :erlang.iolist_size(packed)
    orig = count * 16

    outer =
      <<@magic::64, 1::16, 80::16, count::32, size::32, orig::32, :erlang.crc32(packed)::32,
        t0::64, d1::32-signed, v0_bits::64, ts_len::32, val_len::32, size * 8::32,
        size / orig::float-64, :os.system_time(:second)::64, 0::32>>

    {:ok, IO.iodata_to_binary([outer | packed])}
  end

  # The creation time (bytes 68..75 of the outer header, seconds) differs
  # between two encodes of the same data; agreement compares with it zeroed.
  def normalise({:ok, <<a::binary-68, _::64, b::binary>>}),
    do: {:ok, <<a::binary, 0::64, b::binary>>}

  def normalise(other), do: other
end

defmodule Gorilla.Defk do
  # The caller has a list of {ts, float}. One pass packs it into one binary,
  # each point a native i64 then a native f64 (whose 8 bytes the kernel reads
  # as an i64: the float's bits); four points per append (one per append is
  # ~3x slower to pack, see the header). The kernel builds both streams;
  # headers and CRC32 are Elixir (Gorilla.Frame).
  def encode([]), do: GorillaStream.Compression.Gorilla.Encoder.encode_elixir([], [])

  def encode([{t0, v0} | rest] = data) do
    p = pack(data, <<>>)
    {bits, ts_len, val_len} = Gorilla.Kernels.streams(p)
    <<v0_bits::64>> = <<v0::float-64>>
    d1 = if rest == [], do: 0, else: elem(hd(rest), 0) - t0
    Gorilla.Frame.wrap(div(byte_size(p), 16), t0, d1, v0_bits, ts_len, val_len, [bits])
  end

  def pack([{t1, v1}, {t2, v2}, {t3, v3}, {t4, v4} | rest], acc) do
    pack(
      rest,
      <<acc::binary, t1::signed-64-native, v1::float-64-native, t2::signed-64-native,
        v2::float-64-native, t3::signed-64-native, v3::float-64-native, t4::signed-64-native,
        v4::float-64-native>>
    )
  end

  def pack([{t, v} | rest], acc),
    do: pack(rest, <<acc::binary, t::signed-64-native, v::float-64-native>>)

  def pack([], acc), do: acc
end

defmodule Gorilla.Elixir do
  # The optimised Elixir encoder: same job, same bytes as encode_elixir.
  # One pass over the list writes both streams, each into its own bitstring
  # appended in place. A float's bits are taken as two 32-bit halves, so the
  # XOR, the zero counts and the meaningful bits stay small integers (the
  # 64-bit pattern of any value >= 2.0 is a bignum on the BEAM); the zero
  # counts come from 256-entry tuples.
  import Bitwise

  def encode([]), do: GorillaStream.Compression.Gorilla.Encoder.encode_elixir([], [])

  def encode([{t0, v0}]) do
    <<vb::64>> = <<v0::float-64>>
    Gorilla.Frame.wrap(1, t0, 0, vb, 64, 64, [<<t0::64, vb::64>>])
  end

  def encode([{t0, v0}, {t1, v1} | rest]) do
    <<vb::64>> = <<h0::32, l0::32>> = <<v0::float-64>>
    d1 = t1 - t0
    {vs, h1, l1, plz, ptz} = value(<<vb::64>>, v1, h0, l0, 0, 0)
    {ts, vs, n} = loop(rest, dod(<<t0::64>>, d1), t1, d1, vs, h1, l1, plz, ptz, 2)
    ts_len = bit_size(ts)
    val_len = bit_size(vs)
    pad = rem(8 - rem(ts_len + val_len, 8), 8)
    body = <<ts::bitstring, vs::bitstring, 0::size(pad)>>
    Gorilla.Frame.wrap(n, t0, d1, vb, ts_len, val_len, [body])
  end

  defp loop([{t, v} | rest], ts, pt, pd, vs, ph, pl, plz, ptz, n) do
    d = t - pt
    ts = dod(ts, d - pd)
    {vs, h, l, plz, ptz} = value(vs, v, ph, pl, plz, ptz)
    loop(rest, ts, t, d, vs, h, l, plz, ptz, n + 1)
  end

  defp loop([], ts, _, _, vs, _, _, _, _, n), do: {ts, vs, n}

  def dod(acc, 0), do: <<acc::bitstring, 0::1>>
  def dod(acc, d) when d >= -63 and d <= 64, do: <<acc::bitstring, 0b10::2, d::7-signed>>
  def dod(acc, d) when d >= -255 and d <= 256, do: <<acc::bitstring, 0b110::3, d::9-signed>>
  def dod(acc, d) when d >= -2047 and d <= 2048, do: <<acc::bitstring, 0b1110::4, d::12-signed>>
  def dod(acc, d), do: <<acc::bitstring, 0b1111::4, d::32-signed>>

  # one value: {vs, h, l, plz, ptz}
  def value(vs, v, ph, pl, plz, ptz) do
    <<h::32, l::32>> = <<v::float-64>>
    xh = bxor(h, ph)
    xl = bxor(l, pl)

    if xh == 0 and xl == 0 do
      {<<vs::bitstring, 0::1>>, h, l, plz, ptz}
    else
      lz = if xh == 0, do: 32 + clz32(xl), else: clz32(xh)
      tz = if xl == 0, do: 32 + ctz32(xh), else: ctz32(xl)

      if lz >= plz and tz >= ptz do
        {mbits(<<vs::bitstring, 0b10::2>>, xh, xl, ptz, 64 - plz - ptz), h, l, plz, ptz}
      else
        k = 64 - lz - tz
        lz5 = min(lz, 31)
        {mbits(<<vs::bitstring, 0b11::2, lz5::5, k - 1::6>>, xh, xl, tz, k), h, l, lz5, tz}
      end
    end
  end

  # bits s..s+k-1 of the 64-bit XOR xh:xl (the bits above are zero)
  def mbits(acc, xh, _xl, s, k) when s >= 32, do: <<acc::bitstring, xh >>> (s - 32)::size(k)>>
  def mbits(acc, _xh, xl, s, k) when s + k <= 32, do: <<acc::bitstring, xl >>> s::size(k)>>

  def mbits(acc, xh, xl, s, k),
    do: <<acc::bitstring, xh::size(s + k - 32), xl >>> s::size(32 - s)>>

  @clz8 List.to_tuple(
          for b <- 0..255, do: 8 - length(Integer.digits(b, 2)) + if(b == 0, do: 1, else: 0)
        )
  @ctz8 List.to_tuple(
          for b <- 0..255,
              do:
                if(b == 0,
                  do: 8,
                  else: b |> Integer.digits(2) |> Enum.reverse() |> Enum.find_index(&(&1 == 1))
                )
        )

  def clz32(x) when x >= 0x1000000, do: elem(@clz8, x >>> 24)
  def clz32(x) when x >= 0x10000, do: 8 + elem(@clz8, x >>> 16)
  def clz32(x) when x >= 0x100, do: 16 + elem(@clz8, x >>> 8)
  def clz32(x), do: 24 + elem(@clz8, x)

  def ctz32(x) when (x &&& 0xFF) != 0, do: elem(@ctz8, x &&& 0xFF)
  def ctz32(x) when (x &&& 0xFFFF) != 0, do: 8 + elem(@ctz8, x >>> 8 &&& 0xFF)
  def ctz32(x) when (x &&& 0xFFFFFF) != 0, do: 16 + elem(@ctz8, x >>> 16 &&& 0xFF)
  def ctz32(x), do: 24 + elem(@ctz8, x >>> 24)
end

defmodule Gorilla.Variants do
  # Elixir variants measured on the way to Gorilla.Elixir
  # (GORILLA_VARIANTS=1 times them). Each writes the same bytes.
  import Bitwise
  alias Gorilla.Elixir, as: E

  def all do
    [
      {"encode_elixir (gorilla_stream 3.0.3, the anchor)",
       &GorillaStream.Compression.Gorilla.Encoder.encode_elixir(&1, [])},
      {"one pass, 64-bit patterns (bignums), bit-loop zero counts", &bignum/1},
      {"one pass, 32-bit halves, table zero counts, iolist of pieces", &iolist/1},
      {"two passes (timestamps, then values), halves, tables", &two_pass/1},
      {"one pass, halves, tables, appended bitstrings (Gorilla.Elixir)", &E.encode/1},
      {"same, pending bits kept in a small integer (word buffer)", &wordbuf/1},
      {"same, list packed to a binary first (defk's layout), then matched", &packed/1}
    ]
  end

  defp finish(n, t0, d1, vb, ts, vs) do
    ts_len = bit_size(ts)
    val_len = bit_size(vs)
    pad = rem(8 - rem(ts_len + val_len, 8), 8)

    Gorilla.Frame.wrap(n, t0, d1, vb, ts_len, val_len, [
      <<ts::bitstring, vs::bitstring, 0::size(pad)>>
    ])
  end

  # --- the anchor's arithmetic in one pass: the XOR of two 64-bit patterns
  # (a bignum for most values), zero counts by shifting a bit at a time
  def bignum([_, _ | _] = data) do
    [{t0, v0}, {t1, v1} | rest] = data
    <<vb::64>> = <<v0::float-64>>
    d1 = t1 - t0
    {vs, b1, plz, ptz} = bvalue(<<vb::64>>, v1, vb, 0, 0)
    {ts, vs, n} = bloop(rest, E.dod(<<t0::64>>, d1), t1, d1, vs, b1, plz, ptz, 2)
    finish(n, t0, d1, vb, ts, vs)
  end

  def bignum(data), do: E.encode(data)

  defp bloop([{t, v} | rest], ts, pt, pd, vs, pb, plz, ptz, n) do
    d = t - pt
    {vs, b, plz, ptz} = bvalue(vs, v, pb, plz, ptz)
    bloop(rest, E.dod(ts, d - pd), t, d, vs, b, plz, ptz, n + 1)
  end

  defp bloop([], ts, _, _, vs, _, _, _, n), do: {ts, vs, n}

  defp bvalue(vs, v, pb, plz, ptz) do
    <<b::64>> = <<v::float-64>>
    x = bxor(b, pb)

    if x == 0 do
      {<<vs::bitstring, 0::1>>, b, plz, ptz}
    else
      lz = clz64(x, 0)
      tz = ctz64(x, 0)

      if lz >= plz and tz >= ptz do
        k = 64 - plz - ptz
        {<<vs::bitstring, 0b10::2, x >>> ptz::size(k)>>, b, plz, ptz}
      else
        k = 64 - lz - tz
        lz5 = min(lz, 31)
        {<<vs::bitstring, 0b11::2, lz5::5, k - 1::6, x >>> tz::size(k)>>, b, lz5, tz}
      end
    end
  end

  defp clz64(x, c) when (x &&& 0x8000000000000000) != 0, do: c
  defp clz64(x, c), do: clz64(x <<< 1, c + 1)
  defp ctz64(x, c) when (x &&& 1) != 0, do: c
  defp ctz64(x, c), do: ctz64(x >>> 1, c + 1)

  # --- Gorilla.Elixir's arithmetic, each stream an iolist of bitstring
  # pieces, joined once with :erlang.list_to_bitstring/1
  def iolist([_, _ | _] = data) do
    [{t0, v0}, {t1, v1} | rest] = data
    <<vb::64>> = <<h0::32, l0::32>> = <<v0::float-64>>
    d1 = t1 - t0
    {vp, h1, l1, plz, ptz} = E.value(<<>>, v1, h0, l0, 0, 0)

    {ts, vs, n} =
      iloop(rest, [<<t0::64>> | E.dod(<<>>, d1)], t1, d1, [<<vb::64>> | vp], h1, l1, plz, ptz, 2)

    finish(n, t0, d1, vb, :erlang.list_to_bitstring(ts), :erlang.list_to_bitstring(vs))
  end

  def iolist(data), do: E.encode(data)

  defp iloop([{t, v} | rest], ts, pt, pd, vs, ph, pl, plz, ptz, n) do
    d = t - pt
    {piece, h, l, plz, ptz} = E.value(<<>>, v, ph, pl, plz, ptz)
    iloop(rest, [ts | E.dod(<<>>, d - pd)], t, d, [vs | piece], h, l, plz, ptz, n + 1)
  end

  defp iloop([], ts, _, _, vs, _, _, _, _, n), do: {ts, vs, n}

  # --- one pass for the timestamps, a second for the values
  def two_pass([_, _ | _] = data) do
    [{t0, v0}, {t1, _} | rest] = data
    <<vb::64>> = <<h0::32, l0::32>> = <<v0::float-64>>
    d1 = t1 - t0
    {ts, n} = tloop(rest, E.dod(<<t0::64>>, d1), t1, d1, 2)
    vs = vloop(tl(data), <<vb::64>>, h0, l0, 0, 0)
    finish(n, t0, d1, vb, ts, vs)
  end

  def two_pass(data), do: E.encode(data)

  defp tloop([{t, _} | rest], ts, pt, pd, n) do
    d = t - pt
    tloop(rest, E.dod(ts, d - pd), t, d, n + 1)
  end

  defp tloop([], ts, _, _, n), do: {ts, n}

  defp vloop([{_, v} | rest], vs, ph, pl, plz, ptz) do
    {vs, h, l, plz, ptz} = E.value(vs, v, ph, pl, plz, ptz)
    vloop(rest, vs, h, l, plz, ptz)
  end

  defp vloop([], vs, _, _, _, _), do: vs

  # --- Gorilla.Elixir with each stream's pending bits (up to 59) kept in a
  # small integer and appended to the bitstring when the next piece would
  # not fit: fewer bitstring appends, more arithmetic
  def wordbuf([_, _ | _] = data) do
    [{t0, v0}, {t1, v1} | rest] = data
    <<vb::64>> = <<h0::32, l0::32>> = <<v0::float-64>>
    d1 = t1 - t0
    {tb, tw, tn} = wdod(<<t0::64>>, 0, 0, d1)
    {vsb, vw, vn, h1, l1, plz, ptz} = wvalue(<<vb::64>>, 0, 0, v1, h0, l0, 0, 0)
    {ts, vs, n} = wloop(rest, tb, tw, tn, t1, d1, vsb, vw, vn, h1, l1, plz, ptz, 2)
    finish(n, t0, d1, vb, ts, vs)
  end

  def wordbuf(data), do: E.encode(data)

  defp wloop([{t, v} | rest], tb, tw, tn, pt, pd, vsb, vw, vn, ph, pl, plz, ptz, n) do
    d = t - pt
    {tb, tw, tn} = wdod(tb, tw, tn, d - pd)
    {vsb, vw, vn, h, l, plz, ptz} = wvalue(vsb, vw, vn, v, ph, pl, plz, ptz)
    wloop(rest, tb, tw, tn, t, d, vsb, vw, vn, h, l, plz, ptz, n + 1)
  end

  defp wloop([], tb, tw, tn, _, _, vsb, vw, vn, _, _, _, _, n),
    do: {<<tb::bitstring, tw::size(tn)>>, <<vsb::bitstring, vw::size(vn)>>, n}

  defp wdod(b, w, n, 0), do: put(b, w, n, 0, 1)
  defp wdod(b, w, n, d) when d >= -63 and d <= 64, do: put(b, w, n, 0x100 ||| (d &&& 0x7F), 9)
  defp wdod(b, w, n, d) when d >= -255 and d <= 256, do: put(b, w, n, 0xC00 ||| (d &&& 0x1FF), 12)

  defp wdod(b, w, n, d) when d >= -2047 and d <= 2048,
    do: put(b, w, n, 0xE000 ||| (d &&& 0xFFF), 16)

  defp wdod(b, w, n, d), do: put(b, w, n, 0xF00000000 ||| (d &&& 0xFFFFFFFF), 36)

  defp put(b, w, n, v, k) when n + k <= 59, do: {b, w <<< k ||| v, n + k}
  defp put(b, w, n, v, k), do: {<<b::bitstring, w::size(n)>>, v, k}

  defp wvalue(b, w, n, v, ph, pl, plz, ptz) do
    <<h::32, l::32>> = <<v::float-64>>
    xh = bxor(h, ph)
    xl = bxor(l, pl)

    if xh == 0 and xl == 0 do
      {b, w, n} = put(b, w, n, 0, 1)
      {b, w, n, h, l, plz, ptz}
    else
      lz = if xh == 0, do: 32 + E.clz32(xl), else: E.clz32(xh)
      tz = if xl == 0, do: 32 + E.ctz32(xh), else: E.ctz32(xl)

      if lz >= plz and tz >= ptz do
        {b, w, n} = put(b, w, n, 2, 2)
        {b, w, n} = wbits(b, w, n, xh, xl, ptz, 64 - plz - ptz)
        {b, w, n, h, l, plz, ptz}
      else
        k = 64 - lz - tz
        lz5 = min(lz, 31)
        {b, w, n} = put(b, w, n, 0x1800 ||| lz5 <<< 6 ||| k - 1, 13)
        {b, w, n} = wbits(b, w, n, xh, xl, tz, k)
        {b, w, n, h, l, lz5, tz}
      end
    end
  end

  defp wbits(b, w, n, xh, _xl, s, k) when s >= 32, do: put(b, w, n, xh >>> (s - 32), k)
  defp wbits(b, w, n, _xh, xl, s, k) when s + k <= 32, do: put(b, w, n, xl >>> s, k)

  defp wbits(b, w, n, xh, xl, s, k) do
    {b, w, n} = put(b, w, n, xh, s + k - 32)
    put(b, w, n, xl >>> s, 32 - s)
  end

  # --- Gorilla.Elixir over the layout the defk side gets: the list packed
  # into one binary (big-endian here, four points per append), then the
  # loop matches <<t::64, h::32, l::32>> off it; no float binary per point
  def packed([_, _ | _] = data) do
    <<t0::signed-64, h0::32, l0::32, t1::signed-64, h1::32, l1::32, rest::binary>> =
      bpack(data, <<>>)

    vb = h0 <<< 32 ||| l0
    d1 = t1 - t0
    {vs, h1, l1, plz, ptz} = pvalue(<<vb::64>>, h1, l1, h0, l0, 0, 0)
    {ts, vs, n} = ploop(rest, E.dod(<<t0::64>>, d1), t1, d1, vs, h1, l1, plz, ptz, 2)
    finish(n, t0, d1, vb, ts, vs)
  end

  def packed(data), do: E.encode(data)

  defp bpack([{t1, v1}, {t2, v2}, {t3, v3}, {t4, v4} | rest], acc) do
    bpack(
      rest,
      <<acc::binary, t1::signed-64, v1::float-64, t2::signed-64, v2::float-64, t3::signed-64,
        v3::float-64, t4::signed-64, v4::float-64>>
    )
  end

  defp bpack([{t, v} | rest], acc), do: bpack(rest, <<acc::binary, t::signed-64, v::float-64>>)
  defp bpack([], acc), do: acc

  defp ploop(<<t::signed-64, h::32, l::32, rest::binary>>, ts, pt, pd, vs, ph, pl, plz, ptz, n) do
    d = t - pt
    {vs, h, l, plz, ptz} = pvalue(vs, h, l, ph, pl, plz, ptz)
    ploop(rest, E.dod(ts, d - pd), t, d, vs, h, l, plz, ptz, n + 1)
  end

  defp ploop(<<>>, ts, _, _, vs, _, _, _, _, n), do: {ts, vs, n}

  defp pvalue(vs, h, l, ph, pl, plz, ptz) do
    xh = bxor(h, ph)
    xl = bxor(l, pl)

    if xh == 0 and xl == 0 do
      {<<vs::bitstring, 0::1>>, h, l, plz, ptz}
    else
      lz = if xh == 0, do: 32 + E.clz32(xl), else: E.clz32(xh)
      tz = if xl == 0, do: 32 + E.ctz32(xh), else: E.ctz32(xl)

      if lz >= plz and tz >= ptz do
        {E.mbits(<<vs::bitstring, 0b10::2>>, xh, xl, ptz, 64 - plz - ptz), h, l, plz, ptz}
      else
        k = 64 - lz - tz
        lz5 = min(lz, 31)
        {E.mbits(<<vs::bitstring, 0b11::2, lz5::5, k - 1::6>>, xh, xl, tz, k), h, l, lz5, tz}
      end
    end
  end
end

defmodule Gorilla.Data do
  # A sensor series: a reading every 60 s with a little jitter on some
  # timestamps (9 in 10 deltas of deltas are 0, the rest within +-4); the
  # value a random walk from 20.0 rounded to two decimals (a temperature)
  # that moves on half of the readings and repeats on the others, so the
  # XOR windows vary as real readings do.
  def series(n, seed \\ 1) do
    :rand.seed(:exsss, {seed, 11, 17})
    t0 = 1_700_000_000 + seed

    {pts, _} =
      Enum.map_reduce(0..(n - 1)//1, {t0, 20.0}, fn i, {t, v} ->
        jitter = if :rand.uniform(10) == 1, do: :rand.uniform(5) - 3, else: 0

        v =
          if :rand.uniform(2) == 1, do: v, else: Float.round(v + (:rand.uniform() - 0.5) * 0.2, 2)

        {{t + jitter, v}, {t0 + (i + 1) * 60, v}}
      end)

    pts
  end
end

defmodule Gorilla.Edge do
  # Series that reach every branch of both encoders: each delta-of-delta
  # bucket and its edges (a 7-bit bucket holds -63..64, so 64 and -64 sit on
  # opposite sides), deltas of deltas and first deltas past 32 bits (written
  # as their low 32 bits), negative and decreasing timestamps; XORs with the
  # top bit set (sign changes, -0.0), with all 64 bits meaningful, with 32+
  # leading zeros (the capped 5-bit count), repeated values, integer values
  # (encoded as floats), extreme magnitudes.
  import Bitwise

  def series do
    edges = [
      0,
      1,
      -1,
      63,
      64,
      65,
      -63,
      -64,
      -65,
      255,
      256,
      257,
      -255,
      -256,
      -257,
      2047,
      2048,
      2049,
      -2047,
      -2048,
      -2049,
      1 <<< 31,
      -(1 <<< 31),
      1 <<< 33,
      -(1 <<< 40)
    ]

    ts_edges = Enum.scan([1_000 | edges], fn d, t -> t + d end)

    ts_dods =
      Enum.scan([0 | edges], {0, 0}, fn dd, {t, d} -> {t + d + dd, d + dd} end)
      |> Enum.map(&elem(&1, 0))

    values = [
      1.0,
      1.0,
      -1.0,
      0.0,
      -0.0,
      1.0e308,
      5.0e-324,
      2.5,
      2.5000000000000004,
      -1.0e-300,
      123_456.789,
      3,
      0,
      -7,
      1.5,
      1.5,
      1.5,
      :math.pi(),
      -:math.pi(),
      1.0e10
    ]

    vals = fn n -> Stream.cycle(values) |> Enum.take(n) end

    rand = fn n, seed ->
      :rand.seed(:exsss, {seed, 3, 5})
      for _ <- 1..n, do: (:rand.uniform() - 0.5) * :math.pow(10, :rand.uniform(40) - 20)
    end

    [
      {"dod bucket edges", Enum.zip(ts_dods, vals.(length(ts_dods)))},
      {"first-delta and delta edges", Enum.zip(ts_edges, vals.(length(ts_edges)))},
      {"negative, decreasing timestamps",
       Enum.zip(Enum.map(0..39, &(-1_000 - &1 * &1 * 7)), rand.(40, 1))},
      {"random magnitudes and signs", Enum.zip(Enum.map(0..499, &(&1 * 10)), rand.(500, 2))},
      {"constant series", Enum.map(0..99, &{&1 * 60, 42.0})},
      {"tiny steps (32+ leading zeros)",
       Enum.map(0..99, &{&1 * 15, 1.0 + &1 * 2.220446049250313e-16})},
      {"integer values", Enum.map(0..49, &{&1 * 60, rem(&1 * 7919, 1000)})},
      {"two points", [{100, 1.0}, {160, -2.0}]},
      {"one point", [{5, 0.5}]}
    ] ++
      for {d, i} <- Enum.with_index(edges),
          do: {"two points, first delta #{d}", [{i, 1.0}, {i + d, 3.0}]}
  end
end

defmodule Gorilla.Check do
  def sides do
    Gorilla.Variants.all() ++
      [
        {"NIF.nif_gorilla_encode (gorilla_stream 3.0.3)",
         &GorillaStream.Compression.Gorilla.NIF.nif_gorilla_encode(&1, %{})},
        {"defk", &Gorilla.Defk.encode/1}
      ]
  end

  # every side's output for one series, creation time zeroed; true when all
  # are byte-identical
  def agree?(data) do
    sides()
    |> Enum.map(fn {_, f} -> Gorilla.Frame.normalise(f.(data)) end)
    |> Enum.uniq()
    |> length() == 1
  end
end

alias GorillaStream.Compression.Gorilla.{Encoder, NIF}
import Bitwise

# --- Agreement ---------------------------------------------------------------
cases =
  [{"realistic, 1M points", Gorilla.Data.series(1_000_000, 9)}] ++
    for(
      n <- [2, 3, 10, 100, 1000, 10_000],
      seed <- 1..3,
      do: {"realistic, #{n} points, seed #{seed}", Gorilla.Data.series(n, seed)}
    ) ++
    Gorilla.Edge.series()

bad = for {label, data} <- cases, not Gorilla.Check.agree?(data), do: label

IO.puts(
  "agreement: #{length(cases) - length(bad)}/#{length(cases)} series byte-identical (creation time zeroed) across encode_elixir, #{length(Gorilla.Variants.all()) - 1} Elixir variants, the NIF and defk"
)

if bad != [], do: raise("Gorilla outputs differ: #{inspect(bad)}")

# The empty list: encode_elixir writes an 80-byte header with count 0, the
# NIF returns <<>>. The Elixir and defk encoders follow encode_elixir.
{:ok, <<_::binary-80>>} = Encoder.encode_elixir([], [])
{:ok, <<>>} = NIF.nif_gorilla_encode([], %{})

true =
  Gorilla.Frame.normalise(Gorilla.Defk.encode([])) ==
    Gorilla.Frame.normalise(Encoder.encode_elixir([], []))

# Elixir mode: the kernel against its Elixir-mode twin on the packed edge
# series, plus a delta that overflows i64 (ArithmeticError in both).
outcome = fn f ->
  try do
    {:ok, f.()}
  rescue
    e -> {:raise, e.__struct__}
  end
end

em_inputs =
  for({_, data} <- Gorilla.Edge.series(), do: Gorilla.Defk.pack(data, <<>>)) ++
    [
      Gorilla.Defk.pack(Gorilla.Data.series(300, 4), <<>>),
      Gorilla.Defk.pack([{-(1 <<< 62) * 2, 1.0}, {(1 <<< 62) * 2 - 1, 2.0}], <<>>)
    ]

em =
  for p <- em_inputs,
      do:
        outcome.(fn -> Gorilla.Kernels.streams(p) end) ==
          outcome.(fn -> Gorilla.Kernels.__defk_elixir__(:streams, [p]) end)

IO.puts("Elixir mode: #{Enum.count(em, & &1)}/#{length(em)} kernel cases agree")
if not Enum.all?(em), do: raise("kernel and Elixir mode differ")

# --- Measurement -------------------------------------------------------------
# Inputs live in :persistent_term, as a TSDB's buffered points live outside
# the encoding call's heap. On the benchmark process's heap, the 1M-point
# list (~56 MB) is copied by every GC that a large binary's growth triggers,
# which bills the side allocating most (defk's packed binary) and doubles
# its time.
realistic_series = 1_000

:persistent_term.put(
  :gorilla_blocks,
  for(s <- 1..realistic_series, do: Gorilla.Data.series(100, s))
)

:persistent_term.put(:gorilla_1m, Gorilla.Data.series(1_000_000))

{:ok, enc} = Gorilla.Elixir.encode(:persistent_term.get(:gorilla_1m))

IO.puts(
  "realistic input: 1M points encode to #{byte_size(enc)} bytes (#{Float.round(byte_size(enc) * 8 / 1_000_000, 1)} bits per point, 128 raw)"
)

# Repeated jobs keep only the last output: a list of thousands of results
# held to the end makes every GC during the run walk it.
blocks = fn f ->
  fn -> Enum.reduce(:persistent_term.get(:gorilla_blocks), nil, fn s, _ -> f.(s) end) end
end

one_m = fn f -> fn -> f.(:persistent_term.get(:gorilla_1m)) end end
elixir_f = &Gorilla.Elixir.encode/1
defk_f = &Gorilla.Defk.encode/1
nif_f = &NIF.nif_gorilla_encode(&1, %{})

if System.get_env("GORILLA_VARIANTS") do
  # interleaved: each round runs every side once; best of 7 rounds
  for {label, job} <- [{"1,000 x 100 points", blocks}, {"1M points", one_m}] do
    sides =
      Enum.reject(Gorilla.Check.sides(), fn {l, _} -> label == "1M points" and l =~ "iolist" end)

    t =
      for _ <- 1..7, {l, f} <- sides do
        :erlang.garbage_collect()
        {l, elem(:timer.tc(job.(f)), 0)}
      end

    IO.puts("\n#{label} (ms, best of 7, interleaved):")

    for {l, _} <- sides do
      us = t |> Enum.filter(&(elem(&1, 0) == l)) |> Enum.map(&elem(&1, 1)) |> Enum.min()
      IO.puts("  #{String.pad_trailing(l, 66)} #{Float.round(us / 1000, 2)}")
    end
  end
end

# sweep: block sizes from 100 to 1M points, each timed over ~1M points (one
# block of that size encoded 1M / size times)
sweep_sizes = [100, 630, 4_000, 25_000, 160_000, 1_000_000]

for n <- sweep_sizes,
    n < 1_000_000,
    do: :persistent_term.put({:gorilla_sweep, n}, Gorilla.Data.series(n, n))

sweep_job = fn f, n ->
  reps = div(1_000_000, n)
  key = if n == 1_000_000, do: :gorilla_1m, else: {:gorilla_sweep, n}
  fn -> Enum.reduce(1..reps, nil, fn _, _ -> f.(:persistent_term.get(key)) end) end
end

r100 =
  Defk.Bench.report(
    name: "gorilla_encode",
    expected: :good,
    baseline: :optimized,
    runs: 15,
    realistic_size:
      "100-point blocks (a Gorilla/Prometheus chunk), 1,000 series per timed run, one call each",
    elixir: blocks.(elixir_f),
    defk: blocks.(defk_f),
    native: {blocks.(nif_f), "gorilla_stream 3.0.3 NIF.nif_gorilla_encode"},
    check: fn -> bad == [] and Enum.all?(em) end,
    sweep:
      {Enum.map(sweep_sizes, &"#{&1} pts"),
       fn size ->
         n = size |> String.trim_trailing(" pts") |> String.to_integer()
         {sweep_job.(elixir_f, n), sweep_job.(defk_f, n)}
       end},
    sweep_runs: 3,
    responsiveness: [elixir: one_m.(elixir_f), defk: one_m.(defk_f), native: one_m.(nif_f)],
    reason:
      "both bit streams are built by one kernel with the bitstring accumulator; pure Elixir pays per point for bitstring appends and boxed floats"
  )

r1m =
  Defk.Bench.report(
    name: "gorilla_encode_1m",
    expected: :good,
    baseline: :optimized,
    runs: 15,
    realistic_size: "1M points, one call",
    elixir: one_m.(elixir_f),
    defk: one_m.(defk_f),
    native: {one_m.(nif_f), "gorilla_stream 3.0.3 NIF.nif_gorilla_encode"},
    check: fn -> bad == [] end,
    reason: "the same job on one 1M-point series; packing the list is ~half of defk's time"
  )

for r <- [r100, r1m], not r.correct or r.verdict != r.expected do
  IO.puts("#{r.example}: verdict #{r.verdict}, expected #{r.expected}, correct #{r.correct}")
  System.halt(1)
end
