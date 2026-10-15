<!-- lib/defk/errors.ex line 555 of v0.1.0. A frozen file is never edited. -->

<!-- defk-example error: range-step -->
```elixir
defk f(n :: i64) :: i64 do
  for i <- 0..n//0, reduce: 0 do
    acc -> acc + i
  end
end
```
