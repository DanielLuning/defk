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

  Options:

    * `:forced_yields` - `true` also runs the native side under
      `__defk_force_yields__/1` (every safepoint yields), asserting the same
      agreement, so every resume path is covered by the one call. The flag
      is module-wide while the forced run executes: in `async: true` tests
      only use it on modules no other test file calls.
    * `:message` - `:exact` compares raised exceptions whole (module and
      message text), instead of module plus `agreement_reason/1`. For
      kernels whose messages carry no C-formatted values.
  """
  @spec assert_agrees(module(), atom(), [term()], keyword()) :: outcome()
  def assert_agrees(mod, fun, args, opts \\ []) do
    arity = length(args)
    Code.ensure_loaded(mod)

    if not function_exported?(mod, fun, arity) do
      flunk("#{inspect(mod)}.#{fun}/#{arity} is not exported")
    end

    run_native = fn -> Defk.ElixirMode.with_mode(:native, fn -> apply(mod, fun, args) end) end
    native = outcome(run_native)
    elixir = outcome(fn -> mod.__defk_elixir__(fun, args) end)

    call = "#{inspect(mod)}.#{fun}(#{Enum.map_join(args, ", ", &inspect(&1, limit: 5))})"
    assert_outcomes(call, native, elixir, opts)

    if opts[:forced_yields] do
      forced =
        try do
          mod.__defk_force_yields__(true)
          outcome(run_native)
        after
          mod.__defk_force_yields__(false)
        end

      assert_outcomes("#{call} under forced yields", forced, elixir, opts)
    end

    native
  end

  defp assert_outcomes(call, native, elixir, opts) do
    case {native, elixir} do
      {{:ok, a}, {:ok, b}} ->
        assert a === b,
               "#{call}: native #{inspect(a, limit: 8)}, Elixir mode #{inspect(b, limit: 8)}"

      {{:raise, a}, {:raise, b}} ->
        assert {a.__struct__, raise_key(a, opts)} == {b.__struct__, raise_key(b, opts)},
               "#{call}: native raised #{inspect(a)} (#{inspect(raise_key(a, opts))}), " <>
                 "Elixir mode raised #{inspect(b)} (#{inspect(raise_key(b, opts))})"

      _ ->
        flunk(
          "#{call}: native #{inspect(native, limit: 8)}, Elixir mode #{inspect(elixir, limit: 8)}"
        )
    end
  end

  defp raise_key(e, opts) do
    if opts[:message] == :exact, do: Exception.message(e), else: agreement_reason(e)
  end

  @doc """
  The reason of a kernel or Elixir mode exception, as agreement compares it:
  what went wrong, without the message text, which may differ between the two
  (a kernel prints floats as C does, Elixir mode with `inspect/1`, and
  Elixir's own float errors say "bad argument in arithmetic expression").

  The rules are the runtime's own message templates, the ones the kernel and
  Elixir mode raise with, so a message and its reason cannot drift apart. An
  exception no rule covers gives `{:other, message}`, so it agrees only with
  the identical message. Use it to assert why a kernel raised.

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
  def agreement_reason(e), do: Defk.Messages.reason(e)
end
