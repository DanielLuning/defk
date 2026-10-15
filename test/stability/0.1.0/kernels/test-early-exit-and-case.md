<!-- after test/early_exit_test.exs, test/case_in_test.exs, test/case_guard_errors_test.exs of v0.1.0: the test sample (dev/stability/sample.exs), run at the tag. A frozen file is never edited. -->

```elixir
defk abs_sum_until(n :: i64, limit :: i64) :: i64 do
  Enum.reduce_while(-n..n//1, 0, fn x, acc ->
    next = if x > 0, do: acc + x, else: acc - x
    if next > limit, do: {:halt, acc}, else: {:cont, next}
  end)
end

defk first_div(x :: i64) :: i64 do
  Enum.reduce_while(2..x//1, x, fn d, _ ->
    if rem(x, d) == 0, do: {:halt, d}, else: {:cont, x}
  end)
end

defk sum_first_divs(n :: i64) :: i64 do
  for i <- 2..n//1, reduce: 0 do
    acc -> acc + first_div(i)
  end
end

defk all_any(n :: i64, k :: i64) :: {bool, bool} do
  {Enum.all?(1..n//1, fn x -> rem(x, k) != 0 end), Enum.any?(1..n//1, fn x -> x * x == k end)}
end

defk prime?(x :: i64) :: bool do
  Enum.all?(2..trunc(sqrt(x))//1, fn d -> rem(x, d) != 0 end)
end

defk find_at_least(a :: [i64], t :: i64) :: i64 do
  Enum.reduce_while(0..(length(a) - 1)//1, -1, fn i, _ ->
    if a[i] >= t, do: {:halt, i}, else: {:cont, -1}
  end)
end

defk sum_until(a :: [i64], stop :: i64, n :: i64) :: i64 do
  Enum.reduce_while(0..n//1, 0, fn i, acc ->
    if i == stop, do: {:halt, acc}, else: {:cont, acc + a[i]}
  end)
end

defk until_negative(a :: [f64]) :: {i64, f64} do
  Enum.reduce_while(a, {0, 0.0}, fn x, {n, s} ->
    if x < 0.0, do: {:halt, {n, s}}, else: {:cont, {n + 1, s + x}}
  end)
end

defk case_val(x :: i64) :: i64 do
  case x do
    0 -> 10
    -1 -> 30
    n when n > 100 and rem(n, 2) == 0 -> n * 2
    n when n in 1..9 -> n
    _ -> 40
  end
end

defk case_guard(x :: i64, y :: i64) :: i64 do
  case x do
    n when div(n, y) > 2 -> 1
    n when rem(n, y) == 1 or n < 0 -> 2
    n when n > 1000 -> 3
    _ -> 0
  end
end
```

```elixir
iex> M.abs_sum_until(3, 100)
12

iex> M.abs_sum_until(10, 20)
19

iex> M.first_div(91)
7

iex> M.first_div(97)
97

iex> M.first_div(1)
1

iex> M.sum_first_divs(10)
28

iex> M.all_any(10, 3)
{false, false}

iex> M.all_any(10, 4)
{false, true}

iex> M.all_any(0, 0)
{true, false}

iex> M.all_any(5, 0)
** (ArithmeticError) rem/2 by zero

iex> M.prime?(97)
true

iex> M.prime?(91)
false

iex> M.prime?(2)
true

iex> M.prime?(-1)
** (ArithmeticError) sqrt of negative number -1

iex> M.find_at_least(<<1::64-native, 5::64-native, 9::64-native>>, 5)
1

iex> M.find_at_least(<<1::64-native, 5::64-native, 9::64-native>>, 10)
-1

iex> M.find_at_least(<<>>, 0)
-1

iex> M.sum_until(<<1::64-native, 2::64-native>>, 2, 5)
3

iex> M.sum_until(<<1::64-native, 2::64-native>>, 3, 5)
** (Enum.OutOfBoundsError) index 2 out of bounds for array of length 2

iex> M.sum_until(<<>>, 0, 5)
0

iex> M.until_negative(<<1.0::float-native, 2.0::float-native, -1.0::float-native, 4.0::float-native>>)
{2, 3.0}

iex> M.until_negative(<<>>)
{0, 0.0}

iex> M.case_val(0)
10

iex> M.case_val(-1)
30

iex> M.case_val(102)
204

iex> M.case_val(101)
40

iex> M.case_val(9)
9

iex> M.case_val(10)
40

iex> M.case_guard(10, 3)
1

iex> M.case_guard(7, 3)
2

iex> M.case_guard(2000, 0)
3

iex> M.case_guard(7, 0)
0

iex> M.case_guard(-5, 0)
0

iex> M.case_guard(-5, 1)
2
```
