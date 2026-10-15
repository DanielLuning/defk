<!-- lib/defk/errors.ex line 637 of v0.1.0. A frozen file is never edited. -->

<!-- defk-example error: case-pattern-type -->
```elixir
defk f(b :: bool) :: i64 do
  case b do
    1 -> 1
    _ -> 0
  end
end
```
