<!-- after test/bitstring_test.exs of v0.1.0: the test sample (dev/stability/sample.exs), run at the tag. A frozen file is never edited. -->

```elixir
defk pack(xs :: [i64], n :: i64) :: bitstring do
  for x <- xs, reduce: <<>> do
    acc -> <<acc::bitstring, x::size(n)>>
  end
end

defk pack_u64(xs :: [u64], n :: i64) :: bitstring do
  for x <- xs, reduce: <<>> do
    acc -> <<acc::bitstring, x::size(n)>>
  end
end

defk pack_signed(xs :: [i64], n :: i64) :: bitstring do
  for x <- xs, reduce: <<>> do
    acc -> <<acc::bitstring, x::size(n)-signed>>
  end
end

defk mixed_signed(x :: i64, y :: i64) :: bitstring do
  acc = <<>>
  <<acc::bitstring, x::5-signed, y::3, x::signed-integer-big-size(5), y::signed-8>>
end

defk flags(xs :: [i64]) :: {bitstring, i64} do
  acc = <<>>

  acc =
    for x <- xs, reduce: acc do
      acc ->
        if x > 0, do: <<acc::bitstring, 1::1, band(x, 127)::7>>, else: <<acc::bitstring, 0::1>>
    end

  bits = bit_size(acc)
  pad = rem(8 - rem(bits, 8), 8)
  {<<acc::bitstring, 0::size(pad)>>, bits}
end

defk forks(x :: i64) :: {bitstring, bitstring, bitstring} do
  a = <<>>
  a = <<a::bitstring, band(x, 7)::3>>
  b = <<a::bitstring, 1::1>>
  c = <<a::bitstring, 0::2>>
  b = <<b::bitstring, x::64>>
  {a, b, c}
end

defk zero_width(x :: i64) :: bitstring do
  acc = <<>>
  acc = <<acc::bitstring, 0::0, x::size(0)>>
  if bit_size(acc) == 0, do: <<>>, else: acc
end

defk until_negative(xs :: [i64]) :: bitstring do
  Enum.reduce_while(xs, <<>>, fn x, acc ->
    if x < 0, do: {:halt, acc}, else: {:cont, <<acc::bitstring, band(x, 15)::4>>}
  end)
end
```

```elixir
iex> M.pack(<<1::64-native, 2::64-native, 3::64-native>>, 3)
<<41, 1::size(1)>>

iex> M.pack(<<>>, 3)
""

iex> M.pack(<<8::64-native>>, 3)
** (ArgumentError) bitstring segment value 8 does not fit in 3 bits

iex> M.pack(<<-1::64-native>>, 64)
** (ArgumentError) bitstring segment value -1 does not fit in 64 bits

iex> M.pack(<<1::64-native>>, 65)
** (ArgumentError) bitstring segment size 65 is outside 0..64

iex> M.pack(<<1::64-native>>, -1)
** (ArgumentError) bitstring segment size -1 is outside 0..64

iex> M.pack_u64(<<18446744073709551615::64-native>>, 64)
<<255, 255, 255, 255, 255, 255, 255, 255>>

iex> M.pack_u64(<<9223372036854775808::64-native>>, 63)
** (ArgumentError) bitstring segment value 9223372036854775808 does not fit in 63 bits

iex> M.pack_signed(<<-1::64-native, -64::64-native, 63::64-native>>, 7)
<<255, 1, 31::size(5)>>

iex> M.pack_signed(<<64::64-native>>, 7)
** (ArgumentError) bitstring segment value 64 does not fit in 7 signed bits

iex> M.pack_signed(<<-9223372036854775808::64-native>>, 64)
<<128, 0, 0, 0, 0, 0, 0, 0>>

iex> M.pack_signed(<<-1::64-native>>, 1)
<<1::size(1)>>

iex> M.pack_signed(<<0::64-native>>, 0)
""

iex> M.pack_signed(<<1::64-native>>, 0)
** (ArgumentError) bitstring segment value 1 does not fit in 0 signed bits

iex> M.mixed_signed(-3, 5)
<<237, 232, 5::size(5)>>

iex> M.mixed_signed(-16, 7)
<<135, 128, 7::size(5)>>

iex> M.mixed_signed(16, 5)
** (ArgumentError) bitstring segment value 16 does not fit in 5 signed bits

iex> M.mixed_signed(-1, 8)
** (ArgumentError) bitstring segment value 8 does not fit in 3 bits

iex> M.flags(<<5::64-native, -1::64-native, 200::64-native>>)
{<<133, 100, 0>>, 17}

iex> M.flags(<<>>)
{"", 0}

iex> M.forks(5)
{<<5::size(3)>>, <<176, 0, 0, 0, 0, 0, 0, 0, 5::size(4)>>, <<20::size(5)>>}

iex> M.forks(-1)
** (ArgumentError) bitstring segment value -1 does not fit in 64 bits

iex> M.zero_width(0)
""

iex> M.zero_width(7)
** (ArgumentError) bitstring segment value 7 does not fit in 0 bits

iex> M.until_negative(<<1::64-native, 2::64-native, -1::64-native, 3::64-native>>)
<<18>>

iex> M.until_negative(<<>>)
""
```
