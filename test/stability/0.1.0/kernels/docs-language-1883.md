<!-- docs/language.md line 1883 of v0.1.0. A frozen file is never edited. -->

```elixir
defk prime_early?(x :: i64) :: bool do
  Enum.all?(2..trunc(:math.sqrt(x))//1, fn d -> rem(x, d) != 0 end)
end
```

```elixir
iex> M.prime_early?(97)
true

iex> M.prime_early?(91)
false
```
