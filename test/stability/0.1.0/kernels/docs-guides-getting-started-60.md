<!-- docs/guides/getting-started.md line 60 of v0.1.0. A frozen file is never edited. -->

```elixir
defmodule Stats do
  use Defk

  defk sum(xs :: [f64]) :: f64 do
    for x <- xs, reduce: 0.0 do
      acc -> acc + x
    end
  end
end
```

```elixir
iex> xs = for x <- [1.5, 2.5, 4.0], into: <<>>, do: <<x::float-64-native>>

iex> Stats.sum(xs)
8.0

iex> Stats.sum(<<>>)
0.0

iex> Stats.sum(<<1, 2, 3>>)
** (ArgumentError) argument 1 (xs): byte size 3 is not a multiple of 8 (f64)

iex> big = <<1.0e308::float-64-native, 1.0e308::float-64-native>>

iex> Stats.sum(big)
** (ArithmeticError) float result of 1e+308 + 1e+308 is inf or NaN
```
