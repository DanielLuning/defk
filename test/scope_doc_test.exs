defmodule Defk.ScopeDocTest do
  # docs/scope.md, the scope page: its two lists of compile errors are the
  # registry's text (Defk.Errors.scope/1), the hand-written "Not yet" list
  # names every planned code (its tickets live in the tracker, not on this
  # user page), the hand-written "Won't be" list
  # names only codes outside the subset for good. Its links are checked in
  # test/docs_checks_test.exs, and its example kernel runs in
  # test/language_doc_examples_test.exs.
  use ExUnit.Case, async: true

  @doc_path "docs/scope.md"

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
    all = MapSet.new(Defk.Errors.entries(), & &1.code)
    for [_, a] <- Regex.scan(~r/\(compile-errors\.md#([a-z0-9-]+)\)/, text), a in all, do: a
  end

  defp codes(kind), do: for(%{kind: ^kind, code: code} <- Defk.Errors.entries(), do: code)

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

  test "\"Not yet\" names every planned code", %{doc: doc} do
    text = hand_written(doc, "Not yet: planned")
    assert Enum.sort(Enum.uniq(codes_linked(text))) == Enum.sort(codes(:planned))
  end

  test "\"Won't be\" names only codes outside the subset for good", %{doc: doc} do
    linked = codes_linked(hand_written(doc, "Won't be: by design"))
    assert linked != []
    assert linked -- codes(:subset) == []
  end
end
