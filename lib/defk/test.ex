defmodule Defk.Test do
  @moduledoc false

  import ExUnit.Assertions

  defp outcome(f) do
    {:ok, f.()}
  rescue
    e -> {:raise, e}
  end

  @doc """
  Runs `Mod.fun/arity` (via apply with args) in both native and Elixir mode
  and asserts they agree: both return identical values with === (bit-exact
  floats), or both raise the same exception module for the same `reason/1`.
  Returns the native outcome, `{:ok, value}` or `{:raise, exception}`.
  """
  def assert_agrees(mod, fun, args) do
    arity = length(args)
    Code.ensure_loaded(mod)

    if not function_exported?(mod, fun, arity) do
      flunk("#{inspect(mod)}.#{fun}/#{arity} is not exported")
    end

    native =
      outcome(fn -> Defk.ElixirMode.with_mode(:native, fn -> apply(mod, fun, args) end) end)

    elixir = outcome(fn -> mod.__defk_elixir__(fun, args) end)

    call = "#{inspect(mod)}.#{fun}(#{Enum.map_join(args, ", ", &inspect(&1, limit: 5))})"

    case {native, elixir} do
      {{:ok, a}, {:ok, b}} ->
        assert a === b,
               "#{call}: native #{inspect(a, limit: 8)}, Elixir mode #{inspect(b, limit: 8)}"

      {{:raise, a}, {:raise, b}} ->
        assert {a.__struct__, reason(a)} == {b.__struct__, reason(b)},
               "#{call}: native raised #{inspect(a)} (#{inspect(reason(a))}), " <>
                 "Elixir mode raised #{inspect(b)} (#{inspect(reason(b))})"

      _ ->
        flunk(
          "#{call}: native #{inspect(native, limit: 8)}, Elixir mode #{inspect(elixir, limit: 8)}"
        )
    end

    native
  end

  # message fragments -> reason, first match wins; messages of the kernel
  # (priv/defk_runtime.h), Elixir mode (Defk.ElixirMode.Ops) and Elixir itself
  @arith [
    {"i64 overflow", :overflow},
    {"does not fit in i64", :overflow},
    # u64 arithmetic leaving 0..2^64 - 1, an i64 < 0 where a u64 is expected
    {"u64 overflow", :overflow},
    {"does not fit in u64", :overflow},
    {"negative count", :negative_shift},
    # Elixir's float arithmetic giving inf or NaN, and the kernel's checks for
    # the same (x / 0.0, sqrt/log out of domain, a non-finite result)
    {"bad argument in arithmetic expression", :non_finite},
    {"by zero", :zero_divisor},
    {"within one step of the i64 limit", :range_limit},
    {"non-finite", :non_finite},
    {"inf or NaN", :non_finite},
    {"sqrt of negative", :non_finite},
    {"log of non-positive", :non_finite}
  ]

  @arg [
    # the argument checks at entry: "argument 2 (step) must be ..."
    {{:prefix, "argument "}, :badarg},
    {"non-finite float", :non_finite_input},
    {"length too large", :length_too_large},
    {"out of memory", :out_of_memory},
    {"negative length", :negative_length},
    {"does not fit in u8", :element_range},
    {"does not fit in u64", :element_range},
    {"does not fit in i64", :element_range},
    # Defk.Bits.clz/2 and friends
    {"is not in 1..64", :bits_width},
    {"-bit field", :bits_range},
    {"step", :zero_step}
  ]

  @doc """
  The normalised reason of a kernel or Elixir mode exception: what went
  wrong, without the message text, which differs between the two (`%g`
  against `inspect/1`, Elixir's own messages for float arithmetic). An
  exception no rule covers gives `{:other, message}`, so it agrees only with
  the identical message.
  """
  def reason(%ArithmeticError{message: m}), do: match_reason(m, @arith)
  def reason(%ArgumentError{message: m}), do: match_reason(m, @arg)
  def reason(%Enum.OutOfBoundsError{}), do: :index
  def reason(%CaseClauseError{}), do: :clause
  def reason(e), do: {:other, Exception.message(e)}

  defp match_reason(m, rules) do
    Enum.find_value(rules, {:other, m}, fn {pat, r} -> if matches?(m, pat), do: r end)
  end

  defp matches?(m, {:prefix, p}), do: String.starts_with?(m, p)
  defp matches?(m, p), do: String.contains?(m, p)
end
