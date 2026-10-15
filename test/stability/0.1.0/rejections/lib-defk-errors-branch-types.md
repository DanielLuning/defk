<!-- lib/defk/errors.ex line 236 of v0.1.0. A frozen file is never edited. -->

<!-- defk-example error: branch-types -->
```elixir
defk f(x :: i64) :: f64 do
  if x > 0, do: 1, else: 2.5
end
```
