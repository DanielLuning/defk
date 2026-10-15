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

  # A frozen example a CHANGELOG-named bug fix changed: `{file, words}`, the
  # file relative to test/stability/ and words that the CHANGELOG entry
  # contains. The example then must keep failing (its recorded result or
  # acceptance is the old one), and the CHANGELOG must say why. An entry is
  # never removed, as the file is never edited; it is the only way a frozen
  # check may fail. Empty: no fix has changed a 0.1.0 result yet.
  @fixed []

  @root "test/stability"
  @files Path.wildcard(Path.join(@root, "*/kernels/*.md")) |> Enum.sort()
  for path <- @files, do: @external_resource(path)

  # {file relative to the root, examples}; a frozen file holds exactly one
  # (the per-file test says so when it does not)
  @examples for path <- @files,
                do: {Path.relative_to(path, @root), LanguageDoc.extract(File.read!(path))}

  @dir Path.join(System.tmp_dir!(), "defk_stability_kernels_test")

  # every frozen example's module, compiled concurrently: %{file => result}.
  # A module is named after its file's path and source, so an unchanged
  # example reuses its native build (the build cache keys on the C source)
  # and never shares a name with the live doc examples' modules
  setup_all do
    File.mkdir_p!(@dir)

    compiled =
      @examples
      |> Enum.flat_map(fn {file, exs} -> for ex <- exs, do: {file, named(file, ex)} end)
      |> Task.async_stream(fn {file, ex} -> {file, LanguageDoc.compile(ex, @dir)} end,
        timeout: :infinity,
        ordered: false
      )
      |> Map.new(fn {:ok, r} -> r end)

    %{compiled: compiled}
  end

  defp named(file, ex) do
    hash = :crypto.hash(:md5, file <> ex.source) |> Base.encode16(case: :lower)
    %{ex | module: "Defk.Stability.K#{binary_part(hash, 0, 12)}"}
  end

  defp frozen?(%{check: :run, known_failure: nil}), do: true
  defp frozen?(%{check: {:compiles, _}, known_failure: nil}), do: true
  defp frozen?(_), do: false

  for {file, exs} <- @examples do
    @path file
    @exs exs
    label =
      case exs do
        [ex] -> LanguageDoc.label(ex)
        _ -> "#{length(exs)} example(s)"
      end

    test "#{file} #{label}", %{compiled: compiled} do
      assert [ex] = @exs, "#{@path}: a frozen file holds one example, not #{length(@exs)}"
      ex = named(@path, ex)

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
    assert @examples != [], "no frozen kernels under #{@root}/*/kernels/"
  end

  test "every exception names a frozen file" do
    files = Enum.map(@examples, &elem(&1, 0))

    for {file, _} <- @fixed do
      assert file in files, "@fixed names #{file}, which is not a frozen file"
    end
  end
end
