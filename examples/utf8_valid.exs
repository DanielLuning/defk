# utf8_valid: is a 16 MB binary valid UTF-8?
#
# The trap: writing a Hoehrmann DFA as a kernel to replace String.valid?/1,
# because bandit_native wraps simdutf8 for WebSocket text frames. People wrap
# simdutf8 because it validates with SIMD at many GB/s; the BEAM's own
# validators are scalar C. But a kernel is scalar too: one table lookup per
# byte with a data dependency from one state to the next, so it competes with
# a C BIF on equal terms and has nothing to add. A SIMD validator is "wrap a
# library" territory (docs: Where a wrapper is the right choice), not a kernel.
# This is a scan-only job (bool out, nothing built), the best case for a
# kernel's shape, and it still does not clear the 2x bar.
# Expected verdict: marginal (measured 1.05-1.09x at 16 MB; the research's
# ~2 GB/s BIF / ~1 GB/s DFA estimate was optimistic for both sides here)
#
#   elixir examples/utf8_valid.exs
#
# Recommendation: String.valid?/1 (what Bandit itself uses), or
# :unicode.characters_to_binary/1 if you want to know where the error is.
#
# Elixir baseline: optimised by definition, both are BIFs/ERTS C. Tried:
# String.valid?/1 and :unicode.characters_to_binary/1 (a binary for valid
# input, {:error, _, _} or {:incomplete, _, _} otherwise). The faster one is
# the baseline.
#
# Kernel: Bjoern Hoehrmann's DFA (a 256-entry byte-class table and a 9x16
# state/class transition table, built into alloc'd arrays at the start of
# each call because module attributes are not available yet), one byte per
# iteration, Enum.reduce_while so a rejection exits early.
#
# Input: 16 MB of deterministic mixed text (70% ASCII, then 2-, 3- and 4-byte
# characters); the sweep takes 1 KB, 64 KB, 1 MB and 16 MB prefixes cut at a
# character boundary. Agreement: the kernel, String.valid?/1 and
# :unicode.characters_to_binary/1 are compared over random bytes, valid text
# and crafted cases (overlongs, surrogates, above 10FFFF, truncated at the
# end, 5/6-byte forms); every crafted case is asserted.
#
# Measured (M-series Mac, OTP 29, Elixir 1.20), 16 MB: String.valid? 62 ms
# (0.27 GB/s), :unicode.characters_to_binary 32 ms (0.52 GB/s, the baseline),
# kernel 29.6 ms (0.57 GB/s): 1.05-1.09x over three runs, all marginal. The
# sweep: 1 KB 0.0 vs 0.002 ms (the kernel's fixed call cost, which includes
# building the tables, loses on small frames), 64 KB 0.56-0.68x, 1 MB
# 1.05-1.10x, 16 MB 1.07-1.09x; no crossover to 2x. A 1.07x edge is not worth
# native code, and a kernel that builds the tables on every call loses on
# the WebSocket-sized frames this is used for. String.valid? is the
# recommendation: it is already native and the readable choice (it is 2x
# slower than :unicode on this input, still microseconds on a frame). For
# GB/s, wrap simdutf8.

Mix.install([{:defk, path: Path.expand("..", __DIR__)}])

defmodule Utf8.Kernels do
  use Defk

  # Hoehrmann's DFA. States: 0 accept, 1 reject, 2..8 mid-sequence. Classes
  # 0..11; the transition table is indexed state * 16 + class, default reject.
  defk valid_utf8?(bytes :: [u8]) :: bool do
    cls = alloc(u8, 256)

    for b <- 0..255//1 do
      cls[b] =
        if b < 0x80 do
          0
        else
          if b < 0x90 do
            1
          else
            if b < 0xA0 do
              9
            else
              if b < 0xC0 do
                7
              else
                if b < 0xC2 do
                  8
                else
                  if b < 0xE0 do
                    2
                  else
                    if b == 0xE0 do
                      10
                    else
                      if b == 0xED do
                        4
                      else
                        if b < 0xF0 do
                          3
                        else
                          if b == 0xF0 do
                            11
                          else
                            if b < 0xF4 do
                              6
                            else
                              if b == 0xF4, do: 5, else: 8
                            end
                          end
                        end
                      end
                    end
                  end
                end
              end
            end
          end
        end
    end

    trans = alloc(i64, 144)

    for i <- 0..143//1 do
      trans[i] = 1
    end

    trans[0] = 0
    trans[2] = 2
    trans[3] = 3
    trans[4] = 5
    trans[5] = 8
    trans[6] = 7
    trans[10] = 4
    trans[11] = 6
    trans[33] = 0
    trans[39] = 0
    trans[41] = 0
    trans[49] = 2
    trans[55] = 2
    trans[57] = 2
    trans[71] = 2
    trans[81] = 2
    trans[89] = 2
    trans[103] = 3
    trans[105] = 3
    trans[113] = 3
    trans[119] = 3
    trans[121] = 3
    trans[129] = 3

    final =
      Enum.reduce_while(0..(len(bytes) - 1)//1, 0, fn i, s ->
        next = trans[bsl(s, 4) + cls[bytes[i]]]
        if next == 1, do: {:halt, 1}, else: {:cont, next}
      end)

    final == 0
  end
