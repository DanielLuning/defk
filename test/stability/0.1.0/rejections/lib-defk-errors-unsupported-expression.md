<!-- lib/defk/errors.ex line 724 of v0.1.0. A frozen file is never edited. -->

<!-- defk-example error: unsupported-expression -->
```elixir
defk f(x :: i64) :: i64 do
  r = 1..x
  x
end
```
