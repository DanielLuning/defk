<!-- docs/language.md line 1513 of v0.1.0. A frozen file is never edited. -->

```elixir
defk snapshot(n :: i64) :: {f64, f64} do
  a = alloc(f64, n)
  b = a
  a[0] = 1.0
  {a[0], b[0]}
end
```

```elixir
iex> M.snapshot(1)
{1.0, 0.0}
```
