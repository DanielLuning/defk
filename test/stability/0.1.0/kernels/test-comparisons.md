<!-- after test/comparison_test.exs of v0.1.0: the test sample (dev/stability/sample.exs), run at the tag. A frozen file is never edited. -->

```elixir
defk cmp_if(a :: i64, b :: f64) :: {bool, bool, bool, bool, bool, bool, bool, bool} do
  {a === b, a !== b, a == b, a != b, a < b, a <= b, a > b, a >= b}
end

defk cmp_ff(a :: f64, b :: f64) :: {bool, bool, bool, bool, bool, bool, bool, bool} do
  {a === b, a !== b, a == b, a != b, a < b, a <= b, a > b, a >= b}
end

defk cmp_ii(a :: i64, b :: i64) :: {bool, bool, bool, bool} do
  {a === b, a == b, a < b, a >= b}
end

defk minmax_f(a :: f64, b :: f64) :: {f64, f64} do
  {min(a, b), max(a, b)}
end

defk minmax_i(a :: i64, b :: i64) :: {i64, i64} do
  {min(a, b), max(a, b)}
end

defk count_below(xs :: [i64], t :: f64) :: i64 do
  for i <- 0..(length(xs) - 1)//1, reduce: 0 do
    acc -> if xs[i] < t, do: acc + 1, else: acc
  end
end

defk clip(x :: i64) :: i64 do
  min(max(x, -32_768), 32_767)
end
```

```elixir
iex> M.cmp_if(9007199254740993, 9007199254740992.0)
{false, true, false, true, false, false, true, true}

iex> M.cmp_if(9223372036854775807, 9.223372036854776e18)
{false, true, false, true, true, true, false, false}

iex> M.cmp_if(-9223372036854775808, -9.223372036854776e18)
{false, true, true, false, false, true, false, true}

iex> M.cmp_if(0, -0.0)
{false, true, true, false, false, true, false, true}

iex> M.cmp_if(1, 1.0)
{false, true, true, false, false, true, false, true}

iex> M.cmp_ff(-0.0, 0.0)
{false, true, true, false, false, true, false, true}

iex> M.cmp_ff(0.0, 0.0)
{true, false, true, false, false, true, false, true}

iex> M.cmp_ff(1.0e300, -1.0e300)
{false, true, false, true, false, false, true, true}

iex> M.cmp_ii(-9223372036854775808, 9223372036854775807)
{false, false, true, false}

iex> M.cmp_ii(3, 3)
{true, true, false, true}

iex> M.minmax_f(-0.0, 0.0)
{-0.0, -0.0}

iex> M.minmax_f(0.0, -0.0)
{0.0, 0.0}

iex> M.minmax_f(1.0, -1.0e300)
{-1.0e300, 1.0}

iex> M.minmax_i(-9223372036854775808, 9223372036854775807)
{-9223372036854775808, 9223372036854775807}

iex> M.minmax_i(3, 3)
{3, 3}

iex> M.count_below(<<9007199254740993::64-signed-native, 9007199254740992::64-signed-native, -1::64-signed-native>>, 9007199254740992.0)
1

iex> M.count_below(<<>>, 0.0)
0

iex> M.clip(40000)
32767

iex> M.clip(-40000)
-32768

iex> M.clip(5)
5
```