end

defmodule Utf8.Data do
  # Deterministic mixed text: 70% ASCII, 15% 2-byte, 10% 3-byte, 5% 4-byte.
  def text(bytes) do
    :rand.seed(:exsss, {7, 8, 9})
    chunk = chunk(1_048_576, [])
    reps = div(bytes, byte_size(chunk)) + 1
    trim(binary_part(:binary.copy(chunk, reps), 0, bytes))
  end

  defp chunk(left, acc) when left <= 0, do: IO.iodata_to_binary(acc)

  defp chunk(left, acc) do
    c = codepoint(:rand.uniform(100))
    s = <<c::utf8>>
    chunk(left - byte_size(s), [s | acc])
  end

  defp codepoint(r) when r <= 70, do: 32 + :rand.uniform(94)
  defp codepoint(r) when r <= 85, do: 0xC0 + :rand.uniform(0x500)
  defp codepoint(r) when r <= 95, do: 0x4E00 + :rand.uniform(0x4000)
  defp codepoint(_), do: 0x1F300 + :rand.uniform(0x300)

  # a random scalar value (never a surrogate)
  def scalar do
    c = :rand.uniform(0x10FFFF)
    if c in 0xD800..0xDFFF, do: 0x41, else: c
  end

  # cut back to a character boundary
  def trim(bin) do
    if String.valid?(bin), do: bin, else: trim(binary_part(bin, 0, byte_size(bin) - 1))
  end
end

bif_unicode = fn bin ->
  is_binary(:unicode.characters_to_binary(bin))
end

bif_string = &String.valid?/1
kernel = &Utf8.Kernels.valid_utf8?/1

# crafted cases: {label, bytes, valid?}
crafted = [
  {"empty", <<>>, true},
  {"ascii", "hello", true},
  {"max 2-byte U+07FF", <<0xDF, 0xBF>>, true},
  {"U+0800", <<0xE0, 0xA0, 0x80>>, true},
  {"U+D7FF", <<0xED, 0x9F, 0xBF>>, true},
  {"U+E000", <<0xEE, 0x80, 0x80>>, true},
  {"U+FFFF", <<0xEF, 0xBF, 0xBF>>, true},
  {"U+10000", <<0xF0, 0x90, 0x80, 0x80>>, true},
  {"U+10FFFF", <<0xF4, 0x8F, 0xBF, 0xBF>>, true},
  {"overlong NUL 2-byte", <<0xC0, 0x80>>, false},
  {"overlong '/' 2-byte", <<0xC0, 0xAF>>, false},
  {"overlong 0xC1", <<0xC1, 0xBF>>, false},
  {"overlong 3-byte", <<0xE0, 0x80, 0x80>>, false},
  {"overlong 3-byte 9F", <<0xE0, 0x9F, 0xBF>>, false},
  {"overlong 4-byte", <<0xF0, 0x80, 0x80, 0x80>>, false},
  {"overlong 4-byte 8F", <<0xF0, 0x8F, 0xBF, 0xBF>>, false},
  {"surrogate D800", <<0xED, 0xA0, 0x80>>, false},
  {"surrogate DBFF", <<0xED, 0xAF, 0xBF>>, false},
  {"surrogate DC00", <<0xED, 0xB0, 0x80>>, false},
  {"surrogate DFFF", <<0xED, 0xBF, 0xBF>>, false},
  {"above 10FFFF (F4 90)", <<0xF4, 0x90, 0x80, 0x80>>, false},
  {"above 10FFFF (F5)", <<0xF5, 0x80, 0x80, 0x80>>, false},
  {"above 10FFFF (FF)", <<0xFF>>, false},
  {"5-byte form", <<0xF8, 0x88, 0x80, 0x80, 0x80>>, false},
  {"6-byte form", <<0xFC, 0x84, 0x80, 0x80, 0x80, 0x80>>, false},
  {"lone continuation", <<0x80>>, false},
  {"continuation after ASCII", <<"a", 0xBF>>, false},
  {"truncated 2-byte at end", <<"ok", 0xC3>>, false},
  {"truncated 3-byte at end (1)", <<"ok", 0xE2>>, false},
  {"truncated 3-byte at end (2)", <<"ok", 0xE2, 0x82>>, false},
  {"truncated 4-byte at end (1)", <<"ok", 0xF0>>, false},
  {"truncated 4-byte at end (2)", <<"ok", 0xF0, 0x9F>>, false},
  {"truncated 4-byte at end (3)", <<"ok", 0xF0, 0x9F, 0x98>>, false},
  {"lead then ASCII", <<0xC3, "a">>, false},
  {"bad in the middle", <<"abc", 0xFF, "def">>, false},
  {"valid then bad tail", <<"héllo ", 0xE2, 0x82, "x">>, false}
]

