defmodule Defk.LanguageDocTest do
  # docs/language.md, the kernel subset reference: every error code has its
  # anchor (the compile error footer links docs/language.md#<code>), the error
  # section is the registry's text, and every in-page link resolves.
  use ExUnit.Case, async: true

  import Defk.LanguageDoc, only: [headings: 1, anchors: 1]

  @doc_path "docs/language.md"

  setup_all do
    %{doc: File.read!(@doc_path)}
  end

  # the text of the "Compile errors" section
  defp error_section(doc) do
    [_, rest] = String.split(doc, ~r/^## \d+\. Compile errors$/m, parts: 2)
    [section | _] = String.split(rest, ~r/^## /m, parts: 2)
    section
  end

  test "every error code has a ### heading in the error section, and every heading there is a code",
       %{doc: doc} do
    codes = Enum.map(Defk.Errors.codes(), & &1.code)

    in_section =
      for {3, text} <- headings(error_section(doc)), do: text

    assert in_section == codes
  end

  test "each code's anchor belongs to its heading and to no other", %{doc: doc} do
    anchors = anchors(doc)

    for %{code: code} <- Defk.Errors.codes() do
      assert Enum.count(anchors, &(&1 == code)) == 1, "anchor ##{code}"
    end
  end

  test "the error section is the registry's text", %{doc: doc} do
    assert String.contains?(error_section(doc), Defk.Errors.reference()),
           "regenerate with: mix run -e 'IO.write(Defk.Errors.reference())'"
  end

  test "every in-page link resolves", %{doc: doc} do
    anchors = MapSet.new(anchors(doc))

    for [_, a] <- Regex.scan(~r/\]\(#([^)]+)\)/, doc) do
      assert a in anchors, "broken link ##{a}"
    end
  end
end
