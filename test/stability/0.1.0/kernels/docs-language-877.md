<!-- docs/language.md line 877 of v0.1.0. A frozen file is never edited. -->

```elixir
defk pack(xs :: [i64], n :: i64) :: bitstring do
  for x <- xs, reduce: <<>> do
    acc -> <<acc::bitstring, x::size(n)>>
  end
end
```

```elixir
iex> M.pack(<<1::64-native, 2::64-native, 3::64-native>>, 3)
<<41, 1::size(1)>>
```
