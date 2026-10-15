defmodule Defk.StabilityKernelsTest do
  # The stability promise, checked mechanically: a valid kernel of a release
  # keeps compiling and keeps its meaning. test/stability/<version>/kernels/
  # holds every valid kernel the release shipped (`mix defk.stability.freeze
  # <version>` wrote them from the release's tag; docs/agents/stability.md has
  # the rules), one example per file in the Markdown form Defk.LanguageDoc
  # reads: a kernel followed by its documented `iex>` results, or a module
  # with a `compiles:` annotation. Each frozen kernel compiles natively and in
  # Elixir mode; each recorded step runs in both, the two must agree, and the
  # native result must be the recorded one. The frozen files are never edited:
  # a change that makes one fail is a broken promise, unless it is a bug fix
  # the CHANGELOG names, listed in @fixed.
  use ExUnit.Case, async: true

  alias Defk.LanguageDoc
  alias Defk.StabilityCorpus, as: Corpus

  # A frozen example a CHANGELOG-named bug fix changed: `{file, words}`, the
  # file relative to test/stability/ and words that the CHANGELOG entry
  # contains. The example then must keep failing (its recorded result or
  # acceptance is the old one), and the CHANGELOG must say why. An entry is
  # never removed, as the file is never edited; it is the only way a frozen
  # check may fail. Empty: no fix has changed a 0.1.0 result yet.
  @fixed []

  @examples Corpus.examples(:kernels)
  for path <- Corpus.files(:kernels), do: @external_resource(path)

  # every frozen example's module, compiled concurrently: %{file => result}
  setup_all do
    %{compiled: Corpus.compile_all(@examples, :kernels)}
  end

  defp frozen?(%{check: :run, known_failure: nil}), do: true
  defp frozen?(%{check: {:compiles, _}, known_failure: nil}), do: true
  defp frozen?(_), do: false

  for {file, exs} <- @examples do
    @path file
    @exs exs

    test "#{file} #{Corpus.label(exs)}", %{compiled: compiled} do
      assert [ex] = @exs, "#{@path}: a frozen file holds one example, not #{length(@exs)}"
      ex = Corpus.named(@path, ex, :kernels)

      assert frozen?(ex),
             "#{@path}: a frozen example runs or compiles, this one is #{inspect(ex.check)}"

      case List.keyfind(@fixed, @path, 0) do
        nil ->
          LanguageDoc.verify!(ex, Map.fetch!(compiled, @path))

        {_, words} ->
          assert File.read!("CHANGELOG.md") =~ words,
                 "#{@path}: no CHANGELOG entry contains #{inspect(words)}"

          assert_raise ExUnit.AssertionError, fn ->
            LanguageDoc.verify!(ex, Map.fetch!(compiled, @path))
          end
      end
    end
  end

  test "the corpus holds every release's kernels" do
    assert @examples != [], "no frozen kernels under test/stability/*/kernels/"
  end

  test "every exception names a frozen file" do
    assert Corpus.not_frozen(@fixed, @examples) == [], "@fixed names files that are not frozen"
  end
end
