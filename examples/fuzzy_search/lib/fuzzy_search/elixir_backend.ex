defmodule FuzzySearch.ElixirBackend do
  @moduledoc """
  Pure Elixir Levenshtein top-k search: the baseline a team writes first.

  Written to be fair, not a strawman: the catalog is pre-converted to
  charlists once, rows are built by tail recursion, and top-k is a bounded
  sorted list instead of sorting all distances.
  """

  alias FuzzySearch.Catalog

  @doc "Returns up to `k` `{index, distance}` pairs, best first (ties: lower index)."
  def search(query, k) do
    q = String.to_charlist(query)
    row0 = Enum.to_list(0..length(q))
    words = Catalog.get().charlists

    {_, top} =
      Enum.reduce(0..(tuple_size(words) - 1)//1, {0, []}, fn i, {count, top} ->
        d = distance(elem(words, i), q, row0)
        insert({d, i}, top, count, k)
      end)

    Enum.map(top, fn {d, i} -> {i, d} end)
  end

  # classic two-row DP: one new row per character of the candidate word
  defp distance(word, q, row0) do
    word
    |> Enum.reduce({row0, 1}, fn ch, {prev, i} -> {next_row(q, ch, prev, [i], i), i + 1} end)
    |> elem(0)
    |> List.last()
  end

  defp next_row([], _ch, _prev, acc, _left), do: :lists.reverse(acc)

  defp next_row([qc | qs], ch, [diag | [up | _] = rest], acc, left) do
    cost = if qc == ch, do: 0, else: 1
    v = min(min(up + 1, left + 1), diag + cost)
    next_row(qs, ch, rest, [v | acc], v)
  end

  # keep the k smallest {distance, index} keys in ascending order
  defp insert(key, top, count, k) when count < k, do: {count + 1, :lists.merge([key], top)}

  defp insert(key, top, count, _k) do
    if key < List.last(top), do: {count, :lists.merge([key], List.delete_at(top, -1))}, else: {count, top}
  end
end
