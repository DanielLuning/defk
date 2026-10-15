<!-- docs/guides/cheatsheet.cheatmd line 126 of v0.1.0. A frozen file is never edited. -->

```elixir
defk fnv1a(bytes :: [u8]) :: u64 do
  for b <- bytes, reduce: 0xCBF29CE484222325 do
    h -> band(bxor(h, b) * 0x100000001B3, 0xFFFFFFFFFFFFFFFF)
  end
end
```

```elixir
iex> M.fnv1a("a")
12638187200555641996
```
