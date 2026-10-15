<!-- docs/language.md line 832 of v0.1.0. A frozen file is never edited. -->

```elixir
defk hex_digit(x :: i64) :: i64 do
  "0123456789abcdef"[band(x, 15)]
end

defk starts_with?(s :: [u8], p :: [u8]) :: bool do
  if length(p) > length(s) do
    false
  else
    for i <- 0..(length(p) - 1)//1, reduce: true do
      acc -> acc and s[i] == p[i]
    end
  end
end

defk is_ham?(s :: [u8]) :: bool, do: starts_with?(s, "Ham")
```

```elixir
iex> M.hex_digit(255)
102

iex> M.is_ham?("Hamburg")
true

iex> M.starts_with?("Ha", "Ham")
false
```
