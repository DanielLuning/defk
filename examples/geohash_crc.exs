# geohash_crc: batch geohash encode/decode and CRC-16/CRC-64 over MB-sized buffers
#
# The jobs: geo pipelines encode and decode millions of points to geohash
# strings (some wrap a Rust geohash crate for it), and device protocols and
# archive formats checksum buffers with CRC-16 (CCITT) and CRC-64 (ECMA/XZ).
# The Hex `geohash` package is pure Elixir; the `crc` package is a C NIF
# (crc 0.11.0 compiles c_src; the ticket's "pure Elixir" description is out of
# date), so it is reported as the native anchor beside the verdict, not as
# the baseline.
# Expected verdict: good for 100k-point batches and MB-sized CRCs; poor for
# one point per call (measured and reported beside).
#
#   elixir examples/geohash_crc.exs
#
# DEFK_RESULT lines, in this order (run_all.exs reads the first):
#   1. geohash_encode  (100k points, packed f64 columns in, fixed-width hashes out)
#   2. geohash_decode  (100k hashes in, packed f64 centre columns out)
#   3. crc16           (CRC-16/CCITT-FALSE, 1 MB; sweep to 16 MB)
#   4. crc64           (CRC-64/XZ, 1 MB; sweep to 16 MB)
#   5. geohash_encode_single (one point per call, expected poor)
# The script exits 1 if any of them is incorrect or measures a different
# verdict than it expects.
#
# Measured (M-series Mac, OTP 29, Elixir 1.20; ranges over three runs):
#   geohash_encode, 100k points, precision 11: Elixir 14.1-14.4 ms, defk 1.9-2.0
#     ms: 7.3-7.5x, good (crossover at about 100 points; 1 point: 0.5x). The
#     geohash package takes 105 ms and the bisecting Elixir 111 ms; a bisecting
#     kernel (first version) took 14-31 ms, so the win came from the quantise-
#     and-spread algorithm, which both sides use (Elixir 111 -> 14 ms, kernel
#     31 -> 2 ms). Packing two lists into the kernel's input costs another 5.5
#     ms (7.5 ms total, still 1.9x the Elixir time).
#   geohash_decode, 100k hashes: Elixir 12.0-12.7 ms, defk 1.2 ms: 10.2-10.5x,
#     good (the package takes 1.2 s and the bisecting Elixir 53 ms); unpacking
#     the result to lists adds 2.4 ms.
#   crc16 / crc64 at 1 MB: 1.7x / 1.65-1.8x over the best Elixir, marginal;
#     at 16 MB 1.65-1.8x. Elixir 3.3-3.8 ms per MB (about 300 MB/s) against the
#     kernel's 1.9-2.3 ms (500 MB/s). The crc package NIF: 2.1-3.1 ms (the
#     kernel is 1.0-1.4x faster). :erlang.crc32: 0.03 ms per MB (35 GB/s, zlib
#     with CLMUL; another polynomial), the ceiling the table loops cannot
#     approach. A single integer for CRC-64 state goes bignum and is 10x slower
#     than two 32-bit halves, which is the Elixir baseline. Slicing-by-N (more
#     bytes per step) was not tried on either side.
#   geohash_encode_single, 10k calls of one point: 0.77-0.85x, poor (call cost
#     and packing two floats; Elixir 1.9-2.4 ms for the 10k).
#
# Attributes: `@base32 "0123456789bcdefghjkmnpqrstuvwxyz"` does not compile on
# main yet (module-attribute: "not supported yet"), so the alphabet, the
# reverse table and both CRC tables are built in the kernel at the start of
# each call (about 2 us, visible only at 64 bytes in the CRC sweep).
#
# Elixir baselines (all marked :optimized, after trying the variants below):
#   geohash: the `geohash` package (1.3.0) is the :first_pass reference (a
#     `:math.pow` and bitstring per bit, lists of bits to decode). The
#     baseline is the kernel's own algorithm in pure Elixir (quantise each
#     coordinate to a cell index, correct it against the exact cell edge,
#     interleave with bit spreading, append to one binary), which is 8x
#     faster than the bisecting version (also kept, and used to check
#     agreement). Hashes are identical to the package's. The package and the
#     bisecting version are timed beside.
#   crc16: table-driven, 256-entry tuple built at compile time, one
#     `<<b, rest::binary>>` step per byte. Slicing-by-N was not tried (the
#     kernel is plain table-driven too).
#   crc64: two variants measured: (a) the state as one integer (the value
#     passes 2^59, so the BEAM promotes it to a bignum every step), (b) the
#     state split into two 32-bit halves with two 256-tuples, all small
#     integers. The faster one is the baseline (see numbers below).
#   :erlang.crc32/1 is the BIF ceiling for the CRC family (a different
#     polynomial, so it is printed beside, never the baseline).
#   Native anchor: the `crc` package NIF (`native:` in the report).
#
# Kernels. Tables are built at the start of each call, in the kernel (module
# attributes: see "Attributes" below). `geohash_encode` interleaves the two
# bisections one bit at a time (even bits longitude, odd latitude, 5 bits to
# a character) and writes `precision` bytes per point into one buffer.
# `crc64` is the reflected algorithm: it only shifts right, with the sign
# bits masked off (bsr is arithmetic on i64), and the polynomial
# 0xC96C5795D7870F42 written as -0x3693A86A2878F0BE (its i64 bit pattern).
# The result is the i64 bit pattern of the 64-bit CRC, since the value can
# exceed 2^63-1: the caller reinterprets it with
# `<<u::unsigned-64>> = <<v::signed-64>>`.
#
# Agreement: geohash_encode against the package on 5000 random points at
# precision 1..12 and the known vectors (57.64911, 10.40744 -> "u4pruydqqvj",
# 42.6, -5.6 -> "ezs42"); decode against the Elixir decoder bit for bit and
# against the package within the cell size; encode/decode round trips land
# within a cell; CRC-16 and CRC-64 against the published check values for
# "123456789" (0x29B1 and 0x995DC9BBDF1939FA) and against the `crc` package
# on random inputs of 0..300 bytes; every kernel also against Elixir mode
# (`__defk_elixir__`) on small inputs.

