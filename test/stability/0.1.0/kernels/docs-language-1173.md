<!-- docs/language.md line 1173 of v0.1.0. A frozen file is never edited. -->

```elixir
defk get(a :: [f64], i :: i64) :: f64 do
  a[i]
end
```

```elixir
iex> M.get(<<1.0::float-native>>, 1)
** (Enum.OutOfBoundsError) index 1 out of bounds for array of length 1
```
