<!-- lib/defk/errors.ex line 511 of v0.1.0. A frozen file is never edited. -->

<!-- defk-example error: for-option -->
```elixir
defk f(a :: [f64]) :: f64 do
  for x <- a, uniq: true, reduce: 0.0 do
    acc -> acc + x
  end
end
```
