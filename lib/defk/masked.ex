defmodule Defk.Masked do
  @moduledoc false
  # Masked arithmetic (CONTEXT.md): integer arithmetic written inside
  # `band(expr, 2^k - 1)`, 1 <= k <= 64, which a kernel computes with
  # wrapping machine arithmetic and which still gives Elixir's exact result.
  # One rule for the compiler and Elixir mode, so both wrap the same nodes:
  #
  #   * the mask is an integer literal 2^k - 1 for 1 <= k <= 63, or -1 for
  #     k = 64 (2^64 - 1 is no i64 literal; band(x, -1) is "wrap to 64 bits")
  #   * the wrapped tree is the contiguous tree of `+`, `-` (binary and
  #     unary), unary `+`, `*` and `bsl` by a non-negative integer literal
  #     directly under the mask; anything else in it (a variable, a literal, a
  #     read, a call, another band, bsr, div, ...) is a leaf, lowered as
  #     usual and checked, and its i64 value enters the tree
  #   * the tree is computed modulo 2^64 and the mask applied once at the end
  #
  # Every tree operation is a ring operation modulo 2^64 (bsl by n is a
  # multiplication by 2^n), so the low k bits of the wrapped result are the
  # low k bits of the exact result: band of the bignum, which is what Elixir
  # computes. For k = 64 the result is the i64 bit pattern of those bits.

  @bitwise_names Defk.Builtins.bitwise() ++ Defk.Builtins.bitwise_ops()

  @doc """
  For the arguments of a band/2, `{expr, mask}` when one argument is a mask
  2^k - 1 (or -1) and the other the root of a wrapped tree; otherwise nil.
  """
  def split([a, b]) do
    cond do
      mask?(b) and tree_node(a) != nil -> {a, int(b)}
      mask?(a) and tree_node(b) != nil -> {b, int(a)}
      true -> nil
    end
  end

  def split(_), do: nil

  @doc """
  The wrapped-tree node `ast` is: `{:add | :sub | :mul, a, b}`, `{:neg, a}`,
  `{:pos, a}`, `{:bsl, a, n}` (n a non-negative integer); nil for a leaf.
  """
  def tree_node({:+, _, [a, b]}), do: {:add, a, b}
  def tree_node({:-, _, [a, b]}), do: {:sub, a, b}
  def tree_node({:*, _, [a, b]}), do: {:mul, a, b}
  def tree_node({:-, _, [a]}), do: {:neg, a}
  def tree_node({:+, _, [a]}), do: {:pos, a}

  def tree_node({op, _, [a, n]}) when op in @bitwise_names do
    if Defk.Builtins.bitwise_fun(op) == :bsl, do: bsl(a, n)
  end

  def tree_node({{:., _, [mod, :bsl]}, _, [a, n]}) do
    if mod == :erlang or match?({:__aliases__, _, [:Bitwise]}, mod), do: bsl(a, n)
  end

  def tree_node(_), do: nil

  defp bsl(a, n) when is_integer(n) and n >= 0, do: {:bsl, a, n}
  defp bsl(_a, _n), do: nil

  defp mask?(ast) do
    case int(ast) do
      -1 -> true
      m when is_integer(m) and m > 0 -> Bitwise.band(m, m + 1) == 0 and m <= 0x7FFFFFFFFFFFFFFF
      _ -> false
    end
  end

  defp int(n) when is_integer(n), do: n
  defp int({:-, _, [n]}) when is_integer(n), do: -n
  defp int(_), do: nil
end
