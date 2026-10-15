<!-- docs/guides/cheatsheet.cheatmd line 155 of v0.1.0. A frozen file is never edited. -->

```elixir
defk sign(x :: i64) :: i64 do
  cond do
    x > 0 -> 1
    x < 0 -> -1
    true -> 0
  end
end
```

```elixir
iex> M.sign(-7)
-1
```
