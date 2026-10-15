<!-- lib/defk/errors.ex line 714 of v0.1.0. A frozen file is never edited. -->

<!-- defk-example error: unsupported-construct -->
```elixir
defk f(x :: i64) :: i64 do
  unless x > 0, do: 0, else: x
end
```
