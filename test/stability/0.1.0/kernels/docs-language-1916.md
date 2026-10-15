<!-- docs/language.md line 1916 of v0.1.0. A frozen file is never edited. -->

```elixir
defk insert(slots :: [i64], counts :: [i64], key :: i64) :: {[i64], [i64], i64} do
  j = band(key, length(slots) - 1)
  new = if counts[j] == 0, do: 1, else: 0
  slots[j] = key
  counts[j] = counts[j] + 1
  {slots, counts, new}
end

defk tally(keys :: [i64]) :: {[i64], [i64], i64} do
  for k <- keys, reduce: {alloc(i64, 64), alloc(i64, 64), 0} do
    {slots, counts, n} ->
      {slots, counts, new} = insert(slots, counts, k)
      {slots, counts, n + new}
  end
end
```

```elixir
iex> {_slots, counts, n} = M.tally(<<1::64-native, 2::64-native, 1::64-native>>)

iex> {:binary.part(counts, 8, 16), n}
{<<2::64-native, 1::64-native>>, 2}
```
