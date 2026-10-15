<!-- lib/defk/errors.ex line 693 of v0.1.0. A frozen file is never edited. -->

<!-- defk-example error: unsupported-list -->
```elixir
defk f(x :: i64) :: i64 do
  xs = [x, x + 1]
  x
end
```
