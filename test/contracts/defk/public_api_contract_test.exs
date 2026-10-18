defmodule Defk.Contract.PublicApiTest do
  # The public API (test/contracts/defk/public_api.obligations.md): every
  # release's promised surface, frozen as data in
  # test/stability/<version>/api.exs, checked against the code. Containment
  # only: an addition is not listed in a snapshot, so it passes; a removal, a
  # rename or an arity change fails. The fix for a failure is a deprecation
  # (stability.md, "How a change is made"), not an edit of the snapshot. Like
  # every contract test it calls only defk's public API and Defk.ContractKit
  # (test/contracts/README.md).
  #
  # async: false: the config and env var checks set process-global state
  # (the application env, the system env) while a module compiles.
  use Covenant.Case, component: "defk.public_api", async: false

  import ExUnit.CaptureIO

  alias Defk.ContractKit, as: Kit

  for path <- Kit.api_paths(), do: @external_resource(path)

  for api <- Kit.api_snapshots() do
    @api api

    describe "the public API of #{api.version}" do
      @tag obligation: "defk.public_api.I1"
      test "every promised macro and function exists, is exported and documented, with its arity" do
        broken =
          for {mod, items} <- @api.modules,
              {kind, name, arity} <- items,
              reason = broken(mod, kind, name, arity),
              do: "#{inspect(mod)}.#{name}/#{arity} (#{kind}): #{reason}"

        assert broken == [],
               Enum.join(
                 [
                   "promised by docs/guides/stability.md since #{@api.version}; a removal or rename needs a deprecation first:"
                   | broken
                 ],
                 "\n  "
               )
      end

      @tag obligation: "defk.public_api.I2"
      test "a kernel module gets the generated functions and the kernel's function with its @spec" do
        {mod, beam} = compile_kernel_module("K#{version_tag(@api)}", "use Defk")

        for {kind, name, arity} <- @api.generated do
          assert kind == :function and function_exported?(mod, name, arity),
                 "use Defk no longer generates #{name}/#{arity}"
        end

        # in :test Elixir mode is always compiled, so __defk_elixir__/2 exists
        assert mod.__defk_elixir__(:twice, [4]) == 8
        mod.__defk_force_yields__(true)
        assert mod.twice(4) == 8
        mod.__defk_force_yields__(false)

        for check <- @api.kernel_function, do: assert_kernel_function(check, mod, beam, :twice, 1)
      end

      @tag obligation: "defk.public_api.I3"
      test "a kernel module accepts and honours each `use Defk` option" do
        for {option, value} <- @api.use_defk_options do
          {mod, _} =
            compile_kernel_module(
              "Option#{version_tag(@api)}.#{Macro.camelize("#{option}")}",
              "use Defk, #{option}: #{inspect(value)}"
            )

          assert mod.twice(4) == 8
          assert_option_honoured(option, value, mod)
        end
      end

      @tag obligation: "defk.public_api.I4"
      test "a kernel accepts each kernel option" do
        for {option, value} <- @api.kernel_options do
          {mod, _} =
            compile_kernel_module(
              "KernelOption#{version_tag(@api)}.#{Macro.camelize("#{option}")}",
              "use Defk",
              twice: "#{option}: #{inspect(value)}"
            )

          assert mod.twice(4) == 8
        end
      end

      @tag obligation: "defk.public_api.I5"
      test "config :defk, mode: accepts each value, and it picks the call path" do
        for {app, key, values} <- @api.config, value <- values do
          Application.put_env(app, key, value)

          {mod, _} =
            try do
              compile_kernel_module(
                "Configured#{version_tag(@api)}.#{Macro.camelize("#{value}")}",
                "use Defk",
                twice: :inspect
              )
            after
              Application.delete_env(app, key)
            end

          # IO.inspect in a kernel prints in Elixir mode only
          expected = if value == :elixir, do: "8\n", else: ""
          assert capture_io(fn -> assert mod.twice(4) == 8 end) == expected
        end
      end

      @tag obligation: "defk.public_api.I6"
      test "the build reads each environment variable" do
        for name <- @api.env, do: assert_env_read(name)
      end
    end
  end

  # a module name part per snapshot, so two versions never compile one module
  defp version_tag(api), do: "V" <> String.replace(api.version, ".", "_")

  # nil when the macro or function is exported and documented at that arity,
  # else why not
  defp broken(mod, kind, name, arity) do
    Code.ensure_loaded!(mod)

    cond do
      not exported?(mod, kind, name, arity) -> "missing, or another arity"
      not documented?(mod, kind, name, arity) -> "hidden (@doc false) or undocumented"
      true -> nil
    end
  end

  defp exported?(mod, :macro, name, arity), do: macro_exported?(mod, name, arity)
  defp exported?(mod, :function, name, arity), do: function_exported?(mod, name, arity)

  # Elixir hides underscore names such as `__using__` from the docs; `use Defk`
  # is documented in the Defk moduledoc
  defp documented?(_mod, :macro, :__using__, 1), do: true

  # a doc entry covers the arities its defaults make callable
  defp documented?(mod, kind, name, arity) do
    {:docs_v1, _, _, _, _, _, docs} = Code.fetch_docs(mod)

    Enum.any?(docs, fn
      {{^kind, ^name, max}, _, _, doc, meta} ->
        max - Map.get(meta, :defaults, 0) <= arity and arity <= max and is_map(doc)

      _ ->
        false
    end)
  end

  defp assert_kernel_function(:exported, mod, _beam, name, arity) do
    assert function_exported?(mod, name, arity), "the kernel #{name}/#{arity} has no function"
  end

  # the beam binary: a module compiled in memory has no file to read specs from
  defp assert_kernel_function(:spec, _mod, beam, name, arity) do
    {:ok, specs} = Code.Typespec.fetch_specs(beam)
    assert List.keymember?(specs, {name, arity}, 0), "the kernel #{name}/#{arity} has no @spec"
  end

  # in :test Elixir mode is compiled in every module, so the option can only
  # be seen to be accepted here; its effect outside :test is the
  # elixir_mode tests' concern
  defp assert_option_honoured(:elixir_mode, true, mod) do
    assert mod.__defk_elixir__(:twice, [4]) == 8
  end

  # the report has a vectorisation line per loop whatever CC is
  defp assert_option_honoured(:report, :full, mod) do
    assert Defk.Report.format(mod) =~ "vectorised"
  end

  # fill/1 allocates 8 bytes per element: a count past the budget raises
  defp assert_option_honoured(:max_owned_bytes, bytes, mod) do
    assert mod.fill(1) == 0
    assert_raise ArgumentError, ~r/max_owned_bytes/, fn -> mod.fill(bytes) end
  end

  # reading the build's two lookups costs no C build, where a build with a
  # bad CC or ERTS_INCLUDE_DIR would
  defp assert_env_read("CC") do
    with_env("CC", "stability-cc", fn ->
      assert Kit.build_env().cc == {"stability-cc", []}
    end)
  end

  defp assert_env_read("ERTS_INCLUDE_DIR") do
    dir = "/stability/erts/include"
    with_env("ERTS_INCLUDE_DIR", dir, fn -> assert Kit.build_env().erts_include == dir end)
  end

  defp with_env(name, value, fun) do
    original = System.get_env(name)
    System.put_env(name, value)

    try do
      fun.()
    after
      if original, do: System.put_env(name, original), else: System.delete_env(name)
    end
  end

  # A kernel module with a stable name, `twice/1` and `fill/1` (n i64s on the
  # owned budget, and a loop for the report). `twice:` is the kernel's
  # options (a string) or :inspect (a body that prints in Elixir mode).
  defp compile_kernel_module(name, use_line, opts \\ []) do
    mod = Module.concat(__MODULE__, name)

    {twice_opts, body} =
      case Keyword.get(opts, :twice, "") do
        :inspect -> {"", "IO.inspect(x * 2)"}
        "" -> {"", "x * 2"}
        kernel_opts -> {", " <> kernel_opts, "x * 2"}
      end

    source = """
    defmodule #{inspect(mod)} do
      #{use_line}

      defk twice(x :: i64) :: i64#{twice_opts} do
        #{body}
      end

      defk fill(n :: i64) :: i64 do
        a = alloc(i64, n)

        for i <- 0..(n - 1)//1, reduce: 0 do
          acc ->
            a[i] = i
            acc + a[i]
        end
      end
    end
    """

    # mix test compiles without debug info, which the @spec check reads
    debug_info = Code.get_compiler_option(:debug_info)
    Code.put_compiler_option(:debug_info, true)

    try do
      [{^mod, beam}] = Code.compile_string(source)
      {mod, beam}
    after
      Code.put_compiler_option(:debug_info, debug_info)
    end
  end
end
