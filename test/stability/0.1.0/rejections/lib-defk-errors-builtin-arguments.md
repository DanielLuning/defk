<!-- lib/defk/errors.ex line 387 of v0.1.0. A frozen file is never edited. -->

<!-- defk-example error: builtin-arguments -->
```elixir
defk f(x :: i64, y :: f64) :: i64 do
  div(x, y)
end
```
