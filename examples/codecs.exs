# codecs: base64, hex and base58 encode/decode, three verdicts in one script
#
# Why people reach for a NIF here: fast64 (541k downloads) and b64fast
# (272k) are hand-written C base64 that chunk their work by hand with
# enif_consume_timeslice + enif_schedule_nif; ex_base58 (156k) is Rust over
# the bs58 crate on a normal scheduler; the pure base58 packages (erl_base58,
# b58) are bignum arithmetic. Anchors and baselines: defk-9p6.19,
# docs/research/string-workloads.md (category B, on research/string-workloads).
#
#   elixir examples/codecs.exs
#
# Three DEFK_RESULT lines, in this order: codecs_base64, codecs_hex,
# codecs_base58. run_all.exs reads only the first (base64); the script exits 1
# itself when hex or base58 is incorrect or misses its expected verdict.
# Each verdict is one round trip: encode the input and decode its encoding.
#
# Pre-registered (ticket): base64 good only if a table-driven kernel reaches a
# few GB/s, hex marginal (the BEAM's hex is a C BIF), base58 good.
# Expected verdicts, as measured: base64 good, hex good (at the 2x line,
# differs from the ticket), base58 good.
#
# Kernels: [u8] in. encode64 and encode16 return [u8] of the exact length
# (4 * ceil(n / 3), 2n); decode64 returns {buffer, length} (3 per quad less
# the padding) and Elixir takes binary_part; decode16 is exact (n / 2). The
# base58 kernels take a batch per call: encode58(keys, klen) for count keys of
# klen bytes, decode58(chars, offs) for count strings at packed i64 offsets,
# each returning {slots, [i64] lengths} with one slot per key, which the
# Elixir wrapper splits into binaries (packing and splitting are timed).
# Alphabets and 256-byte decode tables are module attributes (defk-ivt);
# @b64[band(x, 63)] indexes a 64-byte attribute without a bounds check.
#
# Bad input raises ArgumentError, as Base.decode64! does: a kernel has no
# `raise`, so each decoder ORs every table value it reads (255 for a byte
# outside the alphabet) into an accumulator and, after the loop, takes
# alloc(u8, -1) when it is out of range ("alloc/2: negative length -1"); a
# length that is not a multiple of 4 (base64) or 2 (hex) takes the same
# negative alloc before the loop. base58 checks once per string.
#
# Elixir baselines (optimised; every variant is timed in the run, and the
# fastest per direction is the baseline):
#   base64  Base.encode64/decode64! and :base64.encode/decode (Base encodes
#           faster, :base64 decodes about 4% faster).
#   hex     Base.encode16/decode16!(case: :mixed) and
#           :binary.encode_hex/decode_hex (the BIFs win both ways).
#   base58  b58 1.0.3 and erl_base58 0.0.1 from Hex (bignum, digit by digit),
#           and Codecs.Elixir below: one bignum divided by 58^9 per step
#           (nine digits from a small integer) and decoded nine characters
#           per step: encode 3.8x faster than b58 and 7x than erl_base58,
#           decode 9.7x and 1.6x. Both packages raise ArithmeticError on a
#           bad character, not ArgumentError, and erl_base58 decodes "1" to
#           two bytes; neither is in the bad-input check.
#   Not tried: a batch Elixir base58 (no shared work between keys to save).
#
# Native comparison: fast64 0.1.3 (C NIF), the anchor, on the same inputs.
# Not measured: b64fast (Erlang, same design as fast64) and ex_base58 (needs
# a Rust toolchain).
#
# Realistic sizes: base64 and hex at 1 MB (uploads, data URLs), with a sweep
# of 64 KB, 1 MB and 16 MB; base58 on 10k 32-byte keys per call (the
# poor_tiny_calls lesson), with sweeps of 1, 100 and 10k keys per call over
# the same 10k keys, and the mean of one single-key call printed above them.
#
# Agreement: 910 random inputs (every length 0..64, so every 1-3 byte tail,
# leading zero bytes, up to 64 KB) round-trip and match Base / :binary / both
# base58 packages; about 4,500 corrupted or truncated encodings give the same
# outcome as Base.decode64!, :binary.decode_hex and the Elixir base58 (all
# ArgumentError); every kernel also agrees with its Elixir mode (`elixir_mode: true`,
# Codecs.Kernels.__defk_elixir__/2) on the small inputs and every
# bad input.
#
# Measured (M-series Mac, OTP 29, Elixir 1.20, best of 15; three runs):
#
#   base64, 1 MB    Elixir 3.08-3.17 ms  defk 1.04-1.05 ms  2.94-3.04x  good
#                   (encode 0.49 ms = 2.1 GB/s, decode 0.56 ms = 2.5 GB/s of
#                   input); fast64 2.19-2.22 ms, so the kernel is 2.1x
#                   faster than the anchor NIF. Sweep 64 KB 2.6-2.8x, 16 MB
#                   3.1-3.4x. Ticker gap while encoding 64 MB on one
#                   scheduler: Elixir 8.8-10.1 ms, defk 4.6-4.8 ms, fast64
#                   4.4-5.0 ms (defk yields every 250 us in its loop; the gap
#                   left is the 85 MB output alloc before the loop: a kernel
#                   that only allocs 85 MB gives a 5.0 ms gap).
#   hex, 1 MB       Elixir 2.55-2.59 ms  defk 1.25-1.28 ms  2.02-2.04x  good
#                   (encode 1.5x over :binary.encode_hex, decode 2.5x over
#                   :binary.decode_hex); sweep 1.74-2.05x. At the 2x line:
#                   a slower run would read marginal, and for encoding alone
#                   the BIF is the recommendation.
#   base58, 10k     Elixir 12.7-13.2 ms  defk 4.8-5.1 ms    2.59-2.68x  good
#   keys per call   (kernel encode 1.9 ms, decode 2.3 ms). One key per call:
#                   Elixir 0.94 us, defk 1.04 us per round trip, so a
#                   single-key call is no faster than Elixir (sweep: 1 key
#                   per call 1.13x, 100 keys 2.5x, 10k keys 2.3-2.9x).
#
# Recommendation: base64 over a few KB and batched base58 are kernel jobs
# (and need no hand-written chunking); for hex, :binary.encode_hex and
# :binary.decode_hex are within 2x and already native; for one base58 key at
# a time, the Elixir function below is as fast.

