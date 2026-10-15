<!-- docs/guides/cheatsheet.cheatmd line 186 of v0.1.0. A frozen file is never edited. -->

```elixir
defk first_negative(a :: [i64]) :: i64 do
  Enum.reduce_while(0..(length(a) - 1)//1, -1, fn i, acc ->
    if a[i] < 0, do: {:halt, i}, else: {:cont, acc}
  end)
end
```

```elixir
iex> M.first_negative(<<4::signed-64-native, -2::signed-64-native>>)
1
```
