<!-- docs/language.md line 394 of v0.1.0. A frozen file is never edited. -->

```elixir
defk mul(a :: i64, b :: i64) :: i64 do
  a * b
end
```

```elixir
iex> M.mul(4611686018427387904, 2)
** (ArithmeticError) i64 overflow in 4611686018427387904 * 2
```
