<!-- docs/guides/testing.md line 34 of v0.1.0. A frozen file is never edited. -->

```elixir
defmodule Bytes do
  use Defk

  defk count_below(bytes :: [u8], limit :: i64) :: i64 do
    for b <- bytes, reduce: 0 do
      n -> if b < limit, do: n + 1, else: n
    end
  end
end
```

```elixir
iex> Bytes.count_below("hello", 105)
2

iex> Bytes.__defk_elixir__(:count_below, ["hello", 105])
2

iex> Defk.ElixirMode.with_mode(:elixir, fn -> Bytes.count_below("hello", 105) end)
2

iex> Defk.Test.assert_agrees(Bytes, :count_below, ["hello", 105])
{:ok, 2}

iex> {:raise, e} = Defk.Test.assert_agrees(Bytes, :count_below, [:hello, 105])

iex> e.__struct__
ArgumentError
```
