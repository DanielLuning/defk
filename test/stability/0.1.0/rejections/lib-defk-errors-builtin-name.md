<!-- lib/defk/errors.ex line 136 of v0.1.0. A frozen file is never edited. -->

<!-- defk-example error: builtin-name -->
```elixir
defk abs(x :: i64) :: i64 do
  if x < 0, do: -x, else: x
end
```
