defmodule Mix.Tasks.Defk.Messages do
  @shortdoc "Writes priv/defk_messages.h from Defk.Messages"

  @moduledoc """
  Writes the runtime's message defines, `priv/defk_messages.h`, from the
  message templates in `Defk.Messages` (lib/defk/messages.ex).

      mix defk.messages           # rewrite the header
      mix defk.messages --check   # exit 1 when the header is out of date

  The runtime header includes the generated file and raises with its
  `DEFK_MSG_` defines; Elixir mode interpolates the same templates. After
  changing a template, run this task and commit both files.
  `test/messages_test.exs` fails while the header is out of date.

  The task compiles lib/defk/messages.ex on its own, so it works before the
  project compiles (a renamed define would otherwise fail the C build of
  every kernel first).
  """

  use Mix.Task

  @path "priv/defk_messages.h"
  @source "lib/defk/messages.ex"

  @impl Mix.Task
  def run(args) do
    {opts, rest} = OptionParser.parse!(args, strict: [check: :boolean])
    rest == [] || Mix.raise("unexpected arguments: #{Enum.join(rest, " ")}")

    unless Code.ensure_loaded?(Defk.Messages), do: Code.compile_file(@source)

    new = Defk.Messages.header()
    current = File.read(@path)

    cond do
      current == {:ok, new} ->
        Mix.shell().info("#{@path} matches Defk.Messages")

      opts[:check] ->
        Mix.raise("#{@path} is out of date (run mix defk.messages)")

      true ->
        File.write!(@path, new)
        Mix.shell().info("wrote #{@path}")
    end
  end
end
