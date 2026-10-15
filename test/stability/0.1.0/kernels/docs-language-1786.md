<!-- docs/language.md line 1786 of v0.1.0. A frozen file is never edited. -->

```elixir
defk pick_sum(c :: bool, a :: [i64], b :: [i64]) :: {[i64], i64} do
  x = if c, do: a, else: b
  x[0] = x[0] + 1

  s =
    for v <- x, reduce: 0 do
      acc -> acc + v
    end

  {x, s}
end
```

```elixir
iex> a = <<1::64-signed-native, 2::64-signed-native>>

iex> {x, s} = M.pick_sum(true, a, <<>>)

iex> {x, s, a}
{<<2, 0, 0, 0, 0, 0, 0, 0, 2, 0, 0, 0, 0, 0, 0, 0>>, 4, <<1, 0, 0, 0, 0, 0, 0, 0, 2, 0, 0, 0, 0, 0, 0, 0>>}
```
