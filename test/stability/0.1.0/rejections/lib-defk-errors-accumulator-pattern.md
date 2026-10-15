<!-- lib/defk/errors.ex line 591 of v0.1.0. A frozen file is never edited. -->

<!-- defk-example error: accumulator-pattern -->
```elixir
defk f(n :: i64) :: i64 do
  for i <- 1..n//1, reduce: 0 do
    acc when acc < 100 -> acc + i
  end
end
```
