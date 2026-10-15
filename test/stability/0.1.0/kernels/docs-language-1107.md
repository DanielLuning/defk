<!-- docs/language.md line 1107 of v0.1.0. A frozen file is never edited. -->

```elixir
defk rebind(n :: i64) :: i64 do
  x = 0

  for i <- 0..n//1 do
    x = x + i
  end

  x
end
```

```elixir
iex> M.rebind(5)
0
```
