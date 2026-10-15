<!-- lib/defk/errors.ex line 499 of v0.1.0. A frozen file is never edited. -->

<!-- defk-example error: for-collect -->
```elixir
defk f(a :: [f64]) :: [f64] do
  for x <- a, do: x * 2.0
end
```
