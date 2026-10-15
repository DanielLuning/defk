<!-- lib/defk/errors.ex line 440 of v0.1.0. A frozen file is never edited. -->

<!-- defk-example error: enum-reduce -->
```elixir
defk f(a :: [f64]) :: f64 do
  Enum.reduce(a, 0.0, fn x, acc -> acc + x end)
end
```