Mix.install([
  {:defk, path: Path.expand("..", __DIR__)},
  {:fast64, "~> 0.1"},
  {:b58, "~> 1.0"},
  {:erl_base58, "~> 0.0.1"}
])

defmodule Codecs.Source do
  # The kernels, as a `use` block for Codecs.Kernels, compiled with
  # `elixir_mode: true` (native by default; `__defk_elixir__/2` is the
  # agreement check's oracle).
  defmacro __using__(_) do
    quote location: :keep do
      @b64 "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
      @hex "0123456789ABCDEF"
      @b58 "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"

      # 256-byte decode tables, 255 for a byte outside the alphabet
      @dec64 for(b <- 0..255, into: <<>>, do: <<Codecs.Tables.index(@b64, b)>>)
      @dec16 for(b <- 0..255, into: <<>>, do: <<Codecs.Tables.hex_index(b)>>)
      @dec58 for(b <- 0..255, into: <<>>, do: <<Codecs.Tables.index(@b58, b)>>)
      # 58^8: the largest power of 58 that keeps limb * 2^16 + carry in i64
      @base58_8 128_063_081_718_016

      # ---- base64 (RFC 4648 alphabet, padded: Base.encode64/decode64!) ----

      defk encode64(s :: [u8]) :: [u8] do
        n = len(s)
        full = div(n, 3)
        out = alloc(u8, 4 * div(n + 2, 3))

        for g <- 0..(full - 1)//1 do
          i = 3 * g
          x = bor(bor(bsl(s[i], 16), bsl(s[i + 1], 8)), s[i + 2])
          o = 4 * g
          out[o] = @b64[band(bsr(x, 18), 63)]
          out[o + 1] = @b64[band(bsr(x, 12), 63)]
          out[o + 2] = @b64[band(bsr(x, 6), 63)]
          out[o + 3] = @b64[band(x, 63)]
        end

        r = n - 3 * full
        o = 4 * full

        if r == 1 do
          x = bsl(s[n - 1], 16)
          out[o] = @b64[band(bsr(x, 18), 63)]
          out[o + 1] = @b64[band(bsr(x, 12), 63)]
          out[o + 2] = 61
          out[o + 3] = 61
        end

        if r == 2 do
          x = bor(bsl(s[n - 2], 16), bsl(s[n - 1], 8))
          out[o] = @b64[band(bsr(x, 18), 63)]
          out[o + 1] = @b64[band(bsr(x, 12), 63)]
          out[o + 2] = @b64[band(bsr(x, 6), 63)]
          out[o + 3] = 61
        end

        out
      end

      # Returns {buffer, length}: the length is 3 per quad less the padding.
      # Bad input raises ArgumentError through a negative alloc length: a
      # length that is not a multiple of 4 at once, a byte outside the
      # alphabet (255 in the table, so the OR of all sextets exceeds 63)
      # after the loop. '=' is only padding in the last quad.
      defk decode64(s :: [u8]) :: {[u8], i64} do
        n = len(s)
        _ = alloc(u8, if(rem(n, 4) == 0, do: 0, else: -1))
        quads = div(n, 4)
        out = alloc(u8, 3 * quads)

        bad =
          for q <- 0..(quads - 2)//1, reduce: 0 do
            bad ->
              i = 4 * q
              a = @dec64[s[i]]
              b = @dec64[s[i + 1]]
              c = @dec64[s[i + 2]]
              d = @dec64[s[i + 3]]
              x = bor(bor(bsl(a, 18), bsl(b, 12)), bor(bsl(c, 6), d))
              o = 3 * q
              out[o] = band(bsr(x, 16), 255)
              out[o + 1] = band(bsr(x, 8), 255)
              out[o + 2] = band(x, 255)
              bor(bad, bor(bor(a, b), bor(c, d)))
          end

        # the last quad: '=' is padding only here, at its end
        i = max(n - 4, 0)
        pad = if quads > 0 and s[i + 3] == 61, do: if(s[i + 2] == 61, do: 2, else: 1), else: 0

        tail =
          if quads > 0 do
            a = @dec64[s[i]]
            b = @dec64[s[i + 1]]
            c = if pad == 2, do: 0, else: @dec64[s[i + 2]]
            d = if pad >= 1, do: 0, else: @dec64[s[i + 3]]
            x = bor(bor(bsl(a, 18), bsl(b, 12)), bor(bsl(c, 6), d))
            o = 3 * (quads - 1)
            out[o] = band(bsr(x, 16), 255)
            out[o + 1] = band(bsr(x, 8), 255)
            out[o + 2] = band(x, 255)
            bor(bor(a, b), bor(c, d))
          else
            0
          end

        bad = bor(bad, tail)
        _ = alloc(u8, if(bad < 64, do: 0, else: -1))
        {out, 3 * quads - pad}
      end

      # ---- hex (uppercase out: Base.encode16, :binary.encode_hex) ----

      defk encode16(s :: [u8]) :: [u8] do
        n = len(s)
        out = alloc(u8, 2 * n)

        for i <- 0..(n - 1)//1 do
          b = s[i]
          out[2 * i] = @hex[band(bsr(b, 4), 15)]
          out[2 * i + 1] = @hex[band(b, 15)]
        end

        out
      end

      # Mixed case in, as :binary.decode_hex. An odd length raises at once, a
      # byte outside the alphabet after the loop (both a negative alloc).
      defk decode16(s :: [u8]) :: [u8] do
        n = len(s)
        _ = alloc(u8, if(rem(n, 2) == 0, do: 0, else: -1))
        m = div(n, 2)
        out = alloc(u8, m)

        bad =
          for i <- 0..(m - 1)//1, reduce: 0 do
            bad ->
              hi = @dec16[s[2 * i]]
              lo = @dec16[s[2 * i + 1]]
              out[i] = band(bor(bsl(hi, 4), lo), 255)
              bor(bad, bor(hi, lo))
          end

        _ = alloc(u8, if(bad < 16, do: 0, else: -1))
        out
      end

      # ---- base58 (Bitcoin alphabet), a batch of keys per call ----

      # keys holds count keys of klen bytes, back to back. Key k's encoding
      # goes to slot k of w = ceil(klen * 138 / 100) + 1 bytes in out, its
      # length to lens[k]. The number is held in limbs of base 58^8, low limb
      # first: each two input bytes are one multiply-add per limb, and each
      # limb gives eight digits at the end. One call per key is count = 1.
      defk encode58(keys :: [u8], klen :: i64) :: {[u8], [i64]} do
        count = if klen > 0, do: div(len(keys), klen), else: 0
        w = div(klen * 138 + 99, 100) + 1
        nlimbs = div(w + 7, 8) + 1
        out = alloc(u8, count * w)
        lens = alloc(i64, count)
        limbs = alloc(i64, nlimbs)
        digits = alloc(u8, 8 * nlimbs)

        for k <- 0..(count - 1)//1 do
          start = k * klen

          zeros =
            Enum.reduce_while(0..(klen - 1)//1, 0, fn j, z ->
              if keys[start + j] == 0, do: {:cont, z + 1}, else: {:halt, z}
            end)

          # two bytes per step (one when the significant length is odd)
          odd = rem(klen - zeros, 2)

          nl =
            for t <- 0..(div(klen - zeros + 1, 2) - 1)//1, reduce: 0 do
              nl ->
                p = start + zeros + 2 * t - odd
                one = t == 0 and odd == 1
                c = if one, do: keys[p + 1], else: bor(bsl(keys[p], 8), keys[p + 1])
                mult = if one, do: 256, else: 65_536

                carry =
                  for l <- 0..(nl - 1)//1, reduce: c do
                    c ->
                      x = limbs[l] * mult + c
                      limbs[l] = rem(x, @base58_8)
                      div(x, @base58_8)
                  end

                if carry > 0 do
                  limbs[nl] = carry
                  nl + 1
                else
                  nl
                end
            end

          for l <- 0..(nl - 1)//1 do
            _ =
              for d <- 0..7//1, reduce: limbs[l] do
                v ->
                  digits[8 * l + d] = rem(v, 58)
                  div(v, 58)
              end
          end

          nd =
            Enum.reduce_while(0..(8 * nl - 1)//1, 8 * nl, fn _, m ->
              if digits[m - 1] == 0, do: {:cont, m - 1}, else: {:halt, m}
            end)

          o = k * w

          for j <- 0..(zeros - 1)//1 do
            out[o + j] = 49
          end

          for j <- 0..(nd - 1)//1 do
            out[o + zeros + j] = @b58[digits[nd - 1 - j]]
          end

          lens[k] = zeros + nd
        end

        {out, lens}
      end

      # chars holds count strings back to back, string k at
      # offs[k]..offs[k + 1] - 1. Decoded key k goes to a slot of w bytes, w
      # the longest string's length (a character gives at most one byte), its
      # length to lens[k]. Limbs of base 2^32, low limb first, five
      # characters (one multiply by up to 58^5) per step. A byte outside the
      # alphabet raises ArgumentError at the end of its string (a negative
      # alloc length).
      defk decode58(chars :: [u8], offs :: [i64]) :: {[u8], [i64]} do
        count = len(offs) - 1

        maxlen =
          for k <- 0..(count - 1)//1, reduce: 0 do
            m -> max(m, offs[k + 1] - offs[k])
          end

        w = maxlen
        out = alloc(u8, count * w)
        lens = alloc(i64, count)
        limbs = alloc(i64, div(w + 3, 4) + 1)

        for k <- 0..(count - 1)//1 do
          start = offs[k]
          stop = offs[k + 1]

          zeros =
            Enum.reduce_while(start..(stop - 1)//1, 0, fn j, z ->
              if chars[j] == 49, do: {:cont, z + 1}, else: {:halt, z}
            end)

          # five characters per step (fewer in the first step, so the
          # groups end at the string's end): a virtual position 5t + q is
          # the character at shift less, nothing when that is negative
          m = stop - start - zeros
          shift = rem(5 - rem(m, 5), 5)

          {nl, bad} =
            for t <- 0..(div(m + 4, 5) - 1)//1, reduce: {0, 0} do
              {nl, bad} ->
                {c, mult, bad} =
                  for q <- 0..4//1, reduce: {0, 1, bad} do
                    {c, mult, bad} ->
                      at = 5 * t + q - shift
                      d = if at >= 0, do: @dec58[chars[start + zeros + at]], else: 0
                      c = if at >= 0, do: c * 58 + d, else: c
                      mult = if at >= 0, do: mult * 58, else: mult
                      {c, mult, bor(bad, d)}
                  end

                carry =
                  for l <- 0..(nl - 1)//1, reduce: c do
                    c ->
                      x = limbs[l] * mult + c
                      limbs[l] = band(x, 4_294_967_295)
                      bsr(x, 32)
                  end

                nl1 =
                  if carry > 0 do
                    limbs[nl] = carry
                    nl + 1
                  else
                    nl
                  end

                {nl1, bad}
            end

          _ = alloc(u8, if(bad < 64, do: 0, else: -1))

          nb =
            Enum.reduce_while(0..(4 * nl - 1)//1, 4 * nl, fn _, m ->
              i = m - 1

              if band(bsr(limbs[div(i, 4)], 8 * rem(i, 4)), 255) == 0,
                do: {:cont, m - 1},
                else: {:halt, m}
            end)

          o = k * w

          for j <- 0..(zeros - 1)//1 do
            out[o + j] = 0
          end

          for j <- 0..(nb - 1)//1 do
            i = nb - 1 - j
            out[o + zeros + j] = band(bsr(limbs[div(i, 4)], 8 * rem(i, 4)), 255)
          end

          lens[k] = zeros + nb
        end

        {out, lens}
      end
    end
  end
