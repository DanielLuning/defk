<!-- lib/defk/errors.ex line 159 of v0.1.0. A frozen file is never edited. -->

<!-- defk-example error: clause-types -->
```elixir
defk f(x :: i64) :: i64
defk f(0 :: i64) :: i64, do: 1
defk f(x), do: x * 2
```
