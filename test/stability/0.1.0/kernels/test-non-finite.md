<!-- after test/non_finite_test.exs, test/log2_log10_test.exs of v0.1.0: the test sample (dev/stability/sample.exs), run at the tag. A frozen file is never edited. -->

```elixir
defk arith(x :: f64, y :: f64) :: {f64, f64, f64} do
  {x + y, x * y, x / y}
end

defk roots(x :: f64) :: {f64, f64, f64, f64} do
  {sqrt(x), log(x), log2(x), log10(x)}
end

defk growth(x :: f64, y :: f64) :: {f64, f64} do
  {exp(x), pow(x, y)}
end

defk at(a :: [f64], i :: i64) :: f64 do
  a[i]
end

defk sum_all(a :: [f64]) :: f64 do
  for x <- a, reduce: 0.0 do
    acc -> acc + x
  end
end

defk safe_div(x :: f64, y :: f64) :: f64 do
  if y != 0.0, do: x / y, else: 0.0
end

defk trunc_nan(x :: f64, y :: f64) :: i64 do
  trunc((x - y) / (x - y))
end

defk compare(i :: i64, x :: f64, y :: f64) :: bool do
  i > x * y
end
```

```elixir
iex> M.arith(1.0, 2.0)
{3.0, 2.0, 0.5}

iex> M.arith(1.0e308, 10.0)
** (ArithmeticError) float result of 1e+308 * 10 is inf or NaN

iex> M.arith(1.0, 0.0)
** (ArithmeticError) bad argument in arithmetic expression: division by zero

iex> M.arith(0.0, 0.0)
** (ArithmeticError) bad argument in arithmetic expression: division by zero

iex> M.arith(1.0, -0.0)
** (ArithmeticError) bad argument in arithmetic expression: division by zero

iex> M.arith(1.0e-308, 1.0e-308)
{2.0e-308, 0.0, 1.0}

iex> M.arith(3, 2)
{5.0, 6.0, 1.5}

iex> M.roots(4.0)
{2.0, 1.3862943611198906, 2.0, 0.6020599913279624}

iex> M.roots(-1.0)
** (ArithmeticError) sqrt of negative number -1

iex> M.roots(0.0)
** (ArithmeticError) log of non-positive number 0

iex> M.roots(-0.0)
** (ArithmeticError) log of non-positive number -0

iex> M.growth(1.0, 2.0)
{2.718281828459045, 1.0}

iex> M.growth(1000.0, 0.0)
** (ArithmeticError) float result of exp(1000) is inf or NaN

iex> M.growth(-1000.0, 0.0)
{0.0, 1.0}

iex> M.growth(10.0, 400.0)
** (ArithmeticError) float result of pow(10, 400) is inf or NaN

iex> M.growth(-8.0, 0.5)
** (ArithmeticError) float result of pow(-8, 0.5) is inf or NaN

iex> M.at(<<0x7FF8000000000000::64-native>>, 0)
** (ArgumentError) non-finite float (inf or NaN) read from an input array at index 0

iex> M.at(<<0x7FF0000000000000::64-native, 1.0::float-native>>, 1)
1.0

iex> M.at(<<0xFFF0000000000000::64-native>>, 0)
** (ArgumentError) non-finite float (inf or NaN) read from an input array at index 0

iex> M.sum_all(<<1.0::float-native, 0x7FF8000000000000::64-native>>)
** (ArgumentError) non-finite float (inf or NaN) read from an input array at index 1

iex> M.sum_all(<<1.0e308::float-native, 1.0e308::float-native>>)
** (ArithmeticError) float result of 1e+308 + 1e+308 is inf or NaN

iex> M.sum_all(<<>>)
0.0

iex> M.safe_div(1.0, 0.0)
0.0

iex> M.safe_div(1.0, 4.0)
0.25

iex> M.trunc_nan(1.0, 1.0)
** (ArithmeticError) bad argument in arithmetic expression: division by zero

iex> M.trunc_nan(3.0, 1.0)
1

iex> M.compare(1, 1.0e308, 10.0)
** (ArithmeticError) float result of 1e+308 * 10 is inf or NaN

iex> M.compare(1, 0.5, 0.5)
true
```
