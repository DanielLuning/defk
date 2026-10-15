<!-- after test/element_types_test.exs, test/u64_test.exs of v0.1.0: the test sample (dev/stability/sample.exs), run at the tag. A frozen file is never edited. -->

```elixir
defk at(a :: [i16], b :: [i32], c :: [f32], i :: i64) :: {i64, i64, f64} do
  {a[i], b[i], c[i]}
end

defk put16(v :: i64) :: [i16] do
  out = alloc(i16, 2)
  out[1] = v
  out
end

defk put32(v :: i64) :: [i32] do
  out = alloc(i32, 2)
  out[1] = v
  out
end

defk put8(v :: i64) :: [u8] do
  out = alloc(u8, 2)
  out[1] = v
  out
end

defk putf32(v :: f64) :: [f32] do
  out = alloc(f32, 1)
  out[0] = v
  out
end

defk roundtrip(v :: f64) :: f64 do
  out = alloc(f32, 1)
  out[0] = v
  out[0] * 2.0
end

defk set16(a :: [i16], i :: i64, v :: i64) :: [i16] do
  a[i] = v
  a
end

defk sums(a :: [i16], b :: [i32], c :: [f32]) :: {i64, i64, f64} do
  sa =
    for x <- a, reduce: 0 do
      acc -> acc + x
    end

  sb =
    for x <- b, reduce: 0 do
      acc -> acc + x
    end

  sc =
    for x <- c, reduce: 0.0 do
      acc -> acc + x
    end

  {sa, sb, sc}
end

defk mix(a :: [i16], b :: [i16]) :: [i16] do
  out = alloc(i16, length(a))

  for i <- 0..(min(length(a), length(b)) - 1)//1 do
    out[i] = max(min(a[i] + b[i], 32_767), -32_768)
  end

  out
end

defk put_u64(a :: [u64], i :: i64, x :: i64) :: [u64] do
  a[i] = x
  a
end

defk store(a :: [i64], b :: [u8], x :: u64) :: {[i64], [u8]} do
  a[0] = x
  b[0] = x
  {a, b}
end
```

```elixir
iex> M.at(<<-32768::16-native, 1::16-native>>, <<-2147483648::32-native, 1::32-native>>, <<1.5::float-32-native, -0.0::float-32-native>>, 0)
{-32768, -2147483648, 1.5}

iex> M.at(<<-32768::16-native, 1::16-native>>, <<-2147483648::32-native, 1::32-native>>, <<1.5::float-32-native, -0.0::float-32-native>>, 1)
{1, 1, -0.0}

iex> M.at(<<-32768::16-native, 1::16-native>>, <<-2147483648::32-native, 1::32-native>>, <<1.5::float-32-native, -0.0::float-32-native>>, 2)
** (Enum.OutOfBoundsError) index 2 out of bounds for array of length 2

iex> M.at(<<1>>, <<>>, <<>>, 0)
** (ArgumentError) argument 1 (a): byte size 1 is not a multiple of 2 (i16)

iex> M.put16(32767)
<<0, 0, 255, 127>>

iex> M.put16(32768)
** (ArgumentError) value 32768 does not fit in i16

iex> M.put16(-32769)
** (ArgumentError) value -32769 does not fit in i16

iex> M.put32(-2147483648)
<<0, 0, 0, 0, 0, 0, 0, 128>>

iex> M.put32(2147483648)
** (ArgumentError) value 2147483648 does not fit in i32

iex> M.put8(255)
<<0, 255>>

iex> M.put8(256)
** (ArgumentError) value 256 does not fit in u8

iex> M.put8(-1)
** (ArgumentError) value -1 does not fit in u8

iex> M.putf32(0.1)
<<205, 204, 204, 61>>

iex> M.putf32(3.4028234663852886e38)
<<255, 255, 127, 127>>

iex> M.putf32(1.0e40)
** (ArgumentError) value 1e+40 does not fit in f32

iex> M.putf32(1.0e-50)
<<0, 0, 0, 0>>

iex> M.roundtrip(0.1)
0.20000000298023224

iex> M.roundtrip(1.0e-40)
1.999989220222952e-40

iex> M.set16(<<1::16-native, 2::16-native>>, 1, -1)
<<1, 0, 255, 255>>

iex> M.set16(<<1::16-native, 2::16-native>>, 2, 0)
** (Enum.OutOfBoundsError) index 2 out of bounds for array of length 2

iex> M.sums(<<-32768::16-native, -32768::16-native>>, <<-2147483648::32-native, -2147483648::32-native>>, <<0.1::float-32-native, 0.2::float-32-native>>)
{-65536, -4294967296, 0.30000000447034836}

iex> M.sums(<<>>, <<>>, <<0x7FC00000::32-native>>)
** (ArgumentError) non-finite float (inf or NaN) read from an input array at index 0

iex> M.mix(<<30000::16-native, -30000::16-native>>, <<30000::16-native, -30000::16-native>>)
<<255, 127, 0, 128>>

iex> M.mix(<<1::16-native>>, <<>>)
<<0, 0>>

iex> M.put_u64(<<0::64-native>>, 0, 9223372036854775807)
<<255, 255, 255, 255, 255, 255, 255, 127>>

iex> M.put_u64(<<0::64-native>>, 0, -1)
** (ArgumentError) value -1 does not fit in u64

iex> M.store(<<0::64-native>>, <<0>>, 255)
{<<255, 0, 0, 0, 0, 0, 0, 0>>, <<255>>}

iex> M.store(<<0::64-native>>, <<0>>, 256)
** (ArgumentError) value 256 does not fit in u8

iex> M.store(<<0::64-native>>, <<0>>, 9223372036854775808)
** (ArgumentError) value 9223372036854775808 does not fit in i64
```
