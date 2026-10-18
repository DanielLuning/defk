defmodule Defk.Contract.ErrorCodesTest do
  # The contract tests of the compile error codes
  # (test/contracts/defk/error_codes.obligations.md), one surface of the
  # stability promise (docs/guides/stability.md). Each test names the
  # obligations it proves. Like every contract test it calls only defk's
  # public API and Defk.ContractKit, because a release freezes it and later
  # commits run it (test/contracts/README.md). The text of a compile error
  # is not promised and is tested in test/compile_errors_test.exs.
  use Covenant.Case, component: "defk.error_codes", async: true

  alias Defk.ContractKit, as: Kit

  # The tests read the registry when they run, never into a module attribute
  # when this module compiles: mix covenant.mutate swaps Defk.Errors in memory
  # and does not compile the tests again, so a compile-time copy would check
  # the unmutated registry. Only the test names come from it.
  @active_codes for %{kind: kind, code: code} <- Kit.registry(), kind != :retired, do: code

  # codes raised by the build environment, not by a kernel, so no example;
  # test/build_test.exs covers them
  @no_example ["no-c-compiler"]

  @rejections Kit.frozen(:rejections)
  for path <- Kit.frozen_paths(:rejections), do: @external_resource(path)
  @external_resource "test/stability/codes.txt"

  # Compiled concurrently, as each is a module: the registry's examples and
  # rewrites (a distinct key each, so no two tasks compile one module), and
  # every frozen rejection. Cheap: a rejection stops before the C build.
  setup_all do
    registry =
      active()
      |> Enum.filter(&is_binary(&1.example))
      |> Task.async_stream(
        fn e ->
          {e.code, {Kit.compile(__MODULE__, e.example, key: {e.code, :example}), rewrite(e)}}
        end,
        timeout: :infinity,
        ordered: false
      )
      |> Map.new(fn {:ok, r} -> r end)

    %{registry: registry, frozen: Kit.compile_frozen(@rejections, :rejections)}
  end

  # A rewrite compiles and defines a kernel: an empty rewrite would compile
  # too, and show the reader nothing to write instead.
  defp rewrite(e) do
    case Kit.compiled(__MODULE__, e.rewrite, key: {e.code, :rewrite}) do
      {:ok, mod} -> if kernels?(mod), do: :ok, else: "it defines no kernel"
      {:error, msg} -> msg
    end
  end

  # a kernel is a public function of the module other than defk's own
  defp kernels?(mod) do
    Enum.any?(mod.__info__(:functions), fn {name, _} -> not defk_function?(name) end)
  end

  defp defk_function?(name), do: String.starts_with?(Atom.to_string(name), "__")

  defp active, do: for(%{kind: kind} = e <- Kit.registry(), kind != :retired, do: e)
  defp retired, do: for(%{kind: :retired} = e <- Kit.registry(), do: e)
  defp retired?(code), do: Enum.any?(retired(), &(&1.code == code))
  defp ledger, do: Enum.map(Kit.ledger(), &elem(&1, 0))

  describe "I1: an active code rejects its own example" do
    for code <- @active_codes -- @no_example do
      @code code
      @tag obligation: "defk.error_codes.I1"
      test "#{code}: the example is rejected with it alone and the rewrite compiles", %{
        registry: registry
      } do
        assert {msg, rewrite} = Map.get(registry, @code), "#{@code} has no example"
        assert is_binary(msg), "the example for #{@code} compiled"
        assert Kit.codes(msg) == [@code], msg
        assert rewrite == :ok, "the rewrite for #{@code} does not compile:\n#{rewrite}"
      end
    end
  end

  describe "I2: a released code stays in the registry" do
    @tag obligation: "defk.error_codes.I2"
    test "every released code is in the registry, active or retired, and listed once" do
      ledger = ledger()
      assert "unsupported-map" in ledger
      assert ledger == Enum.uniq(ledger), "a code listed twice"

      assert ledger -- Enum.map(Kit.registry(), & &1.code) == [],
             "released codes gone from the registry: a code is retired, never removed"
    end
  end

  describe "I3: a code is never reused" do
    @tag obligation: "defk.error_codes.I3"
    test "the registry lists each code once, with a known kind" do
      codes = Enum.map(Kit.registry(), & &1.code)
      assert codes == Enum.uniq(codes)
      for e <- Kit.registry(), do: assert(e.kind in [:subset, :planned, :error, :retired])
    end

    @tag obligation: "defk.error_codes.I3"
    test "the compiler names only active codes, and every active code" do
      used = Kit.raised_codes()
      registry = MapSet.new(active(), & &1.code)
      retired = MapSet.new(retired(), & &1.code)

      assert MapSet.intersection(used, retired) == MapSet.new(), "retired codes a module names"
      assert MapSet.difference(used, registry) == MapSet.new(), "codes not in the registry"
      assert MapSet.difference(registry, used) == MapSet.new(), "registry codes no module uses"
    end

    # Only a released code can be retired; an unreleased one whose construct
    # became valid is removed. The ledger's mark and the registry agree both
    # ways, so a retired code stays retired (reviving it in the registry
    # fails here) and retiring one is a ledger edit the owner reviews.
    @tag obligation: "defk.error_codes.I3"
    test "a retired code is a released code, marked retired in the ledger, with its version" do
      marked =
        for {code, version} when version != nil <- Kit.ledger(), into: %{}, do: {code, version}

      assert retired() != []

      for e <- retired() do
        assert marked[e.code] == e.retired,
               "#{e.code}: retired in #{e.retired} in the registry, " <>
                 "in the ledger #{marked[e.code] || "not marked"}"
      end

      registry = Map.new(Kit.registry(), &{&1.code, &1.kind})

      for {code, version} <- marked do
        assert registry[code] == :retired,
               "#{code}: marked retired #{version} in the ledger, but active in the registry"
      end
    end
  end

  describe "I4: a retired code stays in the catalogue" do
    @tag obligation: "defk.error_codes.I4"
    test "a retired code says the version that retired it, and has no example" do
      for e <- retired() do
        assert e.retired =~ ~r/^\d+\.\d+\.\d+$/, "#{e.code}: version #{inspect(e.retired)}"
        assert e.example == nil, "#{e.code}: a retired code has no example to reject"
      end
    end

    @tag obligation: "defk.error_codes.I4"
    test "explain!/1 prints a retired code as retired, with its version" do
      for e <- retired() do
        out = ExUnit.CaptureIO.capture_io(fn -> Defk.Errors.explain!(e.code) end)
        assert out =~ "defk #{e.code}\n"
        assert out =~ "retired in #{e.retired}: "
      end
    end
  end

  # test/stability/<version>/rejections/ holds every rejected example a
  # release shipped (`mix defk.stability.freeze <version>` wrote them from the
  # release's tag; docs/agents/stability.md has the rules), one example per
  # file, annotated `error: <code>`. Which error comes first is not promised.
  describe "I5: a frozen rejection keeps its code" do
    for {file, exs} <- @rejections do
      @path file
      @exs exs

      @tag obligation: "defk.error_codes.I5"
      test "#{file} #{Kit.label(exs)}", %{frozen: frozen} do
        assert [ex] = @exs, "#{@path}: a frozen file holds one example, not #{length(@exs)}"

        assert {:error, code} = ex.check,
               "#{@path}: a frozen rejection is annotated error: <code>, this one is #{inspect(ex.check)}"

        case {Map.fetch!(frozen, @path), Kit.exception(:newly_supported, @path)} do
          {:ok, nil} ->
            assert retired?(code),
                   "#{@path}: compiles now, and #{code} is an active code: retire the code in the registry, or list the file under newly_supported in test/stability/exceptions.exs"

          {:ok, words} ->
            assert Kit.changelog?(words),
                   "#{@path}: no CHANGELOG entry contains #{inspect(words)}"

          {msg, nil} ->
            assert code in Kit.codes(msg),
                   "#{@path}: rejected with #{inspect(Kit.codes(msg))}, not #{code}:\n#{msg}"

          {msg, _} ->
            flunk("#{@path}: listed under newly_supported, but still rejected:\n#{msg}")
        end
      end
    end

    @tag obligation: "defk.error_codes.I5"
    test "the corpus holds every release's rejections" do
      assert @rejections != [], "no frozen rejections under test/stability/*/rejections/"
    end

    @tag obligation: "defk.error_codes.I5"
    test "every exception names a frozen file and its CHANGELOG entry" do
      newly = Kit.exceptions(:newly_supported)

      assert Kit.not_frozen(newly, @rejections) == [],
             "newly_supported names files that are not frozen"

      for {file, words} <- newly do
        assert Kit.changelog?(words), "#{file}: no CHANGELOG entry contains #{inspect(words)}"
      end
    end
  end

  describe "I6: explain!/1 refuses an unknown code" do
    @tag obligation: "defk.error_codes.I6"
    test "an unknown code raises, a known one prints its entry" do
      assert_raise ArgumentError, ~s(unknown defk error code "no-such-code"), fn ->
        Defk.Errors.explain!("no-such-code")
      end

      out = ExUnit.CaptureIO.capture_io(fn -> Defk.Errors.explain!("unsupported-map") end)
      assert out =~ "defk unsupported-map\n"
    end
  end
end
