<!-- lib/defk/errors.ex line 364 of v0.1.0. A frozen file is never edited. -->

<!-- defk-example error: nested-tuple -->
```elixir
defk f(x :: i64) :: {i64, {i64, i64}} do
  {x, {x, x}}
end
```
