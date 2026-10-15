<!-- lib/defk/errors.ex line 544 of v0.1.0. A frozen file is never edited. -->

<!-- defk-example error: generator-source -->
```elixir
defk f(n :: i64) :: i64 do
  for i <- n, reduce: 0 do
    acc -> acc + i
  end
end
```
