# lz4_snappy_decode: LZ4 and Snappy block decode written from scratch as
# kernels, against the snappyer and lz4 (lz4_erl) NIFs and pure Elixir
#
# Why people reach for a NIF here: Kafka record batches, RocksDB/LevelDB
# blocks, Cassandra and many caches compress with LZ4 or Snappy, and the Hex
# answers are thin NIFs over the C/C++ reference libraries (snappyer: the
# snappy C++ library, used by kafka_protocol/brod; lz4 / lz4_erl: liblz4).
# Those decoders run on bytes that come off the network, and the reference C
# decoders have had out-of-bounds CVEs. This is the catalog's first
# untrusted-input entry: the safety claim (malformed input raises, never
# crashes the VM) matters as much as the speed.
# Expected verdict: good against the optimised Elixir decoders (both formats).
#
#   elixir examples/lz4_snappy_decode.exs                # checks + tables + two reports
#   LZ_NIF_OPT=1 elixir examples/lz4_snappy_decode.exs   # the NIFs rebuilt with -O3/-O2
#
# DEFK_RESULT lines, in this order (mix defk.examples reads the first):
#   1. snappy_decode     64 KB JSON-like block: defk vs the best Elixir;
#                        snappyer reported as `native`
#   2. lz4_block_decode  the same 64 KB block in LZ4: defk vs the best Elixir;
#                        lz4_erl reported as `native`
#
# Formats (primary sources):
#   Snappy: https://github.com/google/snappy/blob/main/format_description.txt
#     varint preamble (uncompressed length, at most 5 bytes, < 2^32), then
#     elements: a tag byte whose low 2 bits are 00 literal (length - 1 in the
#     upper 6 bits up to 59; 60..63 mean 1..4 little-endian length bytes
#     follow), 01 copy with an 11-bit offset and length 4..11, 10 copy with a
#     16-bit offset, 11 copy with a 32-bit offset (length 1..64). A copy may
#     be longer than its offset ("a form of run-length encoding").
#   LZ4: https://github.com/lz4/lz4/blob/dev/doc/lz4_Block_format.md
#     sequences of token (literal length high nibble, match length - 4 low
#     nibble, 15 continued by bytes summed while 255), literals, a 2-byte
#     little-endian offset (0 is invalid), the match; the last sequence is
#     literals only. The block carries no decompressed size: the caller passes
#     the bound, as liblz4's LZ4_decompress_safe does.
#
# The kernels:
#   snappy_decode(src :: [u8]) :: [u8]
#   lz4_block_decode(src :: [u8], max_out :: i64) :: {[u8], i64}
#     (the buffer and the length; LzSnappy.Defk.lz4_block_decode/2 takes the
#     binary_part)
# Each is one Enum.reduce_while over the elements (at most one element per
# input byte, so the range 0..n bounds the loop), with every length, offset
# and position checked before use; a malformed stream raises ArgumentError
# with a message naming what was wrong ("lz4: match offset out of range"),
# at the element where it is found. The message cannot carry the offset:
# raise takes a literal message only (defk-sbp asks for an integer in it).
# Copies are the range-copy builtins (defk-52v.16): a literal is
# out = copy(out, op, src, ip, ln), a match out = copy_back(out, op, off, ml),
# whose meaning is the format's: out[op + j] = out[op + j - off] for j in
# order, so an offset below the length repeats the last offset bytes. Each
# is one range check, then a few loads and stores (up to 32 bytes), memmove,
# or 8-byte words from at least 8 bytes back for an overlapping match. A
# literal element calls copy and a match element copy_back, in the two arms
# of the reduce_while fn. Snappy's preamble length is also bounded by 22 x the input
# (a copy-2 element turns 3 bytes into at most 64), so a 6-byte stream that
# claims 4 GiB raises before alloc; snappyer allocates the claimed 4 GiB
# first (6.7 ms) and then reports corrupted_data. LZ4 is lenient where the
# format says a decoder may be: it accepts a block whose last match ends
# within 12 bytes of the end (liblz4 rejects some of those; lz4_flex does
# not). The fuzz section counts these disagreements with the NIFs.
#
# Bounds checks left in the hot loops (Defk.Report): one range check per
# copy ("copy(out, op, src, s, ln): one range check for the whole copy"),
# and the tag/token and offset reads keep theirs; there is no per-byte check
# and no copy loop in the kernels (the disassembly of either decoder has no
# byte store, strb, outside the copy_back pattern fill). Before defk-52v.16
# the copies were two helper kernels with a u64_le load and eight checked
# byte stores per word (clang did not merge them), and a bounds and an
# overflow check on every byte: the lz4 kernel had 36 strb and 74
# overflow branches (b.vs), now 0 and 19.
#
# A copy trap found here (defk-33b): calling a helper kernel that writes and
# returns `out` inside one branch of an `if` in the loop body, when another
# branch reads `out` (`if done, do: {:halt, {out, ...}}, else: (out =
# copy_back(out, ...); ...)`), copied the whole output buffer on every
# element and kept every copy until the kernel returned: 47 ms instead of
# 0.1 ms at 64 KB, and the BEAM was SIGKILLed (exit 137, out of memory) at 4
# MB. Fixed in defk-33b. The kernels then still called both copy helpers
# unconditionally, one with length 0; with the builtins that spelling (copy
# and copy_back on every element) costs more than branching: 64 us against
# 39-40 us for Snappy at 64 KB, while LZ4 is the same either way (44-46 us).
# The kernels branch.
#
# Elixir baseline: optimised. There is no pure-Elixir LZ4 or Snappy decoder
# on Hex worth using; three versions per format were written and measured.
# 64 KB JSON-like block, best of interleaved rounds, three runs (Apple M4
# Pro, OTP 29, Elixir 1.20; load average 24-85, so provisional):
#
#                                              snappy        lz4
#   first pass: binary pattern matching on     650-820 us    0.7-1.4 ms
#     the input, output appended to a binary,
#     match copies byte by byte (:binary.at/2)
#   optimised: the same walk, a match is one   175-240 us    230-450 us
#     binary_part/3 of the output appended
#     (offset >= length) or :binary.copy/2 of
#     the offset-long pattern plus a
#     binary_part (overlap)
#   positional: the optimised copies, the      310-325 us    295-320 us
#     input read by index (binary_part,
#     :binary.at) instead of matching the rest
#   defk kernel, byte-store helpers            63-72 us      70-77 us
#   defk kernel, copy/copy_back (defk-52v.16)  39-46 us      42-49 us
#     (load average 150-195, so provisional)
#
# The optimised Elixir times are bimodal (the same lz4 call measured 230 us
# in one part of a run and 450 us in another, with a GC before every
# sample); the reports use Defk.Bench's numbers. Not possible: iodata
# output, because a match reads earlier output at an arbitrary offset (up to
# 64 KB back), so the output must stay one binary. Where Elixir wins:
# incompressible data, which both formats store as one long literal: the
# Elixir decoders return a sub-binary of the input (0.6-1 us at 64 KB,
# 0.08-0.7 ms at 4 MB) where the kernel copies every byte (15 us, 0.95 ms
# with the byte-store helpers; one memmove with copy: 1.2-1.6 us, 85-93 us,
# level with the Elixir sub-binary at 4 MB).
#
# Native: as installed from Hex, both NIFs are built without optimisation:
# rebar3's port compiler (pc) passes no -O, lz4_erl sets no CFLAGS, and
# snappyer sets -O2 in CFLAGS but compiles its C++ with CXXFLAGS
# (-std=c++11 only). So the `native` numbers in the reports are -O0 builds
# of liblz4 1.7.5 (normal scheduler) and of snappy (dirty CPU scheduler).
# LZ_NIF_OPT=1 rebuilds them with CFLAGS=-O3 CXXFLAGS=-O2 in a separate
# Mix.install directory. 64 KB JSON block / 4 MB JSON block:
#
#                                    byte stores (defk-52v.3)  copy builtins (defk-52v.16)
#   defk snappy_decode               63-72 us / 4.5-4.9 ms     39-46 us / 3.2-3.3 ms
#   snappyer as installed (-O0)      99-184 us / 5.9-6.8 ms    0.12-6.4 ms (dirty waits)
#   snappyer rebuilt -O2             23-26 us / 1.6 ms         27-95 us / 1.6-1.7 ms
#   defk lz4_block_decode            70-77 us / 4.1-4.8 ms     42-49 us / 2.7 ms
#   lz4_erl as installed (-O0)       92-97 us / 5.2-5.5 ms     96-222 us (two runs)
#   lz4_erl rebuilt -O3              8-9 us / 0.9 ms           8-12 us / 0.91-0.92 ms
#   nimble_lz4 (lz4_flex, Rust)      20-24 us / 1.1-2.3 ms     35-98 us / 1.2-1.3 ms
#
# (The copy-builtin column: load average 150-195, best of 15-25
# interleaved rounds, the old kernels measured beside the new in the same
# rounds at 65 / 74-75 us and 4.55 / 4.25 ms; snappyer runs on a dirty
# scheduler, which the load slowed in some rounds.) So the kernels are
# 1.2-2x faster than the NIFs people install, and against the same
# libraries built with optimisation 0.5-0.7x (snappy) and 0.2-0.35x (lz4):
# still not the parity the ticket expected. With the per-byte checks gone
# the cost is per element (about 8 ns per LZ4 sequence, from 13, against
# liblz4's 2 ns): the reduce_while step with a safepoint, the checked
# position arithmetic and the format's own checks, where liblz4 copies 16
# bytes unconditionally (wildcopy) into slack it then overwrites. Long
# copies are at memmove speed: the repetitive 4 MB block (long matches)
# decodes in 175-180 us against optimised liblz4's 190 us.
# Responsiveness (4 MB block, 1 ms ticker on one scheduler): the kernels and
# snappyer (dirty) stay at the loaded machine's ~2 ms floor; lz4_erl as
# installed runs 5-7 ms on a normal scheduler without yielding and gaps the
# ticker by 5.1-11.3 ms (0.9 ms when built -O3). A copy over 1 MiB runs in
# 1 MiB strips with a safepoint after each, so a long literal or match
# yields like a loop. With the copy builtins at load 150-195 the kernels
# gapped the ticker by 2.3-6.2 ms, the dirty snappyer and the -O3 lz4_erl by
# 1.8-7.4 ms: the floor of the machine at that load.
#
# Agreement and safety, checked on every run:
#   - corpus: five kinds of data (text: this repo's docs and lib sources;
#     JSON-like log events; packed binary rows; highly repetitive; random
#     incompressible) at 4 KB, 64 KB, 1 MB and 4 MB, compressed by snappyer
#     and by lz4_erl (fast and HC) and nimble_lz4, decoded by the kernels and
#     every Elixir version, byte for byte against the original;
#   - Elixir mode (use Defk, elixir_mode: true) against native on the 4 KB
#     corpus (Elixir mode rebuilds the binary on every byte write, so it is
#     quadratic and kept small);
#   - fuzz: random byte strings and mutated valid streams (byte flips,
#     truncations, extensions), run natively with __defk_force_yields__(true)
#     (a yield at every safepoint, checked with __defk_stats__) against Elixir
#     mode: both raise the same exception and message, or both return
#     identical values. Every native raise must be ArgumentError from the
#     kernels' own checks (never Enum.OutOfBoundsError or ArithmeticError),
#     and the optimised Elixir decoder must agree on accept/reject and value.
#     The NIFs decode the same inputs; their disagreements are counted.
#     Measured: 3,000 inputs per format, 685 (snappy) and 5,230 (lz4) forced
#     yields (973 and 5,383 with the byte-store helpers, whose copy loops had
#     safepoints of their own), every input agreeing in all three checks; 557
#     and 592 accepted.
#     Snappy vs snappyer: 2,994 the same, 6 where snappyer returns "" for an
#     empty input (its NIF wrapper special-cases it; the format needs a
#     preamble, the kernel raises). LZ4 vs liblz4: 2,986 the same, 14 the
#     kernel accepts and liblz4 rejects (blocks breaking the end-of-block
#     rules: the last match ending within 12 bytes of the end, fewer than 5
#     closing literals; the format lets a decoder accept them, and the
#     output is still within max_out). No input decoded to a different value.
# The VM surviving the fuzz is the point: defk-7dm (fault containment) is not
# done, so a real out-of-bounds access in a kernel would crash the node. It
# is the bounds and overflow checks that make that impossible here, not a
# fault handler.

