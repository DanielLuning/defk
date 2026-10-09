# poor_per_pair_distance: Levenshtein distance for 50k pairs of short strings
#
# The trap (expected, and not found): ex_strsim's API shape, one NIF call per
# string pair inside Enum.map, should lose the advantage to call overhead, as
# poor_tiny_calls shows for numbers. Measured, it does not: a Levenshtein DP is
# quadratic in the string length, so even 8-16 bytes is 60-250 cell updates per
# call, far more than the ~0.1-0.2 us boundary. The kernel per pair is 3.4x
# faster than optimised Elixir at 8-16 bytes (3.2-3.4x). Expected verdict: good.
#
#   elixir examples/poor_per_pair_distance.exs
#
# Where the crossover is (length sweep below, 10k pairs): at 4-byte strings
# (16 cells) the per-pair kernel is only 1.1-1.2x ahead, so below about 8 bytes
# stay in Elixir; from 16 bytes up it is 3-3.7x. The pre-registered expectation
# was marginal/poor; the measurement says per-pair is fine for any DP-shaped
# distance, and the trap is a different one: batching FROM A LIST OF PAIRS.
# Packing 50k {a, b} tuples into a blob plus offsets and decoding the result
# costs more in Elixir than the per-pair calls do (18 ms batched vs 13 ms per
# pair), so a batched kernel only pays when the strings already live packed
# (as in examples/fuzzy_search, one blob and offsets kept in :persistent_term;
# the last column of the sweep: 4.2-4.6x at 4 bytes). The file keeps its poor_ name from the ticket;
# the name is the one thing that is not what the measurement says.
#
# Elixir baseline: optimised. A tail-recursive two-row version over the
# strings' bytes: the row is a list, each cell built from the previous row's
# diagonal and up cells and the left cell just computed; the inner loop is
# tail recursive and the row is reversed once per character. Not tried: Myers
# bit-parallel Levenshtein (the subset has no bitwise ops; on the Elixir side
# it would help for strings up to 64 bytes), and a cut-off bound.
#
# The kernel is a minimal single-row DP, lev(a :: [u8], b :: [u8]) :: i64,
# not the FuzzySearch kernel (that one is top-k search over a blob).
#
# Body-recursive cells without the reverse measured the same (44.6 ms for 50k
# pairs of 12 bytes), so the tail-recursive form is kept.

Mix.install([{:defk, path: Path.expand("..", __DIR__)}])

defmodule Pairs.Kernels do
  use Defk

  defk lev(a :: [u8], b :: [u8]) :: i64 do
    m = len(b)
    row = alloc(i64, m + 1)

    for j <- 0..m//1 do
      row[j] = j
    end

    for i <- 1..len(a)//1 do
      ch = a[i - 1]
      diag0 = row[0]
      row[0] = i

      for j <- 1..m//1, reduce: diag0 do
        diag ->
          up = row[j]
          cost = if b[j - 1] == ch, do: 0, else: 1
          row[j] = min(min(up + 1, row[j - 1] + 1), diag + cost)
          up
      end
    end

    row[m]
  end

  # Batched: string i is blob[offs[i] .. offs[i + 1]); pair k is strings 2k and 2k + 1.
  defk lev_batch(blob :: [u8], offs :: [i64], maxlen :: i64) :: [i64] do
    pairs = div(len(offs) - 1, 2)
    out = alloc(i64, pairs)
    row = alloc(i64, maxlen + 1)

    for k <- 0..(pairs - 1)//1 do
      a0 = offs[2 * k]
      n = offs[2 * k + 1] - a0
      b0 = offs[2 * k + 1]
      m = offs[2 * k + 2] - b0

      for j <- 0..m//1 do
        row[j] = j
      end

      for i <- 1..n//1 do
        ch = blob[a0 + i - 1]
        diag0 = row[0]
        row[0] = i

        for j <- 1..m//1, reduce: diag0 do
          diag ->
            up = row[j]
            cost = if blob[b0 + j - 1] == ch, do: 0, else: 1
            row[j] = min(min(up + 1, row[j - 1] + 1), diag + cost)
            up
        end
      end

      out[k] = row[m]
    end

    out
  end
end

