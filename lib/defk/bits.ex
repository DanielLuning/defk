defmodule Defk.Bits do
  @moduledoc """
  Integer bit operations with a plain Elixir meaning, which a kernel can also
  call as builtins and which give the same value in plain Elixir.

  A kernel calls them by their bare names (`clz(x, 32)`) or as
  `Defk.Bits.clz(x, 32)`; the compiler maps them to machine instructions,
  and Elixir mode calls these functions, whose bodies are what the kernel
  computes. `clz/2`, `ctz/2`, `rotl/3` and `rotr/3` take a width, so a
  32-bit hash rotates as 32 bits; `clz/1`, `ctz/1`, `popcount/1`, `rotl64/2`
  and `rotr64/2` work on the 64-bit pattern of any integer. The names are
  the kernel builtins' names too, so renaming one would change the kernel
  subset. `crc32c/3` is a hardware builtin: a kernel runs it as the CPU's
  CRC32C instruction where there is one and as a table step elsewhere, with
  the same value.

      iex> Defk.Bits.rotl(0x80000001, 1, 32)
      3
      iex> Defk.Bits.popcount(0xFF)
      8

  How a kernel uses them, and the errors their arguments can raise:
  [Bit builtins](language.md#bit-builtins),
  [Hardware builtins](language.md#hardware-builtins) and
  [Masked arithmetic](language.md#masked-arithmetic) (for `wrap64/1`).
  """

  @doc """
  The low 64 bits of `x` as a signed 64-bit integer (two's complement).

  In a kernel, `wrap64(expr)` computes the `+ - *` and literal `bsl` tree of
  `expr` with wrapping 64-bit machine arithmetic, which gives exactly this
  value of the exact result: `wrap64(h * 1_099_511_628_211 + b)` is the
  FNV/xxHash idiom. Called from Elixir, it wraps an integer you computed.

      iex> Defk.Bits.wrap64(0xFFFFFFFFFFFFFFFF)
      -1
      iex> Defk.Bits.wrap64(2 ** 64 + 5)
      5
      iex> Defk.Bits.wrap64(-1)
      -1
  """
  @spec wrap64(integer()) :: integer()
  def wrap64(x) when is_integer(x) do
    <<r::signed-64>> = <<x::64>>
    r
  end

  @mask64 0xFFFFFFFFFFFFFFFF

  @doc """
  The high 64 bits of the unsigned 128-bit product of `a` and `b`, each taken
  as a u64 bit pattern, returned as the signed i64 bit pattern. A kernel's
  `mulhi(a, b)` is one multiply (`unsigned __int128`).

      iex> Defk.Bits.mulhi(0, 12345)
      0
      iex> Defk.Bits.mulhi(-1, -1)
      -2
      iex> Defk.Bits.mulhi(0x7FFFFFFFFFFFFFFF, 4)
      1
      iex> Defk.Bits.mulhi(-0x8000000000000000, 2)
      1
  """
  @spec mulhi(integer(), integer()) :: integer()
  def mulhi(a, b) when is_integer(a) and is_integer(b) do
    wrap64(Bitwise.band(Bitwise.bsr(u64(a) * u64(b), 64), @mask64))
  end

  @doc """
  The number of leading zero bits of the u64 bit pattern of `x`: 0 to 64, and
  64 for 0.

      iex> Defk.Bits.clz(0)
      64
      iex> Defk.Bits.clz(1)
      63
      iex> Defk.Bits.clz(-1)
      0
      iex> Defk.Bits.clz(0x00FF)
      56
  """
  @spec clz(integer()) :: 0..64
  def clz(x) when is_integer(x), do: 64 - bit_length(u64(x), 0)

  @doc """
  The number of trailing zero bits of the u64 bit pattern of `x`: 0 to 64, and
  64 for 0.

      iex> Defk.Bits.ctz(0)
      64
      iex> Defk.Bits.ctz(1)
      0
      iex> Defk.Bits.ctz(-0x8000000000000000)
      63
      iex> Defk.Bits.ctz(0x50)
      4
  """
  @spec ctz(integer()) :: 0..64
  def ctz(x) when is_integer(x) do
    case u64(x) do
      0 -> 64
      u -> bit_length(Bitwise.band(u, -u), 0) - 1
    end
  end

  @doc """
  The number of set bits in the u64 bit pattern of `x`: 0 to 64.

      iex> Defk.Bits.popcount(0)
      0
      iex> Defk.Bits.popcount(-1)
      64
      iex> Defk.Bits.popcount(0xF0F0)
      8
  """
  @spec popcount(integer()) :: 0..64
  def popcount(x) when is_integer(x), do: popcount(u64(x), 0)

  @doc """
  Rotate the 64-bit pattern of `x` left by `band(n, 63)` bits, as a signed
  i64 (`n` may be any i64).

      iex> Defk.Bits.rotl64(1, 63)
      -0x8000000000000000
      iex> Defk.Bits.rotl64(-0x8000000000000000, 1)
      1
      iex> Defk.Bits.rotl64(0x0123456789ABCDEF, 64)
      0x0123456789ABCDEF
      iex> Defk.Bits.rotl64(1, -1)
      -0x8000000000000000
  """
  @spec rotl64(integer(), integer()) :: integer()
  def rotl64(x, n) when is_integer(x) and is_integer(n) do
    k = Bitwise.band(n, 63)
    u = u64(x)
    wrap64(Bitwise.bor(Bitwise.bsl(u, k), Bitwise.bsr(u, 64 - k)))
  end

  @doc """
  Rotate the 64-bit pattern of `x` right by `band(n, 63)` bits, as a signed
  i64 (`n` may be any i64).

      iex> Defk.Bits.rotr64(1, 1)
      -0x8000000000000000
      iex> Defk.Bits.rotr64(-0x8000000000000000, 63)
      1
      iex> Defk.Bits.rotr64(5, 64)
      5
  """
  @spec rotr64(integer(), integer()) :: integer()
  def rotr64(x, n) when is_integer(x) and is_integer(n), do: rotl64(x, 64 - Bitwise.band(n, 63))

  @doc """
  The number of leading zero bits of `x` as a `width`-bit value: 0 to
  `width`, and `width` for 0. `width` is 1 to 64 and `x` is in
  `0..2^width - 1`; anything else raises `ArgumentError`. A kernel's
  `clz(x, w)` is one instruction (`__builtin_clzll`) plus the range check.

      iex> Defk.Bits.clz(1, 32)
      31
      iex> Defk.Bits.clz(0, 64)
      64
      iex> Defk.Bits.clz(0xFFFFFFFFFFFFFFFF, 64)
      0
  """
  @spec clz(non_neg_integer(), 1..64) :: non_neg_integer()
  def clz(x, width) do
    field!("clz/2", x, width)
    width - bit_length(x, 0)
  end

  @doc """
  The number of trailing zero bits of `x` as a `width`-bit value: 0 to
  `width`, and `width` for 0. The arguments are checked as `clz/2`'s.

      iex> Defk.Bits.ctz(0x50, 8)
      4
      iex> Defk.Bits.ctz(0, 32)
      32
      iex> Defk.Bits.ctz(0x8000000000000000, 64)
      63
  """
  @spec ctz(non_neg_integer(), 1..64) :: non_neg_integer()
  def ctz(x, width) do
    field!("ctz/2", x, width)
    if x == 0, do: width, else: bit_length(Bitwise.band(x, -x), 0) - 1
  end

  @doc """
  Rotate the `width`-bit value `x` left by `n` bits (`n` taken modulo
  `width`, so it may be negative). `width` is 1 to 64 and `x` is in
  `0..2^width - 1`; anything else raises `ArgumentError`. The result is in
  `0..2^width - 1`. MurmurHash3's `rotl32(k, 15)` is `rotl(k, 15, 32)`.

      iex> Defk.Bits.rotl(0x80000001, 1, 32)
      3
      iex> Defk.Bits.rotl(1, -1, 64)
      0x8000000000000000
      iex> Defk.Bits.rotl(0b0011, 3, 4)
      0b1001
  """
  @spec rotl(non_neg_integer(), integer(), 1..64) :: non_neg_integer()
  def rotl(x, n, width) when is_integer(n) do
    field!("rotl/3", x, width)
    rotate(x, Integer.mod(n, width), width)
  end

  @doc """
  Rotate the `width`-bit value `x` right by `n` bits, as `rotl(x, -n, width)`.

      iex> Defk.Bits.rotr(3, 1, 32)
      0x80000001
      iex> Defk.Bits.rotr(0x0123456789ABCDEF, 64, 64)
      0x0123456789ABCDEF
  """
  @spec rotr(non_neg_integer(), integer(), 1..64) :: non_neg_integer()
  def rotr(x, n, width) when is_integer(n) do
    field!("rotr/3", x, width)
    rotate(x, Integer.mod(-n, width), width)
  end

  @doc """
  The IEEE 754 bits of the float `x` as an unsigned 64-bit integer, as
  `<<b::64>> = <<x::float-64>>` gives them. An integer is converted to a
  float first, as in that match. A kernel's `f64_to_u64(x)` returns a `u64`.

      iex> Defk.Bits.f64_to_u64(1.0)
      0x3FF0000000000000
      iex> Defk.Bits.f64_to_u64(-0.0)
      0x8000000000000000
      iex> Defk.Bits.f64_to_u64(2)
      0x4000000000000000
  """
  @spec f64_to_u64(number()) :: non_neg_integer()
  def f64_to_u64(x) when is_number(x) do
    <<b::64>> = <<x::float-64>>
    b
  end

  # the byte table of the reflected CRC32C polynomial: entry n is n's CRC
  # register after eight one-bit steps
  @crc32c_table List.to_tuple(
                  for n <- 0..255 do
                    Enum.reduce(1..8, n, fn _, c ->
                      Bitwise.bxor(
                        Bitwise.bsr(c, 1),
                        Bitwise.band(0x82F63B78, -Bitwise.band(c, 1))
                      )
                    end)
                  end
                )

  @doc """
  One CRC32C (Castagnoli) step: the CRC register `crc` after the `width`
  bits of `x`, as `width / 8` bytes, least significant byte first. The
  polynomial is the reflected 0x82F63B78, and there is no inversion before
  or after, so this is exactly what the ARMv8 `CRC32CX` and SSE4.2
  `crc32q` instructions compute (`CRC32CB`/`H`/`W` for the narrower
  widths).

  `width` is 8, 16, 32 or 64, `crc` is in `0..2^32 - 1` and `x` in
  `0..2^width - 1`; anything else raises `ArgumentError`. The result is in
  `0..2^32 - 1`. The standard CRC-32C of a message starts from
  `0xFFFFFFFF` and inverts the end result:

      iex> crc = Enum.reduce(~c"123456789", 0xFFFFFFFF, &Defk.Bits.crc32c(&2, &1, 8))
      iex> Bitwise.bxor(crc, 0xFFFFFFFF)
      0xE3069283
      iex> Defk.Bits.crc32c(0, 0, 64)
      0
      iex> Defk.Bits.crc32c(0xFFFFFFFF, 0x34333231, 32) == Enum.reduce(~c"1234", 0xFFFFFFFF, &Defk.Bits.crc32c(&2, &1, 8))
      true

  A kernel's `crc32c(crc, x, 64)` is one instruction where the CPU has it
  (every arm64 Mac, arm64 with the CRC extension, x86-64 with SSE4.2),
  chosen at run time, and a slicing-by-8 table step otherwise: the same
  value either way.
  """
  @spec crc32c(non_neg_integer(), non_neg_integer(), 8 | 16 | 32 | 64) :: non_neg_integer()
  def crc32c(crc, x, width) when width in [8, 16, 32, 64] do
    field!("crc32c/3", crc, 32)
    field!("crc32c/3", x, width)
    crc32c_bytes(crc, x, div(width, 8))
  end

  def crc32c(_crc, _x, width),
    do: raise(ArgumentError, "Defk.Bits.crc32c/3: width #{inspect(width)} is not 8, 16, 32 or 64")

  defp crc32c_bytes(c, _x, 0), do: c

  defp crc32c_bytes(c, x, n) do
    c =
      Bitwise.bxor(Bitwise.bsr(c, 8), elem(@crc32c_table, Bitwise.band(Bitwise.bxor(c, x), 255)))

    crc32c_bytes(c, Bitwise.bsr(x, 8), n - 1)
  end

  # x is a width-bit value, 1 <= width <= 64
  defp field!(f, _x, width) when not is_integer(width) or width < 1 or width > 64,
    do: raise(ArgumentError, "Defk.Bits.#{f}: width #{inspect(width)} is not in 1..64")

  defp field!(f, x, width) do
    (is_integer(x) and x >= 0 and Bitwise.bsr(x, width) == 0) ||
      raise ArgumentError, "Defk.Bits.#{f}: #{inspect(x)} does not fit in a #{width}-bit field"
  end

  defp rotate(x, 0, _width), do: x

  defp rotate(x, k, width) do
    mask = Bitwise.bsl(1, width) - 1
    Bitwise.band(Bitwise.bor(Bitwise.bsl(x, k), Bitwise.bsr(x, width - k)), mask)
  end

  defp u64(x), do: Bitwise.band(x, @mask64)

  defp bit_length(0, acc), do: acc
  defp bit_length(u, acc), do: bit_length(Bitwise.bsr(u, 1), acc + 1)

  defp popcount(0, acc), do: acc
  defp popcount(u, acc), do: popcount(Bitwise.bsr(u, 1), acc + Bitwise.band(u, 1))
end
