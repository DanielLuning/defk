<!-- examples/lz4_snappy_decode.exs line 205 of v0.1.0. A frozen file is never edited. -->

<!-- defk-example compiles: a catalog kernel module -->
```elixir
defmodule LzSnappy.Kernels do
  use Defk, elixir_mode: true

  defk snappy_decode(src :: [u8]) :: [u8] do
    n = length(src)

    {ulen, ip0, done} =
      Enum.reduce_while(0..4//1, {0, 0, false}, fn i, {v, _p, _d} ->
        if i >= n, do: raise(ArgumentError, "snappy: truncated length preamble")
        b = src[i]
        v2 = bor(v, bsl(band(b, 127), 7 * i))
        if b < 128, do: {:halt, {v2, i + 1, true}}, else: {:cont, {v2, i + 1, false}}
      end)

    if not done, do: raise(ArgumentError, "snappy: length preamble longer than 5 bytes")
    if ulen > 0xFFFFFFFF, do: raise(ArgumentError, "snappy: length above 2^32 - 1")

    # a valid element yields at most 64 bytes from 3 (copy-2), so a valid stream
    # never claims more than 22 bytes per input byte: refuse before alloc
    if ulen > 22 * (n - ip0),
      do: raise(ArgumentError, "snappy: length too large for the input")

    out = alloc(u8, ulen)

    # one element per iteration; each consumes at least one byte
    {out, _ip, op} =
      Enum.reduce_while(0..(n - ip0 - 1)//1, {out, ip0, 0}, fn _step, {out, ip, op} ->
        tag = src[ip]
        t = band(tag, 3)
        l6 = bsr(tag, 2)

        hdr =
          cond do
            t == 0 and l6 < 60 -> 1
            t == 0 -> l6 - 58
            t == 1 -> 2
            t == 2 -> 3
            true -> 5
          end

        if ip + hdr > n, do: raise(ArgumentError, "snappy: truncated element header")

        {ln, off} =
          cond do
            t == 0 and l6 < 60 -> {l6 + 1, 0}
            t == 0 and l6 == 60 -> {src[ip + 1] + 1, 0}
            t == 0 and l6 == 61 -> {u16_le(src, ip + 1) + 1, 0}
            t == 0 and l6 == 62 -> {bor(u16_le(src, ip + 1), bsl(src[ip + 3], 16)) + 1, 0}
            t == 0 -> {u32_le(src, ip + 1) + 1, 0}
            t == 1 -> {band(l6, 7) + 4, bor(bsl(bsr(tag, 5), 8), src[ip + 1])}
            t == 2 -> {l6 + 1, u16_le(src, ip + 1)}
            true -> {l6 + 1, u32_le(src, ip + 1)}
          end

        if op + ln > ulen,
          do: raise(ArgumentError, "snappy: output longer than the preamble says")

        s = ip + hdr
        lit = if t == 0, do: ln, else: 0
        if s + lit > n, do: raise(ArgumentError, "snappy: literal runs past the input")

        if t != 0 and (off == 0 or off > op),
          do: raise(ArgumentError, "snappy: copy offset out of range")

        # a literal or a copy: one range copy, checked once
        if t == 0 do
          out = copy(out, op, src, s, ln)
          nip = s + ln
          if nip >= n, do: {:halt, {out, nip, op + ln}}, else: {:cont, {out, nip, op + ln}}
        else
          out = copy_back(out, op, off, ln)
          if s >= n, do: {:halt, {out, s, op + ln}}, else: {:cont, {out, s, op + ln}}
        end
      end)

    if op != ulen, do: raise(ArgumentError, "snappy: output shorter than the preamble says")
    out
  end

  defk lz4_block_decode(src :: [u8], max_out :: i64) :: {[u8], i64} do
    n = length(src)
    if max_out < 0, do: raise(ArgumentError, "lz4: negative max_out")
    if n == 0, do: raise(ArgumentError, "lz4: empty input")
    out = alloc(u8, max_out)

    # one sequence per iteration; each consumes at least one byte
    {out, _ip, op, done} =
      Enum.reduce_while(0..n//1, {out, 0, 0, false}, fn _step, {out, ip, op, _done} ->
        if ip >= n, do: raise(ArgumentError, "lz4: block ends after a match, not literals")
        token = src[ip]

        {lit, ip1} =
          if bsr(token, 4) == 15 do
            ext_len(src, ip + 1, 15)
          else
            {bsr(token, 4), ip + 1}
          end

        if ip1 + lit > n, do: raise(ArgumentError, "lz4: literals run past the input")
        if op + lit > max_out, do: raise(ArgumentError, "lz4: output longer than max_out")
        out = copy(out, op, src, ip1, lit)
        ip2 = ip1 + lit
        op2 = op + lit

        if ip2 == n do
          {:halt, {out, ip2, op2, true}}
        else
          if ip2 + 2 > n, do: raise(ArgumentError, "lz4: truncated match offset")
          o = u16_le(src, ip2)
          if o == 0 or o > op2, do: raise(ArgumentError, "lz4: match offset out of range")

          {m, ip3} =
            if band(token, 15) == 15 do
              ext_len(src, ip2 + 2, 19)
            else
              {band(token, 15) + 4, ip2 + 2}
            end

          if op2 + m > max_out, do: raise(ArgumentError, "lz4: output longer than max_out")
          out = copy_back(out, op2, o, m)
          {:cont, {out, ip3, op2 + m, false}}
        end
      end)

    if not done, do: raise(ArgumentError, "lz4: block does not end")
    {out, op}
  end

  # an LZ4 length continued in bytes from src[ip] while they are 255:
  # {base + their sum, the index after the last one}
  defk ext_len(src :: [u8], ip :: i64, base :: i64) :: {i64, i64} do
    n = length(src)

    Enum.reduce_while(ip..n//1, {base, ip}, fn i, {acc, _p} ->
      if i >= n, do: raise(ArgumentError, "lz4: truncated length")
      b = src[i]
      if b == 255, do: {:cont, {acc + 255, i + 1}}, else: {:halt, {acc + b, i + 1}}
    end)
  end
end
```
