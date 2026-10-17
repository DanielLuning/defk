defmodule Defk.Stability.Contracts do
  @moduledoc false
  # A release's contract, frozen: `mix defk.stability.freeze <version>` copies
  # test/contracts/ at the tag v<version> into test/stability/<version>/contracts/,
  # and from then on `mix test` runs the frozen contract tests against every
  # later commit, as it does the frozen data; `mix defk.contracts <version>`
  # runs one version's contract through Covenant (coverage, records). The
  # copy differs from the source in two ways, so it can live beside the live
  # contract and every other version's: each contract test module is renamed
  # under the version (`Defk.Contract.X` becomes `Defk.Contract.V0_2_0.X`), and
  # `use Covenant.Case` names the frozen contracts directory, so the tags are
  # checked against the frozen obligations. Dev tooling, compiled only in
  # :dev and :test; docs/agents/stability.md has the rules.

  @source "test/contracts"

  @doc "The frozen contract directory of `version`."
  def dir(version), do: Path.join(["test", "stability", version, "contracts"])

  @doc "The versions that have a frozen contract, sorted."
  def versions do
    "test/stability/*/contracts"
    |> Path.wildcard()
    |> Enum.filter(&File.dir?/1)
    |> Enum.map(&(&1 |> Path.dirname() |> Path.basename()))
    |> Enum.sort_by(&Version.parse!/1, Version)
  end

  @doc """
  The frozen copy of a contract: `files` are `{path, text}` relative to
  test/contracts/, the result the same relative to the version's directory.
  Covenant's coverage files are left out: they are output, not contract.
  """
  def freeze(files, version) do
    for {path, text} <- files, not coverage?(path) do
      if String.ends_with?(path, "_test.exs"),
        do: {path, freeze_test(text, version)},
        else: {path, text}
    end
  end

  defp coverage?(path), do: Path.basename(path) in ["coverage.json", "coverage.static.json"]

  @doc """
  A contract test frozen for `version`: its modules renamed under the
  version, `use Covenant.Case` pointed at the frozen contract, formatted.
  """
  def freeze_test(text, version) do
    module = "Defk.Contract.V" <> String.replace(version, ".", "_") <> "."

    renamed =
      Regex.replace(~r/^defmodule Defk\.Contract\./m, text, "defmodule #{module}")

    if renamed == text,
      do: raise(ArgumentError, "no `defmodule Defk.Contract.*` to rename in a contract test")

    pointed =
      Regex.replace(
        ~r/use Covenant\.Case,/,
        renamed,
        "use Covenant.Case, contracts: #{inspect(dir(version))},",
        global: false
      )

    if pointed == renamed,
      do: raise(ArgumentError, "no `use Covenant.Case,` in a contract test")

    IO.iodata_to_binary([Code.format_string!(pointed), "\n"])
  end

  @doc """
  The files of test/contracts/ at git revision `rev`, as `{path, text}`
  relative to it; `[]` when the revision has no contract.
  """
  def at(rev) do
    case System.cmd("git", ["ls-tree", "-r", "--name-only", rev, "--", @source],
           stderr_to_stdout: true
         ) do
      {out, 0} ->
        for path <- String.split(out, "\n", trim: true) do
          {text, 0} = System.cmd("git", ["show", "#{rev}:#{path}"])
          {Path.relative_to(path, @source), text}
        end

      {out, _} ->
        raise ArgumentError, "git ls-tree #{rev} failed:\n#{out}"
    end
  end

  @doc """
  Writes `version`'s frozen contract from git revision `rev` (the tag),
  afresh. Returns the number of files written; 0 when the revision has no
  contract (a release before contracts existed).
  """
  def write!(version, rev) do
    files = rev |> at() |> freeze(version)
    target = dir(version)
    File.rm_rf!(target)

    for {path, text} <- files do
      dest = Path.join(target, path)
      File.mkdir_p!(Path.dirname(dest))
      File.write!(dest, text)
    end

    length(files)
  end
end
