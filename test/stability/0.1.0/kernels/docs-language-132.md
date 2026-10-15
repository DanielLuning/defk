<!-- docs/language.md line 132 of v0.1.0. A frozen file is never edited. -->

```elixir
defk classify(x :: i64, strict :: bool) :: i64
defk classify(0, _), do: 0
defk classify(x, true) when x in 1..9, do: 1
defk classify(x, _strict) when x > 0, do: 2
defk classify(_, false), do: -1
```

```elixir
iex> M.classify(0, true)
0

iex> M.classify(5, true)
1

iex> M.classify(50, true)
2

iex> M.classify(-3, false)
-1

iex> M.classify(-3, true)
** (FunctionClauseError) no function clause matching in M.classify/2
```
