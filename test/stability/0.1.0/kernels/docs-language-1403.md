<!-- docs/language.md line 1403 of v0.1.0. A frozen file is never edited. -->

```elixir
defk update(regs :: [u8], idx :: [i64], ranks :: [i64]) :: [u8] do
  for k <- 0..(length(idx) - 1)//1 do
    j = idx[k]
    regs[j] = max(regs[j], ranks[k])
  end

  regs
end
```

```elixir
iex> regs = <<0, 3, 1, 0>>

iex> M.update(regs, <<0::64-native, 2::64-native>>, <<2::64-native, 5::64-native>>)
<<2, 3, 5, 0>>

iex> regs
<<0, 3, 1, 0>>
```