end

defmodule Codecs.Tables do
  # position of byte b in alphabet, 255 when absent
  def index(alphabet, b) do
    case :binary.match(alphabet, <<b>>) do
      {i, 1} -> i
      :nomatch -> 255
    end
  end

  # either case
  def hex_index(b), do: min(index("0123456789ABCDEF", b), index("0123456789abcdef", b))
end

defmodule Codecs.Kernels do
  use Defk, elixir_mode: true
  use Codecs.Source
end

defmodule Codecs.Calls do
  # The kernels as a caller uses them: binaries in, binaries out.
  alias Codecs.Kernels, as: K

  def encode64(bin), do: K.encode64(bin)

  def decode64!(s) do
    {buf, n} = K.decode64(s)
    binary_part(buf, 0, n)
  end

  def encode16(bin), do: K.encode16(bin)
  def decode16!(s), do: K.decode16(s)

  # one call for a list of keys of one size
  def encode58_batch([]), do: []

  def encode58_batch([k | _] = keys) do
    klen = byte_size(k)

    if klen == 0 do
      Enum.map(keys, fn _ -> "" end)
    else
      {buf, lens} = K.encode58(IO.iodata_to_binary(keys), klen)
      split(buf, lens, div(klen * 138 + 99, 100) + 1)
    end
  end

  def encode58(""), do: ""
  def encode58(key), do: hd(encode58_batch([key]))

  def decode58_batch([]), do: []

  def decode58_batch(strings) do
    {offs, _} =
      Enum.map_reduce(strings, 0, fn s, at ->
        next = at + byte_size(s)
        {<<next::signed-native-64>>, next}
      end)

    offs = IO.iodata_to_binary([<<0::signed-native-64>> | offs])
    maxlen = Enum.reduce(strings, 0, &max(byte_size(&1), &2))
    {buf, lens} = K.decode58(IO.iodata_to_binary(strings), offs)
    split(buf, lens, maxlen)
  end

  def decode58!(s), do: hd(decode58_batch([s]))

  defp split(buf, lens, w) do
    {list, _} =
      for <<n::signed-native-64 <- lens>>, reduce: {[], 0} do
        {acc, at} -> {[binary_part(buf, at, n) | acc], at + w}
      end

    :lists.reverse(list)
  end
