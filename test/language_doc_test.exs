defmodule Defk.LanguageDocTest do
  # docs/language.md, the kernel subset reference: every error code has its
  # anchor (the compile error footer links docs/language.md#<code>), the error
  # section is the registry's text, and every in-page link resolves.
  use ExUnit.Case, async: true

  @doc_path "docs/language.md"

  setup_all do
    %{doc: File.read!(@doc_path)}
  end

  # {level, text} of every Markdown heading outside fenced code blocks
  defp headings(doc) do
    {hs, _} =
      doc
      |> String.split("\n")
      |> Enum.reduce({[], false}, fn line, {acc, fenced?} ->
        cond do
          String.starts_with?(line, "```") ->
            {acc, not fenced?}

          fenced? ->
            {acc, fenced?}

          m = Regex.run(~r/^(#+) (.*)$/, line) ->
            {[{String.length(Enum.at(m, 1)), Enum.at(m, 2)} | acc], fenced?}

          true ->
            {acc, fenced?}
        end
      end)

    Enum.reverse(hs)
  end

  # GitHub's anchor for a heading: lowercase, punctuation dropped, spaces to
  # hyphens, and -1, -2, ... appended to repeats
  defp anchors(doc) do
    {as, _} =
      doc
      |> headings()
      |> Enum.map_reduce(%{}, fn {_, text}, seen ->
        slug =
          text
          |> String.downcase()
          |> String.replace(~r/[^a-z0-9 _-]/u, "")
          |> String.replace(" ", "-")

        n = Map.get(seen, slug, 0)
        {if(n == 0, do: slug, else: "#{slug}-#{n}"), Map.put(seen, slug, n + 1)}
      end)

    as
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
