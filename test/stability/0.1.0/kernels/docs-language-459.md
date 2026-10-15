<!-- docs/language.md line 459 of v0.1.0. A frozen file is never edited. -->

```elixir
defk total(hashes :: [u64]) :: u64 do
  for h <- hashes, reduce: 0 do
    acc -> acc + h
  end
end
```

```elixir
iex> M.total(<<9223372036854775808::unsigned-64-native, 1::unsigned-64-native>>)
9223372036854775809

iex> M.total(<<18446744073709551615::unsigned-64-native, 1::unsigned-64-native>>)
** (ArithmeticError) u64 overflow in 18446744073709551615 + 1
```
