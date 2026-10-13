defmodule Defk.ElixirMode.Guard do
  @moduledoc false
  # A case guard that can fail, as Elixir mode evaluates it (defk-7a6,
  # defk-34l). The guard's operations call Ops, so it runs outside a real
  # guard, with Elixir's guard rule applied by hand:
  #
  # - an error Elixir raises (a zero divisor, a float result of inf) fails
  #   the guard: false, and the next clause is tried;
  # - an i64 limit (Ops.limit?/1) is no Elixir error: the operation's value
  #   is poisoned (:defk_poison) and evaluation goes on, so an error later in
  #   the guard still fails it, in either order. With no error, the guard
  #   raises the first limit it hit, as the kernel does;
  # - a poisoned value is not Elixir's value, so it decides nothing: an
  #   operation on it is poisoned without being checked (a poisoned divisor
  #   is no zero divisor), and an and/or whose left side is poisoned raises
  #   the first limit (stop/0), except an `and` whose false fails the guard,
  #   whose right side runs: false or an error there fails the guard either
  #   way.
  #
  # The generated guard calls run/1 around these functions; and/or are
  # written inline by Defk.ElixirMode (a short-circuit is not a function).

  alias Defk.ElixirMode.Ops

  @key :defk_guard_limit
  @divisions [:div, :rem, :div_u64, :rem_u64]

  @doc false
  # The guard's value: false on an Elixir error, the first limit raised
  # when one was hit, else the boolean.
  def run(fun) do
    Process.delete(@key)

    try do
      v = fun.()
      if e = Process.get(@key), do: raise(e), else: v
    rescue
      e in ArithmeticError -> if Ops.limit?(e), do: reraise(e, __STACKTRACE__), else: false
    after
      Process.delete(@key)
    end
  end

  @doc false
  # mod.fun(args), poisoned when an operand that decides its error is
  # poisoned (the divisor of a division, any operand of anything else) or
  # when it hits a limit
  def call(mod, fun, [a, b]) when fun in @divisions do
    cond do
      b == :defk_poison -> :defk_poison
      a == :defk_poison and b != 0 -> :defk_poison
      a == :defk_poison -> apply(mod, fun, [0, b])
      true -> limited(mod, fun, [a, b])
    end
  end

  def call(mod, fun, args) do
    if :defk_poison in args, do: :defk_poison, else: limited(mod, fun, args)
  end

  @doc false
  # a comparison: poisoned when an operand is
  def cmp(op, a, b) do
    if a == :defk_poison or b == :defk_poison,
      do: :defk_poison,
      else: apply(Kernel, op, [a, b])
  end

  @doc false
  def not_(:defk_poison), do: :defk_poison
  def not_(b), do: not b

  @doc false
  # an and/or decided by a poisoned value: raise the first limit
  @spec stop() :: no_return()
  def stop, do: raise(Process.get(@key))

  defp limited(mod, fun, args) do
    apply(mod, fun, args)
  rescue
    e in ArithmeticError ->
      if Ops.limit?(e) do
        Process.get(@key) || Process.put(@key, e)
        :defk_poison
      else
        reraise e, __STACKTRACE__
      end
  end
end
