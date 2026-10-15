<!-- lib/defk/errors.ex line 429 of v0.1.0. A frozen file is never edited. -->

<!-- defk-example error: unsupported-call -->
```elixir
defk f(a :: [f64]) :: [f64] do
  Enum.map(a, fn x -> x * 2.0 end)
end
```
