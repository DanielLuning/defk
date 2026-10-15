<!-- docs/language.md line 506 of v0.1.0. A frozen file is never edited. -->

```elixir
defk gt(a :: i64, b :: f64) :: bool do
  a > b
end
```

```elixir
iex> M.gt(9007199254740993, 9007199254740992.0)
true
```
