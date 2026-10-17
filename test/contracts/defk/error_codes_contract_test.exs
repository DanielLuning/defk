defmodule Defk.Contract.ErrorCodesTest do
  # The contract tests of the compile error codes
  # (test/contracts/defk/error_codes.obligations.md), one surface of the stability
  # promise (docs/guides/stability.md). Each test names the obligations it
  # proves; Covenant fails the compile on an untagged test or an unknown id,
  # and `mix covenant.check` fails when an active obligation has no passing
  # test. The format of a compile error, its hints and collecting several
  # rejections are not promised and stay in test/compile_errors_test.exs.
  use Covenant.Case, component: "defk.error_codes", async: true

  import Defk.TestKit, only: [codes: 1, compile: 3, compiled: 3, whats: 1]

  alias Defk.StabilityCorpus, as: Corpus

  @ledger "test/stability/codes.txt"

  # The tests read the registry when they run, never into a module attribute
  # when this module compiles: mix covenant.mutate swaps Defk.Errors in memory
  # and does not compile the tests again, so a compile-time copy would check
  # the unmutated registry. Only the test names come from it.
  @active_codes for %{kind: kind, code: code} <- Defk.Errors.entries(), kind != :retired, do: code

  # codes raised by the build environment, not by a kernel, so no example;
  # test/build_test.exs covers them
  @no_example ["no-c-compiler"]

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

  @rejections Corpus.examples(:rejections)
  for path <- Corpus.files(:rejections), do: @external_resource(path)
  @external_resource @ledger

  # Compiled concurrently, as each is a module: the registry's examples and
  # rewrites (a distinct key each, so no two tasks compile one module), and
  # every frozen rejection. Cheap: a rejection stops before the C build.
  setup_all do
    registry =
      active()
      |> Enum.filter(&is_binary(&1.example))
      |> Task.async_stream(
        fn e ->
          {e.code, {compile(__MODULE__, e.example, key: {e.code, :example}), rewrite(e)}}
        end,
        timeout: :infinity,
        ordered: false
      )
      |> Map.new(fn {:ok, r} -> r end)

    %{registry: registry, frozen: Corpus.compile_all(@rejections, :rejections)}
  end

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

  defp ledger, do: Enum.map(ledger_lines(), &elem(&1, 0))

  # A rewrite compiles and defines a kernel: an empty rewrite would compile
  # too, and show the reader nothing to write instead.
  defp rewrite(e) do
    case compiled(__MODULE__, e.rewrite, key: {e.code, :rewrite}) do
      {:ok, mod} -> if mod.__defk_kernels__() == [], do: "it defines no kernel", else: :ok
      {:error, msg} -> msg
    end
  end

  # the codes the compiler raises; a retired code has no example
  defp active, do: for(%{kind: kind} = e <- Defk.Errors.entries(), kind != :retired, do: e)

  defp retired, do: for(%{kind: :retired} = e <- Defk.Errors.entries(), do: e)

  defp retired?(code), do: Enum.any?(retired(), &(&1.code == code))

  # permanent and planned in words
  defp assert_kind(:subset, what), do: assert(what =~ "not in the kernel subset")
  defp assert_kind(:planned, what), do: assert(what =~ "not supported yet")

  defp assert_kind(:error, what),
    do: refute(what =~ ~r/not in the kernel subset|not supported yet/)

  describe "I1: an active code rejects its own example" do
    for code <- @active_codes -- @no_example do
      @code code
      @tag obligation: "defk.error_codes.I1"
      test "#{code}: the example is rejected with it and the rewrite compiles", %{
        registry: registry
      } do
        %{kind: kind} = Defk.Errors.fetch!(@code)
        assert {msg, rewrite} = Map.get(registry, @code), "#{@code} has no example"
        assert is_binary(msg), "the example for #{@code} compiled"
        assert codes(msg) == [@code], msg
        # the public reader agrees with the test's own
        assert [%{code: @code, message: what}] = Defk.Errors.diagnostics(msg), msg
        assert [what] == whats(msg)
        assert_kind(kind, what)
        refute msg =~ ~r/defk-[a-z0-9]{3}/, "a ticket ID in #{msg}"
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

      assert ledger -- Enum.map(Defk.Errors.entries(), & &1.code) == [],
             "released codes gone from the registry: a code is retired, never removed"
    end
  end

  describe "I3: a code is never reused" do
    @tag obligation: "defk.error_codes.I3"
    test "codes are unique, with a kind, summary, why and hint" do
      codes = Enum.map(Defk.Errors.entries(), & &1.code)
      assert codes == Enum.uniq(codes)

      for e <- Defk.Errors.entries(), do: assert(e.kind in [:subset, :planned, :error, :retired])

      for e <- active(),
          k <- [:summary, :why, :hint],
          do: assert(is_binary(Map.fetch!(e, k)) and e[k] != "", "#{e.code} #{k}")
    end

    # Every code literal in lib/ is an active code of the registry (never a
    # retired one), and every active code is used somewhere in lib/. Not
    # errors.ex: it defines every code, so it would make the second half pass
    # for any code. Not test.ex: its strings are message fragments
    # ("non-finite"), not codes. err! checks its own literal codes when the
    # compiler compiles (Errors.validate_code!/1); the rewrites, clauses,
    # raise and diagnostics modules pass theirs as data.
    @tag obligation: "defk.error_codes.I3"
    test "every code literal in lib/ is an active registry code, and every active code is used" do
      src =
        (Path.wildcard("lib/**/*.ex") -- ["lib/defk/errors.ex", "lib/defk/test.ex"])
        |> Enum.map_join("\n", &File.read!/1)

      used =
        ~r/"([a-z0-9]+(?:-[a-z0-9]+)+|recursion|pipe)"[,)]/
        |> Regex.scan(src)
        |> MapSet.new(&Enum.at(&1, 1))

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

    @tag obligation: "defk.error_codes.I3"
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
  end

  describe "I4: a retired code stays in the catalogue" do
    @tag obligation: "defk.error_codes.I4"
    test "a retired entry keeps its summary and says the version and why, without an example" do
      for e <- retired() do
        assert is_binary(e.summary) and e.summary != "", e.code
        assert %{version: version, why: why} = e.retired
        assert version =~ ~r/^\d+\.\d+\.\d+$/, "#{e.code}: version #{inspect(version)}"
        assert is_binary(why) and why != "", "#{e.code}: why"
        refute Map.has_key?(e, :example), "#{e.code}: a retired code has no example to reject"
      end
    end

    @tag obligation: "defk.error_codes.I4"
    test "explain!/1 prints a retired code as retired" do
      out = ExUnit.CaptureIO.capture_io(fn -> Defk.Errors.explain!("bitwise") end)
      assert out =~ "defk bitwise\n"
      assert out =~ Defk.Errors.fetch!("bitwise").summary
      assert out =~ "retired in 0.0.1: "
      refute out =~ "hint:"
    end
  end

  # test/stability/<version>/rejections/ holds every rejected example a
  # release shipped (`mix defk.stability.freeze <version>` wrote them from the
  # release's tag; docs/agents/stability.md has the rules), one example per
  # file in the Markdown form Defk.LanguageDoc reads, annotated
  # `error: <code>`. Which error comes first is not promised.
  describe "I5: a frozen rejection keeps its code" do
    for {file, exs} <- @rejections do
      @path file
      @exs exs

      @tag obligation: "defk.error_codes.I5"
      test "#{file} #{Corpus.label(exs)}", %{frozen: frozen} do
        assert [ex] = @exs, "#{@path}: a frozen file holds one example, not #{length(@exs)}"

        assert {:error, code} = ex.check,
               "#{@path}: a frozen rejection is annotated error: <code>, this one is #{inspect(ex.check)}"

        case {Map.fetch!(frozen, @path), List.keyfind(@newly_supported, @path, 0)} do
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

    @tag obligation: "defk.error_codes.I5"
    test "the corpus holds every release's rejections" do
      assert @rejections != [], "no frozen rejections under test/stability/*/rejections/"
    end

    @tag obligation: "defk.error_codes.I5"
    test "every exception names a frozen file and its CHANGELOG entry" do
      assert Corpus.not_frozen(@newly_supported, @rejections) == [],
             "@newly_supported names files that are not frozen"

      changelog = File.read!("CHANGELOG.md")

      for {file, words} <- @newly_supported do
        assert changelog =~ words, "#{file}: no CHANGELOG entry contains #{inspect(words)}"
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
      assert out =~ Defk.Errors.fetch!("unsupported-map").summary
    end
  end
end
