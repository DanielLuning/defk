<!-- after test/raise_test.exs of v0.1.0: the test sample (dev/stability/sample.exs), run at the tag. A frozen file is never edited. -->

```elixir
defk arg(x :: i64) :: i64 do
  if x < 0, do: raise(ArgumentError, "x must not be negative")
  x * 2
end

defk arith(x :: i64) :: i64 do
  if x == 0, do: raise(ArithmeticError, "x is zero")
  div(100, x)
end

defk runtime(x :: i64) :: i64 do
  if x > 9, do: raise("x is too big")
  x
end

defk defaults(x :: i64) :: i64 do
  if x == 1, do: raise(ArgumentError)
  if x == 2, do: raise(ArithmeticError)
  if x == 3, do: raise(RuntimeError)
  x
end

defk odd_message(x :: i64) :: i64 do
  if x < 0, do: raise(ArgumentError, "a \"quoted\" \\ back??=slash %s %d, é ünïcode")
  x
end

defk in_case(x :: i64) :: i64 do
  case rem(x, 3) do
    0 -> raise ArgumentError, "multiple of three"
    1 -> x
    _ -> x
  end

  x + 1
end

defk in_reduce_while(a :: [i64]) :: i64 do
  Enum.reduce_while(0..(length(a) - 1)//1, 0, fn i, acc ->
    if a[i] < 0, do: raise(ArgumentError, "negative element")
    if a[i] == 0, do: {:halt, acc}, else: {:cont, acc + a[i]}
  end)
end

defk in_loop(n :: i64, at :: i64) :: i64 do
  for i <- 0..(n - 1)//1, reduce: 0 do
    acc ->
      if i == at, do: raise(RuntimeError, "reached at")
      rem(acc + i * i, 1_000_003)
  end
end

defk callee(x :: i64) :: i64 do
  if x == 7, do: raise(ArgumentError, "seven")
  x
end

defk caller(x :: i64) :: i64 do
  callee(x) + 1
end
```

```elixir
iex> M.arg(3)
6

iex> M.arg(-1)
** (ArgumentError) x must not be negative

iex> M.arith(5)
20

iex> M.arith(0)
** (ArithmeticError) x is zero

iex> M.runtime(9)
9

iex> M.runtime(10)
** (RuntimeError) x is too big

iex> M.defaults(0)
0

iex> M.defaults(1)
** (ArgumentError) argument error

iex> M.defaults(2)
** (ArithmeticError) bad argument in arithmetic expression

iex> M.defaults(3)
** (RuntimeError) runtime error

iex> M.odd_message(-1)
** (ArgumentError) a "quoted" \ back??=slash %s %d, é ünïcode

iex> M.in_case(4)
5

iex> M.in_case(3)
** (ArgumentError) multiple of three

iex> M.in_reduce_while(<<1::64-native, 2::64-native, 0::64-native, 5::64-native>>)
3

iex> M.in_reduce_while(<<1::64-native, -2::64-native>>)
** (ArgumentError) negative element

iex> M.in_loop(10, 100)
285

iex> M.in_loop(100_000, 99_999)
** (RuntimeError) reached at

iex> M.caller(1)
2

iex> M.caller(7)
** (ArgumentError) seven
```
