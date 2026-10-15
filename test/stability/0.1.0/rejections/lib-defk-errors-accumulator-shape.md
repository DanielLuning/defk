<!-- lib/defk/errors.ex line 578 of v0.1.0. A frozen file is never edited. -->

<!-- defk-example error: accumulator-shape -->
```elixir
defk f(n :: i64) :: i64 do
  {s, c} =
    for i <- 1..n//1, reduce: {0, 0} do
      {s, c} -> {s + i}
    end

  s + c
end
```
