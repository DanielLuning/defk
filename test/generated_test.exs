defmodule Defk.GeneratedTest do
  # The generated module (Defk.Generated.defs/1): the loader for each
  # placement, the @on_load chain, the stubs, the wrappers and the Elixir
  # mode dispatch, asserted on the quoted code. No C compiler, no real
  # kernel module: the data a compile produces is given by hand. The
  # loaded shapes stay covered end to end (build_test, sanitize_test,
  # release_layout_test, impl_test).
  use ExUnit.Case, async: true

  alias Defk.Generated

  @sig %{
    name: :scale,
    params: [{:xs, {:arr, :f64}}, {:k, :f64}],
    ret: {:arr, :f64},
    yields: false
  }

  defp defs(overrides) do
    Generated.defs(
      Keyword.merge(
        [
          placement: :none,
          sigs: [@sig],
          elixir?: false,
          mode: :native,
          bits: MapSet.new(),
          on_load: nil,
          fault_hooks?: false,
          c_src: "/* c */",
          report: [],
          attrs: %{},
          elixir_mode: []
        ],
        overrides
      )
    )
  end

  defp text(overrides), do: overrides |> defs() |> Macro.to_string()

  # `def name(args) do body end`, as Macro.to_string prints it
  defp fun(head, body), do: ~r/def #{Regex.escape(head)} do\s+#{Regex.escape(body)}\s+end/

  describe "the loader" do
    test "no library: the module loads and has no library path" do
      t = text(placement: :none)
      assert t =~ fun("__defk_load_nif__", ":ok")
      assert t =~ fun("__defk_lib__", "nil")
    end

    test "a path: load_nif with the absolute base, the .so beside it" do
      t = text(placement: {:path, "/abs/build/defk_mod"})
      assert t =~ fun("__defk_load_nif__", ~S|:erlang.load_nif(~c"/abs/build/defk_mod", 0)|)
      assert t =~ fun("__defk_lib__", ~S("/abs/build/defk_mod.so"))
    end

    test "an app: beside the app's beams at load time, else the fallback" do
      t = text(placement: {:app, :my_app, "defk_mod.so", "/abs/fallback/defk_mod.so"})
      assert t =~ ~S|:code.lib_dir(:my_app)|
      assert t =~ ~S|:filename.join(dir, ~c"ebin/defk_mod")|
      assert t =~ ~S|_ -> ~c"/abs/fallback/defk_mod"|
      assert t =~ ~S|@external_resource "/abs/fallback/defk_mod.so"|
      assert t =~ fun("__defk_load_nif__", ":erlang.load_nif(__defk_lib_base__(), 0)")
    end
  end

  describe "@on_load" do
    test "defk's own hook loads the NIF" do
      t = text(on_load: nil)
      assert t =~ "@on_load :__defk_load__"
      assert t =~ fun("__defk_load__", "__defk_load_nif__()")
    end

    test "the module's own hook runs after the NIF loaded, and only then" do
      t = text(on_load: :warm_up)
      assert t =~ ~r/case __defk_load_nif__\(\) do\s+:ok -> warm_up\(\)\s+other -> other\s+end/
    end
  end

  describe "a kernel's function" do
    test "a plain kernel is its own NIF: a spec and a stub that raises until loaded" do
      t = text([])
      assert t =~ "@spec scale(binary(), number()) :: binary()"
      assert t =~ fun("scale(_xs, _k)", ":erlang.nif_error(:defk_not_loaded)")
      refute t =~ "__defk_native_scale__"
    end

    test "a yielding kernel: the NIF is renamed and takes the run-queue hint" do
      t = text(sigs: [%{@sig | yields: true}])

      assert t =~
               fun(
                 "__defk_native_scale__(_xs, _k, _waiting)",
                 ":erlang.nif_error(:defk_not_loaded)"
               )

      assert t =~
               fun(
                 "scale(xs, k)",
                 "__defk_native_scale__(xs, k, :erlang.statistics(:total_run_queue_lengths))"
               )
    end

    test "a bitstring result is decoded from the NIF's {bytes, bit_length}" do
      sig = %{name: :pack, params: [{:xs, {:arr, :u8}}], ret: :bitstring, yields: false}
      t = text(sigs: [sig], bits: MapSet.new([:pack]))
      assert t =~ fun("__defk_native_pack__(_xs)", ":erlang.nif_error(:defk_not_loaded)")
      assert t =~ "@spec pack(binary()) :: bitstring()"
      assert t =~ ~r/def pack\(xs\) do\s+.*__defk_native_pack__\(xs\)/s
      assert t =~ "bitstring"
    end

    test "with Elixir mode: every kernel dispatches on the process's mode" do
      t = text(elixir?: true, mode: :native)
      assert t =~ fun("__defk_native_scale__(_xs, _k)", ":erlang.nif_error(:defk_not_loaded)")
      assert t =~ "Process.get(#{inspect(Defk.ElixirMode.process_mode_key())}, :native)"
      assert t =~ ~r/:elixir ->\s+__defk_elixir__\(:scale, \[xs, k\]\)/
      assert t =~ ~r/_ ->\s+__defk_native_scale__\(xs, k\)/
    end

    test "a leading underscore in a parameter name is dropped in the wrapper" do
      sig = %{@sig | params: [{:_xs, {:arr, :f64}}, {:k, :f64}], yields: true}
      t = text(sigs: [sig])
      assert t =~ "def scale(xs, k) do"
    end

    test "the @doc and @impl a kernel had go before its def, not the stubs" do
      t = text(attrs: %{{:scale, 2} => %{doc: {3, "Scales."}, impl: true}})

      assert t =~
               ~r/Module\.put_attribute\(__MODULE__, :doc, \{3, "Scales\."\}\)\s+@impl true\s+def scale\(_xs, _k\)/
    end
  end

  describe "the module's own hooks" do
    test "the C source, the report and the kernels are kept as functions" do
      t = text(report: [{:scale, 2}], c_src: "int x;")
      assert t =~ fun("__defk_c_source__", ~S("int x;"))
      assert t =~ fun("__defk_report__", "[scale: 2]")

      assert t =~
               fun(
                 "__defk_kernels__",
                 "[%{name: :scale, params: [xs: {:arr, :f64}, k: :f64], ret: {:arr, :f64}}]"
               )

      assert t =~ fun("__defk_stats__", ":erlang.nif_error(:defk_not_loaded)")
      assert t =~ fun("__defk_force_yields__(_on)", ":erlang.nif_error(:defk_not_loaded)")
    end

    test "the build inputs are baked into __mix_recompile__?" do
      t = text([])
      assert t =~ "def __mix_recompile__? do"
      assert t =~ ~S("DEFK_NO_CC")
    end

    test "the fault hooks exist only when asked for" do
      refute text(fault_hooks?: false) =~ "__defk_corrupt_tags__"
      t = text(fault_hooks?: true)
      assert t =~ fun("__defk_corrupt_tags__(_on)", ":erlang.nif_error(:defk_not_loaded)")
      assert t =~ fun("__defk_inject_fault__(_kind)", ":erlang.nif_error(:defk_not_loaded)")
    end
  end

  test "the quoted module compiles and loads without a library; a kernel call raises until loaded" do
    sigs = [@sig, %{name: :sum, params: [{:xs, {:arr, :i64}}], ret: :i64, yields: true}]
    quoted = defs(sigs: sigs, on_load: :warm_up)

    body =
      quote do
        unquote(quoted)
        def warm_up, do: :ok
      end

    {:module, mod, _, _} = Module.create(Defk.GeneratedTest.Loaded, body, __ENV__)

    assert mod.__defk_lib__() == nil
    assert mod.__defk_kernels__() |> Enum.map(& &1.name) == [:scale, :sum]
    assert_raise ErlangError, ~r/defk_not_loaded/, fn -> mod.scale(<<>>, 2.0) end
    assert_raise ErlangError, ~r/defk_not_loaded/, fn -> mod.sum(<<>>) end
  after
    :code.purge(Defk.GeneratedTest.Loaded)
    :code.delete(Defk.GeneratedTest.Loaded)
  end
end
