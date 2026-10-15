<!-- docs/language.md line 1596 of v0.1.0. A frozen file is never edited. -->

```elixir
defk first_nonempty(a :: [i64], b :: [i64]) :: [i64] do
  if length(a) > 0, do: a, else: b
end
```

```elixir
iex> a = <<1::64-signed-native, 2::64-signed-native>>

iex> :erts_debug.same(M.first_nonempty(a, <<>>), a)
true

iex> M.first_nonempty(<<>>, <<3::64-signed-native>>)
<<3, 0, 0, 0, 0, 0, 0, 0>>
```
