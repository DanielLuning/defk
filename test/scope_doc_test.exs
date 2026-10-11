defmodule Defk.ScopeDocTest do
  # docs/scope.md, the scope page: its two lists of compile errors are the
  # registry's text (Defk.Errors.scope/1), the hand-written "Not yet" list
  # names every planned code with a ticket, the hand-written "Won't be" list
  # names only codes outside the subset for good, and every link into
  # docs/language.md resolves. Its example kernel runs in
  # test/language_doc_examples_test.exs.
  use ExUnit.Case, async: true

  @doc_path "docs/scope.md"
  @language_path "docs/language.md"

  setup_all do
    %{doc: File.read!(@doc_path)}
  end

  # the text of the `## <title>` section, up to the next ## heading
  defp section(doc, title) do
    [_, rest] = String.split(doc, "\n## #{title}\n", parts: 2)
    [text | _] = String.split(rest, ~r/^## /m, parts: 2)
    text
  end

  # the section's hand-written part: everything before its generated list
  defp hand_written(doc, title) do
    [text, _] =
      String.split(section(doc, title), "\nEvery compile error the compiler marks", parts: 2)

    text
  end

  # the error codes linked in `text` (other links into docs/language.md are sections)
  defp codes_linked(text) do
    all = MapSet.new(Defk.Errors.codes(), & &1.code)
    for [_, a] <- Regex.scan(~r/\(language\.md#([a-z0-9-]+)\)/, text), a in all, do: a
  end

  defp codes(kind), do: for(%{kind: ^kind, code: code} <- Defk.Errors.codes(), do: code)

  # top-level bullets, each with its continuation lines
  defp bullets(text) do
    text
    |> String.split(~r/^- /m)
    |> Enum.drop(1)
    |> Enum.map(fn b -> b |> String.split(~r/\n\n/, parts: 2) |> hd() end)
  end

  test "the generated lists are the registry's text", %{doc: doc} do
    for kind <- [:planned, :subset] do
      assert String.contains?(doc, Defk.Errors.scope(kind)),
             "regenerate with: mix run -e 'IO.write(Defk.Errors.scope(#{inspect(kind)}))'"
    end
  end

  test "\"Not yet\" names every planned code, and each planned item its ticket", %{doc: doc} do
    text = hand_written(doc, "Not yet: planned")
    assert Enum.sort(Enum.uniq(codes_linked(text))) == Enum.sort(codes(:planned))

    [planned | _] = String.split(text, "\nUnder exploration", parts: 2)

    for b <- bullets(planned) do
      assert b =~ ~r/\(defk-[a-z0-9]+(\.\d+)?[,)]/, "no ticket in: - #{b}"
    end
  end

  test "\"Won't be\" names only codes outside the subset for good", %{doc: doc} do
    linked = codes_linked(hand_written(doc, "Won't be: by design"))
    assert linked != []
    assert linked -- codes(:subset) == []
  end

  test "every link into docs/language.md resolves", %{doc: doc} do
    anchors = MapSet.new(Defk.LanguageDoc.anchors(File.read!(@language_path)))

    for [_, a] <- Regex.scan(~r/\]\(language\.md#([^)]+)\)/, doc) do
      assert a in anchors, "broken link language.md##{a}"
    end
  end
end
