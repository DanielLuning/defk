# defk: a typed native-kernel subset of Elixir.
defmodule Defk.MixProject do
  use Mix.Project

  def project do
    [app: :defk, version: "0.0.1", elixir: "~> 1.18", deps: [{:stream_data, "~> 1.1"}]]
  end

  def application, do: [extra_applications: [:logger]]
end
