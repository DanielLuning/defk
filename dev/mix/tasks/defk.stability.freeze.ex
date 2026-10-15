defmodule Mix.Tasks.Defk.Stability.Freeze do
  # Layout: repo-only Mix tasks live in dev/mix/tasks/ (see
  # Mix.Tasks.Defk.Examples). This one needs Defk.LanguageDoc from
  # test/support, so mix.exs runs it in the :test environment.
  @shortdoc "Freezes a release's valid kernels and rejections under test/stability/<version>/"

  @moduledoc """
  Copies every valid kernel a release shipped, with the results its docs
  give, into `test/stability/<version>/kernels/`, and every rejected example,
  with its error code, into `test/stability/<version>/rejections/`, one
  example per file, read from the release's git tag (`v<version>`). From then
  on every `mix test` compiles each frozen kernel and checks its results
  (test/stability_kernels_test.exs), and compiles each frozen rejection and
  checks it still fails with its code (test/stability_rejections_test.exs):
  the stability promise, checked mechanically. The files are never edited;
  docs/agents/stability.md has the rules.

      mix defk.stability.freeze 0.1.0

  What is frozen, each read with `git show v<version>:<path>`:

    * `kernels/`: the doc pages `mix test` checks (the HexDocs extras,
      docs/performance.md and the usage rules, as `Defk.LanguageDoc` lists
      them; a page the tag has not is skipped and named): every kernel block
      followed by `iex>` lines, which the test compiles, runs natively and in
      Elixir mode and checks against the documented results, and every
      `compiles:` block, compiled only. Sketches, test files, scripts and
      known failures are not valid kernels of the release and stay out.
    * `kernels/`: the catalog's example kernels (test/support/examples.ex)
      and the kernel modules of the catalog scripts `mix test` compiles
      (`Defk.Catalog`), each where it names no other module of its script, as
      a frozen file holds one module: compiled only, as the scripts measure
      their results instead of documenting them.
    * `kernels/`: the test sample, `test-<name>.md`: the kernels
      dev/stability/sample.exs lists, after the test suite's edge cases, with
      the results the tag's code gives to the calls it lists. The tag is
      checked out in a temporary worktree, compiled in the test environment,
      and dev/stability/eval.exs runs every call there, natively and in
      Elixir mode; the two must agree. This step fetches the tag's deps and
      compiles them, so it takes a minute or two.
    * `rejections/`: the `error: <code>` blocks of the same doc pages, and
      the `example` of every entry of the error registry (lib/defk/errors.ex
      at the tag, read from its source), named after its code. An entry
      without an example (the build environment raises its code, not a
      kernel) is skipped and named.

  A frozen file is Markdown that `Defk.LanguageDoc.extract/1` reads back
  as one example: a comment naming the source, the kernel block, and the
  `iex>` block or the `compiles:` or `error:` annotation. The task reads each
  file back and stops if it does not give the example it was written from.

  The version's `kernels/` and `rejections/` directories are written afresh.
  Run the task at the release commit, where the page list and the catalog
  are the release's.
  """
  use Mix.Task

  alias Defk.LanguageDoc
  alias Defk.LanguageDoc.Example

  @requirements ["compile"]

  @registry "lib/defk/errors.ex"

  @impl Mix.Task
  def run([version]) do
    tag = "v#{version}"
    root = Path.join(["test", "stability", version])
    pages = page_examples(tag)

    kernels = doc_examples(tag, pages) ++ catalog_examples(tag) ++ sample_examples(tag)
    write!(Path.join(root, "kernels"), kernels)
    write!(Path.join(root, "rejections"), doc_rejections(tag, pages) ++ registry_rejections(tag))
  end

  def run(_),
    do: Mix.raise("usage: mix defk.stability.freeze <version>   (the tag is v<version>)")

  defp write!(dir, files) do
    File.rm_rf!(dir)
    File.mkdir_p!(dir)

    for {name, text, expected} <- files do
      path = Path.join(dir, name)
      File.write!(path, text)
      read_back!(path, text, expected)
    end

    Mix.shell().info("#{length(files)} frozen file(s) written to #{dir}/")
  end

  # ------------------------------------------------------------------ docs --

  # {page, example} of every example of the doc pages mix test checks
  defp page_examples(tag) do
    pages = LanguageDoc.extras() ++ ["docs/performance.md" | LanguageDoc.usage_rules()]

    for page <- pages,
        doc = at_tag(tag, page),
        ex <- LanguageDoc.extract(doc),
        do: {page, ex}
  end

  defp doc_examples(tag, pages) do
    for {page, ex} <- pages,
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

  defp doc_file(tag, page, %Example{check: {:compiles, reason}} = ex),
    do: annotated(tag, page, ex.line, "compiles: #{reason}", ex.source)

  defp doc_rejections(tag, pages) do
    for {page, %Example{check: {:error, _}} = ex} <- pages,
        do: {file_name(page, ex.line), rejection_file(tag, page, ex.line, ex), ex}
  end

  defp rejection_file(tag, path, line, %Example{check: {:error, code}} = ex),
    do: annotated(tag, path, line, "error: #{code}", ex.source)

  defp origin(tag, path, line),
    do: "<!-- #{path} line #{line} of #{tag}. A frozen file is never edited. -->\n"

  # a file with an annotation in place of an iex> block
  defp annotated(tag, path, line, annotation, source) do
    Enum.join(
      [origin(tag, path, line), "<!-- defk-example #{annotation} -->", fence(source), ""],
      "\n"
    )
  end

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
    text = annotated(tag, path, line, "compiles: #{reason}", source)
    {file_name(path, line), text, %Example{check: {:compiles, reason}, source: source}}
  end

  # -------------------------------------------------------------- registry --

  # the example of every entry of the error registry at the tag, read from
  # the source (the registry loaded here is today's): one file per code,
  # named after it. An example is a module body with the kernel, as the
  # extractor wraps it
  defp registry_rejections(tag) do
    {_, entries} =
      tag
      |> at_tag(@registry)
      |> Code.string_to_quoted!(file: @registry)
      |> Macro.prewalk([], &entry/2)

    for {line, code, example} <- Enum.reverse(entries), example?(code, example) do
      ex = %Example{check: {:error, code}, source: example}
      {file_name(@registry, code), rejection_file(tag, @registry, line, ex), ex}
    end
  end

  # a registry entry: a map literal with a code and an example
  defp entry({:%{}, meta, kvs} = node, acc) when is_list(kvs) do
    case {List.keyfind(kvs, :code, 0), List.keyfind(kvs, :example, 0)} do
      {{:code, code}, {:example, example}} when is_binary(code) ->
        {node, [{meta[:line], code, example} | acc]}

      _ ->
        {node, acc}
    end
  end

  defp entry(node, acc), do: {node, acc}

  defp example?(_code, example) when is_binary(example), do: true

  defp example?(code, nil) do
    Mix.shell().info("#{@registry}: #{code} has no example (not raised by a kernel), skipped")
    false
  end

  defp example?(code, _),
    do: Mix.raise("#{@registry}: the example of #{code} is not a string literal")

  # ---------------------------------------------------------------- sample --

  # The test sample: @sample lists module bodies (kernels after the test
  # suite's edge cases) and the calls to record; @eval runs them at the tag,
  # in a temporary worktree compiled in the test environment, so the frozen
  # results are the release's own, in both modes. One file per entry,
  # `test-<name>.md`: the kernel block, then an iex> block with each call and
  # the native result (a value as `inspect/2` writes it, or the exception).
  @sample "dev/stability/sample.exs"
  @eval "dev/stability/eval.exs"

  defp sample_examples(tag) do
    sample = sample()
    results = Map.new(run_sample_at(tag))

    for entry <- sample do
      steps =
        for {call, result} <- Map.fetch!(results, entry.file),
            do: %{expr: call, expected: recorded(result, entry.file, call)}

      ex = %Example{check: :run, source: entry.source, steps: steps}
      {"test-#{entry.file}.md", sample_file(tag, entry, ex), ex}
    end
  end

  # the entries, each source without its heredoc's final newline, as the
  # extractor reads a fenced block back
  defp sample do
    {sample, _} = Code.eval_file(@sample)
    for entry <- sample, do: %{entry | source: String.trim_trailing(entry.source, "\n")}
  end

  defp sample_file(tag, entry, ex) do
    origin =
      "<!-- after #{Enum.join(entry.from, ", ")} of #{tag}: the test sample " <>
        "(#{@sample}), run at the tag. A frozen file is never edited. -->\n"

    Enum.join([origin, fence(ex.source), "", fence(iex_block(ex.steps)), ""], "\n")
  end

  defp recorded({:value, value}, _file, _call),
    do: {:value, inspect(value, limit: :infinity, printable_limit: :infinity)}

  defp recorded({:raise, mod, msg}, file, call) do
    if msg =~ "\n" do
      Mix.raise(
        "#{file}: #{call} raised a message of several lines, which the iex> form " <>
          "cannot hold; change the call or the kernel:\n#{msg}"
      )
    end

    {:raise, mod, msg}
  end

  # [{file, [{call, {:value, term} | {:raise, module, message}}]}], as @eval
  # writes them at the tag: the tag in a temporary worktree (a stale one
  # from an interrupted run is removed first), its deps fetched, and @eval
  # run there with `MIX_ENV=test mix run`
  defp run_sample_at(tag) do
    dir = Path.join(System.tmp_dir!(), "defk_stability_freeze_#{tag}")
    out = dir <> ".results"
    System.cmd("git", ["worktree", "remove", "--force", dir], stderr_to_stdout: true)
    File.rm_rf!(dir)
    System.cmd("git", ["worktree", "prune"])
    git!(["worktree", "add", "--detach", dir, tag])
    Mix.shell().info("running #{@sample} at #{tag} in #{dir} (a minute or two)")

    try do
      mix_at!(dir, ["deps.get"])
      mix_at!(dir, ["run", Path.expand(@eval), Path.expand(@sample), out])
      out |> File.read!() |> :erlang.binary_to_term()
    after
      System.cmd("git", ["worktree", "remove", "--force", dir], stderr_to_stdout: true)
      File.rm(out)
    end
  end

  defp git!(args) do
    case System.cmd("git", args, stderr_to_stdout: true) do
      {out, 0} -> out
      {out, _} -> Mix.raise("git #{Enum.join(args, " ")} failed:\n#{out}")
    end
  end

  # a mix command in the tag's worktree, its output shown only when it fails
  defp mix_at!(dir, args) do
    env = [{"MIX_ENV", "test"}]

    case System.cmd("mix", args, cd: dir, env: env, stderr_to_stdout: true) do
      {_, 0} -> :ok
      {output, status} -> Mix.raise("mix #{hd(args)} at the tag failed (#{status}):\n#{output}")
    end
  end

  # ---------------------------------------------------------------- shared --

  defp file_name(path, suffix) do
    base = path |> Path.rootname() |> String.replace("/", "-")
    "#{base}-#{suffix}.md"
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
