# Correctness + single-query latency, in-process: `NO_SERVER=1 mix run bench/verify.exs`
# Every backend must return identical results for realistic typo'd queries.

defmodule Typos do
  # one or two edits (replace / delete / insert / swap) of a real word
  def make(word, rng) do
    edits = Enum.random(1..2)
    Enum.reduce(1..edits, String.to_charlist(word), fn _, w -> edit(w, rng) end) |> to_string()
  end

  defp edit(w, _rng) when length(w) < 2, do: w

  defp edit(w, _rng) do
    i = Enum.random(0..(length(w) - 1))
    c = Enum.random(?a..?z)

    case Enum.random([:replace, :delete, :insert, :swap]) do
      :replace -> List.replace_at(w, i, c)
      :delete -> List.delete_at(w, i)
      :insert -> List.insert_at(w, i, c)
      :swap when i < length(w) - 1 -> w |> List.replace_at(i, Enum.at(w, i + 1)) |> List.replace_at(i + 1, Enum.at(w, i))
      :swap -> w
    end
  end
end

:rand.seed(:exsss, {1, 2, 3})
words = FuzzySearch.Catalog.get().words
n = tuple_size(words)
queries = for _ <- 1..40, do: Typos.make(elem(words, :rand.uniform(n) - 1), nil)

IO.puts("catalog: #{n} words; #{length(queries)} typo'd queries, e.g. #{Enum.take(queries, 5) |> Enum.join(", ")}\n")

results =
  for backend <- FuzzySearch.backends(), into: %{} do
    {us, res} = :timer.tc(fn -> Enum.map(queries, &FuzzySearch.search(&1, backend)) end)
    IO.puts("  #{String.pad_trailing(to_string(backend), 9)} #{:erlang.float_to_binary(us / 1000 / length(queries), decimals: 1)} ms/query")
    {backend, res}
  end

same = results.elixir == results.defk and results.defk == results.blocking
IO.puts("\nall backends identical: #{same}")
[q | _] = queries
IO.puts("example: #{inspect(q)} -> #{inspect(hd(results.defk) |> Enum.take(5))}")
same || System.halt(1)
