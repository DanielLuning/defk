defmodule FuzzySearch do
  @moduledoc """
  Typo-tolerant word search: the `k` dictionary words with the smallest
  Levenshtein distance to the query.

  Backends:

    * `:elixir`   - pure Elixir (`FuzzySearch.ElixirBackend`)
    * `:defk`     - defk kernel that yields like Elixir code
    * `:blocking` - the same kernel with `yield: false`, like a typical NIF
  """

  alias FuzzySearch.{Catalog, ElixirBackend, Kernels}

  @backends [:elixir, :defk, :blocking]
  def backends, do: @backends

  @doc "Returns `[{word, distance}]`, best match first."
  def search(query, backend \\ :defk, k \\ 10) when backend in @backends and k >= 1 do
    query = String.downcase(query)

    pairs =
      case backend do
        :elixir -> ElixirBackend.search(query, k)
        :defk -> kernel(&Kernels.search/4, query, k)
        :blocking -> kernel(&Kernels.search_blocking/4, query, k)
      end

    words = Catalog.get().words
    Enum.map(pairs, fn {i, d} -> {elem(words, i), d} end)
  end

  defp kernel(fun, query, k) do
    %{blob: blob, offsets: offsets} = Catalog.get()
    empty = Kernels.empty_distance()

    for(<<i::64-signed-native, d::64-signed-native <- fun.(query, blob, offsets, k)>>, d != empty, do: {d, i})
    |> Enum.sort()
    |> Enum.map(fn {d, i} -> {i, d} end)
  end
end
