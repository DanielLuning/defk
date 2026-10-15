defmodule Defk.StabilityRejectionsTest do
  # The stability promise, checked mechanically: a construct rejected with a
  # code is rejected with the same code, and a code whose construct becomes
  # valid is retired, never reused. test/stability/<version>/rejections/
  # holds every rejected example a release shipped (`mix
  # defk.stability.freeze <version>` wrote them from the release's tag:
  # the registry's examples and the doc pages' rejected examples;
  # docs/agents/stability.md has the rules), one example per file in the
  # Markdown form Defk.LanguageDoc reads, annotated `error: <code>`. Each is
  # compiled and must still fail with the recorded code among its errors
  # (which error comes first is not promised), or compile now because the
  # construct became valid: then its code is retired in the registry, or the
  # file is listed in @newly_supported with its CHANGELOG entry. Anything
  # else is a broken promise.
  use ExUnit.Case, async: true

  import Defk.TestKit, only: [codes: 1]

  alias Defk.StabilityCorpus, as: Corpus

  # A frozen rejection that compiles now because a minor release made the
  # construct valid while its code stays active for other constructs (a code
  # that covers nothing else is retired instead, in the registry):
  # `{file, words}`, the file relative to test/stability/ and words that the
  # CHANGELOG entry contains. The example then must compile. An entry is
  # never removed, as the file is never edited.
  @newly_supported [
    # Enum.reduce/3 became a kernel form; enum-reduce still rejects Enum.reduce/2
    {"0.1.0/rejections/lib-defk-errors-enum-reduce.md", "Added: `Enum.reduce/3` in kernels"},
    # a raise message may interpolate integers; raise-message still rejects other values
    {"0.1.0/rejections/lib-defk-errors-raise-message.md",
     "a kernel's `raise` message may interpolate integer values"}
  ]

  @examples Corpus.examples(:rejections)
  for path <- Corpus.files(:rejections), do: @external_resource(path)

  # every frozen example's module, compiled concurrently: %{file => result}.
  # Cheap: a rejection stops before the C build
  setup_all do
    %{compiled: Corpus.compile_all(@examples, :rejections)}
  end

  defp retired?(code) do
    match?(%{kind: :retired}, Enum.find(Defk.Errors.entries(), &(&1.code == code)))
  end

  for {file, exs} <- @examples do
    @path file
    @exs exs

    test "#{file} #{Corpus.label(exs)}", %{compiled: compiled} do
      assert [ex] = @exs, "#{@path}: a frozen file holds one example, not #{length(@exs)}"

      assert {:error, code} = ex.check,
             "#{@path}: a frozen rejection is annotated error: <code>, this one is #{inspect(ex.check)}"

      case {Map.fetch!(compiled, @path), List.keyfind(@newly_supported, @path, 0)} do
        {:ok, nil} ->
          assert retired?(code),
                 "#{@path}: compiles now, and #{code} is an active code: retire the code in the registry, or list the file in @newly_supported with its CHANGELOG entry"

        {:ok, {_, words}} ->
          assert File.read!("CHANGELOG.md") =~ words,
                 "#{@path}: no CHANGELOG entry contains #{inspect(words)}"

        {msg, nil} ->
          assert code in codes(msg),
                 "#{@path}: rejected with #{inspect(codes(msg))}, not #{code}:\n#{msg}"

        {msg, {_, _}} ->
          flunk("#{@path}: listed in @newly_supported, but still rejected:\n#{msg}")
      end
    end
  end

  test "the corpus holds every release's rejections" do
    assert @examples != [], "no frozen rejections under test/stability/*/rejections/"
  end

  test "every exception names a frozen file and its CHANGELOG entry" do
    assert Corpus.not_frozen(@newly_supported, @examples) == [],
           "@newly_supported names files that are not frozen"

    changelog = File.read!("CHANGELOG.md")

    for {file, words} <- @newly_supported do
      assert changelog =~ words, "#{file}: no CHANGELOG entry contains #{inspect(words)}"
    end
  end
end
