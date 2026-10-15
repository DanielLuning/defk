<!-- docs/language.md line 1969 of v0.1.0. A frozen file is never edited. -->

```elixir
defk fft_size(n :: i64) :: i64 do
  if n < 1 or band(n, n - 1) != 0, do: raise(ArgumentError, "n must be a power of two")
  ctz(n)
end
```

```elixir
iex> M.fft_size(1024)
10

iex> M.fft_size(12)
** (ArgumentError) n must be a power of two
```
