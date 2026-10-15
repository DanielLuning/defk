<!-- after test/u64_test.exs of v0.1.0: the test sample (dev/stability/sample.exs), run at the tag. A frozen file is never edited. -->

```elixir
@mask64 0xFFFFFFFFFFFFFFFF

defk add(a :: u64, b :: u64) :: u64 do
  a + b
end

defk sub(a :: u64, b :: u64) :: u64 do
  a - b
end

defk mul(a :: u64, b :: u64) :: u64 do
  a * b
end

defk divrem(a :: u64, b :: u64) :: {u64, u64} do
  {div(a, b), rem(a, b)}
end

defk shifts(a :: u64, n :: i64) :: {u64, u64} do
  {bsl(a, n), bsr(a, n)}
end

defk minmax(a :: u64, b :: u64) :: {u64, u64} do
  {min(a, b), max(a, b)}
end

defk cmp(a :: u64, b :: i64) :: {bool, bool, bool, bool} do
  {a < b, a == b, a === b, b >= a}
end

defk cmpf(a :: u64, f :: f64) :: {bool, bool, bool} do
  {a < f, a == f, f <= a}
end

defk to_i64(a :: u64) :: i64 do
  a
end

defk from_i64(x :: i64) :: u64 do
  x
end

defk to_u64(x :: i64) :: u64 do
  band(x, @mask64)
end

defk to_f(a :: u64) :: {f64, f64} do
  {float(a), a / 2}
end

defk total(hs :: [u64]) :: u64 do
  for h <- hs, reduce: 0 do
    acc -> acc + h
  end
end
```

```elixir
iex> M.add(18446744073709551615, 0)
18446744073709551615

iex> M.add(18446744073709551615, 1)
** (ArithmeticError) u64 overflow in 18446744073709551615 + 1

iex> M.add(-1, 0)
** (ArgumentError) argument 1 (a) must be an integer fitting in u64

iex> M.sub(5, 5)
0

iex> M.sub(3, 5)
** (ArithmeticError) u64 overflow in 3 - 5

iex> M.mul(4294967296, 4294967295)
18446744069414584320

iex> M.mul(4294967296, 4294967296)
** (ArithmeticError) u64 overflow in 4294967296 * 4294967296

iex> M.divrem(18446744073709551615, 9223372036854775808)
{1, 9223372036854775807}

iex> M.divrem(1, 0)
** (ArithmeticError) div/2 by zero

iex> M.shifts(1, 63)
{9223372036854775808, 0}

iex> M.shifts(9223372036854775808, 0)
{9223372036854775808, 9223372036854775808}

iex> M.shifts(9223372036854775808, 1)
** (ArithmeticError) u64 overflow in bsl(9223372036854775808, 1)

iex> M.shifts(3, 63)
** (ArithmeticError) u64 overflow in bsl(3, 63)

iex> M.shifts(18446744073709551615, 64)
** (ArithmeticError) u64 overflow in bsl(18446744073709551615, 64)

iex> M.minmax(18446744073709551615, 0)
{0, 18446744073709551615}

iex> M.cmp(9223372036854775808, -1)
{false, false, false, false}

iex> M.cmp(9223372036854775808, 9223372036854775807)
{false, false, false, false}

iex> M.cmp(5, 5)
{false, true, true, true}

iex> M.cmpf(9223372036854775808, 9223372036854775808.0)
{false, true, true}

iex> M.cmpf(9223372036854775809, 9223372036854775808.0)
{false, false, true}

iex> M.to_i64(9223372036854775807)
9223372036854775807

iex> M.to_i64(9223372036854775808)
** (ArithmeticError) 9223372036854775808 does not fit in i64

iex> M.from_i64(0)
0

iex> M.from_i64(-1)
** (ArithmeticError) -1 does not fit in u64

iex> M.to_u64(-1)
18446744073709551615

iex> M.to_u64(-9223372036854775808)
9223372036854775808

iex> M.to_f(18446744073709551615)
{1.8446744073709552e19, 9.223372036854776e18}

iex> M.total(<<9223372036854775808::unsigned-64-native, 1::unsigned-64-native>>)
9223372036854775809

iex> M.total(<<18446744073709551615::unsigned-64-native, 1::unsigned-64-native>>)
** (ArithmeticError) u64 overflow in 18446744073709551615 + 1
```
