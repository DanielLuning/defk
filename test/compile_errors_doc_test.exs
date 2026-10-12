defmodule Defk.CompileErrorsDocTest do
  # docs/compile-errors.md, the error catalogue (defk-djy.6): every error code
  # has its anchor (the compile error footer links <page>#<code>), the "Codes"
  # section is the registry's text, and every in-page link resolves.
  use ExUnit.Case, async: true

  import Defk.LanguageDoc, only: [headings: 1, anchors: 1]

  @doc_path "docs/compile-errors.md"

  setup_all do
    %{doc: File.read!(@doc_path)}
  end

  # the text of the "Codes" section
  defp codes_section(doc) do
    [_, rest] = String.split(doc, ~r/^## Codes$/m, parts: 2)
    [section | _] = String.split(rest, ~r/^## /m, parts: 2)
    section
  end

  test "every error code has a ### heading in the Codes section, and every heading there is a code",
       %{doc: doc} do
    codes = Enum.map(Defk.Errors.codes(), & &1.code)

    in_section =
      for {3, text} <- headings(codes_section(doc)), do: text

    assert in_section == codes
  end

  test "each code's anchor belongs to its heading and to no other", %{doc: doc} do
    anchors = anchors(doc)

    for %{code: code} <- Defk.Errors.codes() do
      assert Enum.count(anchors, &(&1 == code)) == 1, "anchor ##{code}"
    end
  end

  test "a code is its own anchor on GitHub and on ex_doc" do
    # Both slug a heading by lowercasing it and turning spaces into hyphens,
    # but differ on dots, apostrophes and the like: a code of only [a-z0-9-]
    # is the same anchor in both.
    for %{code: code} <- Defk.Errors.codes() do
      assert code =~ ~r/^[a-z0-9]+(-[a-z0-9]+)*$/, "code #{inspect(code)} is not a plain slug"
    end
  end

  # the whole section, not just a match inside it: a stray line pasted with
  # the output (mix run's "Compiling N files (.ex)") fails here
  test "the Codes section is the registry's text and nothing else", %{doc: doc} do
    assert codes_section(doc) == "\n\n" <> Defk.Errors.reference(),
           "regenerate with: mix run -e 'IO.write(Defk.Errors.reference())' (docs/agents/generated-docs.md)"
  end

  test "every in-page link resolves", %{doc: doc} do
    anchors = MapSet.new(anchors(doc))

    for [_, a] <- Regex.scan(~r/\]\(#([^)]+)\)/, doc) do
      assert a in anchors, "broken link ##{a}"
    end
  end
end
