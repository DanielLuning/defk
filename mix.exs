# defk: a typed native-kernel subset of Elixir.
defmodule Defk.MixProject do
  use Mix.Project

  @version "0.0.1"
  @source_url "https://github.com/DanielLuning/defk"

  def project do
    [
      app: :defk,
      version: @version,
      elixir: "~> 1.20",
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      dialyzer: [plt_add_apps: [:ex_unit, :mix]],
      name: "defk",
      source_url: @source_url,
      docs: docs(),
      aliases: aliases(),
      usage_rules: usage_rules()
    ]
  end

  def application, do: [extra_applications: [:logger]]

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  # demo.exs and bench/ use the example kernels; deps compile as :prod and skip them
  defp elixirc_paths(:dev), do: ["lib", "test/support/examples.ex"]
  defp elixirc_paths(_), do: ["lib"]

  def cli do
    [
      preferred_envs: [ci: :test, dump_c: :test]
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
      {:igniter, "~> 0.6", optional: true}
    ]
  end

  # `mix usage_rules.sync` writes these rules into the marked section of
  # AGENTS.md; `mix ci` fails when that section is out of date. Choice
  # (defk-mob): usage_rules' own rules (doc lookup with `mix usage_rules.docs`
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
  # Choice (defk-djy.1): guides and docs/language.md are extras. ADRs,
  # research, cold tests, verdict.md, fast-path-report.md and beam-nifs.md are
  # project history for people inside the repo, so they are left out of
  # HexDocs (they stay in the repo and are linked from the README).
  #
  # Choice (defk-djy.4): the how-to guides live in docs/guides/, apart from
  # the reference and the project history in docs/. README stays the main
  # page (what defk is and why, as on GitHub) and Getting started comes
  # right after it; the cheatsheet is a lookup page beside the reference.
  #
  # Choice (defk-djy.14): README stays the main page and the GitHub landing
  # page, trimmed to what a user needs (what defk is, when not to use it,
  # a first kernel, links into the guides). The repo-internal parts (file
  # table, design decisions, results snapshot, roadmap with ticket ids,
  # tracker notes) moved to docs/project.md, which is not an extra; README
  # links it by its GitHub URL.
  @guides [
    "README.md",
    "docs/guides/getting-started.md",
    "docs/guides/testing.md",
    "docs/guides/measuring.md",
    "docs/guides/runtime-contract.md",
    "docs/guides/deploying.md",
    "docs/scope.md",
    "docs/performance.md"
  ]
  @reference ["docs/language.md", "docs/compile-errors.md", "docs/guides/cheatsheet.cheatmd"]

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      # the example kernels compile in :dev for demo.exs and bench/, not as API
      filter_modules: fn mod, _meta -> mod != Examples.Kernels end,
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
  # in the flat doc/ directory (found by the HexDocs cold test, defk-djy.9).
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
      # the byte-identical gate (defk-mif): DEFK_DUMP_C=<dir> mix dump_c
      dump_c: ["compile --force", "run scripts/dump_c.exs"],
      ci: [
        "compile --warnings-as-errors",
        "format --check-formatted",
        "test",
        "docs --warnings-as-errors",
        "credo --strict",
        "dialyzer",
        "ex_dna --max-clones 0",
        "reach.check --arch --smells",
        "usage_rules.sync --check"
      ]
    ]
  end
end
