<!-- docs/guides/testing.md line 168 of v0.1.0. A frozen file is never edited. -->

```elixir
defmodule Grid do
  use Defk

  defk row_max_sum(cells :: [i64], width :: i64) :: i64 do
    rows = div(length(cells), width)

    for r <- 0..(rows - 1)//1, reduce: 0 do
      total ->
        best =
          for c <- 0..(width - 1)//1, reduce: cells[r * width] do
            m -> max(m, cells[r * width + c])
          end

        total + best
    end
  end
end
```

```elixir
iex> cells = for i <- 1..20_000, into: <<>>, do: <<rem(i * 7, 100)::signed-64-native>>

iex> expected = Grid.row_max_sum(cells, 100)

iex> Grid.__defk_force_yields__(true)
:ok

iex> Grid.row_max_sum(cells, 100) === expected
true

iex> Grid.__defk_force_yields__(false)
:ok
```
