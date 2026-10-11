defmodule Defk.Args do
  @moduledoc false
  # The variables a generated function passes its arguments on in: the
  # parameter names, with a leading underscore dropped (`_scale` is used
  # there, which Elixir warns about), numbered when that name is taken.

  def vars(params) do
    names = MapSet.new(params, &elem(&1, 0))

    for {{p, _}, i} <- Enum.with_index(params) do
      trimmed = String.trim_leading(Atom.to_string(p), "_")

      name =
        cond do
          trimmed == "" -> :"arg#{i}"
          trimmed == Atom.to_string(p) -> p
          String.to_atom(trimmed) in names -> :"#{trimmed}#{i}"
          true -> String.to_atom(trimmed)
        end

      {name, [generated: true], nil}
    end
  end
end
