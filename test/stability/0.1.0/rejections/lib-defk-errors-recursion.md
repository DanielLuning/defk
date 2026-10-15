<!-- lib/defk/errors.ex line 417 of v0.1.0. A frozen file is never edited. -->

<!-- defk-example error: recursion -->
```elixir
defk f(x :: i64) :: i64 do
  if x == 0, do: 0, else: x + f(x - 1)
end
```