nif_opt? = System.get_env("LZ_NIF_OPT") == "1"

if nif_opt? do
  System.put_env("CFLAGS", "-O3")
  System.put_env("CXXFLAGS", "-O2")
  System.put_env("MIX_INSTALL_DIR", Path.join(System.tmp_dir!(), "defk_lz_nif_opt"))
end

Mix.install([
  {:defk, path: Path.expand("..", __DIR__)},
  {:snappyer, "~> 1.2"},
  {:lz4, "~> 0.2.4", hex: :lz4_erl},
  {:nimble_lz4, "~> 1.2"}
])

defmodule LzSnappy.Kernels do
  use Defk, elixir_mode: true

  defk snappy_decode(src :: [u8]) :: [u8] do
    n = len(src)

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

        # a literal or a copy: one range copy, checked once (defk-52v.16)
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
    n = len(src)
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
    n = len(src)

    Enum.reduce_while(ip..n//1, {base, ip}, fn i, {acc, _p} ->
      if i >= n, do: raise(ArgumentError, "lz4: truncated length")
      b = src[i]
      if b == 255, do: {:cont, {acc + 255, i + 1}}, else: {:halt, {acc + b, i + 1}}
    end)
  end
end

defmodule LzSnappy.Defk do
  alias LzSnappy.Kernels, as: K

  def snappy_decode(src), do: K.snappy_decode(src)

  def lz4_block_decode(src, max_out) do
    {buf, len} = K.lz4_block_decode(src, max_out)
    binary_part(buf, 0, len)
  end