Mix.install([
  {:defk, path: Path.expand("..", __DIR__)},
  {:geohash, "~> 1.3"},
  {:crc, "~> 0.11"}
])

# The kernels live in a macro so the same source compiles twice: natively
# (GeoCrc.Kernels) and, for the agreement checks, with Elixir mode compiled in
# (GeoCrc.KernelsEM, which needs a Mix project in the :test env; a script has
# none, so a dummy one is pushed for that one compile).
defmodule GeoCrc.Source do
  defmacro kernels do
    quote do
      # bit j of x (below 2^32) moves to bit 2j; compact is the inverse
      defk spread(x :: i64) :: i64 do
        x = band(bor(x, bsl(x, 16)), 0x0000FFFF0000FFFF)
        x = band(bor(x, bsl(x, 8)), 0x00FF00FF00FF00FF)
        x = band(bor(x, bsl(x, 4)), 0x0F0F0F0F0F0F0F0F)
        x = band(bor(x, bsl(x, 2)), 0x3333333333333333)
        band(bor(x, bsl(x, 1)), 0x5555555555555555)
      end

      defk compact(x :: i64) :: i64 do
        x = band(x, 0x5555555555555555)
        x = band(bor(x, bsr(x, 1)), 0x3333333333333333)
        x = band(bor(x, bsr(x, 2)), 0x0F0F0F0F0F0F0F0F)
        x = band(bor(x, bsr(x, 4)), 0x00FF00FF00FF00FF)
        x = band(bor(x, bsr(x, 8)), 0x0000FFFF0000FFFF)
        band(bor(x, bsr(x, 16)), 0x00000000FFFFFFFF)
      end

      # Precision 1..12 (the 60 bits of a precision-12 hash are the most a double
      # carries); anything else raises ArgumentError.
      # Each coordinate is quantised once, `trunc((x - min) / span * 2^bits)`
      # clamped to the grid, and the two integers are interleaved (longitude
      # first), instead of bisecting bit by bit. The division can round a value
      # next to a cell edge into the wrong cell, so the index is corrected
      # against the exact edge (`index * cell - min`, a dyadic value); that
      # makes the result the bisection's, bit for bit (the script checks every
      # cell edge of a precision-3 grid and the doubles on either side).
      defk geohash_encode(lat :: [f64], lon :: [f64], precision :: i64) :: [u8] do
        if precision < 1 or precision > 12,
          do: raise(ArgumentError, "geohash_encode: precision must be 1..12")

        n = min(len(lat), len(lon))
        out = alloc(u8, n * precision)
        alphabet = alloc(u8, 32)

        # "0123456789bcdefghjkmnpqrstuvwxyz": digits, then b..z without a, i, l, o
        for k <- 0..31//1 do
          c = 98 + k - 10
          c = c + if(c >= 105, do: 1, else: 0)
          c = c + if(c >= 108, do: 1, else: 0)
          c = c + if(c >= 111, do: 1, else: 0)
          alphabet[k] = if k < 10, do: 48 + k, else: c
        end

        nlat = div(precision * 5, 2)
        nlon = precision * 5 - nlat
        lat_cells = bsl(1, nlat)
        lon_cells = bsl(1, nlon)
        lat_cell = 180.0 / float(lat_cells)
        lon_cell = 360.0 / float(lon_cells)

        for i <- 0..(n - 1)//1 do
          x = lat[i]
          y = lon[i]
          l0 = max(0, min(trunc((x + 90.0) / 180.0 * float(lat_cells)), lat_cells - 1))
          l1 = if x < float(l0) * lat_cell - 90.0, do: l0 - 1, else: l0
          l2 = if x >= float(l1 + 1) * lat_cell - 90.0, do: l1 + 1, else: l1
          li = max(0, min(l2, lat_cells - 1))
          o0 = max(0, min(trunc((y + 180.0) / 360.0 * float(lon_cells)), lon_cells - 1))
          o1 = if y < float(o0) * lon_cell - 180.0, do: o0 - 1, else: o0
          o2 = if y >= float(o1 + 1) * lon_cell - 180.0, do: o1 + 1, else: o1
          oi = max(0, min(o2, lon_cells - 1))

          # interleave: bit j of an index moves to bit 2j; longitude is the most
          # significant bit, so it takes the odd positions when the total is even
          z =
            if nlon == nlat,
              do: bor(bsl(spread(oi), 1), spread(li)),
              else: bor(spread(oi), bsl(spread(li), 1))

          for c <- 0..(precision - 1)//1 do
            out[i * precision + c] = alphabet[band(bsr(z, 5 * (precision - 1 - c)), 31)]
          end
        end

        out
      end

      # Hashes are fixed width (`precision` bytes each, back to back); the result
      # is the centres of the cells as two packed f64 columns. Each hash is
      # de-interleaved (bit compaction) into its two cell indices and the centre is
      # `(index + 0.5) * cell - min`, which is exact (a short dyadic fraction
      # of 180 or 360), so it equals the bisection's `(lo + hi) / 2` bit for bit.
      # A byte outside the alphabet raises ArgumentError (the package raises
      # ArithmeticError).
      defk geohash_decode(hashes :: [u8], precision :: i64) :: {[f64], [f64]} do
        if precision < 1 or precision > 12,
          do: raise(ArgumentError, "geohash_decode: precision must be 1..12")

        n = div(len(hashes), precision)
        lat = alloc(f64, n)
        lon = alloc(f64, n)
        # alphabet value + 1 by byte; 0 marks a byte that is not in the alphabet
        rev = alloc(i64, 256)

        for k <- 0..31//1 do
          c = 98 + k - 10
          c = c + if(c >= 105, do: 1, else: 0)
          c = c + if(c >= 108, do: 1, else: 0)
          c = c + if(c >= 111, do: 1, else: 0)
          rev[if(k < 10, do: 48 + k, else: c)] = k + 1
        end

        nlat = div(precision * 5, 2)
        nlon = precision * 5 - nlat
        lat_cell = 180.0 / float(bsl(1, nlat))
        lon_cell = 360.0 / float(bsl(1, nlon))

        for i <- 0..(n - 1)//1 do
          z =
            for j <- 0..(precision - 1)//1, reduce: 0 do
              z ->
                t = rev[hashes[i * precision + j]]
                if t == 0, do: raise(ArgumentError, "geohash_decode: a byte is not in the alphabet")
                bor(bsl(z, 5), t - 1)
            end

          {li, oi} =
            if nlon == nlat,
              do: {compact(z), compact(bsr(z, 1))},
              else: {compact(bsr(z, 1)), compact(z)}

          lat[i] = (float(li) + 0.5) * lat_cell - 90.0
          lon[i] = (float(oi) + 0.5) * lon_cell - 180.0
        end

        {lat, lon}
      end

      # CRC-16/CCITT-FALSE: poly 0x1021, init 0xFFFF, no reflection, no xorout.
      defk crc16(bytes :: [u8]) :: i64 do
        table = alloc(i64, 256)

        for i <- 0..255//1 do
          table[i] =
            for _ <- 1..8, reduce: bsl(i, 8) do
              c ->
                s = band(bsl(c, 1), 0xFFFF)
                if band(c, 0x8000) != 0, do: bxor(s, 0x1021), else: s
            end
        end

        for b <- bytes, reduce: 0xFFFF do
          crc -> band(bxor(bsl(crc, 8), table[band(bxor(bsr(crc, 8), b), 255)]), 0xFFFF)
        end
      end

      # CRC-64/XZ: reflected poly 0xC96C5795D7870F42 (as the i64 bit pattern
      # -0x3693A86A2878F0BE), init and xorout all ones. Returns the i64 bit
      # pattern of the 64-bit CRC; the caller reinterprets it with
      # `<<u::unsigned-64>> = <<v::signed-64>>`. Only shifts right, masking off
      # the sign fill (bsr is arithmetic), so nothing ever overflows.
      defk crc64(bytes :: [u8]) :: i64 do
        table = alloc(i64, 256)

        for i <- 0..255//1 do
          table[i] =
            for _ <- 1..8, reduce: i do
              c ->
                s = band(bsr(c, 1), 0x7FFFFFFFFFFFFFFF)
                if band(c, 1) == 1, do: bxor(s, -0x3693A86A2878F0BE), else: s
            end
        end

        crc =
          for b <- bytes, reduce: -1 do
            crc ->
              bxor(table[band(bxor(crc, b), 255)], band(bsr(crc, 8), 0x00FFFFFFFFFFFFFF))
          end

        bnot(crc)
      end
    end
  end
