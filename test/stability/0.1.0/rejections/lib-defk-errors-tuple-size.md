<!-- lib/defk/errors.ex line 280 of v0.1.0. A frozen file is never edited. -->

<!-- defk-example error: tuple-size -->
```elixir
defk f(x :: i64) :: i64 do
  {a, b} = {x, x, x}
  a + b
end
```
