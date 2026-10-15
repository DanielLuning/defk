<!-- docs/language.md line 734 of v0.1.0. A frozen file is never edited. -->

```elixir
@mask64 0xFFFFFFFFFFFFFFFF

defk fnv1a64(bytes :: [u8]) :: u64 do
  for b <- bytes, reduce: 0xCBF29CE484222325 do
    h -> band(bxor(h, b) * 0x100000001B3, @mask64)
  end
end
```

```elixir
iex> M.fnv1a64("")
14695981039346656037

iex> M.fnv1a64("a")
12638187200555641996
```
