<!-- lib/defk/errors.ex line 464 of v0.1.0. A frozen file is never edited. -->

<!-- defk-example error: fn-argument -->
```elixir
defk f(x :: i64) :: bool do
  Enum.all?(1..x//1, &(&1 > 0))
end
```
