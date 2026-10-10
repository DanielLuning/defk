defmodule Defk.Masked do
  @moduledoc false
  # Masked arithmetic (CONTEXT.md): integer arithmetic written inside
  # `band(expr, 2^k - 1)`, 1 <= k <= 64, which a kernel computes with
  # wrapping machine arithmetic and which still gives Elixir's exact result.
  # One rule for the compiler and Elixir mode, so both wrap the same nodes:
  #
  #   * the mask is 2^k - 1 for 1 <= k <= 64, written as an integer literal
  #     (a module attribute is one by then) or a constant expression of
  #     literals such as (1 <<< 64) - 1 (band(x, -1) is an ordinary band:
  #     Elixir's identity); wrap64(expr) wraps the same tree to the low 64
  #     bits as a signed i64 (Defk.Bits.wrap64/1)
  #   * the wrapped tree is the contiguous tree of `+`, `-` (binary and
  #     unary), unary `+`, `*`, `band`, `bor`, `bxor`, `bnot` and `bsl` by a
  #     non-negative literal or by any count that is not a literal, directly
  #     under the mask; anything else in it (a variable, a literal, a read, a
  #     call, bsr, div, rem, a bsl by a negative literal, ...) is a leaf,
  #     lowered as usual and checked, and its i64 or u64 value enters the tree
  #   * the tree is computed modulo 2^64 and the mask applied once at the end;
  #     a bsl by a count that is not a literal raises for a negative count
  #
  # Every tree operation's low 64 bits depend only on the low 64 bits of its
  # operands (+ - * are ring operations modulo 2^64, bsl by n >= 0 is a
  # multiplication by 2^n, and band/bor/bxor/bnot act bit by bit), so the low
  # k bits of the wrapped result are the low k bits of the exact result: band
  # of the bignum, which is what Elixir computes. A negative bsl count would
  # bring high bits down, so it raises instead (a limit). wrap64 gives the
  # i64 bit pattern of the low 64 bits, which is Defk.Bits.wrap64/1 of the
  # exact result.

  @bitwise_names Defk.Builtins.bitwise() ++ Defk.Builtins.bitwise_ops()
  @max_mask 0xFFFFFFFFFFFFFFFF

  @doc """
  For the arguments of a band/2, `{expr, mask}` when one argument is a mask
  2^k - 1 (1 <= k <= 64, a literal or a constant expression); otherwise nil.
  """
  def split([a, b]) do
    cond do
      mask?(b) -> {a, const(b)}
      mask?(a) -> {b, const(a)}
      true -> nil
    end
  end

  def split(_), do: nil

  @doc """
  The wrapped-tree node `ast` is: `{:add | :sub | :mul | :band | :bor | :bxor,
  a, b}`, `{:neg | :pos | :bnot, a}`, `{:bsl, a, n}` (n a non-negative
  integer literal) or `{:bsl_var, a, n_ast}` (a count that is not a literal);
  nil for a leaf.
  """
  def tree_node({:+, _, [a, b]}), do: {:add, a, b}
  def tree_node({:-, _, [a, b]}), do: {:sub, a, b}
  def tree_node({:*, _, [a, b]}), do: {:mul, a, b}
  def tree_node({:-, _, [a]}), do: {:neg, a}
  def tree_node({:+, _, [a]}), do: {:pos, a}

  def tree_node({op, _, args}) when op in @bitwise_names and is_list(args),
    do: bitwise(Defk.Builtins.bitwise_fun(op), args)

  def tree_node({{:., _, [mod, f]}, _, args}) when is_list(args) do
    if f in Defk.Builtins.bitwise() and
         (mod == :erlang or match?({:__aliases__, _, [:Bitwise]}, mod)),
       do: bitwise(f, args)
  end

  def tree_node(_), do: nil

  defp bitwise(f, [a, b]) when f in [:band, :bor, :bxor], do: {f, a, b}
  defp bitwise(:bnot, [a]), do: {:bnot, a}

  defp bitwise(:bsl, [a, n]) do
    case const(n) do
      k when is_integer(k) and k >= 0 -> {:bsl, a, k}
      k when is_integer(k) -> nil
      nil -> {:bsl_var, a, n}
    end
  end

  defp bitwise(_f, _args), do: nil

  @doc "Whether `ast` is a mask 2^k - 1, 1 <= k <= 64."
  def mask?(ast) do
    case const(ast) do
      m when is_integer(m) and m > 0 and m <= @max_mask -> Bitwise.band(m, m + 1) == 0
      _ -> false
    end
  end

  @doc """
  The value of a constant integer expression: a literal, or unary `-` and
  `+ - *` and `bsl`/`<<<` (by 0..128) of constants; nil for anything else.
  """
  def const(n) when is_integer(n), do: n
  def const({:-, _, [a]}), do: with(x when is_integer(x) <- const(a), do: -x)

  def const({op, _, [a, b]}) when op in [:+, :-, :*] do
    with x when is_integer(x) <- const(a), y when is_integer(y) <- const(b) do
      apply(Kernel, op, [x, y])
    end
  end

  def const({op, _, [a, b]}) when op in [:bsl, :<<<] do
    with x when is_integer(x) <- const(a), n when n in 0..128 <- const(b) do
      Bitwise.bsl(x, n)
    else
      _ -> nil
    end
  end

  def const(_), do: nil
end
