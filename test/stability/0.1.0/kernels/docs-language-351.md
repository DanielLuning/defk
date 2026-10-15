<!-- docs/language.md line 351 of v0.1.0. A frozen file is never edited. -->

```elixir
defk mean_var(a :: [f64]) :: {f64, f64} do
  {_n, mean, m2} =
    for x <- a, reduce: {0, 0.0, 0.0} do
      {n, mean, m2} ->
        n1 = n + 1
        d = x - mean
        mean1 = mean + d / n1
        {n1, mean1, m2 + d * (x - mean1)}
    end

  {mean, m2 / length(a)}
end
```

```elixir
iex> M.mean_var(<<1.0::float-native, 2.0::float-native, 3.0::float-native, 4.0::float-native>>)
{2.5, 1.25}
```
