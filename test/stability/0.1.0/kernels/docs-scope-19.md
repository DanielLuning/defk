<!-- docs/scope.md line 19 of v0.1.0. A frozen file is never edited. -->

```elixir
defk total(xs :: [i64]) :: i64 do
  for x <- xs, reduce: 0 do
    acc -> acc + x
  end
end
```

```elixir
iex> M.total(<<1::native-64, 2::native-64, 3::native-64>>)
6

iex> M.total(<<9223372036854775807::native-64, 1::native-64>>)
** (ArithmeticError) i64 overflow in 9223372036854775807 + 1
```
