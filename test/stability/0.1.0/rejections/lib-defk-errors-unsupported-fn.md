<!-- lib/defk/errors.ex line 703 of v0.1.0. A frozen file is never edited. -->

<!-- defk-example error: unsupported-fn -->
```elixir
defk f(x :: i64) :: i64 do
  g = fn y -> y * 2 end
  x
end
```
