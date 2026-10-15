<!-- docs/language.md line 914 of v0.1.0. A frozen file is never edited. -->

```elixir
defk dod_bits(acc :: bitstring, dod :: i64) :: bitstring do
  cond do
    dod == 0 -> <<acc::bitstring, 0::1>>
    dod >= -64 and dod <= 63 -> <<acc::bitstring, 0b10::2, dod::7-signed>>
    true -> <<acc::bitstring, 0b11::2, band(dod, 0xFFFFFFFF)::32>>
  end
end

defk dods(ds :: [i64]) :: bitstring do
  for d <- ds, reduce: <<>> do
    acc -> dod_bits(acc, d)
  end
end
```

```elixir
iex> M.dods(<<0::64-native, -1::64-native, 100::64-native>>)
<<0::1, 0b10::2, -1::7-signed, 0b11::2, 100::32>>
```
