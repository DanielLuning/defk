defmodule Defk.StabilityCodesTest do
  # The compile error code ledger, test/stability/codes.txt: every code
  # released so far, active and retired. The stability promise
  # (docs/guides/stability.md): a code keeps its name, is never reused, and a
  # code whose construct became valid is retired and stays in the catalogue.
  # The ledger grows at release time and is never pruned, so a code the
  # registry adds before the next release is not in it yet. That no module
  # of lib/ raises a retired code is checked in test/compile_errors_test.exs
  # (the literal codes); here, the registry's check behind the compiler's
  # err!, which fails mix compile for a retired literal as for a typo.
  use ExUnit.Case, async: true

  @ledger "test/stability/codes.txt"

  # the lines of the ledger as `{code, retired version | nil}`, in file
  # order; # lines are comments, and a retired code's line is
  # `<code> retired <version>`
  defp ledger_lines do
    for line <- String.split(File.read!(@ledger), "\n", trim: true),
        not String.starts_with?(line, "#") do
      case String.split(line) do
        [code] ->
          {code, nil}

        [code, "retired", version] ->
          {code, version}

        _ ->
          flunk("#{@ledger}: a line is `<code>` or `<code> retired <version>`: #{inspect(line)}")
      end
    end
  end

  # the codes of the ledger, in file order
  defp ledger, do: Enum.map(ledger_lines(), &elem(&1, 0))

  defp retired, do: for(%{kind: :retired} = e <- Defk.Errors.entries(), do: e)

  test "every released code is in the registry, active or retired, and listed once" do
    ledger = ledger()
    assert "unsupported-map" in ledger
    assert ledger == Enum.uniq(ledger), "a code listed twice"

    assert ledger -- Enum.map(Defk.Errors.entries(), & &1.code) == [],
           "released codes gone from the registry: a code is retired, never removed"
  end

  # The other direction is open: a code added since the last release is in
  # the registry and not yet in the ledger. Only a released code can be
  # retired; an unreleased one whose construct became valid is removed. The
  # ledger's mark and the registry agree both ways, so a retired code stays
  # retired (reviving it in the registry fails here) and retiring one is a
  # ledger edit the owner reviews.
  test "a retired code is a released code, marked retired in the ledger, with its version" do
    marked =
      for {code, version} when version != nil <- ledger_lines(), into: %{}, do: {code, version}

    assert retired() != []

    for e <- retired() do
      assert marked[e.code] == e.retired.version,
             "#{e.code}: retired in #{e.retired.version} in the registry, " <>
               "in the ledger #{marked[e.code] || "not marked"}"
    end

    for {code, version} <- marked do
      assert Defk.Errors.fetch!(code).kind == :retired,
             "#{code}: marked retired #{version} in the ledger, but active in the registry"
    end
  end

  test "a retired entry keeps its summary and says the version and why, without an example" do
    for e <- retired() do
      assert is_binary(e.summary) and e.summary != "", e.code
      assert %{version: version, why: why} = e.retired
      assert version =~ ~r/^\d+\.\d+\.\d+$/, "#{e.code}: version #{inspect(version)}"
      assert is_binary(why) and why != "", "#{e.code}: why"
      refute Map.has_key?(e, :example), "#{e.code}: a retired code has no example to reject"
    end
  end

  test "a retired code is never raised: the compiler's code check rejects it" do
    for %{code: code} <- retired() do
      assert_raise ArgumentError, ~r/^retired defk error code "#{code}": retired in /, fn ->
        Defk.Errors.validate_code!(code)
      end
    end

    assert Defk.Errors.validate_code!("unsupported-map") == :ok

    assert_raise ArgumentError, ~r/^unknown defk error code/, fn ->
      Defk.Errors.validate_code!("no-such-code")
    end
  end

  test "explain!/1 prints a retired code as retired" do
    out = ExUnit.CaptureIO.capture_io(fn -> Defk.Errors.explain!("bitwise") end)
    assert out =~ "defk bitwise\n"
    assert out =~ Defk.Errors.fetch!("bitwise").summary
    assert out =~ "retired in 0.0.1: "
    refute out =~ "hint:"
  end
end
