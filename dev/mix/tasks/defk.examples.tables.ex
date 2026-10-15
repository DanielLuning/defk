defmodule Mix.Tasks.Defk.Examples.Tables do
  @shortdoc "Rewrites the catalog's result tables from examples/scoreboard.json"

  @moduledoc """
  Rewrites the result tables in examples/README.md (the scoreboard) and
  README.md (the summary) from the stored scoreboard, examples/scoreboard.json,
  and the hand-written text in examples/_tables.exs.

      mix defk.examples --bench --all --snapshot --fresh   # measure, store the scoreboard
      mix defk.examples.tables                             # rewrite the tables
      mix defk.examples.tables --check                     # exit 1 when a table is out of date

  Each table sits between `<!-- NAME:start -->` and `<!-- NAME:end -->`
  comments; the rest of each file is left alone. Never edit a number inside
  them: measure again, or change the text in examples/_tables.exs.
  `test/scoreboard_doc_test.exs` fails when a table and the scoreboard
  disagree.
  """

  use Mix.Task

  alias Defk.Examples
  alias Defk.Examples.{Snapshot, Tables}

  @impl Mix.Task
  def run(args) do
    {opts, rest} = OptionParser.parse!(args, strict: [check: :boolean])
    rest == [] || Mix.raise("unexpected arguments: #{Enum.join(rest, " ")}")

    snapshot =
      case Snapshot.read() do
        {:ok, s} ->
          s

        {:error, why} ->
          Mix.raise(
            "no stored scoreboard (#{why}); run mix defk.examples --bench --all --snapshot"
          )
      end

    blocks =
      case Tables.render(snapshot, Tables.text()) do
        {:ok, blocks} ->
          blocks

        {:error, problems} ->
          Mix.raise(
            "the tables cannot be rendered:\n" <> Enum.map_join(problems, "\n", &("  * " <> &1))
          )
      end

    stale =
      for {file, marker} <- Tables.targets(),
          path = Path.join(Examples.root(), file),
          content = File.read!(path),
          new = updated!(content, file, marker, blocks[marker]),
          new != content do
        unless opts[:check], do: File.write!(path, new)
        file
      end

    cond do
      stale == [] ->
        Mix.shell().info("the result tables match #{Path.relative_to_cwd(Snapshot.path())}")

      opts[:check] ->
        Mix.raise("out of date: #{Enum.join(stale, ", ")} (run mix defk.examples.tables)")

      true ->
        Mix.shell().info("rewrote #{Enum.join(stale, ", ")}")
    end
  end

  defp updated!(content, file, marker, block) do
    case Tables.put(content, marker, block) do
      {:ok, new} -> new
      {:error, why} -> Mix.raise("#{file}: #{why}")
    end
  end
end
