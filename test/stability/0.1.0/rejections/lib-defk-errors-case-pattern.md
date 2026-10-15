<!-- lib/defk/errors.ex line 625 of v0.1.0. A frozen file is never edited. -->

<!-- defk-example error: case-pattern -->
```elixir
defk f(x :: i64) :: i64 do
  case x do
    {a, b} -> a + b
    _ -> 0
  end
end
```
