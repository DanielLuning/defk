<!-- docs/guides/runtime-contract.md line 65 of v0.1.0. A frozen file is never edited. -->

```elixir
defk bump(a :: [i64], i :: i64) :: [i64] do
  a[i] = a[i] + 1
  a
end
```

```elixir
iex> a = <<1::signed-64-native, 2::signed-64-native>>

iex> M.bump(a, 1)
<<1::signed-64-native, 3::signed-64-native>>

iex> a
<<1::signed-64-native, 2::signed-64-native>>

iex> M.bump(a, 2)
** (Enum.OutOfBoundsError) index 2 out of bounds for array of length 2
```
