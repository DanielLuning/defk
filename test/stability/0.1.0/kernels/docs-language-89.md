<!-- docs/language.md line 89 of v0.1.0. A frozen file is never edited. -->

```elixir
defmodule Stats do
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
iex> Stats.dot(<<1.0::float-native, 2.0::float-native>>, <<3.0::float-native, 4.0::float-native>>)
11.0
```
