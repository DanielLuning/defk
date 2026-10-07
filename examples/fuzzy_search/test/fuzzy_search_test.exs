defmodule FuzzySearchTest do
  # The early cut-off (defk-8i4) must not change any result: every backend is
  # compared with a plain full scan (every distance computed, all sorted).
  use ExUnit.Case, async: true

  alias FuzzySearch.Catalog

  # full Levenshtein distance, no cut-off
  defp levenshtein(word, q) do
    row0 = Enum.to_list(0..length(q))

    word
    |> Enum.with_index(1)
    |> Enum.reduce(row0, fn {ch, i}, prev ->
      {row, _} =
        Enum.zip(q, Enum.zip(prev, tl(prev)))
        |> Enum.map_reduce(i, fn {qc, {diag, up}}, left ->
          v = Enum.min([up + 1, left + 1, diag + if(qc == ch, do: 0, else: 1)])
          {v, v}
        end)

      [i | row]
    end)
    |> List.last()
  end

  defp full_scan(query) do
    q = String.to_charlist(query)
    words = Catalog.get().words

    Catalog.get().charlists
    |> Tuple.to_list()
    |> Enum.with_index()
    |> Enum.map(fn {w, i} -> {levenshtein(w, q), i} end)
    |> Enum.sort()
    |> Enum.map(fn {d, i} -> {elem(words, i), d} end)
  end

  # typo'd real words, one-letter and no-match queries, and a query longer than any word
  @queries ~w(elixr mezzotinat photolqith a zz qqqqqqqqqqqqqqqqqqqqqqqqqqqqqq kitten)
  @ks [1, 3, 10, 57]

  for query <- @queries do
    test "every backend matches a full scan for #{inspect(query)}" do
      all = full_scan(unquote(query))

      for k <- @ks, backend <- FuzzySearch.backends() do
        assert FuzzySearch.search(unquote(query), backend, k) == Enum.take(all, k),
               "backend #{backend}, k = #{k}"
      end
    end
  end
end
