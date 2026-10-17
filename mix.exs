# defk: a typed native-kernel subset of Elixir.
defmodule Defk.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/DanielLuning/defk"

  def project do
    [
      app: :defk,
      version: @version,
      elixir: "~> 1.20",
      elixirc_paths: elixirc_paths(Mix.env()),
      # test/stability/<version>/ holds frozen data of each release (the
      # promised API surface, kernels); the stability tests read it, mix
      # test does not load it
      test_ignore_filters: [&String.starts_with?(&1, "test/stability/")],
      deps: deps(),
      dialyzer: [plt_add_apps: [:ex_unit, :mix]],
      name: "defk",
      source_url: @source_url,
      description:
        "A typed subset of Elixir that compiles to checked native kernels, with the BEAM's promises kept",
      package: package(),
      docs: docs(),
      aliases: aliases(),
      usage_rules: usage_rules()
    ]
  end

  def application, do: [extra_applications: [:logger]]

  # The Hex package. It holds what a dependent's build needs: the compiler
  # (lib/), the runtime header (priv/defk_runtime.h) and the user docs
  # ex_doc builds from (the extras below). examples/, bench/, dev/, test/, the research
  # notes and docs/performance.md (a maintainers' record) stay out.
  # Defk.Errors' footer links the installed version's HexDocs page
  # (@url_base).
  #
  # Choice: the package ships usage rules for a dependent's agent
  # (usage-rules.md and usage-rules/, which `mix usage_rules.sync` reads
  # from deps/defk or a path dependency). The main file is short, as it is
  # inlined into someone else's AGENTS.md; the sub-rules (language.md,
  # testing.md) hold the longer parts, to inline or link. Measuring stays in
  # the main file and the guide: a few rules, no code of its own. No
  # pre-built skill: usage_rules builds a `use-defk` skill from these
  # files (`skills: [deps: [:defk]]`), so a skill of ours would be a second
  # copy; the Getting started guide shows a skill whose description names
  # what to look for. The links are this version's HexDocs URLs, like the
  # error footer, and test/usage_rules_test.exs keeps the rules true.
  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url, "Changelog" => @source_url <> "/blob/main/CHANGELOG.md"},
      files:
        ~w(lib priv/defk_runtime.h priv/defk_messages.h mix.exs README.md LICENSE CHANGELOG.md CONTEXT.md
                docs/guides docs/language.md docs/compile-errors.md docs/scope.md
                usage-rules.md usage-rules)
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "dev", "test/support"]
  # bench/ (incl. demo.exs) uses the example kernels; deps compile as :prod and skip them.
  # dev/ holds the repo-only Mix tasks (mix defk.examples, later mix defk.verify):
  # never compiled for a dependent, never in the Hex package. The dev compile
  # compiles every task under dev/, so it also needs the test/support modules
  # the tasks name (mix defk.stability.freeze reads docs with Defk.LanguageDoc).
  defp elixirc_paths(:dev),
    do: [
      "lib",
      "dev",
      "test/support/examples.ex",
      "test/support/catalog.ex",
      "test/support/language_doc.ex",
      "test/support/language_doc"
    ]

  defp elixirc_paths(_), do: ["lib"]

  def cli do
    [
      preferred_envs: [
        ci: :test,
        "ci.test": :test,
        dump_c: :test,
        "defk.stability.freeze": :test
      ]
    ]
  end

  defp deps do
    [
      {:ex_slop, "~> 0.4", only: [:dev, :test], runtime: false},
      {:reach, "~> 2.0", only: [:dev, :test], runtime: false},
      {:ex_dna, "~> 1.0", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.0", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.0", only: [:dev, :test], runtime: false},
      {:vibe_kit, "~> 0.1", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.34", only: [:dev, :test], runtime: false},
      {:usage_rules, "~> 1.2", only: [:dev, :test], runtime: false},
      {:stream_data, "~> 1.1", only: :test},
      {:covenant, "~> 0.2", only: [:dev, :test], runtime: false},
      {:igniter, "~> 0.6", optional: true}
    ]
  end

  # `mix usage_rules.sync` writes these rules into the marked section of
  # AGENTS.md; `mix ci` fails when that section is out of date. Choice:
  # usage_rules' own rules (doc lookup with `mix usage_rules.docs`
  # and `search_docs`) and the generic Elixir and OTP rules. `:usage_rules`
  # brings its :elixir and :otp sub-rules with it; listing them as well
  # (usage_rules 1.2.8) repeats the main rules once per entry. igniter's
  # rules are left out: defk writes no Igniter code.
  defp usage_rules do
    [
      file: "AGENTS.md",
      usage_rules: [:usage_rules]
    ]
  end

  # Docs structure. Adding a page is a one-line change: append its path to
  # @guides (how-to pages) or @reference (lookup pages); the group is derived
  # from the list.
  #
  # Choice: guides and docs/language.md are extras. ADRs,
  # research, cold tests, verdict.md, fast-path-report.md and beam-nifs.md are
  # project history for people inside the repo, so they are left out of
  # HexDocs (they stay in the repo and are linked from the README).
  #
  # Choice: the how-to guides live in docs/guides/, apart from
  # the reference and the project history in docs/. README stays the main
  # page (what defk is and why, as on GitHub) and Getting started comes
  # right after it; the cheatsheet is a lookup page beside the reference.
  #
  # Choice: README stays the main page and the GitHub landing
  # page, trimmed to what a user needs (what defk is, when not to use it,
  # a first kernel, links into the guides). The repo-internal parts (file
  # table, design decisions, results snapshot, roadmap with ticket ids,
  # tracker notes) moved to docs/project.md, which is not an extra; README
  # links it by its GitHub URL.
  #
  # Choice: the extras are for users, so they carry no ticket
  # ids and no ADR references (test/docs_checks_test.exs checks it).
  # docs/performance.md is a maintainers' record with a source line per
  # entry: it left the extras, and the pages link it by its GitHub URL.
  @guides [
    "README.md",
    "docs/guides/getting-started.md",
    "docs/guides/testing.md",
    "docs/guides/measuring.md",
    "docs/guides/runtime-contract.md",
    "docs/guides/deploying.md",
    "docs/guides/stability.md",
    "docs/scope.md"
  ]
  @reference ["docs/language.md", "docs/compile-errors.md", "docs/guides/cheatsheet.cheatmd"]

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      # the example kernels compile in :dev for bench/ (incl. demo.exs), not as API
      filter_modules: fn mod, _meta ->
        mod != Examples.Kernels and not String.starts_with?(inspect(mod), "Mix.Tasks.Defk.")
      end,
      extras: @guides ++ @reference,
      groups_for_extras: [Guides: @guides, Reference: @reference],
      groups_for_modules: [
        Kernels: [Defk],
        Testing: [Defk.Test, Defk.ElixirMode],
        "Benchmarking (unstable)": [Defk.Bench, Defk.Bench.TickGap],
        Report: [Defk.Report],
        "Bits helpers": [Defk.Bits],
        Errors: [Defk.Errors]
      ]
    ]
  end

  # ex_doc rewrites the links between pages in the HTML and the EPUB, but
  # writes each page's Markdown copy (doc/*.md, which llms.txt lists) as the
  # source has it, where `../language.md` or `cheatsheet.cheatmd` lead nowhere
  # in the flat doc/ directory (found by the HexDocs cold test).
  # After `mix docs`, point those links at the pages, then fail on any
  # relative link in doc/ that still leads nowhere.
  @md_link ~r/\]\(([^)\s]+)\)/
  @href ~r/href="([^"]+)"/

  defp docs_links(_args) do
    out = "doc"

    for md <- Path.wildcard(Path.join(out, "*.md")) do
      text = Regex.replace(@md_link, File.read!(md), fn _, t -> "](#{doc_link(t, out)})" end)
      File.write!(md, text)
    end

    broken =
      for file <- Path.wildcard(Path.join(out, "*.{md,html}")),
          re = if(Path.extname(file) == ".md", do: @md_link, else: @href),
          [_, target] <- Regex.scan(re, File.read!(file)),
          relative?(target),
          path = target |> String.split("#") |> hd(),
          path != "" and not File.exists?(Path.join(out, path)),
          uniq: true,
          do: "#{file}: #{target}"

    if broken != [] do
      Mix.raise("links that lead nowhere in #{out}/:\n  " <> Enum.join(broken, "\n  "))
    end
  end

  defp relative?(target),
    do: not String.match?(target, ~r/^([a-z]+:|#|`)/)

  # a Markdown link target as it should read in doc/: an extra's page by
  # its name there, a module (`Defk.Report`) by its page, else unchanged
  defp doc_link("`" <> _ = target, out) do
    page = String.trim(target, "`") <> ".md"
    if File.exists?(Path.join(out, page)), do: page, else: target
  end

  defp doc_link(target, _out) do
    with true <- relative?(target), {:ok, link} <- hexdocs_link(target) do
      link
    else
      _ -> target
    end
  end

  @doc false
  # Where a relative link in an extra leads in the built docs: `{:ok, link}`,
  # the page of the extra it names (by file name, as ex_doc resolves it in
  # the HTML), or `:error` when it names no extra. test/docs_checks_test.exs
  # runs every extra's links through it.
  def hexdocs_link(target) do
    [path | fragment] = String.split(target, "#", parts: 2)

    pages =
      Map.new(@guides ++ @reference, fn src ->
        name = Path.basename(src)
        {name, String.downcase(Path.rootname(name)) <> ".md"}
      end)

    case Map.fetch(pages, Path.basename(path)) do
      {:ok, page} -> {:ok, Enum.join([page | fragment], "#")}
      :error -> :error
    end
  end

  defp aliases() do
    [
      docs: ["docs", &docs_links/1],
      # the byte-identical gate: DEFK_DUMP_C=<dir> mix dump_c
      dump_c: ["compile --force", "run dev/dump_c.exs"],
      # the part of `ci` that can differ between machines and C compilers:
      # the release matrix runs it on the machines other than the one
      # that runs `ci` (ci/README.md)
      "ci.test": ["compile --warnings-as-errors", "test"],
      ci: [
        "compile --warnings-as-errors",
        "format --check-formatted",
        "test",
        # every active obligation under test/contracts/ has a passing test,
        # read from the results the test run just recorded
        "covenant.check --no-run",
        "docs --warnings-as-errors",
        "credo --strict",
        "dialyzer",
        # every compiled path, tests included; defk kernel
        # bodies are skipped, as tests repeat a kernel on purpose (the same
        # kernel under other options). Helpers under ~30 AST nodes stay a
        # review concern: a lower --min-mass reports noise.
        "ex_dna lib dev test --exclude-macro defk --max-clones 0",
        "reach.check --arch --smells",
        "usage_rules.sync --check",
        # the package builds (its tarball is git-ignored); publishing is a
        # decision, not a step. A fresh `mix`, because Hex's tasks are loaded
        # only when a mix process starts with them in hand, not inside an alias.
        "cmd mix hex.build"
      ]
    ]
  end
end