crafted_ok =
  for {label, bin, want} <- crafted, reduce: true do
    acc ->
      got = {kernel.(bin), bif_string.(bin), bif_unicode.(bin)}

      if got == {want, want, want} do
        acc
      else
        IO.puts("DISAGREE #{label}: want #{want}, kernel/String/unicode = #{inspect(got)}")
        false
      end
  end

# every single byte and every 2-byte and 3-byte prefix-shaped combination
# around the boundaries would be exhaustive for 2 bytes; do all 65536 pairs
pairs_ok =
  for a <- 0..255, b <- 0..255, reduce: true do
    acc ->
      bin = <<a, b>>
      acc and kernel.(bin) == bif_string.(bin) and bif_string.(bin) == bif_unicode.(bin)
  end

:rand.seed(:exsss, {1, 2, 3})

random_ok =
  for _ <- 1..2000, reduce: true do
    acc ->
      bin = :rand.bytes(:rand.uniform(64))
      acc and kernel.(bin) == bif_string.(bin) and bif_string.(bin) == bif_unicode.(bin)
  end

# random valid text, and the same text with one byte corrupted
text_ok =
  for i <- 1..200, reduce: true do
    acc ->
      valid = for(_ <- 1..:rand.uniform(40), into: <<>>, do: <<Utf8.Data.scalar()::utf8>>)

      pos = rem(i * 7, max(byte_size(valid), 1))

      bad =
        if byte_size(valid) > 0,
          do:
            binary_part(valid, 0, pos) <>
              <<0xFF>> <> binary_part(valid, pos + 1, byte_size(valid) - pos - 1),
          else: valid

      acc and kernel.(valid) and bif_string.(valid) and bif_unicode.(valid) and
        not kernel.(bad) and not bif_string.(bad) and not bif_unicode.(bad)
  end

agree = crafted_ok and pairs_ok and random_ok and text_ok

unless agree do
  raise "agreement failed: crafted #{crafted_ok}, pairs #{pairs_ok}, random #{random_ok}, text #{text_ok}"
end

IO.puts(
  "agreement: #{length(crafted)} crafted cases, 65536 byte pairs, 2000 random, 200 text/corrupt: ok"
)

text = Utf8.Data.text(16 * 1024 * 1024)
true = kernel.(text) and bif_string.(text) and bif_unicode.(text)

best = fn fun ->
  fun.()

  1..5
  |> Enum.map(fn _ ->
    :erlang.garbage_collect()
    elem(:timer.tc(fun), 0)
  end)
  |> Enum.min()
end

IO.puts("16 MB valid text, best of 5 (ms):")

for {label, f} <- [
      {"String.valid?", fn -> bif_string.(text) end},
      {":unicode.characters_to_binary", fn -> bif_unicode.(text) end},
      {"defk valid_utf8?", fn -> kernel.(text) end}
    ] do
  IO.puts("  #{String.pad_trailing(label, 32)} #{Float.round(best.(f) / 1000, 2)}")
end

# the faster BIF is the baseline (chosen from the measurement above)
elixir = bif_unicode

sweep_fun = fn size ->
  bin = Utf8.Data.trim(binary_part(text, 0, size))
  {fn -> elixir.(bin) end, fn -> kernel.(bin) end}
end

Defk.Bench.report(
  name: "utf8_valid",
  expected: :marginal,
  baseline: :optimized,
  runs: 15,
  realistic_size: "16 MB",
  elixir: fn -> elixir.(text) end,
  defk: fn -> kernel.(text) end,
  check: fn -> agree and elixir.(text) == kernel.(text) end,
  sweep: {[1024, 65_536, 1_048_576, 16 * 1024 * 1024], sweep_fun},
  sweep_runs: 5,
  reason:
    "a scalar byte DFA competes with a C BIF; :unicode.characters_to_binary is already C and the DFA is only about 1.07x ahead, so use String.valid? (a SIMD validator is a wrapper job)"
)
