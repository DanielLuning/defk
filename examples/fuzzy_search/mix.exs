defmodule FuzzySearch.MixProject do
  use Mix.Project

  def project do
    [app: :fuzzy_search, version: "0.1.0", elixir: "~> 1.18", deps: deps()]
  end

  def application do
    [extra_applications: [:logger], mod: {FuzzySearch.Application, []}]
  end

  defp deps do
    [
      {:defk, path: "../.."},
      {:bandit, "~> 1.6"},
      {:plug, "~> 1.16"}
    ]
  end
end