end

defmodule GeoCrc.Kernels do
  use Defk
  require GeoCrc.Source
  GeoCrc.Source.kernels()
end

defmodule GeoCrc.Project do
  def project, do: [app: :geo_crc, version: "0.0.0"]
end

old_env = Mix.env()
Mix.env(:test)
Mix.Project.push(GeoCrc.Project, "geo_crc_dummy_mix.exs")

defmodule GeoCrc.KernelsEM do
  use Defk
  require GeoCrc.Source
  GeoCrc.Source.kernels()
end

Mix.Project.pop()
Mix.env(old_env)

# The Elixir side: optimised pure-Elixir encode/decode and the CRC variants.
defmodule GeoCrc.Pure do
  import Bitwise

  @alphabet List.to_tuple(~c"0123456789bcdefghjkmnpqrstuvwxyz")
  @rev (for c <- 0..255 do
          case :binary.match("0123456789bcdefghjkmnpqrstuvwxyz", <<c>>) do
            {i, 1} -> i
            :nomatch -> :bad
          end
        end)
       |> List.to_tuple()

  # ---- geohash: lists of floats in, one packed binary of precision-byte hashes out

  def encode_all(lats, lons, p), do: encode_all(lats, lons, p, [])

  defp encode_all([la | lt], [lo | ot], p, acc),
    do: encode_all(lt, ot, p, [encode_point(la, lo, p) | acc])

  defp encode_all([], [], _p, acc), do: acc |> :lists.reverse() |> IO.iodata_to_binary()

  def encode_point(la, lo, p), do: enc(la, lo, p * 5, true, -90.0, 90.0, -180.0, 180.0, 0, <<>>)

  defp enc(_la, _lo, 0, _even, _llo, _lhi, _olo, _ohi, _ch, acc), do: acc

  defp enc(la, lo, left, true, llo, lhi, olo, ohi, ch, acc) do
    mid = (olo + ohi) / 2.0
    {bit, olo, ohi} = if lo >= mid, do: {1, mid, ohi}, else: {0, olo, mid}
    next(la, lo, left, false, llo, lhi, olo, ohi, ch * 2 + bit, acc)
  end

  defp enc(la, lo, left, false, llo, lhi, olo, ohi, ch, acc) do
    mid = (llo + lhi) / 2.0
    {bit, llo, lhi} = if la >= mid, do: {1, mid, lhi}, else: {0, llo, mid}
    next(la, lo, left, true, llo, lhi, olo, ohi, ch * 2 + bit, acc)
  end

  defp next(la, lo, left, even, llo, lhi, olo, ohi, ch, acc) do
    if rem(left, 5) == 1,
      do:
        enc(la, lo, left - 1, even, llo, lhi, olo, ohi, 0, <<acc::binary, elem(@alphabet, ch)>>),
      else: enc(la, lo, left - 1, even, llo, lhi, olo, ohi, ch, acc)
  end

  # hashes in, {lat column, lon column} out as packed f64 binaries
  def decode_all(hashes, p), do: decode_all(hashes, p, [], [])

  defp decode_all(<<>>, _p, lats, lons),
    do:
      {lats |> :lists.reverse() |> IO.iodata_to_binary(),
       lons |> :lists.reverse() |> IO.iodata_to_binary()}

  defp decode_all(hashes, p, lats, lons) do
    <<h::binary-size(^p), rest::binary>> = hashes
    {la, lo} = dec(h, true, -90.0, 90.0, -180.0, 180.0)
    decode_all(rest, p, [<<la::float-native>> | lats], [<<lo::float-native>> | lons])
  end

  defp dec(<<>>, _even, llo, lhi, olo, ohi), do: {(llo + lhi) / 2.0, (olo + ohi) / 2.0}

  defp dec(<<c, rest::binary>>, even, llo, lhi, olo, ohi),
    do: dec_bits(elem(@rev, c), 4, rest, even, llo, lhi, olo, ohi)

  defp dec_bits(_v, -1, rest, even, llo, lhi, olo, ohi), do: dec(rest, even, llo, lhi, olo, ohi)

  defp dec_bits(v, k, rest, true, llo, lhi, olo, ohi) do
    mid = (olo + ohi) / 2.0

    if band(v >>> k, 1) == 1,
      do: dec_bits(v, k - 1, rest, false, llo, lhi, mid, ohi),
      else: dec_bits(v, k - 1, rest, false, llo, lhi, olo, mid)
  end

  defp dec_bits(v, k, rest, false, llo, lhi, olo, ohi) do
    mid = (llo + lhi) / 2.0

    if band(v >>> k, 1) == 1,
      do: dec_bits(v, k - 1, rest, true, mid, lhi, olo, ohi),
      else: dec_bits(v, k - 1, rest, true, llo, mid, olo, ohi)
  end

  # ---- the same with quantised integers and bit spreading (the kernel's
  # algorithm); appends straight to one binary, which the BEAM grows in place

  def encode_all_int(lats, lons, p), do: encode_all_int(lats, lons, p, <<>>)

  defp encode_all_int([la | lt], [lo | ot], p, acc),
    do: encode_all_int(lt, ot, p, encode_point_int(la, lo, p, acc))

  defp encode_all_int([], [], _p, acc), do: acc

  def encode_point_int(la, lo, p), do: encode_point_int(la, lo, p, <<>>)

  defp encode_point_int(la, lo, p, acc) do
    nlat = div(p * 5, 2)
    nlon = p * 5 - nlat
    li = cell(la, 90.0, 180.0, nlat)
    oi = cell(lo, 180.0, 360.0, nlon)
    # longitude takes the first (most significant) bit, then they alternate
    z =
      if nlon == nlat, do: spread(oi) <<< 1 ||| spread(li), else: spread(oi) ||| spread(li) <<< 1

    emit(z, p - 1, acc)
  end

  defp emit(_z, -1, acc), do: acc

  defp emit(z, k, acc),
    do: emit(z, k - 1, <<acc::binary, elem(@alphabet, band(z >>> (5 * k), 31))>>)

  # the cell index of x in a grid of 2^bits cells over [-half, half): quantise,
  # then correct against the exact cell edges so it equals the bisection
  defp cell(x, half, span, bits) do
    cells = 1 <<< bits
    size = span / cells
    c0 = max(0, min(trunc((x + half) / span * cells), cells - 1))
    c1 = if x < c0 * size - half, do: c0 - 1, else: c0
    c2 = if x >= (c1 + 1) * size - half, do: c1 + 1, else: c1
    max(0, min(c2, cells - 1))
  end

  # bit j of x moves to bit 2j (x below 2^32), and back
  defp spread(x) do
    x = band(bor(x, x <<< 16), 0x0000FFFF0000FFFF)
    x = band(bor(x, x <<< 8), 0x00FF00FF00FF00FF)
    x = band(bor(x, x <<< 4), 0x0F0F0F0F0F0F0F0F)
    x = band(bor(x, x <<< 2), 0x3333333333333333)
    band(bor(x, x <<< 1), 0x5555555555555555)
  end

  defp compact(x) do
    x = band(x, 0x5555555555555555)
    x = band(bor(x, x >>> 1), 0x3333333333333333)
    x = band(bor(x, x >>> 2), 0x0F0F0F0F0F0F0F0F)
    x = band(bor(x, x >>> 4), 0x00FF00FF00FF00FF)
    x = band(bor(x, x >>> 8), 0x0000FFFF0000FFFF)
    band(bor(x, x >>> 16), 0x00000000FFFFFFFF)
  end

  def decode_all_int(hashes, p), do: decode_all_int(hashes, p, <<>>, <<>>)

  defp decode_all_int(<<>>, _p, lats, lons), do: {lats, lons}

  defp decode_all_int(hashes, p, lats, lons) do
    <<h::binary-size(^p), rest::binary>> = hashes
    nlat = div(p * 5, 2)
    nlon = p * 5 - nlat
    z = to_int(h, 0)

    {li, oi} =
      if nlon == nlat, do: {compact(z), compact(z >>> 1)}, else: {compact(z >>> 1), compact(z)}

    la = (li + 0.5) * (180.0 / (1 <<< nlat)) - 90.0
    lo = (oi + 0.5) * (360.0 / (1 <<< nlon)) - 180.0

    decode_all_int(
      rest,
      p,
      <<lats::binary, la::float-native>>,
      <<lons::binary, lo::float-native>>
    )
  end

  defp to_int(<<>>, z), do: z
  defp to_int(<<c, rest::binary>>, z), do: to_int(rest, z <<< 5 ||| elem(@rev, c))

  # ---- CRC-16/CCITT-FALSE

  @t16 (for i <- 0..255 do
          Enum.reduce(1..8, i <<< 8, fn _, c ->
            s = band(c <<< 1, 0xFFFF)
            if band(c, 0x8000) != 0, do: bxor(s, 0x1021), else: s
          end)
        end)
       |> List.to_tuple()

  def crc16(bin), do: crc16(bin, 0xFFFF)

  defp crc16(<<b, rest::binary>>, crc),
    do: crc16(rest, band(bxor(crc <<< 8, elem(@t16, band(bxor(crc >>> 8, b), 255))), 0xFFFF))

  defp crc16(<<>>, crc), do: crc

  # ---- CRC-64/XZ, reflected, unsigned result

  @poly64 0xC96C5795D7870F42
  @t64 Enum.map(0..255, fn i ->
         Enum.reduce(1..8, i, fn _, c ->
           if band(c, 1) == 1, do: bxor(c >>> 1, @poly64), else: c >>> 1
         end)
       end)
  @t64_whole List.to_tuple(@t64)
  @t64_hi @t64 |> Enum.map(&(&1 >>> 32)) |> List.to_tuple()
  @t64_lo @t64 |> Enum.map(&band(&1, 0xFFFFFFFF)) |> List.to_tuple()

  # (a) the state as one integer: promoted to a bignum above 2^59
  def crc64_whole(bin), do: bxor(crc64_whole(bin, 0xFFFFFFFFFFFFFFFF), 0xFFFFFFFFFFFFFFFF)

  defp crc64_whole(<<b, rest::binary>>, crc),
    do: crc64_whole(rest, bxor(elem(@t64_whole, band(bxor(crc, b), 255)), crc >>> 8))

  defp crc64_whole(<<>>, crc), do: crc

  # (b) two 32-bit halves, every value a small integer
  def crc64_halves(bin), do: crc64_halves(bin, 0xFFFFFFFF, 0xFFFFFFFF)

  defp crc64_halves(<<b, rest::binary>>, hi, lo) do
    idx = band(bxor(lo, b), 255)

    crc64_halves(
      rest,
      bxor(hi >>> 8, elem(@t64_hi, idx)),
      bxor(bor(lo >>> 8, band(hi, 0xFF) <<< 24), elem(@t64_lo, idx))
    )
  end

  defp crc64_halves(<<>>, hi, lo), do: bxor(hi, 0xFFFFFFFF) <<< 32 ||| bxor(lo, 0xFFFFFFFF)
