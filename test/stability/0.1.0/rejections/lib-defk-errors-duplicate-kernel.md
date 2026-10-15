<!-- lib/defk/errors.ex line 124 of v0.1.0. A frozen file is never edited. -->

<!-- defk-example error: duplicate-kernel -->
```elixir
defk f(x :: i64) :: i64 do
  x
end

defk f(x :: i64) :: i64 do
  x + 1
end
```
