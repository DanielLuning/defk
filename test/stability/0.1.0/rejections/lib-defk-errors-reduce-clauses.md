<!-- lib/defk/errors.ex line 566 of v0.1.0. A frozen file is never edited. -->

<!-- defk-example error: reduce-clauses -->
```elixir
defk f(n :: i64) :: i64 do
  for i <- 1..n//1, reduce: 0 do
    0 -> i
    acc -> acc + i
  end
end
```