end

defmodule LzSnappy.Elixir do
  @moduledoc false
  import Bitwise

  defp bad(msg), do: raise(ArgumentError, msg)

  # Snappy preamble: {length, rest}
  defp varint(bin), do: varint(bin, 0, 0)

  defp varint(<<b, rest::binary>>, v, sh) when sh <= 28 do
    v = bor(v, bsl(band(b, 127), sh))

    cond do
      b >= 128 -> varint(rest, v, sh + 7)
      v > 0xFFFFFFFF -> bad("snappy: length above 2^32 - 1")
      true -> {v, rest}
    end
  end

  defp varint(_, _, _), do: bad("snappy: bad length preamble")

  defp preamble(src) do
    {ulen, rest} = varint(src)
    if ulen > 22 * byte_size(rest), do: bad("snappy: length too large for the input")
    {ulen, rest}
  end

  defp finish(out, ulen) do
    if byte_size(out) != ulen, do: bad("snappy: output shorter than the preamble says")
    out
  end

  # copy l bytes from off back, appended: one binary_part, or the overlapping
  # pattern repeated with :binary.copy/2 and a binary_part for the rest
  defp copy(out, off, l, max) do
    size = byte_size(out)
    if off == 0 or off > size, do: bad("copy offset out of range")
    if size + l > max, do: bad("output too long")

    if off >= l do
      <<out::binary, binary_part(out, size - off, l)::binary>>
    else
      pat = binary_part(out, size - off, off)

      <<out::binary, :binary.copy(pat, div(l, off))::binary,
        binary_part(pat, 0, rem(l, off))::binary>>
    end
  end

  # the first pass's copy: byte by byte with :binary.at/2
  defp bytecopy(out, off, l, max) do
    size = byte_size(out)
    if off == 0 or off > size, do: bad("copy offset out of range")
    if size + l > max, do: bad("output too long")
    bytes(out, size - off, l)
  end

  defp bytes(out, _from, 0), do: out
  defp bytes(out, from, l), do: bytes(<<out::binary, :binary.at(out, from)>>, from + 1, l - 1)

  ## Snappy, optimised: match the input, binary_part copies

  def snappy(src) do
    {ulen, rest} = preamble(src)
    finish(sn(rest, <<>>, ulen), ulen)
  end

  defp sn(<<>>, out, _), do: out
  defp sn(<<l6::6, 0::2, rest::binary>>, out, ulen) when l6 < 60, do: lit(rest, l6 + 1, out, ulen)
  defp sn(<<60::6, 0::2, l, rest::binary>>, out, ulen), do: lit(rest, l + 1, out, ulen)
  defp sn(<<61::6, 0::2, l::little-16, rest::binary>>, out, ulen), do: lit(rest, l + 1, out, ulen)
  defp sn(<<62::6, 0::2, l::little-24, rest::binary>>, out, ulen), do: lit(rest, l + 1, out, ulen)
  defp sn(<<63::6, 0::2, l::little-32, rest::binary>>, out, ulen), do: lit(rest, l + 1, out, ulen)

  defp sn(<<hi::3, l3::3, 1::2, lo, rest::binary>>, out, ulen),
    do: sn(rest, copy(out, bor(bsl(hi, 8), lo), l3 + 4, ulen), ulen)

  defp sn(<<l6::6, 2::2, off::little-16, rest::binary>>, out, ulen),
    do: sn(rest, copy(out, off, l6 + 1, ulen), ulen)

  defp sn(<<l6::6, 3::2, off::little-32, rest::binary>>, out, ulen),
    do: sn(rest, copy(out, off, l6 + 1, ulen), ulen)

  defp sn(_, _, _), do: bad("snappy: truncated element header")

  defp lit(rest, l, out, ulen) do
    case rest do
      <<s::binary-size(^l), rest::binary>> ->
        if byte_size(out) + l > ulen, do: bad("snappy: output longer than the preamble says")
        sn(rest, <<out::binary, s::binary>>, ulen)

      _ ->
        bad("snappy: literal runs past the input")
    end
  end

  ## Snappy, first pass: byte-by-byte match copies

  def snappy_first_pass(src) do
    {ulen, rest} = preamble(src)
    finish(fp(rest, <<>>, ulen), ulen)
  end

  defp fp(<<>>, out, _), do: out

  defp fp(<<l6::6, 0::2, rest::binary>>, out, ulen) when l6 < 60,
    do: fplit(rest, l6 + 1, out, ulen)

  defp fp(<<60::6, 0::2, l, rest::binary>>, out, ulen), do: fplit(rest, l + 1, out, ulen)

  defp fp(<<61::6, 0::2, l::little-16, rest::binary>>, out, ulen),
    do: fplit(rest, l + 1, out, ulen)

  defp fp(<<62::6, 0::2, l::little-24, rest::binary>>, out, ulen),
    do: fplit(rest, l + 1, out, ulen)

  defp fp(<<63::6, 0::2, l::little-32, rest::binary>>, out, ulen),
    do: fplit(rest, l + 1, out, ulen)

  defp fp(<<hi::3, l3::3, 1::2, lo, rest::binary>>, out, ulen),
    do: fp(rest, bytecopy(out, bor(bsl(hi, 8), lo), l3 + 4, ulen), ulen)

  defp fp(<<l6::6, 2::2, off::little-16, rest::binary>>, out, ulen),
    do: fp(rest, bytecopy(out, off, l6 + 1, ulen), ulen)

  defp fp(<<l6::6, 3::2, off::little-32, rest::binary>>, out, ulen),
    do: fp(rest, bytecopy(out, off, l6 + 1, ulen), ulen)

  defp fp(_, _, _), do: bad("snappy: truncated element header")

  defp fplit(rest, l, out, ulen) do
    case rest do
      <<s::binary-size(^l), rest::binary>> ->
        if byte_size(out) + l > ulen, do: bad("snappy: output longer than the preamble says")
        fp(rest, <<out::binary, s::binary>>, ulen)

      _ ->
        bad("snappy: literal runs past the input")
    end
  end

  ## Snappy, positional: read the input by index instead of matching the rest

  def snappy_positional(src) do
    {ulen, rest} = preamble(src)
    finish(pos(rest, 0, byte_size(rest), <<>>, ulen), ulen)
  end

  defp pos(_src, ip, n, out, _) when ip >= n, do: out

  defp pos(src, ip, n, out, ulen) do
    tag = :binary.at(src, ip)
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

    if ip + hdr > n, do: bad("snappy: truncated element header")
    field = fn k -> :binary.decode_unsigned(binary_part(src, ip + 1, k), :little) end

    case t do
      0 ->
        l = if l6 < 60, do: l6 + 1, else: field.(l6 - 59) + 1
        if ip + hdr + l > n, do: bad("snappy: literal runs past the input")
        if byte_size(out) + l > ulen, do: bad("snappy: output longer than the preamble says")
        pos(src, ip + hdr + l, n, <<out::binary, binary_part(src, ip + hdr, l)::binary>>, ulen)

      1 ->
        off = bor(bsl(bsr(tag, 5), 8), :binary.at(src, ip + 1))
        pos(src, ip + 2, n, copy(out, off, band(l6, 7) + 4, ulen), ulen)

      2 ->
        pos(src, ip + 3, n, copy(out, field.(2), l6 + 1, ulen), ulen)

      3 ->
        pos(src, ip + 5, n, copy(out, field.(4), l6 + 1, ulen), ulen)
    end
  end

  ## LZ4, optimised

  def lz4(src, max_out) do
    if byte_size(src) == 0, do: bad("lz4: empty input")
    lz(src, <<>>, max_out, &copy/4)
  end

  def lz4_first_pass(src, max_out) do
    if byte_size(src) == 0, do: bad("lz4: empty input")
    lz(src, <<>>, max_out, &bytecopy/4)
  end

  defp lz(<<token, rest::binary>>, out, max, cp) do
    {lit, rest} = if token >= 0xF0, do: ext(rest, 15), else: {bsr(token, 4), rest}

    case rest do
      <<s::binary-size(^lit), rest::binary>> ->
        if byte_size(out) + lit > max, do: bad("lz4: output longer than max_out")
        out = <<out::binary, s::binary>>

        case rest do
          <<>> ->
            out

          <<off::little-16, rest::binary>> ->
            ml = band(token, 15)
            {ml, rest} = if ml == 15, do: ext(rest, 19), else: {ml + 4, rest}
            lz(rest, cp.(out, off, ml, max), max, cp)

          _ ->
            bad("lz4: truncated match offset")
        end

      _ ->
        bad("lz4: literals run past the input")
    end
  end

  defp lz(<<>>, _, _, _), do: bad("lz4: block ends after a match, not literals")

  defp ext(<<255, rest::binary>>, acc), do: ext(rest, acc + 255)
  defp ext(<<b, rest::binary>>, acc), do: {acc + b, rest}
  defp ext(<<>>, _), do: bad("lz4: truncated length")

  ## LZ4, positional

  def lz4_positional(src, max_out) do
    if byte_size(src) == 0, do: bad("lz4: empty input")
    lzp(src, 0, byte_size(src), <<>>, max_out)
  end

  defp lzp(src, ip, n, out, max) do
    if ip >= n, do: bad("lz4: block ends after a match, not literals")
    token = :binary.at(src, ip)
    {lit, ip1} = if token >= 0xF0, do: extp(src, ip + 1, n, 15), else: {bsr(token, 4), ip + 1}
    if ip1 + lit > n, do: bad("lz4: literals run past the input")
    if byte_size(out) + lit > max, do: bad("lz4: output longer than max_out")
    out = <<out::binary, binary_part(src, ip1, lit)::binary>>
    ip2 = ip1 + lit

    if ip2 == n do
      out
    else
      if ip2 + 2 > n, do: bad("lz4: truncated match offset")
      <<off::little-16>> = binary_part(src, ip2, 2)
      ml = band(token, 15)
      {ml, ip3} = if ml == 15, do: extp(src, ip2 + 2, n, 19), else: {ml + 4, ip2 + 2}
      lzp(src, ip3, n, copy(out, off, ml, max), max)
    end
  end

  defp extp(_src, i, n, _acc) when i >= n, do: bad("lz4: truncated length")

  defp extp(src, i, n, acc) do
    case :binary.at(src, i) do
      255 -> extp(src, i + 1, n, acc + 255)
      b -> {acc + b, i + 1}
    end
  end