end

defmodule GeoCrc.Data do
  def points(n, seed) do
    :rand.seed(:exsss, seed)
    for _ <- 1..n, do: {:rand.uniform() * 180.0 - 90.0, :rand.uniform() * 360.0 - 180.0}
  end

  def pack(floats), do: for(x <- floats, into: <<>>, do: <<x::float-native>>)
  def unpack(bin), do: for(<<x::float-native <- bin>>, do: x)
  # the neighbouring doubles of x
  def up(x) when x >= 0.0, do: (fn <<f::float>> -> f end).(<<bits(x) + 1::64>>)
  def up(x), do: -down(-x)
  def down(x) when x > 0.0, do: (fn <<f::float>> -> f end).(<<bits(x) - 1::64>>)
  def down(x) when x == 0.0, do: -5.0e-324
  def down(x), do: -up(-x)
  defp bits(x), do: (fn <<i::64>> -> i end).(<<x::float>>)

  def unsigned(v), do: (fn <<u::unsigned-64>> -> u end).(<<v::signed-64>>)

  # cell sizes in degrees: floor(5p/2) latitude bits, ceil(5p/2) longitude bits
  def lat_cell(p), do: 180.0 / :math.pow(2, div(p * 5, 2))
  def lon_cell(p), do: 360.0 / :math.pow(2, div(p * 5 + 1, 2))
