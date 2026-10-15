<!-- lib/defk/errors.ex line 451 of v0.1.0. A frozen file is never edited. -->

<!-- defk-example error: enum-find -->
```elixir
defk f(a :: [f64], t :: f64) :: i64 do
  Enum.find_index(a, fn x -> x > t end)
end
```
