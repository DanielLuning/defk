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
  and asserts they agree. Agreement means both return identical values with ===
  (bit-exact floats) or both raise the same exception module.
  """
  def assert_agrees(mod, fun, args) do
    arity = length(args)

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

      {{:raise, %a_mod{}}, {:raise, %b_mod{}}} ->
        assert a_mod == b_mod,
               "#{call}: native raised #{inspect(native)}, Elixir mode #{inspect(elixir)}"

      _ ->
        flunk(
          "#{call}: native #{inspect(native, limit: 8)}, Elixir mode #{inspect(elixir, limit: 8)}"
        )
    end

    native
  end
end
