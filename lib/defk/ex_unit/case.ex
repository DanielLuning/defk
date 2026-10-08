defmodule Defk.Case do
  @moduledoc false

  use ExUnit.CaseTemplate

  using do
    quote do
      import Defk.Case
    end
  end

  defmacro __using__(opts \\ []) do
    quote do
      use ExUnit.Case, unquote(opts)
      import Defk.Case
    end
  end

  defmacro in_both_modes(do: block) do
    quote do
      Defk.ElixirMode.with_mode(:native, fn -> unquote(block) end)
      Defk.ElixirMode.with_mode(:elixir, fn -> unquote(block) end)
    end
  end
end
