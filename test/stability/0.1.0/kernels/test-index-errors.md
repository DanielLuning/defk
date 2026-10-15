<!-- after test/non_finite_test.exs, test/range_copy_test.exs, test/alloc_test.exs of v0.1.0: the test sample (dev/stability/sample.exs), run at the tag. A frozen file is never edited. -->

```elixir
defk get(a :: [f64], i :: i64) :: f64 do
  a[i]
end

defk bump(a :: [i64], i :: i64) :: [i64] do
  a[i] = a[i] + 1
  a
end

defk gather(a :: [f64], ix :: [i64], k :: i64) :: f64 do
  for i <- 0..(length(ix) - 1)//1, reduce: 0.0 do
    acc -> acc + a[ix[i] * k] * 2.0
  end
end

defk zeros(n :: i64) :: [u8] do
  alloc(u8, n)
end

defk splice(out :: [u8], at :: i64, src :: [u8], from :: i64, n :: i64) :: [u8] do
  out = copy(out, at, src, from, n)
  out
end

defk repeat(out :: [u8], at :: i64, off :: i64, n :: i64) :: [u8] do
  out = copy_back(out, at, off, n)
  out
end
```

```elixir
iex> M.get(<<1.0::float-native, 2.0::float-native>>, 1)
2.0

iex> M.get(<<1.0::float-native, 2.0::float-native>>, 2)
** (Enum.OutOfBoundsError) index 2 out of bounds for array of length 2

iex> M.get(<<1.0::float-native, 2.0::float-native>>, -1)
** (Enum.OutOfBoundsError) index -1 out of bounds for array of length 2

iex> M.get(<<1, 2, 3>>, 0)
** (ArgumentError) argument 1 (a): byte size 3 is not a multiple of 8 (f64)

iex> M.bump(<<1::signed-64-native>>, 0)
<<2, 0, 0, 0, 0, 0, 0, 0>>

iex> M.bump(<<>>, 0)
** (Enum.OutOfBoundsError) index 0 out of bounds for array of length 0

iex> M.gather(<<1.0::float-native, 2.0::float-native>>, <<1::signed-64-native>>, 1)
4.0

iex> M.gather(<<1.0::float-native, 2.0::float-native>>, <<1::signed-64-native>>, 2)
** (Enum.OutOfBoundsError) index 2 out of bounds for array of length 2

iex> M.gather(<<1.0::float-native>>, <<4611686018427387904::signed-64-native>>, 2)
** (ArithmeticError) i64 overflow in 4611686018427387904 * 2

iex> M.zeros(3)
<<0, 0, 0>>

iex> M.zeros(0)
""

iex> M.zeros(-1)
** (ArgumentError) alloc/2: negative length -1

iex> M.zeros(281474976710657)
** (ArgumentError) alloc/2: length too large

iex> M.splice(<<0, 0, 0, 0, 0>>, 1, <<200, 201, 202>>, 0, 3)
<<0, 200, 201, 202, 0>>

iex> M.splice(<<0, 0, 0, 0, 0>>, 3, <<200, 201, 202>>, 0, 3)
** (Enum.OutOfBoundsError) copy/5: 3 elements at index 3 out of bounds for array of length 5

iex> M.splice(<<0, 0, 0, 0, 0>>, 0, <<200, 201, 202>>, 2, 2)
** (Enum.OutOfBoundsError) copy/5: 2 elements from index 2 out of bounds for source array of length 3

iex> M.splice(<<0, 0, 0, 0, 0>>, 0, <<200, 201, 202>>, 0, -1)
** (ArgumentError) copy/5: negative length -1

iex> M.splice(<<0, 0, 0, 0, 0>>, 5, <<200, 201, 202>>, 3, 0)
<<0, 0, 0, 0, 0>>

iex> M.repeat(<<1, 2, 3, 0, 0, 0, 0>>, 3, 3, 4)
<<1, 2, 3, 1, 2, 3, 1>>

iex> M.repeat(<<1, 2, 3, 0, 0, 0, 0>>, 3, 1, 4)
<<1, 2, 3, 3, 3, 3, 3>>

iex> M.repeat(<<1, 2, 3, 0, 0, 0, 0>>, 3, 0, 4)
** (ArgumentError) copy_back/4: offset 0 is not positive

iex> M.repeat(<<1, 2, 3, 0, 0, 0, 0>>, 3, 4, 4)
** (Enum.OutOfBoundsError) copy_back/4: offset 4 from index 3 is before the start of the array

iex> M.repeat(<<1, 2, 3, 0, 0, 0, 0>>, 3, 3, 5)
** (Enum.OutOfBoundsError) copy_back/4: 5 elements at index 3 out of bounds for array of length 7

iex> M.repeat(<<1, 2, 3>>, 3, 0, 0)
<<1, 2, 3>>
```