end

alias GeoCrc.{Data, Pure, Kernels}
alias GeoCrc.KernelsEM, as: EM
import Bitwise

best_us = fn fun, runs ->
  fun.()

  1..runs
  |> Enum.map(fn _ ->
    :erlang.garbage_collect()
    elem(:timer.tc(fun), 0)
  end)
  |> Enum.min()
end

# ---------------------------------------------------------------- agreement

# geohash: known vectors
vectors = [
  {57.64911, 10.40744, 11, "u4pruydqqvj"},
  {42.6, -5.6, 5, "ezs42"},
  {-90.0, -180.0, 6, "000000"},
  {90.0, 180.0, 6, "zzzzzz"},
  {0.0, 0.0, 6, "s00000"}
]

vectors_ok =
  for {la, lo, p, want} <- vectors, reduce: true do
    acc ->
      got = Kernels.geohash_encode(Data.pack([la]), Data.pack([lo]), p)

      ok =
        got == want and Pure.encode_point(la, lo, p) == want and
          Geohash.encode(la, lo, p) == want

      unless ok, do: IO.puts("DISAGREE vector #{la},#{lo},#{p}: want #{want}, kernel #{got}")
      acc and ok
  end

# encode against the package, round trips, decode against the package
roundtrip =
  for p <- 1..12, reduce: %{enc: true, dec_elixir: true, dec_pkg: true, trip: true} do
    acc ->
      pts = Data.points(400, {p, 2, 3})
      {la, lo} = Enum.unzip(pts)
      hashes = Kernels.geohash_encode(Data.pack(la), Data.pack(lo), p)
      pkg = pts |> Enum.map(fn {a, o} -> Geohash.encode(a, o, p) end) |> Enum.join()
      {klat, klon} = Kernels.geohash_decode(hashes, p)
      {elat, elon} = Pure.decode_all(hashes, p)
      dlat = Data.unpack(klat)
      dlon = Data.unpack(klon)
      pkg_dec = for <<h::binary-size(^p) <- hashes>>, do: Geohash.decode(h)
      la_c = Data.lat_cell(p)
      lo_c = Data.lon_cell(p)

      %{
        enc: acc.enc and hashes == pkg,
        dec_elixir: acc.dec_elixir and {klat, klon} == {elat, elon},
        dec_pkg:
          acc.dec_pkg and
            Enum.all?(Enum.zip([dlat, dlon, pkg_dec]), fn {a, o, {pa, po}} ->
              abs(a - pa) <= la_c and abs(o - po) <= lo_c
            end),
        trip:
          acc.trip and
            Enum.all?(Enum.zip([la, lo, dlat, dlon]), fn {a, o, da, dlo_} ->
              abs(a - da) <= la_c / 2 + 1.0e-9 and abs(o - dlo_) <= lo_c / 2 + 1.0e-9
            end)
      }
  end

