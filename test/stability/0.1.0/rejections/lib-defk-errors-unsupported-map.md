<!-- lib/defk/errors.ex line 661 of v0.1.0. A frozen file is never edited. -->

<!-- defk-example error: unsupported-map -->
```elixir
defk f(x :: i64) :: i64 do
  m = %{a: x}
  x
end
```
