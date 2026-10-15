<!-- lib/defk/errors.ex line 289 of v0.1.0. A frozen file is never edited. -->

<!-- defk-example error: unsupported-pattern -->
```elixir
defk f(x :: i64) :: i64 do
  [a, b] = {x, x + 1}
  a + b
end
```
