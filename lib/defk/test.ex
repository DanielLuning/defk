defmodule Defk.Test do
  @moduledoc """
  Agreement checks for tests: does a kernel give what its Elixir mode gives?

  A kernel and its Elixir mode **agree** on an input when both return
  identical values (`===`, so floats must be bit-exact), or both raise the
  same exception module for the same reason (`agreement_reason/1`). Elixir
  mode is the oracle: it defines what the same code gives in Elixir, with the
  kernel subset's limits applied. `assert_agrees/3` runs one call both ways
  and fails the test when they disagree.

      iex> defmodule MyApp.Bytes do
      ...>   use Defk, elixir_mode: true
      ...>
      ...>   defk count_below(bytes :: [u8], limit :: i64) :: i64 do
      ...>     for b <- bytes, reduce: 0 do
      ...>       n -> if b < limit, do: n + 1, else: n
      ...>     end
      ...>   end
      ...> end
      iex> Defk.Test.assert_agrees(MyApp.Bytes, :count_below, ["hello", 105])
      {:ok, 2}

  It needs ExUnit (its failures are ExUnit assertion errors) and a module
  compiled with Elixir mode: every kernel module in the `:test`
  environment, or one with `use Defk, elixir_mode: true`.

  [Testing kernels](testing.md) shows it in a test file, with property tests
  over generated inputs and forced yields.
  """

  import ExUnit.Assertions

  @typedoc """
  What a call did: `{:ok, value}` or `{:raise, exception}`.
  """
  @type outcome :: {:ok, term()} | {:raise, Exception.t()}

  @typedoc """
  The cause of a kernel or Elixir mode exception, without its message: an
  atom such as `:overflow`, `:zero_divisor`, `:non_finite`, `:index` or
  `:badarg`, or `{:other, message}` for an exception no rule covers.
  """
  @type reason :: atom() | {:other, String.t()}

  defp outcome(f) do
    {:ok, f.()}
  rescue
    e -> {:raise, e}
  end

  @doc """
  Calls `mod.fun(args...)` natively and in Elixir mode, and asserts that the
  two agree. Returns the native outcome.

  Both return identical values (`===`, bit-exact floats), or both raise the
  same exception module with the same `agreement_reason/1`; otherwise the
  assertion fails with both outcomes in its message. It also fails when
  `mod.fun/arity` is not exported. `mod` must be compiled with Elixir mode
  (see the module docs).

      iex> defmodule MyApp.Sum do
      ...>   use Defk, elixir_mode: true
      ...>
      ...>   defk sum(a :: [i64]) :: i64 do
      ...>     for x <- a, reduce: 0 do
      ...>       acc -> acc + x
      ...>     end
      ...>   end
      ...> end
      iex> pack = fn xs -> for x <- xs, into: <<>>, do: <<x::signed-64-native>> end
      iex> Defk.Test.assert_agrees(MyApp.Sum, :sum, [pack.([1, 2, 3])])
      {:ok, 6}
      iex> {:raise, e} = Defk.Test.assert_agrees(MyApp.Sum, :sum, [pack.([2 ** 62, 2 ** 62])])
      iex> {e.__struct__, Defk.Test.agreement_reason(e)}
      {ArithmeticError, :overflow}
  """
  @spec assert_agrees(module(), atom(), [term()]) :: outcome()
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
        assert {a.__struct__, agreement_reason(a)} == {b.__struct__, agreement_reason(b)},
               "#{call}: native raised #{inspect(a)} (#{inspect(agreement_reason(a))}), " <>
                 "Elixir mode raised #{inspect(b)} (#{inspect(agreement_reason(b))})"

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
    {"log of non-positive", :non_finite},
    {"log2 of non-positive", :non_finite},
    {"log10 of non-positive", :non_finite}
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
    {"does not fit in i16", :element_range},
    {"does not fit in i32", :element_range},
    {"does not fit in f32", :element_range},
    {"bitstring segment size", :segment_size},
    {"bitstring segment value", :segment_fit},
    {"step", :zero_step}
  ]

  @doc """
  The reason of a kernel or Elixir mode exception, as agreement compares it:
  what went wrong, without the message text, which may differ between the two
  (a kernel prints floats as C does, Elixir mode with `inspect/1`, and
  Elixir's own float errors say "bad argument in arithmetic expression").

  An exception no rule covers gives `{:other, message}`, so it agrees only
  with the identical message. Use it to assert why a kernel raised.

      iex> Defk.Test.agreement_reason(%ArithmeticError{message: "i64 overflow in 1 + 2"})
      :overflow
      iex> Defk.Test.agreement_reason(%ArithmeticError{message: "bad argument in arithmetic expression"})
      :non_finite
      iex> Defk.Test.agreement_reason(%Enum.OutOfBoundsError{})
      :index
      iex> Defk.Test.agreement_reason(%RuntimeError{message: "boom"})
      {:other, "boom"}
  """
  @spec agreement_reason(Exception.t()) :: reason()
  def agreement_reason(%ArithmeticError{message: m}), do: match_reason(m, @arith)
  def agreement_reason(%ArgumentError{message: m}), do: match_reason(m, @arg)
  def agreement_reason(%Enum.OutOfBoundsError{}), do: :index
  def agreement_reason(%CaseClauseError{}), do: :clause
  def agreement_reason(e), do: {:other, Exception.message(e)}

  defp match_reason(m, rules) do
    Enum.find_value(rules, {:other, m}, fn {pat, r} -> if matches?(m, pat), do: r end)
  end

  defp matches?(m, {:prefix, p}), do: String.starts_with?(m, p)
  defp matches?(m, p), do: String.contains?(m, p)
end
