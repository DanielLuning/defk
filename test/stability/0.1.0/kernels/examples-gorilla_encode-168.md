<!-- examples/gorilla_encode.exs line 168 of v0.1.0. A frozen file is never edited. -->

<!-- defk-example compiles: a catalog kernel module -->
```elixir
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
```