# Elixir mode on small inputs
em_ok =
  for p <- [1, 5, 11] do
    {la, lo} = Data.points(30, {p, 9, 9}) |> Enum.unzip()
    h = Kernels.geohash_encode(Data.pack(la), Data.pack(lo), p)

    EM.__defk_elixir__(:geohash_encode, [Data.pack(la), Data.pack(lo), p]) === h and
      EM.__defk_elixir__(:geohash_decode, [h, p]) === Kernels.geohash_decode(h, p)
  end
  |> Enum.all?()

# an invalid alphabet byte raises in the kernel, as in the package
bad_raises =
  try do
    Kernels.geohash_decode("abc", 3)
    false
  rescue
    e in ArgumentError -> e.message == "geohash_decode: a byte is not in the alphabet"
  end

# Every cell edge of a precision-3 grid (7 latitude and 8 longitude bits), and
# the doubles on either side of it, against the bisecting package: this is
# where quantising could differ from bisecting.
edge_mismatches =
  for {min, span, bits, side} <- [{-90.0, 180.0, 7, :lat}, {-180.0, 360.0, 8, :lon}],
      k <- 0..(1 <<< bits),
      x0 = min + span * k / (1 <<< bits),
      x <- [Data.down(x0), x0, Data.up(x0)],
      {la, lo} = if(side == :lat, do: {x, 33.3}, else: {33.3, x}),
      reduce: 0 do
    acc ->
      got = Kernels.geohash_encode(Data.pack([la]), Data.pack([lo]), 3)
      if got == Geohash.encode(la, lo, 3), do: acc, else: acc + 1
  end

edges_ok = edge_mismatches == 0

# CRC: published check values and random inputs against the package
check_ok =
  Kernels.crc16("123456789") == 0x29B1 and
    Data.unsigned(Kernels.crc64("123456789")) == 0x995DC9BBDF1939FA and
    Pure.crc16("123456789") == 0x29B1 and
    Pure.crc64_whole("123456789") == 0x995DC9BBDF1939FA and
    Pure.crc64_halves("123456789") == 0x995DC9BBDF1939FA and
    CRC.crc(:crc_16_ccitt_false, "123456789") == 0x29B1 and
    CRC.crc(:crc_64_xz, "123456789") == 0x995DC9BBDF1939FA and
    EM.__defk_elixir__(:crc16, ["123456789"]) == 0x29B1 and
    Data.unsigned(EM.__defk_elixir__(:crc64, ["123456789"])) == 0x995DC9BBDF1939FA

