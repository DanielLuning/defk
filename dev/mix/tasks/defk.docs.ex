defmodule Mix.Tasks.Defk.Docs do
  @shortdoc "Rewrites every generated region of the docs"

  @moduledoc """
  Rewrites every generated region of the repository's docs (`Defk.Docs`):
  the error catalogue and the lists of codes from the registry
  (`Defk.Errors`), the runtime's message defines from the templates
  (`Defk.Messages`), and the catalog's result tables from the stored
  scoreboard (`Defk.Examples.Tables`).

      mix defk.docs           # rewrite every region that is out of date
      mix defk.docs --check   # exit 1 when a region is out of date

  A region is a whole file, or the lines between `<!-- NAME:start -->` and
  `<!-- NAME:end -->`; the rest of each file is left alone. `mix ci` runs
  the check. Never edit a generated line: change the registry, the
  template or the measured scoreboard, and run this task.

  The message defines come from `lib/defk/messages.ex` alone, compiled on
  its own when the project is not: a renamed define must reach the header
  before the C of any kernel is built.
  """

  use Mix.Task

  @messages "lib/defk/messages.ex"

  @impl Mix.Task
  def run(args) do
    {opts, rest} = OptionParser.parse!(args, strict: [check: :boolean])
    rest == [] || Mix.raise("unexpected arguments: #{Enum.join(rest, " ")}")

    unless Code.ensure_loaded?(Defk.Messages), do: Code.compile_file(@messages)
    Mix.Task.run("compile")

    stale =
      for {file, marker, text} <- Defk.Docs.regions(),
          content = File.read!(file),
          new = updated!(content, file, marker, text),
          new != content,
          uniq: true do
        unless opts[:check], do: File.write!(file, new)
        Path.relative_to_cwd(file)
      end

    cond do
      stale == [] ->
        Mix.shell().info("every generated region is up to date")

      opts[:check] ->
        Mix.raise("out of date: #{Enum.join(stale, ", ")} (run mix defk.docs)")

      true ->
        Mix.shell().info("rewrote #{Enum.join(stale, ", ")}")
    end
  end

  defp updated!(content, file, marker, text) do
    case Defk.Docs.put(content, marker, text) do
      {:ok, new} -> new
      {:error, why} -> Mix.raise("#{file}: #{why}")
    end
  end
end
