<!-- lib/defk/errors.ex line 405 of v0.1.0. A frozen file is never edited. -->

<!-- defk-example error: tuple-argument -->
```elixir
defk g(a :: i64, b :: i64) :: i64 do
  a + b
end

defk f(x :: i64) :: i64 do
  g({x, x})
end
```
