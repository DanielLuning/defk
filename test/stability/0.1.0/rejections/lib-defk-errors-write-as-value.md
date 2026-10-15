<!-- lib/defk/errors.ex line 202 of v0.1.0. A frozen file is never edited. -->

<!-- defk-example error: write-as-value -->
```elixir
defk f(n :: i64) :: [f64] do
  out = alloc(f64, 1)
  out[0] = float(n)
end
```
