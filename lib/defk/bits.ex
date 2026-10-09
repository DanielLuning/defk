defmodule Defk.Bits do
  @moduledoc """
  Integer bit operations with a plain Elixir meaning, which a kernel can also
  call as builtins and which give the same value in plain Elixir.
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

  defp u64(x), do: Bitwise.band(x, @mask64)

  defp bit_length(0, acc), do: acc
  defp bit_length(u, acc), do: bit_length(Bitwise.bsr(u, 1), acc + 1)

  defp popcount(0, acc), do: acc
  defp popcount(u, acc), do: popcount(Bitwise.bsr(u, 1), acc + Bitwise.band(u, 1))
end
