defmodule Defk.Catalog do
  @moduledoc false
  # The catalog's kernels live in scripts that also install deps and run a
  # benchmark; load compiles only their modules. test_helper.exs calls it
  # once, before any test file is loaded.

  @scripts ~w(geo_nearest rolling_stats image_blur poor_list_data poor_tiny_calls _template)

  def load do
    for name <- @scripts do
      file = Path.expand("../../examples/#{name}.exs", __DIR__)
      {:__block__, _, top} = Code.string_to_quoted!(File.read!(file), file: file)
      for {:defmodule, _, _} = mod <- top, do: Code.compile_quoted(mod, file)
    end

    :ok
  end
end
