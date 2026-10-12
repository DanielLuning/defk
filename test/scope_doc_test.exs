defmodule Defk.ScopeDocTest do
  # docs/scope.md, the scope page: its two lists of compile errors are the
  # registry's text (Defk.Errors.scope/1), the hand-written "Not yet" list
  # names every planned code with a ticket, the hand-written "Won't be" list
  # names only codes outside the subset for good, and every link into
  # docs/compile-errors.md or docs/language.md resolves. Its example kernel runs in
  # test/language_doc_examples_test.exs.
  use ExUnit.Case, async: true

  @doc_path "docs/scope.md"
  @language_path "docs/language.md"
  @errors_path "docs/compile-errors.md"

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

  # the error codes linked in `text` (other links are sections of docs/language.md)
  defp codes_linked(text) do
    all = MapSet.new(Defk.Errors.codes(), & &1.code)
    for [_, a] <- Regex.scan(~r/\(compile-errors\.md#([a-z0-9-]+)\)/, text), a in all, do: a
  end

  defp codes(kind), do: for(%{kind: ^kind, code: code} <- Defk.Errors.codes(), do: code)

  # top-level bullets, each with its continuation lines
  defp bullets(text) do
    text
    |> String.split(~r/^- /m)
    |> Enum.drop(1)
    |> Enum.map(fn b -> b |> String.split(~r/\n\n/, parts: 2) |> hd() end)
  end

  # the generated list of a section: from the blank line after "Every compile
  # error the compiler marks ..." to the next blank line
  defp generated(doc, title) do
    [_, after_intro] =
      String.split(section(doc, title), "\nEvery compile error the compiler marks", parts: 2)

    [_, rest] = String.split(after_intro, "\n\n", parts: 2)
    [list | _] = String.split(rest, "\n\n", parts: 2)
    String.trim_trailing(list, "\n") <> "\n"
  end

  # the whole list, not just a match inside it: a stray line pasted with the
  # output (mix run's "Compiling N files (.ex)") fails here
  test "the generated lists are the registry's text and nothing else", %{doc: doc} do
    for {kind, title} <- [planned: "Not yet: planned", subset: "Won't be: by design"] do
      assert generated(doc, title) == Defk.Errors.scope(kind),
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

  test "every link into docs/language.md and docs/compile-errors.md resolves", %{doc: doc} do
    for {page, path} <- [{"language.md", @language_path}, {"compile-errors.md", @errors_path}] do
      anchors = MapSet.new(Defk.LanguageDoc.anchors(File.read!(path)))

      for [_, a] <- Regex.scan(~r/\]\(#{Regex.escape(page)}#([^)]+)\)/, doc) do
        assert a in anchors, "broken link #{page}##{a}"
      end
    end
  end
end
