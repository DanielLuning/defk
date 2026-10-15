<!-- lib/defk/errors.ex line 214 of v0.1.0. A frozen file is never edited. -->

<!-- defk-example error: if-without-else -->
```elixir
defk f(x :: i64) :: i64 do
  y = if x > 0, do: 1
  y
end
```
