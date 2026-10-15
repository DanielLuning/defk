<!-- lib/defk/errors.ex line 474 of v0.1.0. A frozen file is never edited. -->

<!-- defk-example error: reduce-while-tail -->
```elixir
defk f(x :: i64) :: i64 do
  Enum.reduce_while(1..x//1, 0, fn i, acc -> acc + i end)
end
```
