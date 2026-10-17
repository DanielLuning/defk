defmodule Defk.StabilityContractsTest do
  # Freezing a release's contract (Defk.Stability.Contracts, used by `mix
  # defk.stability.freeze`): the live contract, frozen for a made-up version,
  # keeps every file but Covenant's coverage, renames each contract test
  # module under the version and points it at the frozen obligations.
  # Whether a frozen contract then holds against later code is what `mix
  # test` checks on the real frozen directories.
  use ExUnit.Case, async: true

  alias Defk.Stability.Contracts

  defp live do
    for path <- Path.wildcard("test/contracts/**/*", match_dot: false),
        File.regular?(path),
        do: {Path.relative_to(path, "test/contracts"), File.read!(path)}
  end

  test "the frozen copy keeps every contract file but the coverage output" do
    frozen = Contracts.freeze(live(), "9.8.7")
    paths = Enum.map(frozen, &elem(&1, 0))

    assert "defk/error_codes.obligations.md" in paths
    assert "system/decisions.yml" in paths
    refute "coverage.json" in paths
    assert length(paths) == length(live()) - Enum.count(live(), &(elem(&1, 0) == "coverage.json"))
  end

  test "a frozen contract test is renamed under the version and reads the frozen obligations" do
    for {path, text} <- Contracts.freeze(live(), "9.8.7"), String.ends_with?(path, "_test.exs") do
      assert text =~ ~r/^defmodule Defk\.Contract\.V9_8_7\./m, path
      refute text =~ ~r/^defmodule Defk\.Contract\.[A-Z][A-Za-z]*Test do/m, path
      assert text =~ ~s(contracts: "test/stability/9.8.7/contracts"), path
      assert Code.format_string!(text) |> IO.iodata_to_binary() |> Kernel.<>("\n") == text, path
    end
  end

  test "obligations, records and prose are copied as they are" do
    frozen = Map.new(Contracts.freeze(live(), "9.8.7"))

    for {path, text} <- live(),
        not String.ends_with?(path, "_test.exs"),
        path != "coverage.json" do
      assert frozen[path] == text, path
    end
  end

  test "a file that is not a contract test is refused as one" do
    assert_raise ArgumentError, ~r/no `defmodule Defk.Contract/, fn ->
      Contracts.freeze_test("defmodule Other do\nend\n", "1.0.0")
    end
  end

  test "a version without a frozen contract is not listed" do
    refute "0.1.0" in Contracts.versions()
  end
end
