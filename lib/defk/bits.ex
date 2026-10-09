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
end
