defmodule Defk.ApiDoctestTest do
  # The examples in the API docs (moduledocs and @doc) run here, in native
  # code; Defk.Bits's run in masked_arith_test.exs. An example that defines a
  # kernel module compiles it with Elixir mode (this is :test), so the module
  # below runs the same examples again in Elixir mode.
  use ExUnit.Case, async: true

  doctest Defk
  doctest Defk.Test
  doctest Defk.ElixirMode
  doctest Defk.Report
  doctest Defk.Errors
  doctest Defk.Bench.TickGap
end

defmodule Defk.ApiDoctestElixirModeTest do
  # The same doctests, with every kernel call of the test process in Elixir
  # mode (Defk.ElixirMode.with_mode/2 sets the same key): a kernel example
  # gives what the docs say both ways.
  use ExUnit.Case, async: true

  setup do
    Process.put(Defk.ElixirMode.process_mode_key(), :elixir)
    :ok
  end

  doctest Defk
end
