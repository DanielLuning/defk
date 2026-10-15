<!-- lib/defk/errors.ex line 533 of v0.1.0. A frozen file is never edited. -->

<!-- defk-example error: generator-pattern -->
```elixir
defk f(a :: [f64]) :: f64 do
  for {x, i} <- Enum.with_index(a), reduce: 0.0 do
    acc -> acc + x * i
  end
end
```
