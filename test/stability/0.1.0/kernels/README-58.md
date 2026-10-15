<!-- README.md line 58 of v0.1.0. A frozen file is never edited. -->

```elixir
defmodule Stats do
  use Defk

  defk dot(a :: [f64], b :: [f64]) :: f64 do
    for i <- 0..(length(a) - 1)//1, reduce: 0.0 do
      acc -> acc + a[i] * b[i]
    end
  end
end
```

```elixir
iex> bin_a = for x <- [1.0, 2.0], into: <<>>, do: <<x::float-64-native>>

iex> bin_b = for x <- [3.0, 4.0], into: <<>>, do: <<x::float-64-native>>

iex> Stats.dot(bin_a, bin_b)
11.0
```