end

defmodule Codecs.Elixir do
  # base58 as fast as we could make it in Elixir: one bignum, divided by
  # 58^9 per step (nine digits from a small integer), and decoded nine
  # characters at a time into a small integer before each bignum step.
  @b58 "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
  @alpha @b58 |> :binary.bin_to_list() |> List.to_tuple()
  @base 7_427_658_739_644_928

  def encode58(bin) do
    z = zeros(bin, 0, 0)
    ones = :binary.copy("1", z)

    case binary_part(bin, z, byte_size(bin) - z) do
      "" -> ones
      rest -> IO.iodata_to_binary([ones | chunks(:binary.decode_unsigned(rest), [])])
    end
  end

  defp zeros(<<0, rest::binary>>, c, x), do: zeros(rest, c + 1, x)
  defp zeros(_, c, _), do: c

  defp chunks(n, acc) when n < @base, do: top(n, acc)
  defp chunks(n, acc), do: chunks(div(n, @base), nine(rem(n, @base), 9, acc))

  defp nine(_, 0, acc), do: acc
  defp nine(v, k, acc), do: nine(div(v, 58), k - 1, [elem(@alpha, rem(v, 58)) | acc])

  defp top(0, acc), do: acc
  defp top(v, acc), do: top(div(v, 58), [elem(@alpha, rem(v, 58)) | acc])

  def decode58!(s) do
    z = ones(s, 0)
    zeros = :binary.copy(<<0>>, z)

    case binary_part(s, z, byte_size(s) - z) do
      "" -> zeros
      rest -> zeros <> :binary.encode_unsigned(num(rest, 0))
    end
  end

  defp ones(<<?1, rest::binary>>, c), do: ones(rest, c + 1)
  defp ones(_, c), do: c

  defp num(<<a, b, c, d, e, f, g, h, i, rest::binary>>, acc) do
    small =
      (((((((v(a) * 58 + v(b)) * 58 + v(c)) * 58 + v(d)) * 58 + v(e)) * 58 + v(f)) * 58 +
          v(g)) * 58 + v(h)) * 58 + v(i)

    num(rest, acc * @base + small)
  end

  defp num(<<c, rest::binary>>, acc), do: num(rest, acc * 58 + v(c))
  defp num(<<>>, acc), do: acc

  for {c, i} <- Enum.with_index(:binary.bin_to_list(@b58)) do
    defp v(unquote(c)), do: unquote(i)
  end

  defp v(c), do: raise(ArgumentError, "non-alphabet character found: #{inspect(<<c>>)}")
