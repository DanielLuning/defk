defmodule Defk.Builtins do
  @moduledoc false
  # The functions a kernel calls without defining them: one list for the
  # compiler, Elixir mode and the compile errors.

  # f64 -> f64 math, also callable as :math.sqrt/1 and so on
  @math1 [:sqrt, :exp, :log, :log2, :log10, :sin, :cos]
  # i64 -> i64 bitwise, as Elixir's Bitwise; each also has an operator form
  @bitwise [:band, :bor, :bxor, :bnot, :bsl, :bsr]
  @bitwise_ops %{&&&: :band, |||: :bor, "^^^": :bxor, "~~~": :bnot, <<<: :bsl, >>>: :bsr}
  # [u8], i64 -> i64 word loads: unsigned w-byte integers at a byte offset
  @loads [:u64_le, :u64_be, :u32_le, :u32_be, :u16_le, :u16_be]
  # range copies into an array: copy/5 (memmove) and copy_back/4 (an LZ match)
  @copies [:copy, :copy_back]
  # bit builtins with a plain Elixir meaning in Defk.Bits (clz and ctz also
  # take a width: clz/2, ctz/2)
  @bits [:mulhi, :clz, :ctz, :popcount, :rotl64, :rotr64, :rotl, :rotr, :f64_to_u64, :crc32c]
  @all [:len, :bit_size, :min, :max, :abs, :float, :trunc, :round, :div, :rem] ++
         @math1 ++ [:pow] ++ @bitwise ++ [:wrap64] ++ @loads ++ @copies ++ [:alloc] ++ @bits

  @doc "Every builtin name."
  def all, do: @all

  @doc "The one-argument math builtins."
  def math1, do: @math1

  @doc "The bitwise builtins (band/2, bor/2, bxor/2, bnot/1, bsl/2, bsr/2)."
  def bitwise, do: @bitwise

  @doc "The bitwise operators (&&&, |||, ^^^, ~~~, <<<, >>>)."
  def bitwise_ops, do: Map.keys(@bitwise_ops)

  @doc "The bitwise builtin an operator or bitwise function name stands for."
  def bitwise_fun(name), do: Map.get(@bitwise_ops, name, name)

  @doc "The arity of bitwise builtin `f`."
  def bitwise_arity(:bnot), do: 1
  def bitwise_arity(_f), do: 2

  @doc "The word loads from a [u8] (u64_le/2, u32_be/2, ...)."
  def loads, do: @loads

  @doc "The width in bytes of word load `f`."
  def load_width(f) when f in [:u64_le, :u64_be], do: 8
  def load_width(f) when f in [:u32_le, :u32_be], do: 4
  def load_width(f) when f in [:u16_le, :u16_be], do: 2

  @doc "The range copies into an array (copy/5, copy_back/4)."
  def copies, do: @copies

  @doc """
  The bit builtins (mulhi/2, clz/1,2, ctz/1,2, popcount/1, rotl64/2,
  rotr64/2, rotl/3, rotr/3, f64_to_u64/1, crc32c/3).
  """
  def bits, do: @bits

  @doc "Whether `name` is a builtin."
  def builtin?(name), do: name in @all

  @doc """
  Whether a call of `name` with `arity` arguments is a builtin. A kernel may
  reuse a builtin's name at an arity the builtin does not take: calls are
  looked up by name and arity.
  """
  def builtin?(name, arity), do: arity in arities(name)

  @doc "The arities builtin `name` takes (none for a name that is not a builtin)."
  def arities(name) when name in [:len, :bit_size, :abs, :float, :trunc, :round, :wrap64], do: [1]
  def arities(name) when name in [:min, :max, :div, :rem, :pow, :alloc], do: [2]
  def arities(name) when name in @math1, do: [1]
  def arities(name) when name in @bitwise, do: [bitwise_arity(name)]
  def arities(name) when name in @loads, do: [2]
  def arities(:copy), do: [5]
  def arities(:copy_back), do: [4]
  def arities(name) when name in [:clz, :ctz], do: [1, 2]
  def arities(name) when name in [:mulhi, :rotl64, :rotr64], do: [2]
  def arities(name) when name in [:rotl, :rotr, :crc32c], do: [3]
  def arities(name) when name in [:popcount, :f64_to_u64], do: [1]
  def arities(_name), do: []

  # Enum.all?/any? with a predicate are the same fold with a different bool
  # accumulator: {init, if kw} for `reduce_while` over the predicate.
  @doc "The {init, if kw} that lowers Enum.all?/any? to a bool-accumulator reduce."
  def bool_reduce(f) when f in [:all?, :any?] do
    if f == :all?,
      do: {true, [do: {:cont, true}, else: {:halt, false}]},
      else: {false, [do: {:halt, true}, else: {:cont, false}]}
  end
end