:rand.seed(:exsss, {4, 5, 6})

crc_random_ok =
  for _ <- 1..400, reduce: true do
    acc ->
      bin = :rand.bytes(:rand.uniform(301) - 1)
      k64 = Data.unsigned(Kernels.crc64(bin))

      acc and Kernels.crc16(bin) == CRC.crc(:crc_16_ccitt_false, bin) and
        Kernels.crc16(bin) == Pure.crc16(bin) and
        k64 == CRC.crc(:crc_64_xz, bin) and k64 == Pure.crc64_whole(bin) and
        k64 == Pure.crc64_halves(bin) and
        (byte_size(bin) > 40 or
           (Kernels.crc16(bin) == EM.__defk_elixir__(:crc16, [bin]) and
              Kernels.crc64(bin) == EM.__defk_elixir__(:crc64, [bin])))
  end

agree =
  vectors_ok and Enum.all?(Map.values(roundtrip)) and edges_ok and em_ok and bad_raises and
    check_ok and
    crc_random_ok

unless agree do
  raise "agreement failed: vectors #{vectors_ok}, #{inspect(roundtrip)}, cell edges #{edge_mismatches} mismatches, elixir mode #{em_ok}, bad byte #{bad_raises}, check values #{check_ok}, crc random #{crc_random_ok}"
end

IO.puts(
  "agreement: 5 geohash vectors, 12 precisions x 400 points (encode vs package, decode vs Elixir and package, round trips), CRC check values, 400 random buffers vs the crc package, Elixir mode: ok"
)

# ---------------------------------------------------------------- data

n = 100_000
pts = Data.points(n, {1, 2, 3})
{lats, lons} = Enum.unzip(pts)
latb = Data.pack(lats)
lonb = Data.pack(lons)
p = 11

hashes = Kernels.geohash_encode(latb, lonb, p)
true = hashes == Pure.encode_all(lats, lons, p) and hashes == Pure.encode_all_int(lats, lons, p)

# the first-pass reference: the package, one string per point
pkg_encode = fn -> for {a, o} <- pts, do: Geohash.encode(a, o, p) end
pkg_decode = fn -> for <<h::binary-size(^p) <- hashes>>, do: Geohash.decode(h) end

IO.puts("geohash, #{n} points, precision #{p}, best of 3 (ms):")

for {label, f} <- [
      {"geohash package encode (first pass)", pkg_encode},
      {"Elixir encode, bisecting", fn -> Pure.encode_all(lats, lons, p) end},
      {"Elixir encode, quantised (baseline)", fn -> Pure.encode_all_int(lats, lons, p) end},
      {"defk encode (packed in)", fn -> Kernels.geohash_encode(latb, lonb, p) end},
      {"defk encode incl. packing two lists",
       fn -> Kernels.geohash_encode(Data.pack(lats), Data.pack(lons), p) end},
      {"geohash package decode (first pass)", pkg_decode},
      {"Elixir decode, bisecting", fn -> Pure.decode_all(hashes, p) end},
      {"Elixir decode, quantised (baseline)", fn -> Pure.decode_all_int(hashes, p) end},
      {"defk decode (packed out)", fn -> Kernels.geohash_decode(hashes, p) end},
      {"defk decode incl. unpacking to lists",
       fn ->
         {a, o} = Kernels.geohash_decode(hashes, p)
         {Data.unpack(a), Data.unpack(o)}
       end}
    ] do
  IO.puts("  #{String.pad_trailing(label, 40)} #{Float.round(best_us.(f, 3) / 1000, 2)}")
end

mb = 1024 * 1024
bin16 = :rand.bytes(16 * mb)
bin1 = binary_part(bin16, 0, mb)

IO.puts("CRC variants, best of 3 (ms):")

for {label, bin} <- [{"1 MB", bin1}, {"16 MB", bin16}] do
  for {name, f} <- [
        {"Elixir crc16 (table)", fn -> Pure.crc16(bin) end},
        {"Elixir crc64, one integer (bignum)", fn -> Pure.crc64_whole(bin) end},
        {"Elixir crc64, two 32-bit halves", fn -> Pure.crc64_halves(bin) end},
        {":erlang.crc32 (BIF ceiling, other poly)", fn -> :erlang.crc32(bin) end},
        {"crc package crc16 (NIF)", fn -> CRC.crc(:crc_16_ccitt_false, bin) end},
        {"crc package crc64 (NIF)", fn -> CRC.crc(:crc_64_xz, bin) end}
      ] do
    IO.puts(
      "  #{label} #{String.pad_trailing(name, 42)} #{Float.round(best_us.(f, 3) / 1000, 2)}"
    )
  end
end

# ---------------------------------------------------------------- reports

geo_sweep = fn size ->
  l = Enum.take(lats, size)
  o = Enum.take(lons, size)
  lb = Data.pack(l)
  ob = Data.pack(o)
  {fn -> Pure.encode_all_int(l, o, p) end, fn -> Kernels.geohash_encode(lb, ob, p) end}
end