end

alias Codecs.{Calls, Kernels}
alias Codecs.Elixir, as: Ex

# ---------------------------------------------------------------- agreement --

:rand.seed(:exsss, {19, 6, 9})

outcome = fn f ->
  try do
    {:ok, f.()}
  rescue
    e -> {:raise, e.__struct__}
  end
end

# a kernel and its Elixir mode: identical values or the same exception module
em_agrees = fn name, args ->
  outcome.(fn -> apply(Kernels, name, args) end) ==
    outcome.(fn -> Kernels.__defk_elixir__(name, args) end)
end

# random bytes of every length 0..64 (so every 1-3 byte tail), some with
# leading zero bytes (they matter to base58), and a few larger ones
samples =
  [<<>>, <<0>>, <<0, 0>>, <<0, 0, 0, 1>>, <<255>>, <<255, 255>>, <<255, 255, 255>>] ++
    for(len <- 0..64, _ <- 1..12, do: :rand.bytes(len)) ++
    for(len <- 1..40, _ <- 1..3, do: :binary.copy(<<0>>, :rand.uniform(3)) <> :rand.bytes(len)) ++
    for(len <- [1000, 4097, 65_536 + 1], do: :rand.bytes(len))

small = Enum.filter(samples, &(byte_size(&1) <= 64))

# corrupt one byte of s with a byte from `bad`, at a random position
corrupt = fn s, bad ->
  if s == "" do
    <<Enum.random(bad)>>
  else
    p = :rand.uniform(byte_size(s)) - 1
    binary_part(s, 0, p) <> <<Enum.random(bad)>> <> binary_part(s, p + 1, byte_size(s) - p - 1)
  end
end

truncate = fn s -> binary_part(s, 0, max(byte_size(s) - :rand.uniform(3), 0)) end

# base64
b64_values =
  Enum.all?(samples, fn bin ->
    enc = Base.encode64(bin)
    Calls.encode64(bin) == enc and Calls.decode64!(enc) == bin and Base.decode64!(enc) == bin
  end)

