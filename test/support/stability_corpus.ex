defmodule Defk.StabilityCorpus do
  @moduledoc false
  # The frozen files of test/stability/<version>/<kind>/ (`mix
  # defk.stability.freeze` writes them; docs/agents/stability.md has the
  # rules), read for the stability tests: test/contracts/defk/kernel_subset_contract_test.exs
  # (kind `:kernels`) and test/contracts/defk/error_codes_contract_test.exs (kind
  # `:rejections`). Each file is Markdown in the form Defk.LanguageDoc reads,
  # and holds one example.

  alias Defk.LanguageDoc
  alias Defk.LanguageDoc.Example

  @root "test/stability"

  @doc "The frozen files of a kind, every release, sorted."
  def files(kind), do: @root |> Path.join("*/#{kind}/*.md") |> Path.wildcard() |> Enum.sort()

  @doc """
  `{file relative to test/stability/, examples}` of every frozen file of a
  kind. A frozen file holds exactly one example; the per-file test says so
  when it does not.
  """
  def examples(kind) do
    for path <- files(kind),
        do: {Path.relative_to(path, @root), LanguageDoc.extract(File.read!(path))}
  end

  @doc """
  The example with its module named after its file's path and source, so an
  unchanged example reuses its native build (the build cache keys on the C
  source) and never shares a name with the live doc examples' modules.
  """
  def named(file, %Example{} = ex, kind) do
    hash = :crypto.hash(:md5, file <> ex.source) |> Base.encode16(case: :lower)
    %{ex | module: "Defk.Stability.#{prefix(kind)}#{binary_part(hash, 0, 12)}"}
  end

  defp prefix(:kernels), do: "K"
  defp prefix(:rejections), do: "R"

  @doc """
  Every example's module, compiled concurrently: `%{file => result}`, the
  result as `Defk.LanguageDoc.compile/2` gives it (`:ok` or the message).
  """
  def compile_all(examples, kind) do
    dir = Path.join(System.tmp_dir!(), "defk_stability_#{kind}_test")
    File.mkdir_p!(dir)

    examples
    |> Enum.flat_map(fn {file, exs} -> for ex <- exs, do: {file, named(file, ex, kind)} end)
    |> Task.async_stream(fn {file, ex} -> {file, LanguageDoc.compile(ex, dir)} end,
      timeout: :infinity,
      ordered: false
    )
    |> Map.new(fn {:ok, r} -> r end)
  end

  @doc "A test name for a frozen file: its one example's label, or how many it holds."
  def label([ex]), do: LanguageDoc.label(ex)
  def label(exs), do: "#{length(exs)} example(s)"

  @doc """
  The files an exception list (`{file, words}` entries) names that are not
  frozen files of `examples`.
  """
  def not_frozen(exceptions, examples) do
    files = Enum.map(examples, &elem(&1, 0))
    for {file, _} <- exceptions, file not in files, do: file
  end
end
