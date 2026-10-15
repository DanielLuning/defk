<!-- lib/defk/errors.ex line 748 of v0.1.0. A frozen file is never edited. -->

<!-- defk-example error: shift-overflow -->
```elixir
defk f(x :: i64) :: i64 do
  band(x, 1 <<< 63)
end
```
