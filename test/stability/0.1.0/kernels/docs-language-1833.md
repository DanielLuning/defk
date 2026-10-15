<!-- docs/language.md line 1833 of v0.1.0. A frozen file is never edited. -->

```elixir
defk even_sum(n :: i64) :: i64 do
  for i <- 0..n//1, rem(i, 2) == 0, reduce: 0 do
    acc -> acc + i
  end
end
```

```elixir
iex> M.even_sum(10)
30

iex> M.even_sum(-1)
0
```
