<!-- lib/defk/errors.ex line 646 of v0.1.0. A frozen file is never edited. -->

<!-- defk-example error: case-guard -->
```elixir
defk g(x :: i64) :: i64 do
  x * 2
end

defk f(x :: i64) :: i64 do
  case x do
    n when g(n) > 4 -> 1
    _ -> 0
  end
end
```
