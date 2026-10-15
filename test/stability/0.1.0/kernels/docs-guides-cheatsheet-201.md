<!-- docs/guides/cheatsheet.cheatmd line 201 of v0.1.0. A frozen file is never edited. -->

```elixir
defk evens(a :: [i64]) :: bitstring do
  for x <- a, reduce: <<>> do
    acc -> if rem(x, 2) == 0, do: <<acc::bitstring, x::64>>, else: acc
  end
end
```

```elixir
iex> M.evens(<<1::signed-64-native, 2::signed-64-native, 4::signed-64-native>>)
<<2::64, 4::64>>
```
