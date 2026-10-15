defmodule Mix.Tasks.Defk.Stability.Freeze do
  # Layout: repo-only Mix tasks live in dev/mix/tasks/ (see
  # Mix.Tasks.Defk.Examples). This one needs Defk.LanguageDoc from
  # test/support, so mix.exs runs it in the :test environment.
  @shortdoc "Freezes a release's valid kernels under test/stability/<version>/kernels/"

  @moduledoc """
  Copies every valid kernel a release shipped, with the results its docs
  give, into `test/stability/<version>/kernels/`, one example per file, read
  from the release's git tag (`v<version>`). From then on every `mix test`
  compiles each frozen kernel and checks its results
  (test/stability_kernels_test.exs): the stability promise, checked
  mechanically. The files are never edited; docs/agents/stability.md has the
  rules.

      mix defk.stability.freeze 0.1.0

  What is frozen, each read with `git show v<version>:<path>`:

    * the doc pages `mix test` checks (the HexDocs extras,
      docs/performance.md and the usage rules, as `Defk.LanguageDoc` lists
      them; a page the tag has not is skipped and named): every kernel block
      followed by `iex>` lines, which the test compiles, runs natively and in
      Elixir mode and checks against the documented results, and every
      `compiles:` block, compiled only. Rejected examples, sketches, test
      files, scripts and known failures are not valid kernels of the release
      and stay out.
    * the catalog's example kernels (test/support/examples.ex) and the kernel
      modules of the catalog scripts `mix test` compiles (`Defk.Catalog`),
      each where it names no other module of its script, as a frozen file
      holds one module: compiled only, as the scripts measure their results
      instead of documenting them.

  A frozen file is Markdown that `Defk.LanguageDoc.extract/1` reads back
  as one example: a comment naming the source, the kernel block, and the
  `iex>` block or the `compiles:` annotation. The task reads each file back
  and stops if it does not give the example it was written from.

  The version's `kernels/` directory is written afresh. Run the task at the
  release commit, where the page list and the catalog are the release's.
  """
  use Mix.Task

  alias Defk.LanguageDoc
  alias Defk.LanguageDoc.Example

  @requirements ["compile"]

  @impl Mix.Task
  def run([version]) do
    tag = "v#{version}"
    dir = Path.join(["test", "stability", version, "kernels"])
    File.rm_rf!(dir)
    File.mkdir_p!(dir)

    files = doc_examples(tag) ++ catalog_examples(tag)

    for {name, text, expected} <- files do
      path = Path.join(dir, name)
      File.write!(path, text)
      read_back!(path, text, expected)
    end

    Mix.shell().info("#{length(files)} frozen file(s) written to #{dir}/")
  end

  def run(_),
    do: Mix.raise("usage: mix defk.stability.freeze <version>   (the tag is v<version>)")

  # ------------------------------------------------------------------ docs --

  defp doc_examples(tag) do
    pages = LanguageDoc.extras() ++ ["docs/performance.md" | LanguageDoc.usage_rules()]

    for page <- pages,
        doc = at_tag(tag, page),
        ex <- LanguageDoc.extract(doc),
        frozen?(ex),
        do: {file_name(page, ex.line), doc_file(tag, page, ex), ex}
  end

  # a valid kernel of the release with a check the test can repeat
  defp frozen?(%Example{known_failure: nil, check: :run}), do: true
  defp frozen?(%Example{known_failure: nil, check: {:compiles, _}}), do: true
  defp frozen?(_), do: false

  defp doc_file(tag, page, %Example{check: :run} = ex) do
    Enum.join(
      [origin(tag, page, ex.line), fence(ex.source), "", fence(iex_block(ex.steps)), ""],
      "\n"
    )
  end

  defp doc_file(tag, page, %Example{check: {:compiles, reason}} = ex) do
    Enum.join([origin(tag, page, ex.line), compiles(reason), fence(ex.source), ""], "\n")
  end

  defp origin(tag, path, line),
    do: "<!-- #{path} line #{line} of #{tag}. A frozen file is never edited. -->\n"

  defp compiles(reason), do: "<!-- defk-example compiles: #{reason} -->"

  defp fence(body), do: "```elixir\n#{body}\n```"

  # the iex> block as the extractor parses it back: an expression over
  # `iex>` and `...>` lines, then its documented output
  defp iex_block(steps) do
    Enum.map_join(steps, "\n\n", fn step ->
      [first | more] = String.split(step.expr, "\n")
      lines = ["iex> #{first}" | Enum.map(more, &"...> #{&1}")]

      output =
        case step.expected do
          nil -> []
          {:value, src} -> [src]
          {:raise, mod, msg} -> ["** (#{mod}) #{msg}"]
        end

      Enum.join(Enum.map(lines, &String.trim_trailing/1) ++ output, "\n")
    end)
  end

  # --------------------------------------------------------------- catalog --

  defp catalog_examples(tag) do
    kernels = "test/support/examples.ex"
    source = at_tag(tag, kernels)
    [module_file(tag, kernels, 1, source, "the catalog's example kernels") | script_examples(tag)]
  end

  # the kernel modules of the catalog scripts mix test compiles: a module
  # with `use Defk` that names no other module of its script
  defp script_examples(tag) do
    for script <- Defk.Catalog.scripts(),
        path = "examples/#{script}.exs",
        source = at_tag(tag, path),
        {name, first, last} <- modules(path, source),
        kernel_module?(name, first, last, source, path, modules(path, source)),
        do: module_file(tag, path, first, slice(source, first, last), "a catalog kernel module")
  end

  # {name, first line, last line} of each top-level defmodule of a script
  defp modules(path, source) do
    {:__block__, _, forms} = Code.string_to_quoted!(source, file: path, token_metadata: true)

    for {:defmodule, meta, [{:__aliases__, _, parts} | _]} <- forms,
        do: {Enum.map_join(parts, ".", &Atom.to_string/1), meta[:line], meta[:end][:line]}
  end

  defp kernel_module?(name, first, last, source, path, modules) do
    text = slice(source, first, last)

    if text =~ ~r/^\s*use Defk\b/m do
      named =
        for {other, _, _} <- modules,
            other != name,
            text =~ ~r/(?<![\w.])#{Regex.escape(other)}(?!\w|\.[A-Z])/,
            do: other

      if named == [] do
        true
      else
        Mix.shell().info("#{path}: #{name} skipped, it names #{Enum.join(named, ", ")}")
        false
      end
    else
      false
    end
  end

  defp slice(source, first, last) do
    source
    |> String.split("\n")
    |> Enum.slice((first - 1)..(last - 1)//1)
    |> Enum.join("\n")
  end

  defp module_file(tag, path, line, source, reason) do
    text = Enum.join([origin(tag, path, line), compiles(reason), fence(source), ""], "\n")
    {file_name(path, line), text, %Example{check: {:compiles, reason}, source: source}}
  end

  # ---------------------------------------------------------------- shared --

  defp file_name(path, line) do
    base = path |> Path.rootname() |> String.replace("/", "-")
    "#{base}-#{line}.md"
  end

  defp at_tag(tag, path) do
    case System.cmd("git", ["show", "#{tag}:#{path}"], stderr_to_stdout: true) do
      {text, 0} ->
        text

      {_, _} ->
        Mix.shell().info("#{path}: not in #{tag}, skipped")
        nil
    end
  end

  # the file gives back one example: the check, the kernel and the steps it
  # was written from (line numbers aside)
  defp read_back!(path, text, expected) do
    case LanguageDoc.extract(text) do
      [%Example{} = ex] ->
        if {ex.check, ex.source, steps(ex)} == {expected.check, expected.source, steps(expected)},
          do: :ok,
          else: Mix.raise("#{path}: read back as #{inspect(ex.check)}, not the example written")

      other ->
        Mix.raise("#{path}: read back as #{length(other)} example(s), not one")
    end
  end

  defp steps(%Example{steps: steps}), do: Enum.map(steps, &Map.delete(&1, :line))
end
