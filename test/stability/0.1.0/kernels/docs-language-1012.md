<!-- docs/language.md line 1012 of v0.1.0. A frozen file is never edited. -->

```elixir
@s16_min -32_768
@s16_max 32_767
@table <<0, 1, 3, 7, 15, 31, 63, 127>>

defk clip(x :: i64) :: i64 do
  min(max(x, @s16_min), @s16_max)
end

defk ones(i :: i64) :: i64 do
  @table[band(i, 7)]
end
```

```elixir
iex> M.clip(40_000)
32767

iex> M.clip(-40_000)
-32768

iex> M.ones(10)
3
```
