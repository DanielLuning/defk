defmodule Mix.Tasks.Defk.Contracts do
  @shortdoc "Checks a released version's frozen contract against the code"

  @moduledoc """
  Runs the contract a release froze (test/stability/<version>/contracts/,
  written by `mix defk.stability.freeze`) against the code in the working
  tree, through Covenant: every active obligation of that release must have
  a passing test, and its decision records must parse.

      mix defk.contracts            # list the versions with a frozen contract
      mix defk.contracts 0.2.0      # check one version's contract
      mix defk.contracts --all      # check every version's contract

  `mix test` already runs every frozen contract test; this task adds
  Covenant's checks of that version's Contract (coverage, tags, records), and
  writes its coverage to the version's directory, where git ignores it.
  Dev tooling (docs/agents/stability.md).
  """
  use Mix.Task

  alias Defk.Stability.Contracts

  @impl Mix.Task
  def run([]) do
    case Contracts.versions() do
      [] -> Mix.shell().info("no frozen contract under test/stability/*/contracts/")
      versions -> Mix.shell().info(Enum.join(versions, "\n"))
    end
  end

  def run(["--all"]), do: Enum.each(Contracts.versions(), &check/1)
  def run([version]), do: check(version)

  def run(_),
    do: Mix.raise("usage: mix defk.contracts [<version> | --all]")

  defp check(version) do
    dir = Contracts.dir(version)
    unless File.dir?(dir), do: Mix.raise("#{version} has no frozen contract (#{dir}/)")

    Mix.shell().info("defk.contracts: the contract of #{version} against the working tree")
    Mix.Task.rerun("covenant.check", ["--contracts", dir, "--test-path", dir])
  end
end
