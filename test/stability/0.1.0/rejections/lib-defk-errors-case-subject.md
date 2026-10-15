<!-- lib/defk/errors.ex line 614 of v0.1.0. A frozen file is never edited. -->

<!-- defk-example error: case-subject -->
```elixir
defk f(x :: f64) :: i64 do
  case x do
    0.0 -> 0
    _ -> 1
  end
end
```
