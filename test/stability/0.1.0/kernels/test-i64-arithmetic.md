<!-- after test/trunc_boundary_test.exs, test/range_limit_test.exs, test/defk_test.exs of v0.1.0: the test sample (dev/stability/sample.exs), run at the tag. A frozen file is never edited. -->

```elixir
defk add(a :: i64, b :: i64) :: i64 do
  a + b
end

defk mul(a :: i64, b :: i64) :: i64 do
  a * b
end

defk neg_abs(x :: i64) :: {i64, i64} do
  {-x, abs(x)}
end

defk divrem(a :: i64, b :: i64) :: {i64, i64} do
  {div(a, b), rem(a, b)}
end

defk trunc_round(x :: f64) :: {i64, i64} do
  {trunc(x), round(x)}
end

defk count(first :: i64, last :: i64, step :: i64) :: i64 do
  for _ <- first..last//step, reduce: 0 do
    acc -> acc + 1
  end
end
```

```elixir
iex> M.add(9223372036854775806, 1)
9223372036854775807

iex> M.add(9223372036854775807, 1)
** (ArithmeticError) i64 overflow in 9223372036854775807 + 1

iex> M.add(-9223372036854775808, -1)
** (ArithmeticError) i64 overflow in -9223372036854775808 + -1

iex> M.add(9223372036854775808, 0)
** (ArgumentError) argument 1 (a) must be an integer fitting in i64

iex> M.add(1.0, 0)
** (ArgumentError) argument 1 (a) must be an integer fitting in i64

iex> M.mul(-4611686018427387904, 2)
-9223372036854775808

iex> M.mul(4611686018427387904, 2)
** (ArithmeticError) i64 overflow in 4611686018427387904 * 2

iex> M.mul(-9223372036854775808, -1)
** (ArithmeticError) i64 overflow in -9223372036854775808 * -1

iex> M.neg_abs(-9223372036854775807)
{9223372036854775807, 9223372036854775807}

iex> M.neg_abs(-9223372036854775808)
** (ArithmeticError) i64 overflow in 0 - -9223372036854775808

iex> M.divrem(-7, 2)
{-3, -1}

iex> M.divrem(7, -2)
{-3, 1}

iex> M.divrem(-9223372036854775808, -1)
** (ArithmeticError) i64 overflow in div/2

iex> M.divrem(1, 0)
** (ArithmeticError) div/2 by zero

iex> M.trunc_round(-9223372036854775808.0)
{-9223372036854775808, -9223372036854775808}

iex> M.trunc_round(9223372036854774784.0)
{9223372036854774784, 9223372036854774784}

iex> M.trunc_round(9223372036854775808.0)
** (ArithmeticError) trunc/1: 9.22337e+18 does not fit in i64

iex> M.trunc_round(-9223372036854777856.0)
** (ArithmeticError) trunc/1: -9.22337e+18 does not fit in i64

iex> M.trunc_round(-2.5)
{-2, -3}

iex> M.trunc_round(2.5)
{2, 3}

iex> M.count(0, 9, 3)
4

iex> M.count(9, 0, -3)
4

iex> M.count(1, 0, 1)
0

iex> M.count(0, 9, 0)
** (ArgumentError) range step cannot be zero

iex> M.count(0, 9223372036854775807, 1)
** (ArithmeticError) range element 9223372036854775807 is within one step of the i64 limit (stepping past it overflows)

iex> M.count(9223372036854775800, 9223372036854775806, 1)
7
```
