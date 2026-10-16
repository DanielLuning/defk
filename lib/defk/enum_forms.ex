defmodule Defk.EnumForms do
  @moduledoc false
  # Enum.reduce/3 and Enum.find/3 in kernel bodies, written as the forms the
  # compiler and Elixir mode already know, before either sees the body (as
  # Defk.Attributes.inline/1 does for attributes), so both modes give them
  # the same meaning:
  #
  #   Enum.reduce(src, init, fn x, acc -> body end)
  #     for x <- src, reduce: init do acc -> body end
  #
  #   Enum.find(src, default, fn x -> pred end)
  #     Enum.reduce_while(src, default, fn x, d -> if pred, do: {:halt, x}, else: {:cont, d} end)
  #
  # Only a literal one-clause fn with no guard, and for find a plain variable
  # x, is rewritten; any other form stays as written and the compiler rejects
  # it (fn-argument). Enum.find/2 and Enum.find_index/2 return nil when
  # nothing matches, and a kernel has no nil, so they stay rejected
  # (enum-find).

  # the accumulator and element of a find: names no kernel writes (a name
  # that starts with _ would not be bound)
  @default :defk__find_default
  @elem :defk__find_elem

  @doc false
  # the accumulator's name: the compiler reports a type mismatch on it as
  # one between Enum.find/3's default and the elements
  def find_default, do: @default

  @doc false
  def desugar(%{body: body} = kernel), do: %{kernel | body: Macro.prewalk(body, &form/1)}

  # the same on a bare expression (the compiler checks the inside of a
  # rejected pipe this way, since a pipe hides the arity before unpiping)
  def desugar(ast), do: Macro.prewalk(ast, &form/1)

  defp form({{:., _, [{:__aliases__, _, [:Enum]}, :reduce]}, m, [src, init, f]} = node) do
    case f do
      {:fn, _, [{:->, am, [[x, acc], body]}]} ->
        {:for, m, [{:<-, m, [x, src]}, [reduce: init, do: [{:->, am, [[acc], body]}]]]}

      _ ->
        node
    end
  end

  defp form({{:., dm, [{:__aliases__, _, [:Enum]} = enum, :find]}, m, [src, default, f]} = node) do
    case f do
      {:fn, fm, [{:->, am, [[{name, _, ctx} = x], pred]}]} when is_atom(name) and is_atom(ctx) ->
        d = {@default, m, nil}
        # `fn _ -> ... end`: the element still needs a name to be returned
        x = if String.starts_with?(Atom.to_string(name), "_"), do: {@elem, m, nil}, else: x
        body = {:if, m, [pred, [do: {:halt, x}, else: {:cont, d}]]}
        fun = {:fn, fm, [{:->, am, [[x, d], body]}]}
        {{:., dm, [enum, :reduce_while]}, m, [src, default, fun]}

      _ ->
        node
    end
  end

  defp form(node), do: node
end
