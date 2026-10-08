defmodule Defk.Divergences do
  @moduledoc false

  @divergences %{}

  def list, do: @divergences

  def registry, do: @divergences

  def has_divergences?, do: false

  def match?(_mod, _fun, _args), do: false

  def explain(_divergence), do: ""

  def generate_page!(_path \\ "docs/divergences.md"), do: :ok
end
