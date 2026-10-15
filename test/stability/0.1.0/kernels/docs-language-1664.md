<!-- docs/language.md line 1664 of v0.1.0. A frozen file is never edited. -->

```elixir
defk classify(x :: i64, y :: i64) :: i64 do
  case x do
    ^y -> 0
    -1 -> 1
    n when n > 10 and rem(n, 2) == 0 -> n
    _ -> 2
  end
end
```

```elixir
iex> M.classify(3, 3)
0

iex> M.classify(12, 0)
12

iex> M.classify(11, 0)
2
```
