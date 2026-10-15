<!-- lib/defk/errors.ex line 270 of v0.1.0. A frozen file is never edited. -->

<!-- defk-example error: tuple-binding -->
```elixir
defk f(x :: i64) :: i64 do
  t = {x, x + 1}
  x
end
```
