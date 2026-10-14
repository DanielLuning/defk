# poor_substring_search: find a 16-byte needle in a 16 MB binary
#
# The trap: writing a Horspool or Boyer-Moore search as a kernel for a job the
# BEAM already does in C. :binary.match/2 is Boyer-Moore (Horspool-style skip
# table plus a good-suffix rule) inside ERTS, returns {pos, len} without
# copying, and is preemptible through its own reduction accounting. A kernel
# that runs the same skip loop one byte at a time cannot beat it.
# Expected verdict: marginal (measured 1.16x with the 16-byte needle the report
# uses; a 64-byte needle ties at 1.03-1.11x and flips to poor on noise, so it
# stays in the length sweep only; neither ever reaches good)
#
#   elixir examples/poor_substring_search.exs
#
# Use :binary.match/2 for one needle, :binary.compile_pattern/1 when the same
# pattern is searched many times, and :binary.matches/2 with a compiled list
# of patterns (Aho-Corasick) for many needles at once. defk has nothing to add
# to fixed-string search; for a pattern that is not fixed, :re is native too.
#
# Elixir baseline: optimised. Tried: :binary.match(hay, needle), and
# :binary.match(hay, compiled) with :binary.compile_pattern/1 (compiled once,
# outside the timed call, as an app would keep it in :persistent_term). The
# faster of the two is the baseline. A Horspool written in Elixir over
# :binary.at/2 is hundreds of times slower and was not kept.
#
# Input: 16 MB of pseudo-random lowercase bytes (seeded), a 64-byte needle
# planted 1000 bytes from the end (so the whole haystack is scanned), its
# 16-byte prefix as the reported needle, and an absent needle of the same
# length. Agreement: the kernel returns the position
# and :binary.match returns {pos, len}; both are checked for found and absent.
#
# Measured (M-series Mac, OTP 29, Elixir 1.20): both sides take about 2.2-2.4 ms
# for 16 MB (about 7 GB/s) and the kernel is 1.03-1.11x ahead, for found and
# absent needles alike: the two are the same algorithm and both limited by
# memory and the skip rate. A 1.05x edge is not worth native code, so the
# recommendation is :binary.match. The script prints per-variant times and the
# effect of needle length.

Mix.install([{:defk, path: Path.expand("..", __DIR__)}])

defmodule Search.Kernels do
  use Defk

  # Maps every byte to a lowercase letter; used once to build the input.
  defk lower(a :: [u8]) :: [u8] do
    out = alloc(u8, length(a))

    for i <- 0..(length(a) - 1)//1 do
      out[i] = rem(a[i], 26) + 97
    end

    out
  end

  # Horspool: shift by the skip of the byte under the window's last position.
  # -1 when absent. Every step advances by at least 1, so n steps suffice.
  defk find(hay :: [u8], needle :: [u8]) :: i64 do
    n = length(hay)
    m = length(needle)
    skip = alloc(i64, 256)

    for b <- 0..255//1 do
      skip[b] = m
    end

    for i <- 0..(m - 2)//1 do
      skip[needle[i]] = m - 1 - i
    end

    {pos, found} =
      Enum.reduce_while(0..n//1, {0, false}, fn _, {pos, _} ->
        if pos > n - m do
          {:halt, {pos, false}}
        else
          if Enum.all?((m - 1)..0//-1, fn j -> hay[pos + j] == needle[j] end) do
            {:halt, {pos, true}}
          else
            {:cont, {pos + skip[hay[pos + m - 1]], false}}
          end
        end
      end)

    if found, do: pos, else: -1
  end
end

:rand.seed(:exsss, {1, 2, 3})
size = 16 * 1024 * 1024
needle = Search.Kernels.lower(:rand.bytes(64))
absent = Search.Kernels.lower(:rand.bytes(64))
planted = size - 1000 - 64

hay =
  Search.Kernels.lower(:rand.bytes(size))
  |> then(fn h ->
    <<pre::binary-size(^planted), _::binary-size(64), post::binary>> = h
    :binary.copy(<<pre::binary, needle::binary, post::binary>>)
  end)

compiled = :binary.compile_pattern(needle)
compiled_absent = :binary.compile_pattern(absent)

pos = fn
  :nomatch -> -1
  {p, _len} -> p
end

best = fn fun ->
  fun.()

  1..5
  |> Enum.map(fn _ ->
    :erlang.garbage_collect()
    elem(:timer.tc(fun), 0)
  end)
  |> Enum.min()
end

IO.puts("variants (best of 5, ms):")

for {label, f} <- [
      {"binary.match found", fn -> :binary.match(hay, needle) end},
      {"binary.match compiled found", fn -> :binary.match(hay, compiled) end},
      {"defk find found", fn -> Search.Kernels.find(hay, needle) end},
      {"binary.match absent", fn -> :binary.match(hay, absent) end},
      {"binary.match compiled absent", fn -> :binary.match(hay, compiled_absent) end},
      {"defk find absent", fn -> Search.Kernels.find(hay, absent) end}
    ] do
  IO.puts("  #{String.pad_trailing(label, 30)} #{Float.round(best.(f) / 1000, 3)}")
end

IO.puts("needle length (found, best of 5, ms; binary.match / defk):")

for len <- [8, 16, 32, 64] do
  nd = binary_part(needle, 0, len)
  a = Float.round(best.(fn -> :binary.match(hay, nd) end) / 1000, 3)
  b = Float.round(best.(fn -> Search.Kernels.find(hay, nd) end) / 1000, 3)
  IO.puts("  #{String.pad_leading(Integer.to_string(len), 3)} bytes  #{a} / #{b}")
end

# the reported case: a 16-byte needle, where the margin is widest
reported = binary_part(needle, 0, 16)
compiled_reported = :binary.compile_pattern(reported)
elixir_find = fn -> pos.(:binary.match(hay, compiled_reported)) end
defk_find = fn -> Search.Kernels.find(hay, reported) end

agree =
  pos.(:binary.match(hay, needle)) == planted and
    elixir_find.() == planted and defk_find.() == planted and
    pos.(:binary.match(hay, absent)) == -1 and Search.Kernels.find(hay, absent) == -1 and
    pos.(:binary.match(hay, compiled_absent)) == -1

Defk.Bench.report(
  name: "poor_substring_search",
  expected: :marginal,
  baseline: :optimized,
  runs: 15,
  elixir: elixir_find,
  defk: defk_find,
  check: fn -> agree end,
  reason:
    ":binary.match is already native Boyer-Moore; the Horspool kernel is only about 1.1-1.2x ahead, not worth native code"
)
