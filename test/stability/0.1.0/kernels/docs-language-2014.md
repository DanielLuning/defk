<!-- docs/language.md line 2014 of v0.1.0. A frozen file is never edited. -->

```elixir
defk count_primes(n :: i64) :: i64 do
  for i <- 2..n//1, reduce: 0 do
    count -> if prime?(i), do: count + 1, else: count
  end
end

defk prime?(x :: i64) :: bool do
  limit = trunc(:math.sqrt(x))

  for d <- 2..limit//1, reduce: true do
    p -> p and rem(x, d) != 0
  end
end
```

```elixir
iex> M.count_primes(100)
25
```
