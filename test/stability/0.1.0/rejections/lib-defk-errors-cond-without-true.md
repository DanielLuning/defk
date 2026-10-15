<!-- lib/defk/errors.ex line 224 of v0.1.0. A frozen file is never edited. -->

<!-- defk-example error: cond-without-true -->
```elixir
defk f(x :: i64) :: i64 do
  cond do
    x > 0 -> 1
    x < 0 -> -1
  end
end
```
