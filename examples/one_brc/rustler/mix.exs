defmodule OneBrcRustler.MixProject do
  use Mix.Project

  def project do
    [app: :one_brc_rustler, version: "0.1.0", elixir: "~> 1.18", deps: [{:rustler, "~> 0.37"}, {:defk, path: "../../.."}]]
  end

  def application, do: [extra_applications: [:logger]]
end
