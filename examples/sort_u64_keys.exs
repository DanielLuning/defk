# sort_u64_keys: sort 1M random 64-bit keys that arrive packed in a binary
#
# Why people reach for a NIF: sorting millions of fixed-width keys (ids,
# hashes, timestamps) in Elixir means decoding the binary into a list, sorting
# the list and, if the next stage wants packed data, encoding it again. No NIF
# package covers this (docs/research/string-workloads.md, category I).
#
# The trap is the shape of the output. Two measurements from the same packed
# binary of 1M random i64, reported as two DEFK_RESULT lines:
#
#   sort_packed   the result stays packed (written to a file, sent to a
#                 socket, handed to the next kernel).        expected: good
#   sort_to_list  the caller needs an Elixir list afterwards (to Enum.take,
#                 pattern match, join, ...); the defk side pays for the
#                 decode too.                                  expected: good
#
#   elixir examples/sort_u64_keys.exs
#
# examples/run_all.exs collects only the FIRST DEFK_RESULT line of a script,
# so sort_packed (the claim the catalog lists under "Where defk helps") is
# printed first and sort_to_list second. Because the runner never sees the
# second line, this script checks its own claim and exits 1 when sort_to_list
# measures a different verdict than expected.
#
# Pre-registered expectation was good for sort_packed and POOR for
# sort_to_list. The measurement disagreed: decoding the sorted result costs
# 40 ms, but :lists.sort of 1M keys costs 230+ ms, so the kernel still wins
# the list shape by 2.3-2.7x. What the list shape does cost is the margin:
# 4.3-5.3x packed (kernel 63-76 ms vs Elixir 300-380 ms, which also re-encodes) down to
# 2.3-2.7x, close to the 2x bar. Use defk here when the data is packed; if the
# keys are already an Elixir list, packing them first costs more than it saves
# (see poor_list_data), and :lists.sort is the right call.
#
# Elixir baseline: optimised. Tried, from the same binary: decode with a
# binary comprehension, then :lists.sort/1 or Enum.sort/1 (Enum.sort is
# :lists.sort for lists), then re-encode with a binary comprehension; the
# faster of the two is the baseline. :ets ordered_set and :gb_trees were not
# tried: they are slower than :lists.sort for a one-shot sort. Not tried:
# splitting the keys into chunks and sorting in parallel processes (a fair
# Elixir option that uses more cores; the kernel is single-threaded).
#
# Kernel: in-place heapsort over an alloc'd copy (the subset has no
# recursion, so no quicksort without an explicit stack). Keys are signed i64,
# ascending, duplicates kept.

Mix.install([{:defk, path: Path.expand("..", __DIR__)}])

defmodule Keys.Kernels do
  use Defk

  defk sort_i64(keys :: [i64]) :: [i64] do
    n = len(keys)
    a = alloc(i64, n)

    for i <- 0..(n - 1)//1 do
      a[i] = keys[i]
    end

    half = div(n, 2)

    # Heapsort as one loop of "sift" tasks: first the build phase (sift
    # half-1 .. 0 over the whole array), then n-1 rounds of "swap the root
    # with the last element of the heap, sift the root over the shrunk heap".
    for t <- 0..(half + n - 2)//1 do
      last = n - 1 - (t - half)
      start = if t < half, do: half - 1 - t, else: 0
      e = if t < half, do: n, else: last

      if t >= half do
        top = a[0]
        a[0] = a[last]
        a[last] = top
      end

      Enum.reduce_while(0..63//1, start, fn _, root ->
        child = 2 * root + 1

        if child >= e do
          {:halt, root}
        else
          c = if child + 1 < e and a[child + 1] > a[child], do: child + 1, else: child

          if a[root] >= a[c] do
            {:halt, root}
          else
            tmp = a[root]
            a[root] = a[c]
            a[c] = tmp
            {:cont, c}
          end
        end
      end)
    end

    a
  end
end

:rand.seed(:exsss, {7, 8, 9})
n = 1_000_000
packed = :rand.bytes(n * 8)

decode = fn bin -> for <<x::signed-64-native <- bin>>, do: x end
encode = fn list -> for x <- list, into: <<>>, do: <<x::signed-64-native>> end

elixir_packed = fn -> packed |> decode.() |> :lists.sort() |> encode.() end
elixir_list = fn -> packed |> decode.() |> :lists.sort() end
defk_packed = fn -> Keys.Kernels.sort_i64(packed) end
defk_list = fn -> packed |> Keys.Kernels.sort_i64() |> decode.() end

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
      {"decode + :lists.sort", fn -> packed |> decode.() |> :lists.sort() end},
      {"decode + Enum.sort", fn -> packed |> decode.() |> Enum.sort() end},
      {"decode only", fn -> decode.(packed) end},
      {"kernel only", defk_packed}
    ] do
  IO.puts("  #{String.pad_trailing(label, 24)} #{Float.round(best.(f) / 1000, 1)}")
end

reference = packed |> decode.() |> :lists.sort()
agree = fn -> encode.(reference) == defk_packed.() and reference == defk_list.() end

r1 =
  Defk.Bench.report(
    name: "sort_packed",
    expected: :good,
    baseline: :optimized,
    elixir: elixir_packed,
    defk: defk_packed,
    check: agree,
    reason: "packed in, packed out: no list is ever built on the defk side"
  )

r2 =
  Defk.Bench.report(
    name: "sort_to_list",
    expected: :good,
    baseline: :optimized,
    elixir: elixir_list,
    defk: defk_list,
    check: agree,
    reason:
      "decoding the sorted result to a list costs 40 ms, the margin shrinks to about 2.5x but holds"
  )

if r2.verdict != :good or not r2.correct or not r1.correct, do: System.halt(1)
