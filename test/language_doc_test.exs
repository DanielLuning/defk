defmodule Defk.LanguageDocTest do
  # docs/language.md, the kernel subset reference: every in-page link resolves.
  # Its compile error section is a pointer to docs/compile-errors.md, which
  # test/compile_errors_doc_test.exs checks against the registry.
  use ExUnit.Case, async: true

  import Defk.LanguageDoc, only: [anchors: 1]

  @doc_path "docs/language.md"

  setup_all do
    %{doc: File.read!(@doc_path)}
  end

  test "every in-page link resolves", %{doc: doc} do
    anchors = MapSet.new(anchors(doc))

    for [_, a] <- Regex.scan(~r/\]\(#([^)]+)\)/, doc) do
      assert a in anchors, "broken link ##{a}"
    end
  end
end
