<!-- docs/guides/cheatsheet.cheatmd line 11 of v0.1.0. A frozen file is never edited. -->

```elixir
defmodule Geo do
  use Defk

  defk dot(a :: [f64], b :: [f64]) :: f64 do
    n = min(length(a), length(b))

    for i <- 0..(n - 1)//1, reduce: 0.0 do
      acc -> acc + a[i] * b[i]
    end
  end
end
```

```elixir
iex> a = <<1.0::float-64-native, 2.0::float-64-native>>

iex> Geo.dot(a, a)
5.0
```
