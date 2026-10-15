<!-- docs/language.md line 1743 of v0.1.0. A frozen file is never edited. -->

```elixir
defk split(x :: i64, f :: f64) :: f64 do
  {n, g} =
    cond do
      x > 100 -> {x - 100, f}
      x < 0 -> {-x, -f}
      true -> {0, f * 0.5}
    end

  float(n) + g
end
```

```elixir
iex> M.split(150, 1.0)
51.0

iex> M.split(-3, 2.0)
1.0

iex> M.split(7, 3.0)
1.5
```