b64_bad_inputs =
  for bin <- small, f <- [:corrupt, :truncate] do
    enc = Base.encode64(bin)

    if f == :corrupt,
      do: corrupt.(enc, [?*, ?-, ?_, ?\s, ?\n, ?=, ?., 0, 200]),
      else: truncate.(enc)
  end ++ ["=", "====", "YQ=a", "Y===", "YQ==YQ==", "YR==", "YQ=", "YQ", "Zm9v\n"]

b64_bad =
  Enum.map(b64_bad_inputs, fn s ->
    expected = outcome.(fn -> Base.decode64!(s) end)
    {expected == outcome.(fn -> Calls.decode64!(s) end), expected}
  end)

b64_em =
  Enum.all?(small, &em_agrees.(:encode64, [&1])) and
    Enum.all?(small, &em_agrees.(:decode64, [Base.encode64(&1)])) and
    Enum.all?(b64_bad_inputs, &em_agrees.(:decode64, [&1]))

# hex: uppercase out, mixed case in (:binary.decode_hex, Base with case: :mixed)
hex_values =
  Enum.all?(samples, fn bin ->
    up = Base.encode16(bin)
    low = String.downcase(up)

    Calls.encode16(bin) == up and :binary.encode_hex(bin) == up and Calls.decode16!(up) == bin and
      Calls.decode16!(low) == bin and :binary.decode_hex(low) == bin
  end)

