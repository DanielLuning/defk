defmodule ReleaseDebian.MixProject do
  use Mix.Project

  def project do
    [
      app: :release_debian,
      version: "0.1.0",
      elixir: "~> 1.18",
      deps: [{:defk, path: "../.."}],
      releases: [release_debian: []]
    ]
  end

  def application, do: [extra_applications: [:logger]]
end
