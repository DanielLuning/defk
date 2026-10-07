defmodule FuzzySearch.ElixirBackend do
  @moduledoc """
  Pure Elixir Levenshtein top-k search, with the same early cut-off as the
  defk kernel.

  Written to be fair, not a strawman: the catalog is pre-converted to
  charlists once, rows are built by tail recursion, and top-k is a bounded
  sorted list instead of sorting all distances.

  Cut-off: a row's minimum never decreases from one row to the next, and the
  final distance is at least that minimum. Once the top k is full, a word
  stops as soon as its row minimum reaches the k-th best distance (`bound`):
  it can no longer get in. Words are scanned in index order, so a word that
  only ties the k-th best would lose the tie-break and is cut too.

  `bench/elixir_variants.exs` measures the alternatives that were tried
  (`Enum.reduce_while`, binary words, tuple, `:array` and binary rows,
  `:lists.min`); this tail-recursive list version was the fastest.
  """

  alias FuzzySearch.Catalog

  @inf 1_000_000_000

  @doc "Returns up to `k` `{index, distance}` pairs, best first (ties: lower index)."
  def search(query, k) do
    q = String.to_charlist(query)
    row0 = Enum.to_list(0..length(q))
    words = Catalog.get().charlists

    {top, _, _} =
      Enum.reduce(0..(tuple_size(words) - 1)//1, {[], 0, @inf}, fn i, {top, count, bound} = acc ->
        case distance(elem(words, i), q, row0, 1, bound) do
          :cut -> acc
          d -> insert(d, i, top, count, k, bound)
        end
      end)

    Enum.map(top, fn {d, i} -> {i, d} end)
  end

  # classic two-row DP: one new row per character of the candidate word;
  # `:cut` once the row minimum reaches `bound`
  defp distance([], _q, prev, _i, _bound), do: List.last(prev)

  defp distance([ch | rest], q, prev, i, bound) do
    case next_row(q, ch, prev, [i], i, i) do
      {_, min} when min >= bound -> :cut
      {row, _} -> distance(rest, q, row, i + 1, bound)
    end
  end

  defp next_row([], _ch, _prev, acc, _left, min), do: {:lists.reverse(acc), min}

  defp next_row([qc | qs], ch, [diag | [up | _] = rest], acc, left, row_min) do
    cost = if qc == ch, do: 0, else: 1
    v = min(min(up + 1, left + 1), diag + cost)
    next_row(qs, ch, rest, [v | acc], v, min(row_min, v))
  end

  # keep the k smallest {distance, index} keys in ascending order; returns the
  # new bound (the k-th best distance, or @inf while fewer than k are kept).
  # Indices ascend, so a newcomer gets in only with a strictly smaller distance.
  defp insert(d, i, top, count, k, _bound) when count < k do
    top = :lists.merge([{d, i}], top)
    count = count + 1
    {top, count, if(count == k, do: elem(List.last(top), 0), else: @inf)}
  end

  defp insert(d, i, top, count, _k, bound) when d < bound do
    top = :lists.merge([{d, i}], :lists.droplast(top))
    {top, count, elem(List.last(top), 0)}
  end

  defp insert(_d, _i, top, count, _k, bound), do: {top, count, bound}
end
