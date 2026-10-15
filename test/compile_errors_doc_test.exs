defmodule Defk.CompileErrorsDocTest do
  # docs/compile-errors.md, the error catalogue: every error code
  # has its anchor (the compile error footer links <page>#<code>), and the
  # "Codes" section with the "Retired" section after it are the registry's
  # text. Its links are checked in test/docs_checks_test.exs.
  use ExUnit.Case, async: true

  import Defk.LanguageDoc, only: [headings: 1, anchors: 1]

  @doc_path "docs/compile-errors.md"

  setup_all do
    %{doc: File.read!(@doc_path)}
  end

  # the generated part: from the "Codes" heading to the end of the file
  defp generated(doc) do
    [_, rest] = String.split(doc, ~r/^## Codes$/m, parts: 2)
    rest
  end

  # the text of the `## <title>` section, up to the next ## heading
  defp section(doc, title) do
    [_, rest] = String.split(doc, ~r/^## #{title}$/m, parts: 2)
    [section | _] = String.split(rest, ~r/^## /m, parts: 2)
    section
  end

  defp codes(retired?),
    do: for(%{kind: k, code: code} <- Defk.Errors.entries(), k == :retired == retired?, do: code)

  test "the Codes section has a ### heading per active code, Retired one per retired code, and nothing else",
       %{doc: doc} do
    for {title, retired?} <- [{"Codes", false}, {"Retired", true}] do
      in_section = for {3, text} <- headings(section(doc, title)), do: text
      assert in_section == codes(retired?), title
    end
  end

  test "each code's anchor belongs to its heading and to no other", %{doc: doc} do
    anchors = anchors(doc)

    for %{code: code} <- Defk.Errors.entries() do
      assert Enum.count(anchors, &(&1 == code)) == 1, "anchor ##{code}"
    end
  end

  test "a code is its own anchor on GitHub and on ex_doc" do
    # Both slug a heading by lowercasing it and turning spaces into hyphens,
    # but differ on dots, apostrophes and the like: a code of only [a-z0-9-]
    # is the same anchor in both.
    for %{code: code} <- Defk.Errors.entries() do
      assert code =~ ~r/^[a-z0-9]+(-[a-z0-9]+)*$/, "code #{inspect(code)} is not a plain slug"
    end
  end

  # the whole generated part, not just a match inside it: a stray line pasted
  # with the output (mix run's "Compiling N files (.ex)") fails here
  test "the Codes and Retired sections are the registry's text and nothing else", %{doc: doc} do
    assert generated(doc) == "\n\n" <> Defk.Errors.reference(),
           "regenerate with: mix run -e 'IO.write(Defk.Errors.reference())' (docs/agents/generated-docs.md)"
  end
end
