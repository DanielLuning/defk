# PROTOTYPE: throwaway exploration of a typed native-kernel subset of Elixir.
defmodule Defk.MixProject do
  use Mix.Project

  def project do
    [app: :defk, version: "0.0.1", elixir: "~> 1.18", deps: []]
  end

  def application, do: [extra_applications: [:logger]]
end
