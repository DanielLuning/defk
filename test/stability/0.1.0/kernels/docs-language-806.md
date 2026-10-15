<!-- docs/language.md line 806 of v0.1.0. A frozen file is never edited. -->

```elixir
defk mix32(h :: i64, k :: i64) :: i64 do
  k = band(rotl(band(k * 0xCC9E2D51, 0xFFFFFFFF), 15, 32) * 0x1B873593, 0xFFFFFFFF)
  band(rotl(bxor(h, k), 13, 32) * 5 + 0xE6546B64, 0xFFFFFFFF)
end
```

```elixir
iex> M.mix32(0, 1)
651101558
```
