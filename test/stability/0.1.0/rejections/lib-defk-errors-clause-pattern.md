<!-- lib/defk/errors.ex line 168 of v0.1.0. A frozen file is never edited. -->

<!-- defk-example error: clause-pattern -->
```elixir
defk f(x :: i64, y :: i64) :: i64
defk f(x, x), do: 0
defk f(x, y), do: x - y
```
