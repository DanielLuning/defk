<!-- docs/language.md line 1383 of v0.1.0. A frozen file is never edited. -->

```elixir
defk histogram(bytes :: [u8]) :: [i64] do
  h = alloc(i64, 256)

  for b <- bytes do
    h[b] = h[b] + 1
  end

  h
end
```

```elixir
iex> h = M.histogram(<<1, 1, 255>>)

iex> {byte_size(h), :binary.part(h, 8, 8)}
{2048, <<2::64-native>>}
```
