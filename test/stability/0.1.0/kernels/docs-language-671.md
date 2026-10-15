<!-- docs/language.md line 671 of v0.1.0. A frozen file is never edited. -->

```elixir
defk crc32c_of(b :: [u8]) :: i64 do
  n = length(b)
  words = n - rem(n, 8)

  crc =
    for i <- 0..(words - 8)//8, reduce: 0xFFFFFFFF do
      crc -> crc32c(crc, band(u64_le(b, i), 0xFFFFFFFFFFFFFFFF), 64)
    end

  crc =
    for i <- words..(n - 1)//1, reduce: crc do
      crc -> crc32c(crc, b[i], 8)
    end

  bxor(crc, 0xFFFFFFFF)
end
```

```elixir
iex> M.crc32c_of("123456789")
0xE3069283

iex> M.crc32c_of(<<>>)
0
```
