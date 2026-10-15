<!-- docs/language.md line 195 of v0.1.0. A frozen file is never edited. -->

```elixir
defk dod_bits(acc :: bitstring, dod :: i64) :: bitstring
defk dod_bits(acc, 0), do: <<acc::bitstring, 0::1>>

defk dod_bits(acc, dod) when dod >= -64 and dod <= 63,
  do: <<acc::bitstring, 0b10::2, dod::7-signed>>

defk dod_bits(acc, dod), do: <<acc::bitstring, 0b11::2, band(dod, 0xFFFFFFFF)::32>>

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