defmodule Pairs.Elixir do
  def lev(a, b) do
    bl = :binary.bin_to_list(b)
    rows(a, bl, Enum.to_list(0..length(bl)), 1)
  end

  defp rows(<<>>, _b, row, _i), do: List.last(row)

  defp rows(<<c, rest::binary>>, b, [_ | _] = prev, i) do
    rows(rest, b, cells(b, prev, i, c, [i]), i + 1)
  end

  # prev = [diag, up | _]; acc is the new row, reversed; left is its head
  defp cells([], _prev, _left, _c, acc), do: :lists.reverse(acc)

  defp cells([bc | bt], [diag, up | prest], left, c, acc) do
    cost = if bc == c, do: 0, else: 1
    v = min(min(left + 1, up + 1), diag + cost)
    cells(bt, [up | prest], v, c, [v | acc])
  end
end

:rand.seed(:exsss, {4, 5, 6})

rand_str = fn len ->
  :rand.bytes(len)
  |> :binary.bin_to_list()
  |> Enum.map(&(rem(&1, 26) + 97))
  |> :binary.list_to_bin()
end

make_pairs = fn count, lo, hi ->
  for _ <- 1..count, do: {rand_str.(Enum.random(lo..hi)), rand_str.(Enum.random(lo..hi))}
end

pack = fn pairs ->
  flat = Enum.flat_map(pairs, fn {a, b} -> [a, b] end)
  blob = :erlang.iolist_to_binary(flat)

  {offs, total} =
    Enum.map_reduce(flat, 0, fn s, acc -> {acc, acc + byte_size(s)} end)

  offs = for o <- offs ++ [total], into: <<>>, do: <<o::signed-64-native>>
  maxlen = flat |> Enum.map(&byte_size/1) |> Enum.max()
  {blob, offs, maxlen}
end

run_packed = fn {blob, offs, maxlen} ->
  out = Pairs.Kernels.lev_batch(blob, offs, maxlen)
  for <<d::signed-64-native <- out>>, do: d
end

batched = fn pairs -> run_packed.(pack.(pairs)) end

best = fn fun, runs ->
  fun.()

  1..runs
  |> Enum.map(fn _ ->
    :erlang.garbage_collect()
    elem(:timer.tc(fun), 0)
  end)
  |> Enum.min()
end

IO.puts(
  "length sweep (10k pairs, ms; Elixir per pair / kernel per pair / batched from a pair list / batched from a packed blob):"
)

for len <- [4, 16, 64] do
  ps = make_pairs.(10_000, len, len)
  e = best.(fn -> Enum.map(ps, fn {a, b} -> Pairs.Elixir.lev(a, b) end) end, 3)
  k = best.(fn -> Enum.map(ps, fn {a, b} -> Pairs.Kernels.lev(a, b) end) end, 3)
  b = best.(fn -> batched.(ps) end, 3)
  packed = pack.(ps)
  bp = best.(fn -> run_packed.(packed) end, 3)
  f = &Float.round(&1 / 1000, 2)

  IO.puts(
    "  #{String.pad_leading(to_string(len), 3)} bytes  #{f.(e)} / #{f.(k)} / #{f.(b)} / #{f.(bp)}   speedup: per pair #{Float.round(e / k, 2)}x, batched list #{Float.round(e / b, 2)}x, batched packed #{Float.round(e / bp, 2)}x"
  )
end

pairs = make_pairs.(50_000, 8, 16)
elixir_pairs = fn -> Enum.map(pairs, fn {a, b} -> Pairs.Elixir.lev(a, b) end) end
defk_pairs = fn -> Enum.map(pairs, fn {a, b} -> Pairs.Kernels.lev(a, b) end) end

IO.puts(
  "50k pairs of 8-16 bytes: batched kernel #{Float.round(best.(fn -> batched.(pairs) end, 5) / 1000, 2)} ms"
)

Defk.Bench.report(
  name: "poor_per_pair_distance",
  expected: :good,
  baseline: :optimized,
  elixir: elixir_pairs,
  defk: defk_pairs,
  check: fn -> elixir_pairs.() == defk_pairs.() and batched.(pairs) == elixir_pairs.() end,
  reason:
    "one NIF call per pair: the call overhead eats most of the kernel's advantage on 8-16 byte strings"
)
