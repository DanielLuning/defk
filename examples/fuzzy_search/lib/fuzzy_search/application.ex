defmodule FuzzySearch.Application do
  @moduledoc false
  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    {micros, catalog} = :timer.tc(&FuzzySearch.Catalog.load/0)
    Logger.info("loaded #{tuple_size(catalog.words)} words in #{div(micros, 1000)} ms")
    port = String.to_integer(System.get_env("PORT", "4000"))

    children =
      if System.get_env("NO_SERVER"),
        do: [],
        else: [{Bandit, plug: FuzzySearch.Router, port: port}]

    Supervisor.start_link(children, strategy: :one_for_one, name: FuzzySearch.Supervisor)
  end
end
