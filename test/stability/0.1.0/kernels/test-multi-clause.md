<!-- after test/multi_clause_test.exs of v0.1.0: the test sample (dev/stability/sample.exs), run at the tag. A frozen file is never edited. -->

```elixir
defk pick(x :: i64, y :: i64) :: i64
defk pick(0, y), do: y
defk pick(x, 0) when x > 0, do: x * 10
defk pick(x, y) when x in [1, 2, 3] and y in -5..-1, do: x - y
defk pick(_x, 7), do: -7

defk classify(x :: i64, y :: i64) :: i64
defk classify(x, y) when div(x, y) > 2, do: 1
defk classify(x, y) when rem(x, y) == 1 or x < 0, do: 2
defk classify(x, _) when x > 1000, do: 3

defk choose(c :: bool, a :: f64, b :: f64) :: f64
defk choose(true, a, _), do: a
defk choose(false, _, b), do: b * 2.0

defk swap(a :: i64, b :: i64) :: i64
defk swap(b, a) when b > a, do: b - a

defk swap(x, 0) do
  b = x * 2
  b + 1
end

defk swap(a, b), do: a * 100 + b

defk stats(n :: i64, k :: i64) :: {i64, i64}
defk stats(0, _), do: {0, 0}

defk stats(n, k) when n > 0 do
  s =
    for i <- 1..n//1, reduce: 0 do
      acc -> acc + i * k
    end

  {n, s}
end

defk step(x :: i64) :: i64
defk step(x) when x >= 0 and x < 100, do: x + 1
defk step(x) when x < 0, do: x - 1

defk steps(xs :: [i64]) :: i64 do
  for x <- xs, reduce: 0 do
    acc -> acc + step(x)
  end
end

defk dod_bits(acc :: bitstring, dod :: i64) :: bitstring
defk dod_bits(acc, 0), do: <<acc::bitstring, 0::1>>
defk dod_bits(acc, dod) when dod >= -64 and dod <= 63, do: <<acc::bitstring, 0b10::2, dod::7-signed>>
defk dod_bits(acc, dod), do: <<acc::bitstring, 0b11::2, band(dod, 0xFFFFFFFF)::32>>

defk dods(ds :: [i64]) :: bitstring do
  for d <- ds, reduce: <<>> do
    acc -> dod_bits(acc, d)
  end
end
```

```elixir
iex> M.pick(0, 5)
5

iex> M.pick(4, 0)
40

iex> M.pick(2, -3)
5

iex> M.pick(4, 7)
-7

iex> M.pick(-1, 0)
** (FunctionClauseError) no function clause matching in M.pick/2

iex> M.pick(1, -6)
** (FunctionClauseError) no function clause matching in M.pick/2

iex> M.classify(10, 3)
1

iex> M.classify(7, 3)
2

iex> M.classify(2000, 0)
3

iex> M.classify(7, 0)
** (FunctionClauseError) no function clause matching in M.classify/2

iex> M.choose(true, 1.5, 2.0)
1.5

iex> M.choose(false, 1.5, 2.0)
4.0

iex> M.swap(5, 3)
2

iex> M.swap(3, 0)
3

iex> M.swap(3, 5)
305

iex> M.swap(0, 0)
1

iex> M.stats(0, 9)
{0, 0}

iex> M.stats(4, 3)
{4, 30}

iex> M.stats(-1, 3)
** (FunctionClauseError) no function clause matching in M.stats/2

iex> M.steps(<<1::64-native, -1::64-native>>)
0

iex> M.steps(<<100::64-native>>)
** (FunctionClauseError) no function clause matching in M.step/1

iex> M.dods(<<0::64-native, -1::64-native, 100::64-native>>)
<<95, 240, 0, 0, 6, 4::size(4)>>

iex> M.dods(<<>>)
""
```
