defmodule Mix.Tasks.Defk.Stability.Freeze do
  # Layout: repo-only Mix tasks live in dev/mix/tasks/ (see
  # Mix.Tasks.Defk.Examples). This one needs Defk.LanguageDoc from
  # test/support, so mix.exs runs it in the :test environment.
  @shortdoc "Freezes a release's kernels, rejections and API under test/stability/<version>/"

  @moduledoc """
  Copies every valid kernel a release shipped, with the results its docs
  give, into `test/stability/<version>/kernels/`, every rejected example,
  with its error code, into `test/stability/<version>/rejections/`, one
  example per file, and the public API the release promised into
  `test/stability/<version>/api.exs`, all read from the release's git tag
  (`v<version>`). From then on every `mix test` compiles each frozen kernel
  and checks its results (test/stability_kernels_test.exs), compiles each
  frozen rejection and checks it still fails with its code
  (test/stability_rejections_test.exs), and checks that each promised
  macro, function and option is still there (test/stability_api_test.exs):
  the stability promise, checked mechanically. The files are never edited;
  docs/agents/stability.md has the rules.

      mix defk.stability.freeze 0.1.0

  The API snapshot (`api.exs`) is the surface docs/guides/stability.md
  ("The public API") promised at the tag, as the data
  test/stability_api_test.exs reads:

    * the public modules with their documented macros and functions and
      every arity each is callable at: `Code.fetch_docs/1` on the modules
      compiled at the tag (the tag checked out in a temporary git worktree
      and compiled there in `:prod`, which compiles lib/ alone and needs no
      dependency; the docs read from its beams; the worktree removed), minus
      everything `@doc false` and the unstable tier, which is a list in code
      (`unstable/0`, which the docs checks hold the guide's "What it does not
      cover" to). Plus `__using__/1`, which is `use Defk` and which Elixir
      hides from the docs;
    * the generated functions the Defk moduledoc's table marks public, read
      from the same docs;
    * the `use Defk` options `Defk.__options__/0` marks public, each with a
      value a kernel module accepts (the values are the task's), the kernel
      option, the configuration key and the environment variables
      `Defk.Build.env_vars/0` marks public. These come from the code the
      task runs in, like the page list and the catalog below.

  What else is frozen, each read with `git show v<version>:<path>`:

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
    * `rejections/`: the `error: <code>` blocks of the same doc pages, and
      the `example` of every entry of the error registry (lib/defk/errors.ex
      at the tag, read from its source), named after its code. An entry
      without an example (the build environment raises its code, not a
      kernel) is skipped and named.

  A frozen file is Markdown that `Defk.LanguageDoc.extract/1` reads back
  as one example: a comment naming the source, the kernel block, and the
  `iex>` block or the `compiles:` or `error:` annotation. The task reads each
  file back and stops if it does not give the example it was written from;
  `api.exs` is read back the same way, as the data it was written from.

  The version's `kernels/` and `rejections/` directories and its `api.exs`
  are written afresh. Run the task at the release commit, where the page
  list, the catalog, the options and the environment variables are the
  release's. Rerun for a version already frozen, it reproduces that
  version's files byte for byte.
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

    write!(Path.join(root, "kernels"), doc_examples(tag, pages) ++ catalog_examples(tag))
    write!(Path.join(root, "rejections"), doc_rejections(tag, pages) ++ registry_rejections(tag))
    write_api!(Path.join(root, "api.exs"), version, tag)
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

  # ------------------------------------------------------------------- api --

  # The unstable tier (docs/guides/stability.md, "What it does not cover"),
  # kept out of the API snapshot: these modules and functions, the options
  # and environment variables Defk.__options__/0 and Defk.Build.env_vars/0
  # mark unstable, and the generated functions the Defk moduledoc's table
  # does.
  @unstable_modules [Defk.Bench, Defk.Bench.TickGap]
  @unstable_functions [{Defk.Errors, :fetch!, 1}]

  # The promised surface no module's docs describe, as the test reads it:
  # what a kernel's own function keeps, a value a kernel module accepts for
  # each public `use Defk` option (the option names are Defk.__options__/0's;
  # the values are the task's), the kernel option with a value, and the
  # configuration key with the values it accepts.
  @kernel_function [:exported, :spec]
  @option_values [elixir_mode: true, report: :full, max_owned_bytes: 4096]
  @kernel_options [yield: false]
  @config [{:defk, :mode, [:native, :elixir]}]

  @doc """
  The unstable tier, each item named as the stability guide writes it: the
  modules and functions, the `use Defk` options, the environment variables
  and the generated functions that may change in any release.
  test/docs_checks_test.exs holds the guide's "What it does not cover" to
  this list.
  """
  def unstable do
    {:docs_v1, _, _, _, %{"en" => moduledoc}, _, _} = Code.fetch_docs(Defk)

    Enum.map(@unstable_modules, &inspect/1) ++
      Enum.map(@unstable_functions, fn {mod, name, arity} ->
        "#{inspect(mod)}.#{name}/#{arity}"
      end) ++
      for({option, :unstable} <- Defk.__options__(), do: "#{option}:") ++
      for({name, :unstable} <- Defk.Build.env_vars(), do: name) ++
      for({name, arity, :unstable} <- generated(moduledoc), do: "#{name}/#{arity}")
  end

  defp write_api!(path, version, tag) do
    modules = Enum.map(public_modules(tag), &with_using/1)

    {Defk, moduledoc, _} =
      List.keyfind(modules, Defk, 0) || Mix.raise("#{tag}: the Defk module has no docs")

    api = %{
      version: version,
      modules: Map.new(modules, fn {mod, _, items} -> {mod, items} end),
      generated:
        for({name, arity, :public} <- generated(moduledoc), do: {:function, name, arity}),
      kernel_function: @kernel_function,
      use_defk_options: option_values(),
      kernel_options: @kernel_options,
      config: @config,
      env: for({name, :public} <- Defk.Build.env_vars(), do: name)
    }

    {formatter, _} = Mix.Tasks.Format.formatter_for_file(path)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, formatter.(api_file(version, tag, modules, api)))

    case Code.eval_file(path) do
      {^api, []} -> Mix.shell().info("the API snapshot written to #{path}")
      _ -> Mix.raise("#{path}: read back as other data than it was written from")
    end
  end

  # `{module, moduledoc, [{kind, name, arity}]}` of each public module
  # compiled at the tag, by name: a module with a moduledoc, with every
  # documented macro and function at every arity its defaults make it
  # callable at, minus the unstable tier
  defp public_modules(tag) do
    for {mod, {:docs_v1, _, _, _, %{"en" => moduledoc}, _, docs}} <- docs_at_tag(tag),
        mod not in @unstable_modules do
      items =
        for {{kind, name, max}, _, _, doc, meta} <- docs,
            kind in [:function, :macro],
            is_map(doc),
            arity <- (max - Map.get(meta, :defaults, 0))..max//1,
            {mod, name, arity} not in @unstable_functions,
            do: {kind, name, arity}

      {mod, moduledoc, items}
    end
    |> Enum.sort()
  end

  # `use Defk` is `__using__/1`, which Elixir hides from the docs
  defp with_using({Defk, moduledoc, items}),
    do: {Defk, moduledoc, [{:macro, :__using__, 1} | items]}

  defp with_using(other), do: other

  # `{module, docs}` of every module of the tag's lib/, read with
  # Code.fetch_docs/1 from the beams: the tag checked out in a temporary git
  # worktree, compiled there in :prod (lib/ alone, with no dependency loaded
  # and none built), and the worktree removed
  defp docs_at_tag(tag) do
    dir = Path.join(System.tmp_dir!(), "defk-freeze-#{System.unique_integer([:positive])}")
    git!(["worktree", "add", "--detach", dir, tag])

    try do
      env = [
        {"MIX_ENV", "prod"},
        {"MIX_BUILD_PATH", Path.join(dir, "_build")},
        {"MIX_DEPS_PATH", Path.join(dir, "deps")}
      ]

      case System.cmd("mix", ["compile", "--no-deps-check"],
             cd: dir,
             env: env,
             stderr_to_stdout: true
           ) do
        {_, 0} -> :ok
        {out, _} -> Mix.raise("mix compile of #{tag} in #{dir} failed:\n#{out}")
      end

      for beam <- Path.wildcard(Path.join([dir, "_build", "lib", "defk", "ebin", "*.beam"])),
          do: {Module.concat([Path.basename(beam, ".beam")]), Code.fetch_docs(beam)}
    after
      git!(["worktree", "remove", "--force", dir])
    end
  end

  defp git!(args) do
    case System.cmd("git", args, stderr_to_stdout: true) do
      {out, 0} -> out
      {out, _} -> Mix.raise("git #{Enum.join(args, " ")} failed:\n#{out}")
    end
  end

  # `{name, arity, tier}` of the generated functions the Defk moduledoc's
  # table lists ("Generated functions"), public or unstable
  defp generated(moduledoc) do
    for [name, stability | _] <- LanguageDoc.table(moduledoc, "## Generated functions") do
      [fun, arity] = Regex.run(~r/^`(__defk_\w+__)\/(\d+)`$/, name, capture: :all_but_first)
      {String.to_atom(fun), String.to_integer(arity), tier(stability)}
    end
  end

  defp tier("public" <> _), do: :public
  defp tier("unstable" <> _), do: :unstable

  defp option_values do
    for {option, :public} <- Defk.__options__() do
      case Keyword.fetch(@option_values, option) do
        {:ok, value} ->
          {option, value}

        :error ->
          Mix.raise("use Defk, #{option}: is public, and @option_values has no value for it")
      end
    end
  end

  # the file's text, before the formatter: a comment per section, one item
  # per line where the test checks each
  defp api_file(version, tag, modules, api) do
    """
    # The public API of defk #{version}, as data, written by
    # `mix defk.stability.freeze #{version}` from the #{tag} tag.
    #
    # This is the surface that docs/guides/stability.md ("The public API")
    # promised at the tag: the documented macros and functions of the public
    # modules with their arities (`Code.fetch_docs/1` on the modules compiled
    # at the tag, minus the unstable tier and everything `@doc false`), the
    # functions `use Defk` generates in a kernel module, the options, the
    # configuration key and the environment variables.
    #
    # Frozen: this file is never edited. A later release adds a directory with
    # its own file. test/stability_api_test.exs reads it and fails when an item
    # listed here is missing, no longer exported, hidden, or has another arity.
    # Additions are not listed here, so they pass.
    %{
      version: #{inspect(version)},
      # the public modules, with the promised macros and functions of each;
      # `__using__/1` is `use Defk`, which Elixir hides from the docs
      modules: %{
    #{Enum.map_join(modules, ",\n", fn {mod, _, items} -> "#{inspect(mod)} => #{lines(items)}" end)}
      },
      # what `use Defk` defines in a kernel module: a function per kernel with
      # the kernel's name and arity and a @spec, and these
      generated: #{lines(api.generated)},
      kernel_function: #{inspect(api.kernel_function)},
      # `use Defk, ...`: each option, with a value a kernel module accepts
      use_defk_options: #{inspect(api.use_defk_options)},
      # `defk head, ...`: the kernel option, with a value
      kernel_options: #{inspect(api.kernel_options)},
      # the configuration key and the values it accepts
      config: #{inspect(api.config)},
      # the environment variables, in the elixir_make convention
      env: #{inspect(api.env)}
    }
    """
  end

  # a list with one item per line (the formatter keeps the lines)
  defp lines(items), do: "[\n#{Enum.map_join(items, ",\n", &inspect/1)}\n]"

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
