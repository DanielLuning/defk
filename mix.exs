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
      aliases: aliases()
    ]
  end

  def application, do: [extra_applications: [:logger]]

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  # demo.exs and bench/ use the example kernels; deps compile as :prod and skip them
  defp elixirc_paths(:dev), do: ["lib", "test/support/examples.ex"]
  defp elixirc_paths(_), do: ["lib"]

  def cli do
    [
      preferred_envs: [ci: :test]
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
      {:stream_data, "~> 1.1", only: :test},
      {:igniter, "~> 0.6", optional: true}
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
  @reference ["docs/language.md", "docs/guides/cheatsheet.cheatmd"]

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

  defp aliases() do
    [
      ci: [
        "compile --warnings-as-errors",
        "format --check-formatted",
        "test",
        "docs --warnings-as-errors",
        "credo --strict",
        "dialyzer",
        "ex_dna --max-clones 0",
        "reach.check --arch --smells"
      ]
    ]
  end
end