end

import Bitwise
alias LzSnappy.Kernels, as: K
alias LzSnappy.Elixir, as: E

# ---------------------------------------------------------------- corpus

:rand.seed(:exsss, {52, 3, 2026})
root = Path.expand("..", __DIR__)

source_text =
  (Path.wildcard(Path.join(root, "docs/**/*.md")) ++ Path.wildcard(Path.join(root, "lib/**/*.ex")))
  |> Enum.sort()
  |> Enum.map_join(&File.read!/1)

json_event = fn i ->
  levels = ~w(debug info info info warn error)
  paths = ~w(/api/users /api/orders /api/orders/items /health /api/search /api/cart)

  ~s({"ts":#{1_760_000_000_000 + i * 37 + :rand.uniform(30)},"level":"#{Enum.random(levels)}",) <>
    ~s("path":"#{Enum.random(paths)}","status":#{Enum.random([200, 200, 200, 201, 404, 500])},) <>
    ~s("user_id":#{:rand.uniform(50_000)},"duration_ms":#{Float.round(:rand.uniform() * 250, 3)},) <>
    ~s("trace":"#{Base.encode16(:rand.bytes(8), case: :lower)}"}\n)
end

binary_rows = fn rows ->
  for i <- 1..rows, into: <<>> do
    <<1_760_000_000_000 + i * 1000 + :rand.uniform(9)::little-64, :rand.uniform(400)::little-32,
      Float.round(20 + :rand.normal() * 3, 2)::float-little-64, rem(i, 7)::little-16, 0::16>>
  end
end

# a short pattern with an occasional change, then long zero runs: overlapping copies
repetitive = fn ->
  unit = String.duplicate("ABCD", 25) <> :binary.copy(<<0>>, 300) <> "x"

  Stream.repeatedly(fn ->
    if :rand.uniform(4) == 1, do: unit <> <<:rand.uniform(255)>>, else: unit
  end)
end

take = fn kind, n ->
  bin =
    case kind do
      :text ->
        String.duplicate(source_text, div(n, byte_size(source_text)) + 1)

      :json ->
        Stream.iterate(0, &(&1 + 1))
        |> Stream.map(json_event)
        |> Enum.reduce_while(<<>>, fn e, acc ->
          if byte_size(acc) >= n, do: {:halt, acc}, else: {:cont, acc <> e}
        end)

      :binary ->
        binary_rows.(div(n, 24) + 1)

      :repetitive ->
        repetitive.()
        |> Enum.reduce_while(<<>>, fn u, acc ->
          if byte_size(acc) >= n, do: {:halt, acc}, else: {:cont, acc <> u}
        end)

      :incompressible ->
        :rand.bytes(n)
    end

  binary_part(bin, 0, n)
end

kinds = [:text, :json, :binary, :repetitive, :incompressible]
sizes = [{"4 KB", 4096}, {"64 KB", 65536}, {"1 MB", 1 <<< 20}, {"4 MB", 4 <<< 20}]

corpus =
  for kind <- kinds, {label, n} <- sizes do
    d = take.(kind, n)
    {:ok, s} = :snappyer.compress(d)
    {:ok, l} = :lz4.compress(d, [])
    {:ok, lhc} = :lz4.compress(d, [:high])
    l_flex = NimbleLZ4.compress(d)
    %{kind: kind, label: label, n: n, data: d, snappy: s, lz4: l, lz4_hc: lhc, lz4_flex: l_flex}
  end

IO.puts("corpus: #{length(corpus)} blocks (5 kinds x 4 sizes), compressed sizes (snappy / lz4):")

for c <- corpus, c.label in ["64 KB", "4 MB"] do
  IO.puts(
    "  #{String.pad_trailing("#{c.kind} #{c.label}", 22)} #{byte_size(c.snappy)} / #{byte_size(c.lz4)} " <>
      "(#{Float.round(byte_size(c.lz4) / c.n * 100, 1)}% lz4)"
  )
end

# ---------------------------------------------------------------- corpus agreement

snappy_decoders = [
  {"defk", &LzSnappy.Defk.snappy_decode/1},
  {"elixir", &E.snappy/1},
  {"elixir first pass", &E.snappy_first_pass/1},
  {"elixir positional", &E.snappy_positional/1}
]

lz4_decoders = [
  {"defk", &LzSnappy.Defk.lz4_block_decode/2},
  {"elixir", &E.lz4/2},
  {"elixir first pass", &E.lz4_first_pass/2},
  {"elixir positional", &E.lz4_positional/2}
]

corpus_fail =
  for c <- corpus,
      {name, f} <- snappy_decoders,
      f.(c.snappy) != c.data,
      do: {:snappy, name, c.kind, c.label}

corpus_fail =
  corpus_fail ++
    for c <- corpus,
        stream <- [:lz4, :lz4_hc, :lz4_flex],
        {name, f} <- lz4_decoders,
        # the exact bound and a looser one (a caller that only knows a maximum)
        max <- [c.n, c.n + 100],
        f.(Map.fetch!(c, stream), max) != c.data,
        do: {stream, name, c.kind, c.label, max}

# the NIFs decode what they compressed (sanity), and nimble_lz4 decodes liblz4's blocks
nif_ok =
  Enum.all?(corpus, fn c ->
    :snappyer.decompress(c.snappy) == {:ok, c.data} and
      :lz4.uncompress(c.lz4, c.n) == {:ok, c.data} and
      NimbleLZ4.decompress(c.lz4, c.n) == {:ok, c.data}
  end)

corpus_ok = corpus_fail == [] and nif_ok

IO.puts(
  "\ncorpus agreement: #{length(corpus)} blocks x (snappy + 3 LZ4 encoders x 2 bounds) x 4 decoders: " <>
    if(corpus_ok, do: "all byte-identical", else: "FAILED #{inspect(Enum.take(corpus_fail, 5))}")
)

# ---------------------------------------------------------------- outcomes and Elixir mode

outcome = fn f ->
  try do
    {:ok, f.()}
  rescue
    e -> {:raise, e.__struct__, Exception.message(e)}
  end
end

native_vs_mode = fn name, args ->
  {outcome.(fn -> apply(K, name, args) end), outcome.(fn -> K.__defk_elixir__(name, args) end)}
end

small = Enum.filter(corpus, &(&1.n == 4096))

mode_ok =
  Enum.all?(small, fn c ->
    {a, b} = native_vs_mode.(:snappy_decode, [c.snappy])
    {x, y} = native_vs_mode.(:lz4_block_decode, [c.lz4, c.n + 16])
    a == b and x == y and a == {:ok, c.data}
  end)

IO.puts("Elixir mode vs native on the #{length(small)} 4 KB blocks, both formats: #{mode_ok}")

# hand-written malformed streams: each raises ArgumentError natively, in Elixir
# mode and in the Elixir decoder
crafted_snappy = [
  {"empty", <<>>},
  {"preamble only, length 0 (valid, empty)", <<0>>},
  {"6-byte stream claiming 4 GiB", <<0xFF, 0xFF, 0xFF, 0xFF, 0x0F, 0>>},
  {"preamble over 5 bytes", <<0x80, 0x80, 0x80, 0x80, 0x80, 0x01>>},
  {"literal past the input", <<5, 4 <<< 2, ?a, ?b>>},
  {"copy before any output", <<4, 0b000_000_01, 1>>},
  {"copy offset 0", <<5, 0, ?a, 0b000_000_01, 0>>},
  {"output longer than preamble", <<2, 0, ?a, 0b000_000_01, 1>>},
  {"output shorter than preamble", <<9, 0, ?a>>},
  {"truncated copy-4 header", <<5, 0, ?a, 0b000011_11, 1, 0>>},
  {"overlapping copy (valid)", <<9, 0, ?a, 0b000_100_01, 1>>}
]

crafted_lz4 = [
  {"empty", <<>>, 10},
  {"zero token, max 0 (valid, empty)", <<0>>, 0},
  {"literal past the input", <<0x50, ?a, ?b>>, 10},
  {"offset 0", <<0x10, ?a, 0, 0, 0x10, ?b>>, 10},
  {"offset beyond output", <<0x10, ?a, 2, 0, 0x10, ?b>>, 10},
  {"ends after a match", <<0x10, ?a, 1, 0>>, 10},
  {"output above max_out", <<0x1F, ?a, 1, 0, 200, 0x00>>, 50},
  {"truncated extended length", <<0xF0, 255, 255>>, 1000},
  {"overlapping match (valid)", <<0x14, ?a, 1, 0, 0x10, ?b>>, 20}
]

crafted =
  for {label, s} <- crafted_snappy do
    {a, b} = native_vs_mode.(:snappy_decode, [s])
    c = outcome.(fn -> E.snappy(s) end)
    {"snappy " <> label, a, b, c}
  end ++
    for {label, s, max} <- crafted_lz4 do
      {a, b} = native_vs_mode.(:lz4_block_decode, [s, max])
      c = outcome.(fn -> E.lz4(s, max) end)
      a = with {:ok, {buf, len}} <- a, do: {:ok, binary_part(buf, 0, len)}
      b = with {:ok, {buf, len}} <- b, do: {:ok, binary_part(buf, 0, len)}
      {"lz4 " <> label, a, b, c}
    end

same_kind = fn
  {:ok, v}, {:ok, w} -> v == w
  {:raise, m, _}, {:raise, n, _} -> m == n
  _, _ -> false
end

crafted_ok =
  Enum.all?(crafted, fn {label, a, b, c} ->
    valid = String.contains?(label, "(valid")
    a == b and same_kind.(a, c) and (valid or match?({:raise, ArgumentError, _}, a))
  end)

IO.puts("\ncrafted malformed streams (native / Elixir mode / Elixir decoder):")

for {label, a, _b, _c} <- crafted do
  shown =
    case a do
      {:ok, v} -> "ok #{inspect(v)}"
      {:raise, m, msg} -> "#{inspect(m)} #{msg}"
    end

  IO.puts("  #{String.pad_trailing(label, 42)} #{shown}")
end

IO.puts("crafted cases agree and raise ArgumentError where malformed: #{crafted_ok}")

# ---------------------------------------------------------------- fuzz under forced yields

fuzz_seeds =
  for kind <- kinds, n <- [64, 300, 1024, 2048] do
    d = take.(kind, n)
    {:ok, s} = :snappyer.compress(d)
    {:ok, l} = :lz4.compress(d, [])
    {d, s, l}
  end

mutate = fn bin ->
  size = byte_size(bin)

  case :rand.uniform(5) do
    1 ->
      binary_part(bin, 0, :rand.uniform(size + 1) - 1)

    2 ->
      bin <> :rand.bytes(:rand.uniform(8))

    _ ->
      Enum.reduce(1..:rand.uniform(4), bin, fn _, b ->
        i = :rand.uniform(byte_size(b)) - 1
        <<pre::binary-size(^i), _, post::binary>> = b
        <<pre::binary, :rand.uniform(256) - 1, post::binary>>
      end)
  end
end

fuzz_inputs = fn which ->
  random = for _ <- 1..1500, do: :rand.bytes(:rand.uniform(301) - 1)

  mutated =
    for _ <- 1..1500 do
      {d, s, l} = Enum.random(fuzz_seeds)
      if which == :snappy, do: {mutate.(s), byte_size(d)}, else: {mutate.(l), byte_size(d)}
    end

  Enum.map(random, &{&1, :rand.uniform(2049) - 1}) ++ mutated
end

# kernel vs NIF on one input: :same, or which side accepted what the other refused
vs_nif = fn kernel, nif ->
  case {kernel, nif} do
    {{:ok, v}, {:ok, v}} -> :same
    {{:raise, _, _}, {:error, _}} -> :same
    {{:ok, _}, {:ok, _}} -> :different_value
    {{:ok, _}, {:error, _}} -> :kernel_accepts
    {{:raise, _, _}, {:ok, _}} -> :nif_accepts
  end
end

run_fuzz = fn which ->
  inputs = fuzz_inputs.(which)
  yields0 = K.__defk_stats__().yields
  K.__defk_force_yields__(true)

  results =
    try do
      for {bin, max} <- inputs do
        {native, mode, elixir, nif} =
          case which do
            :snappy ->
              {a, b} = native_vs_mode.(:snappy_decode, [bin])
              nif = :snappyer.decompress(bin)
              {a, b, outcome.(fn -> E.snappy(bin) end), nif}

            :lz4 ->
              {a, b} = native_vs_mode.(:lz4_block_decode, [bin, max])
              nif = :lz4.uncompress(bin, max)
              {a, b, outcome.(fn -> E.lz4(bin, max) end), nif}
          end

        cut = fn
          {:ok, {buf, len}} -> {:ok, binary_part(buf, 0, len)}
          x -> x
        end

        %{
          agree: native == mode,
          own_check: match?({:ok, _}, native) or match?({:raise, ArgumentError, _}, native),
          elixir_agrees: same_kind.(cut.(native), elixir),
          nif: vs_nif.(cut.(native), nif),
          accepted: match?({:ok, _}, native)
        }
      end
    after
      K.__defk_force_yields__(false)
    end

  yields = K.__defk_stats__().yields - yields0
  {results, yields}
end

fuzz =
  for which <- [:snappy, :lz4] do
    {results, yields} = run_fuzz.(which)
    count = fn key -> Enum.count(results, & &1[key]) end
    nif = Enum.frequencies_by(results, & &1.nif)

    IO.puts(
      "\nfuzz #{which}: #{length(results)} inputs (1500 random, 1500 mutated valid), forced yields (#{yields} yields): " <>
        "native = Elixir mode on #{count.(:agree)}, own ArgumentError or ok on #{count.(:own_check)}, " <>
        "Elixir decoder agrees on #{count.(:elixir_agrees)}; accepted #{count.(:accepted)}; " <>
        "vs the NIF #{inspect(nif)}"
    )

    ok =
      count.(:agree) == length(results) and count.(:own_check) == length(results) and
        count.(:elixir_agrees) == length(results) and Map.get(nif, :different_value, 0) == 0 and
        yields > 0

    {which, ok, nif}
  end

fuzz_ok = Enum.all?(fuzz, fn {_, ok, _} -> ok end)
IO.puts("fuzz agreement (and the VM is still up): #{fuzz_ok}")

checks_ok = corpus_ok and mode_ok and crafted_ok and fuzz_ok

# ---------------------------------------------------------------- timing table

{:ok, _} = Application.ensure_all_started(:defk)
:erlang.system_flag(:schedulers_online, :erlang.system_info(:schedulers))

{load1, load5} =
  case System.cmd("uptime", []) do
    {out, 0} ->
      case Regex.run(~r/load averages?: ([\d.]+),? ([\d.]+)/, out) do
        [_, a, b] -> {a, b}
        _ -> {"?", "?"}
      end

    _ ->
      {"?", "?"}
  end

# interleaved best-of: every round runs each side once (reps calls per sample)
best_of = fn sides, rounds, reps ->
  init = Map.new(sides, fn {k, _} -> {k, :infinity} end)

  Enum.reduce(1..rounds, init, fn _, best ->
    Enum.reduce(sides, best, fn {k, f}, best ->
      :erlang.garbage_collect()
      {t, _} = :timer.tc(fn -> Enum.each(1..reps, fn _ -> f.() end) end)
      Map.update!(best, k, &min(&1, t / reps))
    end)
  end)
end

fmt = fn
  nil -> "-"
  us when us >= 1000 -> "#{Float.round(us / 1000, 2)} ms"
  us -> "#{Float.round(us / 1, 1)} us"
end

IO.puts(
  "\nbest of interleaved rounds, load average #{load1} / #{load5} (1 / 5 min)" <>
    if(nif_opt?, do: ", NIFs rebuilt with -O3/-O2", else: ", NIFs as installed (-O0, see header)")
)

IO.puts(
  "  #{String.pad_trailing("block", 22)}" <>
    Enum.map_join(
      ~w(snappy:fp snappy:elixir snappy:defk snappyer lz4:fp lz4:elixir lz4:defk lz4_erl nimble_lz4),
      &String.pad_leading(&1, 12)
    )
)

for c <- corpus, c.kind == :json or c.label in ["64 KB", "4 MB"] do
  reps = if c.n <= 4096, do: 50, else: if(c.n <= 65536, do: 5, else: 1)
  rounds = if c.n >= 1 <<< 20, do: 4, else: 7
  fp? = c.n <= 1 <<< 20

  sides =
    [
      fp? && {:sfp, fn -> E.snappy_first_pass(c.snappy) end},
      {:se, fn -> E.snappy(c.snappy) end},
      {:sd, fn -> LzSnappy.Defk.snappy_decode(c.snappy) end},
      {:sn, fn -> :snappyer.decompress(c.snappy) end},
      fp? && {:lfp, fn -> E.lz4_first_pass(c.lz4, c.n) end},
      {:le, fn -> E.lz4(c.lz4, c.n) end},
      {:ld, fn -> LzSnappy.Defk.lz4_block_decode(c.lz4, c.n) end},
      {:ln, fn -> :lz4.uncompress(c.lz4, c.n) end},
      {:lf, fn -> NimbleLZ4.decompress(c.lz4, c.n) end}
    ]
    |> Enum.filter(& &1)

  t = best_of.(sides, rounds, reps)

  IO.puts(
    "  #{String.pad_trailing("#{c.kind} #{c.label}", 22)}" <>
      Enum.map_join(
        [:sfp, :se, :sd, :sn, :lfp, :le, :ld, :ln, :lf],
        &String.pad_leading(fmt.(t[&1]), 12)
      )
  )
end

# the Elixir variants on the 64 KB JSON block
c64 = Enum.find(corpus, &(&1.kind == :json and &1.n == 65536))

variants =
  best_of.(
    [
      {"snappy first pass", fn -> E.snappy_first_pass(c64.snappy) end},
      {"snappy optimised", fn -> E.snappy(c64.snappy) end},
      {"snappy positional", fn -> E.snappy_positional(c64.snappy) end},
      {"lz4 first pass", fn -> E.lz4_first_pass(c64.lz4, 65536) end},
      {"lz4 optimised", fn -> E.lz4(c64.lz4, 65536) end},
      {"lz4 positional", fn -> E.lz4_positional(c64.lz4, 65536) end}
    ],
    7,
    5
  )

IO.puts("\nElixir variants, 64 KB JSON block:")
for {k, us} <- Enum.sort(variants), do: IO.puts("  #{String.pad_trailing(k, 20)} #{fmt.(us)}")

# ---------------------------------------------------------------- reports

json = fn n -> Enum.find(corpus, &(&1.kind == :json and &1.n == n)) end
c4m = json.(4 <<< 20)

sweep = fn fmt_ ->
  for {label, n} <- sizes do
    c = json.(n)

    case fmt_ do
      :snappy ->
        {label, fn -> E.snappy(c.snappy) end, fn -> LzSnappy.Defk.snappy_decode(c.snappy) end}

      :lz4 ->
        {label, fn -> E.lz4(c.lz4, n) end, fn -> LzSnappy.Defk.lz4_block_decode(c.lz4, n) end}
    end
  end
end

nif_label = fn name ->
  if nif_opt?, do: "#{name}, rebuilt -O3/-O2", else: "#{name}, as installed (-O0)"
end

Defk.Bench.report(
  name: "snappy_decode",
  expected: :good,
  baseline: :optimized,
  realistic_size: "64 KB block (JSON-like events)",
  runs: 9,
  elixir: fn -> E.snappy(c64.snappy) end,
  defk: fn -> LzSnappy.Defk.snappy_decode(c64.snappy) end,
  native: {fn -> :snappyer.decompress(c64.snappy) end, nif_label.("snappyer 1.2.10")},
  check: fn -> checks_ok and LzSnappy.Defk.snappy_decode(c64.snappy) == E.snappy(c64.snappy) end,
  sweep: sweep.(:snappy),
  responsiveness: [
    elixir: fn -> E.snappy(c4m.snappy) end,
    defk: fn -> LzSnappy.Defk.snappy_decode(c4m.snappy) end,
    native: fn -> :snappyer.decompress(c4m.snappy) end
  ],
  reason:
    "a tag loop with checked copies beats appending binary_part copies in Elixir; the -O2 snappy C++ library is faster than the kernel"
)

Defk.Bench.report(
  name: "lz4_block_decode",
  expected: :good,
  baseline: :optimized,
  realistic_size: "64 KB block (JSON-like events)",
  runs: 9,
  elixir: fn -> E.lz4(c64.lz4, 65536) end,
  defk: fn -> LzSnappy.Defk.lz4_block_decode(c64.lz4, 65536) end,
  native: {fn -> :lz4.uncompress(c64.lz4, 65536) end, nif_label.("lz4_erl 0.2.4 (liblz4 1.7.5)")},
  check: fn ->
    checks_ok and LzSnappy.Defk.lz4_block_decode(c64.lz4, 65536) == E.lz4(c64.lz4, 65536)
  end,
  sweep: sweep.(:lz4),
  responsiveness: [
    elixir: fn -> E.lz4(c4m.lz4, c4m.n) end,
    defk: fn -> LzSnappy.Defk.lz4_block_decode(c4m.lz4, c4m.n) end,
    native: fn -> :lz4.uncompress(c4m.lz4, c4m.n) end
  ],
  reason:
    "a sequence loop with checked copies beats appending binary_part copies in Elixir; an optimised liblz4 build is several times faster than the kernel"
)
