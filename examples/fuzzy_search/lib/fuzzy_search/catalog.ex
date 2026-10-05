defmodule FuzzySearch.Catalog do
  @moduledoc """
  The searchable word list, loaded once at boot and kept in `:persistent_term`.

  Two representations are built from the same words:

    * `words` / `charlists` - tuples for the pure Elixir backend
    * `blob` / `offsets` - one packed binary of all words plus an `[i64]`
      offset table, for the defk backend (word `i` is
      `blob[offsets[i] .. offsets[i + 1] - 1]`)
  """

  @default_path "/usr/share/dict/words"

  def load(path \\ System.get_env("WORDS", @default_path)) do
    words =
      path
      |> File.stream!()
      |> Stream.map(&(&1 |> String.trim() |> String.downcase()))
      |> Stream.filter(&(&1 =~ ~r/^[a-z]+$/))
      |> Enum.uniq()

    {offsets, _} = Enum.map_reduce(words, 0, fn w, at -> {at, at + byte_size(w)} end)
    total = Enum.reduce(words, 0, &(&2 + byte_size(&1)))

    catalog = %{
      words: List.to_tuple(words),
      charlists: words |> Enum.map(&String.to_charlist/1) |> List.to_tuple(),
      blob: IO.iodata_to_binary(words),
      offsets: for(o <- offsets ++ [total], into: <<>>, do: <<o::64-signed-native>>)
    }

    :persistent_term.put(__MODULE__, catalog)
    catalog
  end

  def get, do: :persistent_term.get(__MODULE__)
  def size, do: tuple_size(get().words)
end
