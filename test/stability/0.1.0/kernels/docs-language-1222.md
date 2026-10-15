<!-- docs/language.md line 1222 of v0.1.0. A frozen file is never edited. -->

```elixir
defk sum_words(b :: [u8]) :: i64 do
  for i <- 0..(length(b) - 8)//8, reduce: 0 do
    acc -> wrap64(acc + u64_le(b, i))
  end
end
```

```elixir
iex> M.sum_words(<<1::64-little, 2::64-little, 7>>)
3

iex> M.sum_words(<<-1::64-little, 1::64-little>>)
0
```
