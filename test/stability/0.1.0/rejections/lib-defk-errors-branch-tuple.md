<!-- lib/defk/errors.ex line 245 of v0.1.0. A frozen file is never edited. -->

<!-- defk-example error: branch-tuple -->
```elixir
defk f(x :: i64) :: i64 do
  {a, b} = if x > 0, do: {x, 1}, else: x
  a + b
end
```