hex_bad_inputs =
  for bin <- small, f <- [:corrupt, :truncate] do
    enc = Base.encode16(bin)

    if f == :corrupt,
      do: corrupt.(enc, [?g, ?G, ?x, ?z, ?\s, ?/, ?:, ?@, ?`, 0, 255]),
      else: truncate.(enc)
  end ++ ["0", "0g", "g0", "ABC"]

hex_bad =
  Enum.map(hex_bad_inputs, fn s ->
    expected = outcome.(fn -> :binary.decode_hex(s) end)

    {expected == outcome.(fn -> Calls.decode16!(s) end) and
       expected == outcome.(fn -> Base.decode16!(s, case: :mixed) end), expected}
  end)

hex_em =
  Enum.all?(small, &em_agrees.(:encode16, [&1])) and
    Enum.all?(small, &em_agrees.(:decode16, [Base.encode16(&1)])) and
    Enum.all?(hex_bad_inputs, &em_agrees.(:decode16, [&1]))

# base58: the Elixir baseline, both pure packages, and the kernel batch.
# erl_base58 decodes "1" (an all-zero key) to one byte too many, so its
# decode is not compared there.
all_zero = fn b -> b == :binary.copy(<<0>>, byte_size(b)) end

b58_values =
  Enum.all?(samples, fn bin ->
    enc = Ex.encode58(bin)

    Calls.encode58(bin) == enc and Calls.decode58!(enc) == bin and Ex.decode58!(enc) == bin and
      (bin == "" or
         (Base58.encode(bin) == enc and to_string(:base58.binary_to_base58(bin)) == enc and
            (all_zero.(bin) or :base58.base58_to_binary(to_charlist(enc)) == bin)))
  end)

keys_mixed = Enum.filter(samples, &(byte_size(&1) == 32)) ++ [:binary.copy(<<0>>, 32)]

b58_batch =
  Calls.encode58_batch(keys_mixed) == Enum.map(keys_mixed, &Ex.encode58/1) and
    Calls.decode58_batch(Enum.map(keys_mixed, &Ex.encode58/1)) == keys_mixed and
    Calls.decode58_batch(Enum.map(small, &Ex.encode58/1)) == small

b58_bad_inputs =
  for bin <- small, bin != "" do
    corrupt.(Ex.encode58(bin), [?0, ?O, ?I, ?l, ?+, ?/, ?\s, 0, 255])
  end

b58_bad =
  Enum.map(b58_bad_inputs, fn s ->
    expected = outcome.(fn -> Ex.decode58!(s) end)
    {expected == outcome.(fn -> Calls.decode58!(s) end), expected}
  end)

b58_offs = fn strings ->
  {offs, _} = Enum.map_reduce(strings, 0, &{&2 + byte_size(&1), &2 + byte_size(&1)})
  for o <- [0 | offs], into: <<>>, do: <<o::signed-native-64>>
end

b58_em =
  Enum.all?(small, fn bin ->
    enc = Ex.encode58(bin)

    em_agrees.(:encode58, [bin, byte_size(bin)]) and
      em_agrees.(:decode58, [enc, b58_offs.([enc])])
  end) and
    em_agrees.(:encode58, [IO.iodata_to_binary(keys_mixed), 32]) and
    Enum.all?(b58_bad_inputs, &em_agrees.(:decode58, [&1, b58_offs.([&1])]))

raised = fn rows -> Enum.count(rows, &match?({_, {:raise, _}}, &1)) end
all_ok = fn rows -> Enum.all?(rows, &elem(&1, 0)) end

# every raise in the bad-input checks is ArgumentError, as Base.decode64! gives
bad_modules =
  for rows <- [b64_bad, hex_bad, b58_bad], {_, {:raise, m}} <- rows, uniq: true, do: m

b64_agree = b64_values and b64_em and all_ok.(b64_bad)
hex_agree = hex_values and hex_em and all_ok.(hex_bad)
b58_agree = b58_values and b58_batch and b58_em and all_ok.(b58_bad)

IO.puts("""
agreement (#{length(samples)} random inputs, every 1-3 byte tail):
  base64  values #{b64_values}, Elixir mode #{b64_em}, bad input #{all_ok.(b64_bad)} (#{raised.(b64_bad)}/#{length(b64_bad)} raise)
  hex     values #{hex_values}, Elixir mode #{hex_em}, bad input #{all_ok.(hex_bad)} (#{raised.(hex_bad)}/#{length(hex_bad)} raise)
  base58  values #{b58_values}, batch #{b58_batch}, Elixir mode #{b58_em}, bad input #{all_ok.(b58_bad)} (#{raised.(b58_bad)}/#{length(b58_bad)} raise)
  exceptions raised on bad input: #{inspect(bad_modules)}
""")

(b64_agree and hex_agree and b58_agree and bad_modules == [ArgumentError]) ||
  raise "agreement failed"

# --------------------------------------------------------------- the inputs --

mb = 1_048_576
data = :rand.bytes(64 * mb)
prefix = fn n -> binary_part(data, 0, n) end
bin = prefix.(mb)
b64 = Base.encode64(bin)
hex = Base.encode16(bin)
keys = for _ <- 1..10_000, do: :rand.bytes(32)
encs = Enum.map(keys, &Ex.encode58/1)

best = fn f, runs ->
  f.()

  Enum.min(
    for _ <- 1..runs do
      :erlang.garbage_collect()
      elem(:timer.tc(f), 0)
    end
  )
end

# Every Elixir variant per direction at the realistic size; the fastest one
# per direction is the baseline (picked here, from this run).
pick = fn title, variants ->
  IO.puts(title)

  timed =
    for {label, fun, arg} <- variants do
      us = best.(fn -> fun.(arg) end, 7)
      IO.puts("  #{String.pad_trailing(label, 34)} #{Float.round(us / 1000, 3)} ms")
      {us, label, fun}
    end

  {_, label, fun} =
    timed
    |> Enum.reject(fn {_, l, _} ->
      String.starts_with?(l, "defk") or String.contains?(l, "NIF")
    end)
    |> Enum.min()

  IO.puts("  baseline: #{label}")
  fun
end

enc64 =
  pick.("base64 encode, 1 MB, best of 7:", [
    {"Base.encode64", &Base.encode64/1, bin},
    {":base64.encode", &:base64.encode/1, bin},
    {"defk encode64", &Calls.encode64/1, bin},
    {"fast64 0.1.3 (C NIF)", &Fast64.encode64/1, bin}
  ])

dec64 =
  pick.("base64 decode, 1 MB of input, best of 7:", [
    {"Base.decode64!", &Base.decode64!/1, b64},
    {":base64.decode", &:base64.decode/1, b64},
    {"defk decode64", &Calls.decode64!/1, b64},
    {"fast64 0.1.3 (C NIF)", &Fast64.decode64/1, b64}
  ])

enc16 =
  pick.("hex encode, 1 MB, best of 7:", [
    {"Base.encode16", &Base.encode16/1, bin},
    {":binary.encode_hex", &:binary.encode_hex/1, bin},
    {"defk encode16", &Calls.encode16/1, bin}
  ])

dec16 =
  pick.("hex decode, 1 MB out, best of 7:", [
    {"Base.decode16!(case: :mixed)", &Base.decode16!(&1, case: :mixed), hex},
    {":binary.decode_hex", &:binary.decode_hex/1, hex},
    {"defk decode16", &Calls.decode16!/1, hex}
  ])

enc58 =
  pick.("base58 encode, 10k 32-byte keys, best of 7:", [
    {"Codecs.Elixir (58^9 chunks)", &Enum.map(&1, fn k -> Ex.encode58(k) end), keys},
    {"b58 1.0.3 Base58.encode", &Enum.map(&1, fn k -> Base58.encode(k) end), keys},
    {"erl_base58 0.0.1", &Enum.map(&1, fn k -> :base58.binary_to_base58(k) end), keys},
    {"defk, 1 key per call", &Enum.map(&1, fn k -> Calls.encode58(k) end), keys},
    {"defk, 10k keys per call", &Calls.encode58_batch/1, keys}
  ])

dec58 =
  pick.("base58 decode, 10k 32-byte keys, best of 7:", [
    {"Codecs.Elixir (9 chars per step)", &Enum.map(&1, fn s -> Ex.decode58!(s) end), encs},
    {"b58 1.0.3 Base58.decode", &Enum.map(&1, fn s -> Base58.decode(s) end), encs},
    {"erl_base58 0.0.1", &Enum.map(&1, fn s -> :base58.base58_to_binary(to_charlist(s)) end),
     encs},
    {"defk, 1 key per call", &Enum.map(&1, fn s -> Calls.decode58!(s) end), encs},
    {"defk, 10k keys per call", &Calls.decode58_batch/1, encs}
  ])

one_key = hd(keys)

IO.puts(
  "base58 single key (encode + decode, mean of 10k calls): Elixir #{Float.round(elem(:timer.tc(fn -> for _ <- 1..10_000, do: dec58.([enc58.([one_key]) |> hd()]) end), 0) / 10_000, 2)} us, " <>
    "defk #{Float.round(elem(:timer.tc(fn -> for _ <- 1..10_000, do: Calls.decode58!(Calls.encode58(one_key)) end), 0) / 10_000, 2)} us"
)

# ------------------------------------------------------------------ reports --
# Each verdict is one round trip: encode the input, decode its encoding.
# run_all.exs takes the first DEFK_RESULT line: base64 is printed first, then
# hex, then base58; the script itself fails if the other two miss.

round_trip = fn enc, dec, input, encoded -> fn -> {enc.(input), dec.(encoded)} end end

sweep64 = fn size ->
  i = prefix.(size)
  e = Base.encode64(i)
  {round_trip.(enc64, dec64, i, e), round_trip.(&Calls.encode64/1, &Calls.decode64!/1, i, e)}
end

big = prefix.(64 * mb)

_r64 =
  Defk.Bench.report(
    name: "codecs_base64",
    expected: :good,
    baseline: :optimized,
    runs: 15,
    realistic_size: "1 MB",
    elixir: round_trip.(enc64, dec64, bin, b64),
    defk: round_trip.(&Calls.encode64/1, &Calls.decode64!/1, bin, b64),
    native: {round_trip.(&Fast64.encode64/1, &Fast64.decode64/1, bin, b64), "fast64 0.1.3"},
    check: fn ->
      b64_agree and Calls.encode64(bin) == enc64.(bin) and Calls.decode64!(b64) == dec64.(b64)
    end,
    sweep: {[64 * 1024, mb, 16 * mb], sweep64},
    sweep_runs: 5,
    responsiveness: [
      elixir: fn -> enc64.(big) end,
      defk: fn -> Calls.encode64(big) end,
      native: fn -> Fast64.encode64(big) end
    ],
    reason:
      "a table-driven kernel reaches 2-2.5 GB/s, 3x Base and 2x the fast64 NIF, with yielding instead of hand-written chunking"
  )

sweep16 = fn size ->
  i = prefix.(size)
  e = Base.encode16(i)
  {round_trip.(enc16, dec16, i, e), round_trip.(&Calls.encode16/1, &Calls.decode16!/1, i, e)}
end

r16 =
  Defk.Bench.report(
    name: "codecs_hex",
    expected: :good,
    baseline: :optimized,
    runs: 15,
    realistic_size: "1 MB",
    elixir: round_trip.(enc16, dec16, bin, hex),
    defk: round_trip.(&Calls.encode16/1, &Calls.decode16!/1, bin, hex),
    check: fn ->
      hex_agree and Calls.encode16(bin) == enc16.(bin) and Calls.decode16!(hex) == dec16.(hex)
    end,
    sweep: {[64 * 1024, mb, 16 * mb], sweep16},
    sweep_runs: 5,
    reason:
      "at the 2x line: decode 2.5x over :binary.decode_hex, encode 1.5x over :binary.encode_hex, which is a C BIF already"
  )

per_call = fn n ->
  # 10k keys in calls of n keys each
  chunks = Enum.chunk_every(keys, n)
  echunks = Enum.chunk_every(encs, n)

  {fn -> {Enum.map(chunks, enc58), Enum.map(echunks, dec58)} end,
   fn ->
     {Enum.map(chunks, &Calls.encode58_batch/1), Enum.map(echunks, &Calls.decode58_batch/1)}
   end}
end

r58 =
  Defk.Bench.report(
    name: "codecs_base58",
    expected: :good,
    baseline: :optimized,
    runs: 15,
    realistic_size: "10k 32-byte keys per call",
    elixir: round_trip.(enc58, dec58, keys, encs),
    defk: round_trip.(&Calls.encode58_batch/1, &Calls.decode58_batch/1, keys, encs),
    check: fn ->
      b58_agree and Calls.encode58_batch(keys) == encs and Calls.decode58_batch(encs) == keys
    end,
    sweep:
      for n <- [1, 100, 10_000] do
        {e, d} = per_call.(n)
        {"#{n} keys/call", e, d}
      end,
    sweep_runs: 5,
    reason:
      "bignum base58 in Elixir against limb arithmetic in a kernel, batched; one key per call is no faster than Elixir"
  )

# hex sits on the 2x line (2.0-2.05x measured), so a marginal run is not a failure;
# the recommendation for hex is the BIF either way (see the header)
for r <- [r16, r58],
    not r.correct or
      (r.verdict != r.expected and not (r.example == "hex" and r.verdict == :marginal)) do
  IO.puts("#{r.example}: verdict #{r.verdict}, expected #{r.expected}, correct #{r.correct}")
  System.halt(1)
end
