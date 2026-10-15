<!-- docs/language.md line 1430 of v0.1.0. A frozen file is never edited. -->

```elixir
defk update_many(sk :: [u64], d :: i64, w :: i64, hashes :: [u64]) :: [u64] do
  for h <- hashes do
    h1 = band(h, 0xFFFFFFFF)
    h2 = bsr(h, 32)

    for r <- 0..(d - 1)//1 do
      col = rem(band(h1 + r * h2, 0xFFFFFFFF), w)
      idx = r * w + col
      sk[idx] = sk[idx] + 1
    end
  end

  sk
end
```

```elixir
iex> sk = <<0::size(6 * 64)>>

iex> out = M.update_many(sk, 2, 3, <<4294967297::64-native, 4294967297::64-native>>)

iex> for <<c::64-native <- out>>, do: c
[0, 2, 0, 0, 0, 2]
```