r1 =
  Defk.Bench.report(
    name: "geohash_encode",
    expected: :good,
    baseline: :optimized,
    runs: 5,
    realistic_size: "100k points",
    elixir: fn -> Pure.encode_all_int(lats, lons, p) end,
    defk: fn -> Kernels.geohash_encode(latb, lonb, p) end,
    check: fn -> agree and hashes == Pure.encode_all_int(lats, lons, p) end,
    sweep: {[1, 10, 100, 1_000, 10_000, 100_000], geo_sweep},
    sweep_runs: 5,
    reason:
      "a branch-light integer loop over packed f64 columns: quantise, interleave by bit spreading, write bytes; Elixir is held back by building 100k binaries and boxed floats"
  )

r2 =
  Defk.Bench.report(
    name: "geohash_decode",
    expected: :good,
    baseline: :optimized,
    runs: 5,
    realistic_size: "100k hashes",
    elixir: fn -> Pure.decode_all_int(hashes, p) end,
    defk: fn -> Kernels.geohash_decode(hashes, p) end,
    check: fn ->
      Kernels.geohash_decode(hashes, p) == Pure.decode_all_int(hashes, p) and
        Kernels.geohash_decode(hashes, p) == Pure.decode_all(hashes, p)
    end,
    sweep:
      {[1, 10, 100, 1_000, 10_000, 100_000],
       fn size ->
         h = binary_part(hashes, 0, size * p)
         {fn -> Pure.decode_all_int(h, p) end, fn -> Kernels.geohash_decode(h, p) end}
       end},
    sweep_runs: 5,
    reason:
      "the inverse of the encoder: hashes to two cell indices to packed f64 centres; no BEAM terms are built on the kernel side"
  )

crc_sweep = fn elixir_fun, defk_fun ->
  {[64, 1024, 65_536, mb, 16 * mb],
   fn size ->
     b = binary_part(bin16, 0, size)
     {fn -> elixir_fun.(b) end, fn -> defk_fun.(b) end}
   end}
end

elixir_crc64 = &Pure.crc64_halves/1

r3 =
  Defk.Bench.report(
    name: "crc16",
    expected: :marginal,
    baseline: :optimized,
    runs: 5,
    realistic_size: "1 MB",
    elixir: fn -> Pure.crc16(bin1) end,
    defk: fn -> Kernels.crc16(bin1) end,
    native: {fn -> CRC.crc(:crc_16_ccitt_false, bin1) end, "crc 0.11.0"},
    check: fn ->
      agree and Kernels.crc16(bin16) == Pure.crc16(bin16) and
        Kernels.crc16(bin16) == CRC.crc(:crc_16_ccitt_false, bin16)
    end,
    sweep: crc_sweep.(&Pure.crc16/1, &Kernels.crc16/1),
    sweep_runs: 5,
    reason:
      "a byte-serial table lookup (one dependent load per byte) is about 2 ns per byte natively and the Elixir binary loop is already about 3.6 ns, so the gain is under 2x; :erlang.crc32 (zlib, another polynomial) is 100x faster than both and the crc NIF is no faster than the kernel"
  )

r4 =
  Defk.Bench.report(
    name: "crc64",
    expected: :marginal,
    baseline: :optimized,
    runs: 5,
    realistic_size: "1 MB",
    elixir: fn -> elixir_crc64.(bin1) end,
    defk: fn -> Data.unsigned(Kernels.crc64(bin1)) end,
    native: {fn -> CRC.crc(:crc_64_xz, bin1) end, "crc 0.11.0"},
    check: fn ->
      agree and Data.unsigned(Kernels.crc64(bin16)) == elixir_crc64.(bin16) and
        Data.unsigned(Kernels.crc64(bin16)) == CRC.crc(:crc_64_xz, bin16)
    end,
    sweep: crc_sweep.(elixir_crc64, fn b -> Data.unsigned(Kernels.crc64(b)) end),
    sweep_runs: 5,
    reason:
      "same shape as crc16: the reflected table loop is 1.7-1.9x the best Elixir (two 32-bit halves, since one integer goes bignum and costs 10x), and the crc package NIF is within 1.1-1.4x of the kernel"
  )

# one point per call: 10k calls, each packing its own two floats
singles = Enum.take(pts, 10_000)

r5 =
  Defk.Bench.report(
    name: "geohash_encode_single",
    expected: :poor,
    baseline: :optimized,
    runs: 5,
    realistic_size: "10k calls of 1 point",
    elixir: fn -> for {a, o} <- singles, do: Pure.encode_point_int(a, o, p) end,
    defk: fn ->
      for {a, o} <- singles,
          do: Kernels.geohash_encode(<<a::float-native>>, <<o::float-native>>, p)
    end,
    check: fn ->
      for({a, o} <- singles, do: Pure.encode_point_int(a, o, p)) ==
        for(
          {a, o} <- singles,
          do: Kernels.geohash_encode(<<a::float-native>>, <<o::float-native>>, p)
        )
    end,
    reason:
      "one point per call: packing two floats and the call cost more than the 50-bit loop saves; batch the points (a batch of 10 already breaks even)"
  )

results = [r1, r2, r3, r4, r5]

bad = for r <- results, not r.correct or r.verdict != r.expected, do: r.example

unless bad == [],
  do:
    (
      IO.puts("verdict or agreement mismatch: #{inspect(bad)}")
      System.halt(1)
    )
