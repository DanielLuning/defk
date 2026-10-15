<!-- after test/u64_test.exs, test/bit_builtins_test.exs, test/masked_arith_test.exs of v0.1.0: the test sample (dev/stability/sample.exs), run at the tag. A frozen file is never edited. -->

```elixir
@mask64 0xFFFFFFFFFFFFFFFF

defk mask32(x :: i64, y :: i64) :: i64 do
  band(x * y + bsl(x, 40), 0xFFFFFFFF)
end

defk mask64(x :: i64, y :: i64) :: u64 do
  band(x * y - x, @mask64)
end

defk wrap(x :: i64, y :: i64) :: i64 do
  wrap64(x * y + 1)
end

defk shift_in_mask(x :: i64, n :: i64) :: i64 do
  band(bsl(x, n), 0xFFFF)
end

defk unmasked(x :: i64, y :: i64) :: i64 do
  p = x * y
  band(p, 0xFFFF)
end

defk mulhi_f(a :: i64, b :: i64) :: i64 do
  mulhi(a, b)
end

defk counts(a :: i64) :: {i64, i64, i64} do
  {clz(a), ctz(a), popcount(a)}
end

defk rot(a :: i64, n :: i64) :: {i64, i64} do
  {rotl(a, n), rotr(a, n)}
end

defk counts_w(x :: u64, w :: i64) :: {i64, i64} do
  {clz(x, w), ctz(x, w)}
end

defk rot_w(x :: u64, n :: i64, w :: i64) :: {u64, u64} do
  {rotl(x, n, w), rotr(x, n, w)}
end

defk rot_w_i(x :: i64, n :: i64, w :: i64) :: i64 do
  rotl(x, n, w)
end

defk bits_of(x :: f64) :: u64 do
  f64_bits(x)
end

defk crc(crc :: i64, x :: i64, w :: i64) :: i64 do
  crc32c(crc, x, w)
end

defk words(b :: [u8], i :: i64) :: {i64, i64, i64} do
  {u64_le(b, i), u32_be(b, i), u16_le(b, i)}
end
```

```elixir
iex> M.mask32(4294967295, 4294967295)
1

iex> M.mask32(9223372036854775807, 3)
4294967293

iex> M.mask64(-1, 9223372036854775807)
9223372036854775810

iex> M.mask64(-9223372036854775808, 2)
9223372036854775808

iex> M.wrap(9223372036854775807, 2)
-1

iex> M.wrap(-9223372036854775808, -1)
-9223372036854775807

iex> M.shift_in_mask(1, 20)
0

iex> M.shift_in_mask(1, 64)
0

iex> M.shift_in_mask(1, -1)
** (ArithmeticError) bsl/2 by the negative count -1 inside a mask

iex> M.unmasked(65537, 2)
2

iex> M.unmasked(4611686018427387904, 2)
** (ArithmeticError) i64 overflow in 4611686018427387904 * 2

iex> M.mulhi_f(-1, -1)
-2

iex> M.mulhi_f(9223372036854775807, 4)
1

iex> M.mulhi_f(-9223372036854775808, 2)
1

iex> M.counts(0)
{64, 64, 0}

iex> M.counts(1)
{63, 0, 1}

iex> M.counts(-1)
{0, 0, 64}

iex> M.counts(-9223372036854775808)
{0, 63, 1}

iex> M.rot(1, 63)
{-9223372036854775808, 2}

iex> M.rot(1, -1)
{-9223372036854775808, 2}

iex> M.rot(81985529216486895, 64)
{81985529216486895, 81985529216486895}

iex> M.rot(1, 65)
{2, -9223372036854775808}

iex> M.counts_w(1, 32)
{31, 0}

iex> M.counts_w(0, 8)
{8, 8}

iex> M.counts_w(256, 8)
** (ArgumentError) Defk.Bits.clz/2: 256 does not fit in a 8-bit field

iex> M.counts_w(1, 65)
** (ArgumentError) Defk.Bits.clz/2: width 65 is not in 1..64

iex> M.rot_w(2147483648, 1, 32)
{1, 1073741824}

iex> M.rot_w(1, -1, 32)
{2147483648, 2}

iex> M.rot_w(18446744073709551615, 7, 64)
{18446744073709551615, 18446744073709551615}

iex> M.rot_w_i(2147483648, 1, 32)
1

iex> M.rot_w_i(1, 62, 64)
4611686018427387904

iex> M.rot_w_i(1, 63, 64)
** (ArithmeticError) 9223372036854775808 does not fit in i64

iex> M.bits_of(1.0)
4607182418800017408

iex> M.bits_of(-0.0)
9223372036854775808

iex> M.bits_of(-2.0)
13835058055282163712

iex> M.crc(4294967295, 49, 8)
1862952476

iex> M.crc(0, 4050765991979987505, 64)
3970904592

iex> M.crc(0, 1, 12)
** (ArgumentError) Defk.Bits.crc32c/3: width 12 is not 8, 16, 32 or 64

iex> M.crc(0, 256, 8)
** (ArgumentError) Defk.Bits.crc32c/3: 256 does not fit in a 8-bit field

iex> M.crc(4294967296, 0, 8)
** (ArgumentError) Defk.Bits.crc32c/3: 4294967296 does not fit in a 32-bit field

iex> M.words(<<255, 255, 255, 255, 255, 255, 255, 255>>, 0)
{-1, 4294967295, 65535}

iex> M.words(<<1, 2, 3, 4, 5, 6, 17, 18, 19>>, 1)
{1374179553853047554, 33752069, 770}

iex> M.words(<<1, 2, 3, 4, 5, 6, 17, 18>>, 1)
** (Enum.OutOfBoundsError) 8-byte load at index 1 out of bounds for array of length 8

iex> M.words(<<1, 2, 3, 4, 5, 6, 17, 18>>, -1)
** (Enum.OutOfBoundsError) 8-byte load at index -1 out of bounds for array of length 8
```
