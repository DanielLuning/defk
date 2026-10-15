defmodule Defk.UsageRulesTest do
  # The usage rules (usage-rules.md and usage-rules/*.md), which a dependent's
  # `mix usage_rules.sync` copies into their AGENTS.md or skills. They are a
  # condensed view of the docs, so these checks keep them from drifting:
  #
  #   - each generated list is the registry's text (Defk.Errors.scope/2)
  #   - each row of the main file's rewrite table is a row of the cheatsheet's
  #   - every link is a URL (the rules are read inside another project), a
  #     HexDocs one names this version, an extra and a heading of it
  #   - no ticket ids or ADRs: the rules are for users
  #   - the Hex package ships them
  #
  # Their examples run in test/language_doc_examples_test.exs.
  use ExUnit.Case, async: true

  alias Defk.LanguageDoc

  @version Mix.Project.config()[:version]
  @hexdocs "https://hexdocs.pm/defk/#{@version}/"
  @repo_url "https://github.com/DanielLuning/defk/blob/main/"

  setup_all do
    %{rules: Map.new(LanguageDoc.usage_rules(), &{&1, File.read!(&1)})}
  end

  # {kind, text} of each generated block: the lines between
  # `<!-- generated: ... Defk.Errors.scope(:kind, :hexdocs) ... -->` and
  # `<!-- end generated -->`
  defp generated(text) do
    for [_, kind, list] <-
          Regex.scan(
            ~r/<!-- generated: [^\n]*Defk\.Errors\.scope\(:(\w+), :hexdocs\)[^\n]* -->\n(.*?)<!-- end generated -->/s,
            text
          ),
        do: {String.to_existing_atom(kind), list}
  end

  test "the generated lists are the registry's text", %{rules: rules} do
    blocks = for {path, text} <- rules, {kind, list} <- generated(text), do: {path, kind, list}

    for {path, kind, list} <- blocks do
      assert list == Defk.Errors.scope(kind, :hexdocs),
             "#{path}: regenerate with mix run -e 'IO.write(Defk.Errors.scope(#{inspect(kind)}, :hexdocs))'"
    end

    assert Enum.sort(for {_, kind, _} <- blocks, do: kind) == [:planned, :subset]
  end

  # the first two cells of each body row of the table under `heading`
  defp rewrite_rows(text, heading) do
    [_, after_heading] = String.split(text, heading, parts: 2)

    after_heading
    |> String.split("\n")
    |> Enum.drop_while(&(not String.starts_with?(&1, "|")))
    |> Enum.take_while(&String.starts_with?(&1, "|"))
    |> Enum.drop(2)
    |> Enum.map(fn row -> row |> String.split(~r/(?<!\\)\|/) |> Enum.slice(1, 2) end)
  end

  test "the rewrite table is rows of the cheatsheet's", %{rules: rules} do
    ours = rewrite_rows(rules["usage-rules.md"], "## Write this instead")
    cheatsheet = File.read!("docs/guides/cheatsheet.cheatmd")
    theirs = rewrite_rows(cheatsheet, "### Write this instead")

    assert ours != []
    assert ours -- theirs == [], "rows not in the cheatsheet: #{inspect(ours -- theirs)}"
  end

  # nil, or why the link is wrong
  defp broken(@hexdocs <> rest) do
    [page | anchor] = String.split(rest, "#", parts: 2)

    sources =
      Map.new(LanguageDoc.extras(), &{String.downcase(Path.rootname(Path.basename(&1))), &1})

    with {:ok, source} <- Map.fetch(sources, Path.rootname(page)),
         [a] <- anchor,
         false <- a in LanguageDoc.anchors(File.read!(source)) do
      "no heading ##{a} in #{source}"
    else
      :error -> "#{page} is not a page of the docs"
      _ -> nil
    end
  end

  defp broken("https://hexdocs.pm/defk/" <> _), do: "not this version's docs (#{@hexdocs})"

  defp broken(@repo_url <> path),
    do: unless(File.exists?(path), do: "no such file #{path}")

  defp broken("http" <> _), do: nil
  defp broken(_relative), do: "a relative link: the rules are read in another project"

  test "every link is a URL that resolves", %{rules: rules} do
    bad =
      for {path, text} <- rules,
          target <- LanguageDoc.links(text),
          why = broken(target),
          do: "#{path}: (#{target}) #{why}"

    assert bad == [], Enum.join(["links:" | bad], "\n  ")
  end

  test "the link check catches a wrong page, heading, version and a relative link" do
    assert broken(@hexdocs <> "language.html#builtins") == nil
    assert broken(@hexdocs <> "compile-errors.html#unsupported-map") == nil
    assert broken(@hexdocs <> "no-such.html") =~ "not a page"
    assert broken(@hexdocs <> "language.html#no-such") =~ "no heading"
    assert broken("https://hexdocs.pm/defk/0.0.1/language.html") =~ "not this version"
    assert broken("docs/language.md") =~ "relative"
  end

  test "no ticket ids or ADRs", %{rules: rules} do
    found =
      for {path, text} <- rules,
          {line, n} <- text |> String.split("\n") |> Enum.with_index(1),
          line =~ ~r/\bdefk-[a-z0-9]{3}(\.\d+)?\b|\bADR[- ]?\d|docs\/adr\//,
          do: "#{path}:#{n}: #{line}"

    assert found == []
  end

  test "the Hex package ships them" do
    files = Mix.Project.config()[:package][:files]
    assert "usage-rules.md" in files and "usage-rules" in files
  end
end
