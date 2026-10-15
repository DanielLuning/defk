defmodule Defk.DeprecationsTest.Legacy do
  @moduledoc false
  # the deprecated public function of the table's test entry: a
  # `@deprecated` `defdelegate`, as a real rename is made
  def new_name(x), do: x + 1

  @deprecated "Use new_name/1 instead"
  defdelegate old_name(x), to: __MODULE__, as: :new_name
end

defmodule Defk.DeprecationsTest do
  # The deprecation mechanism (Defk.Deprecations): an old name keeps working,
  # lowered as the new one, and warns once per use site with the use site's
  # location. Nothing real is deprecated: the entries under test come from
  # config/config.exs (defk's :test environment only), and each kind of name
  # the stability promise covers has one.
  #
  # Every entry of the table is compiled here: the maps below give each
  # builtin, option and config entry the source that exercises it, and a
  # test fails when an entry has none.
  use ExUnit.Case, async: false

  # not async: capture_io(:stderr) sees every test's warnings
  import ExUnit.CaptureIO
  import Defk.TestKit, only: [compiled: 3, i64s: 1]

  alias Defk.Deprecations

  @entries Deprecations.entries()

  # a kernel calling each deprecated builtin, at the arity of its entry
  @builtins %{
    {:legacy_length, 1} => "defk f(xs :: [i64]) :: i64, do: legacy_length(xs)"
  }

  # a value for each deprecated `use Defk` option
  @options %{legacy_cap: "4096"}

  # a value for each deprecated `config :defk` key
  @configs %{legacy_mode: :native}

  # the compiled module's source file, as the warning names it (TestKit
  # writes `defmodule` on line 1, `use Defk` on line 2 and the body from
  # line 4)
  defp location(out, line), do: Regex.scan(~r/M[0-9A-F]{12}\.ex:#{line}:/, out)

  # {warnings, result} of compiling `body`; `opts[:key]` tells apart modules
  # with one source (TestKit compiles a source once per VM)
  defp compile(body, opts \\ []) do
    {result, out} = with_io(:stderr, fn -> compiled(__MODULE__, body, opts) end)
    {out, result}
  end

  describe "the table" do
    test "has an entry of every kind the promise covers, each exercised here" do
      kinds = @entries |> Enum.map(& &1.kind) |> Enum.uniq() |> Enum.sort()
      assert kinds == [:builtin, :config, :function, :option]

      for %{kind: :builtin, old: old} <- @entries,
          do: assert(Map.has_key?(@builtins, old), "no kernel calls builtin #{inspect(old)}")

      for %{kind: :option, old: old} <- @entries,
          do: assert(Map.has_key?(@options, old), "no value for use Defk, #{old}:")

      for %{kind: :config, old: old} <- @entries,
          do: assert(Map.has_key?(@configs, old), "no value for config :defk, #{old}:")
    end

    test "every message names the old name, the version and the replacement" do
      for e <- @entries do
        msg = Deprecations.message(e)
        assert msg =~ "is deprecated since #{e.since}"
        assert msg =~ "use "
        assert msg =~ "until the next major version"
      end

      assert Deprecations.message(%{kind: :builtin, old: {:a, 1}, new: {:b, 1}, since: "9.0.0"}) ==
               "defk: builtin a/1 is deprecated since 9.0.0; use b/1 instead. " <>
                 "The old name keeps working until the next major version."
    end
  end

  describe "a deprecated builtin" do
    test "every entry compiles, lowered as its replacement in both backends, warning once" do
      for %{kind: :builtin, old: {old, arity} = key, new: {new, _}, since: since} <- @entries do
        {out, {:ok, _}} = compile(Map.fetch!(@builtins, key))

        assert out =~
                 "defk: builtin #{old}/#{arity} is deprecated since #{since}; use #{new}/#{arity} instead"

        assert [_] = location(out, 4)
        assert [_] = Regex.scan(~r/warning:/, out)
      end
    end

    test "is the new builtin natively and in Elixir mode" do
      {_, {:ok, mod}} = compile(Map.fetch!(@builtins, {:legacy_length, 1}), key: :result)

      assert mod.f(i64s([1, 2, 3])) == 3
      assert mod.__defk_elixir__(:f, [i64s([1, 2, 3])]) == 3
    end

    test "warns once per call site, each with its own line" do
      {out, {:ok, mod}} =
        compile("""
        defk f(xs :: [i64]) :: i64 do
          legacy_length(xs) +
            legacy_length(xs)
        end
        """)

      assert mod.f(i64s([1, 2])) == 4
      assert [_] = location(out, 5)
      assert [_] = location(out, 6)
      assert [_, _] = Regex.scan(~r/warning:/, out)
    end

    test "a kernel the module defines under the old name is called, without a warning" do
      {out, {:ok, mod}} =
        compile("""
        defk legacy_length(xs :: [i64]) :: i64, do: 42

        defk f(xs :: [i64]) :: i64, do: legacy_length(xs)
        """)

      assert out == ""
      assert mod.f(i64s([1, 2, 3])) == 42
    end
  end

  describe "a deprecated use Defk option" do
    test "every entry compiles as its replacement, warning at the use Defk line" do
      for %{kind: :option, old: old, new: new, since: since} <- @entries do
        {out, {:ok, _}} = compile("", use: "#{old}: #{Map.fetch!(@options, old)}")

        assert out =~ "defk: use Defk, #{old}: is deprecated since #{since}; use #{new}: instead"
        assert [_] = location(out, 2)
        assert [_] = Regex.scan(~r/warning:/, out)
      end
    end

    test "its value reaches the new option" do
      {_, {:ok, mod}} =
        compile("defk f(x :: i64) :: i64, do: x", use: "legacy_cap: 4096")

      assert mod.__defk_stats__().max_owned_bytes == 4096
    end
  end

  describe "a deprecated config key" do
    setup do
      on_exit(fn ->
        for key <- [:mode | Map.keys(@configs)], do: Application.delete_env(:defk, key)
      end)
    end

    test "every entry is read as its replacement, warning at the use Defk line" do
      for %{kind: :config, old: old, new: new, since: since} <- @entries do
        Application.put_env(:defk, old, Map.fetch!(@configs, old))
        {out, {:ok, _}} = compile("", key: {:config, old})

        assert out =~
                 "defk: config :defk, #{old}: is deprecated since #{since}; use #{new}: instead"

        assert [_] = location(out, 2)
        assert [_] = Regex.scan(~r/warning:/, out)
      end
    end

    test "its value is the mode's" do
      Application.put_env(:defk, :legacy_mode, :bogus)
      {out, {:error, msg}} = compile("", key: :bogus_mode)

      assert out =~ "config :defk, legacy_mode: is deprecated"
      assert msg =~ "unknown mode :bogus"
    end

    test "the new key wins over the old one" do
      Application.put_env(:defk, :legacy_mode, :bogus)
      Application.put_env(:defk, :mode, :native)
      {out, {:ok, _}} = compile("", key: :both_keys)

      assert out =~ "config :defk, legacy_mode: is deprecated"
    end

    test "without the old key there is no warning" do
      {out, {:ok, _}} = compile("", key: :no_old_key)

      assert out == ""
    end
  end

  describe "a deprecated public function" do
    test "every entry is a @deprecated delegate to its replacement, and Elixir warns at a call" do
      for %{kind: :function, old: {m, f, a}, new: {nm, nf, na}} <- @entries do
        assert function_exported?(nm, nf, na)
        assert {{^f, ^a}, reason} = List.keyfind(m.__info__(:deprecated), {f, a}, 0)
        assert reason =~ "#{nf}/#{na}"

        args = Enum.map_join(1..a//1, ", ", &"x#{&1}")

        src = """
        defmodule Defk.DeprecationsTest.Caller#{f} do
          def go(#{args}), do: #{inspect(m)}.#{f}(#{args})
        end
        """

        out = capture_io(:stderr, fn -> Code.compile_string(src, "caller_#{f}.ex") end)
        assert out =~ "#{inspect(m)}.#{f}/#{a} is deprecated. #{reason}"
        assert out =~ "caller_#{f}.ex:2"
      end
    end

    test "the delegate gives the replacement's result" do
      assert Defk.DeprecationsTest.Legacy.new_name(1) == 2
      assert Function.capture(Defk.DeprecationsTest.Legacy, :old_name, 1).(1) == 2
    end
  end
end
