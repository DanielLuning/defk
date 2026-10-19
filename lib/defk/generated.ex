defmodule Defk.Generated do
  # The generated module: the Elixir functions `defk` adds to a module
  # beside its kernels. The NIF loader for the library's placement, the
  # `@on_load` chain, the native stubs, the Elixir mode dispatch, the
  # bitstring decode wrappers and the specs: plumbing a kernel's caller
  # never sees (CONTEXT.md, "Generated module").
  #
  # One function, defs/1: data in (signatures, placement, mode, hooks),
  # one quoted block out. It reads no module attribute and runs no build,
  # so a test can assert on the quoted code without a C compiler or a
  # real module. `Defk.__before_compile__/1` owns the pipeline that
  # produces the data.
  @moduledoc false

  @doc """
  The quoted definitions `defk` adds to a module. Options, all required:

    * `:placement` - where the library is (`Defk.Build.placement!/3`):
      `:none` (no library: the module loads without its NIFs and a kernel
      call raises), `{:path, base}` (an absolute path without `.so`) or
      `{:app, app, name, fallback}` (beside the app's beams at load time,
      else the absolute `fallback`)
    * `:sigs` - the kernels' signatures that get a function (helpers taking
      a bitstring are inlined only): `name`, `params`, `ret` and `yields`
      (whether the kernel's NIF takes the run-queue hint)
    * `:elixir?` - whether Elixir mode is compiled in: every kernel then
      dispatches on the process's mode
    * `:mode` - the module's default mode for that dispatch
    * `:bits` - the names of the kernels returning a bitstring, whose
      result the wrapper decodes
    * `:on_load` - the module's own `@on_load` hook (an atom), chained
      after the kernels load, or `nil`
    * `:fault_hooks?` - whether the test-only fault hooks are generated
    * `:c_src` - the generated C, kept as `__defk_c_source__/0`
    * `:report` - the fast-path report, kept as `__defk_report__/0`
    * `:attrs` - the `@doc` and `@impl` a kernel had before its `defk`,
      by `{name, arity}`, put back before that kernel's `def`
    * `:elixir_mode` - the Elixir mode definitions (quoted), or `[]`
  """
  @spec defs(keyword()) :: Macro.t()
  def defs(opts) do
    sigs = Keyword.fetch!(opts, :sigs)
    elixir? = Keyword.fetch!(opts, :elixir?)
    c_src = Keyword.fetch!(opts, :c_src)
    report = Keyword.fetch!(opts, :report)

    stubs =
      sigs
      |> kernel_defs(elixir?, Keyword.fetch!(opts, :mode), Keyword.fetch!(opts, :bits))
      |> attrs_before(Keyword.fetch!(opts, :attrs))

    # The generated functions are `@doc false` (ADR-0006): the Defk moduledoc
    # ("Generated functions") describes them, with their stability.
    quote do
      @on_load :__defk_load__
      unquote(load_def(Keyword.fetch!(opts, :on_load)))
      unquote(loader_defs(Keyword.fetch!(opts, :placement)))
      @doc false
      def __defk_c_source__, do: unquote(c_src)

      unquote(recompile_def())

      @doc false
      def __defk_report__, do: unquote(Macro.escape(report))
      @doc false
      def __defk_stats__, do: :erlang.nif_error(:defk_not_loaded)
      @doc false
      def __defk_kernels__, do: unquote(Macro.escape(Enum.map(sigs, &Map.delete(&1, :yields))))
      @doc false
      def __defk_force_yields__(_on), do: :erlang.nif_error(:defk_not_loaded)
      unquote(fault_hooks_def(Keyword.fetch!(opts, :fault_hooks?)))
      unquote_splicing(stubs)
      unquote_splicing(Keyword.fetch!(opts, :elixir_mode))
    end
  end

  # Mix's compile.elixir asks every module __mix_recompile__? on every
  # compile: the build inputs read from the environment (the C compiler, the
  # include dir, the sanitizer mode) are baked in, so a change recompiles the
  # module. Raw values, so set-versus-unset counts; harmless outside Mix.
  # DEFK_NO_CC is one of them: a module compiled without its library
  # compiles again, with it, as soon as the variable is unset.
  @build_env ["CC", "ERTS_INCLUDE_DIR", "DEFK_SANITIZE", "DEFK_NO_CC"]

  defp recompile_def do
    baked = for var <- @build_env, do: {var, System.get_env(var)}

    quote do
      @doc false
      def __mix_recompile__? do
        Enum.any?(unquote(baked), fn {var, value} -> System.get_env(var) != value end)
      end
    end
  end

  # __defk_load__/0 is the module's on_load: load the kernels, then the
  # module's own hook; only :ok from both lets the module load.
  defp load_def(nil) do
    quote do
      @doc false
      def __defk_load__, do: __defk_load_nif__()
    end
  end

  defp load_def(user_hook) do
    quote do
      @doc false
      def __defk_load__ do
        case __defk_load_nif__() do
          :ok -> unquote(user_hook)()
          other -> other
        end
      end
    end
  end

  # __defk_load_nif__/0 and __defk_lib__/0 (Defk.Build.placement!/3). A Mix app's
  # module loads its library from beside its beams, wherever the app is at
  # load time (a release, a moved _build); anything else from the
  # absolute build path. Only :code and :filename at load time: the on_load
  # function may run before other applications' modules are loaded.
  # DEFK_NO_CC with no cached library: the module loads without its NIFs, so
  # a dump can load test files and examples; a kernel call raises
  # (:erlang.nif_error from its stub).
  defp loader_defs(:none) do
    quote do
      @doc false
      def __defk_load_nif__, do: :ok
      @doc false
      def __defk_lib__, do: nil
    end
  end

  defp loader_defs({:path, base}) do
    quote do
      @doc false
      def __defk_load_nif__, do: :erlang.load_nif(unquote(String.to_charlist(base)), 0)
      @doc false
      def __defk_lib__, do: unquote(base <> ".so")
    end
  end

  defp loader_defs({:app, app, name, fallback}) do
    rel = String.to_charlist(Path.join("ebin", Path.rootname(name)))
    fallback = String.to_charlist(Path.rootname(fallback))

    quote do
      # Mix recompiles the module when the library is gone. A module whose
      # library is missing cannot load, so __mix_recompile__?/0 never runs.
      @external_resource unquote(List.to_string(fallback) <> ".so")

      defp __defk_lib_base__ do
        case :code.lib_dir(unquote(app)) do
          dir when is_list(dir) -> :filename.join(dir, unquote(rel))
          _ -> unquote(fallback)
        end
      end

      @doc false
      def __defk_load_nif__, do: :erlang.load_nif(__defk_lib_base__(), 0)
      @doc false
      def __defk_lib__, do: :unicode.characters_to_binary(__defk_lib_base__() ++ ~c".so")
    end
  end

  # Each kernel's function: the NIF itself (a stub it replaces), or an Elixir
  # function calling the renamed NIF (Elixir mode, a bitstring result, the
  # run-queue hint)
  defp kernel_defs(sigs, true, mode, _bits), do: native_stubs(sigs) ++ dispatch_defs(sigs, mode)

  defp kernel_defs(sigs, false, _mode, bits) do
    {wrapped, plain} = Enum.split_with(sigs, &(&1.name in bits or &1.yields))
    render_stubs(plain) ++ native_stubs(wrapped) ++ wrappers(wrapped)
  end

  # `__defk_corrupt_tags__/1` deliberately breaks the frame-tag check and
  # `__defk_inject_fault__/1` makes a kernel fault on purpose, so they are
  # generated only when the user's module compiles under MIX_ENV=test
  # (scripts without Mix never get them).
  defp fault_hooks_def(false), do: nil

  defp fault_hooks_def(true) do
    quote do
      @doc false
      def __defk_corrupt_tags__(_on), do: :erlang.nif_error(:defk_not_loaded)
      @doc false
      def __defk_inject_fault__(_kind), do: :erlang.nif_error(:defk_not_loaded)
    end
  end

  # A kernel's spec and stub, whose call raises unless the NIF is loaded.
  defp render_stubs(sigs) do
    for %{name: name, params: params, ret: ret} <- sigs do
      args = for {p, _} <- params, do: Macro.var(:"_#{p}", nil)
      specs = for {_, t} <- params, do: spec(t, :in)

      quote do
        @spec unquote(name)(unquote_splicing(specs)) :: unquote(spec(ret, :out))
        def unquote(name)(unquote_splicing(args)), do: :erlang.nif_error(:defk_not_loaded)
      end
    end
  end

  # The NIF of a kernel that gets an Elixir function (Elixir mode, a
  # bitstring result, the run-queue hint) is renamed: a bare native stub for
  # it, which the NIF replaces. With the hint it takes one more argument.
  defp native_stubs(sigs) do
    for %{name: name, params: params} = sig <- sigs do
      args = for {p, _} <- params, do: Macro.var(:"_#{p}", nil)
      args = if sig.yields, do: args ++ [Macro.var(:_waiting, nil)], else: args

      quote do
        @doc false
        def unquote(Defk.ElixirMode.native_name(name))(unquote_splicing(args)),
          do: :erlang.nif_error(:defk_not_loaded)
      end
    end
  end

  # The call of a renamed NIF; a yielding kernel passes how many processes
  # wait in the run queues, and a crowded queue gets short first slices
  # (defk_slice_init in priv/defk_runtime.h).
  defp nif_call(%{name: name, yields: yields}, vs) do
    native = Defk.ElixirMode.native_name(name)

    if yields,
      do:
        quote(
          do: unquote(native)(unquote_splicing(vs), :erlang.statistics(:total_run_queue_lengths))
        ),
      else: quote(do: unquote(native)(unquote_splicing(vs)))
  end

  # A kernel's function that calls its renamed NIF; a bitstring result is
  # made from the NIF's {bytes, bit_length} (Defk.Bitstring.decode/2).
  defp wrappers(sigs) do
    for %{name: name, params: params, ret: ret} = sig <- sigs do
      specs = for {_, t} <- params, do: spec(t, :in)
      vs = Defk.Args.vars(params)
      body = Defk.Bitstring.decode(ret, nif_call(sig, vs))

      quote do
        @spec unquote(name)(unquote_splicing(specs)) :: unquote(spec(ret, :out))
        def unquote(name)(unquote_splicing(vs)), do: unquote(body)
      end
    end
  end

  defp dispatch_defs(sigs, mode) do
    for %{name: name, params: params, ret: ret} = sig <- sigs do
      specs = for {_, t} <- params, do: spec(t, :in)
      vs = Defk.Args.vars(params)

      quote do
        @spec unquote(name)(unquote_splicing(specs)) :: unquote(spec(ret, :out))
        def unquote(name)(unquote_splicing(vs)) do
          case Process.get(unquote(Defk.ElixirMode.process_mode_key()), unquote(mode)) do
            :elixir ->
              __defk_elixir__(unquote(name), [unquote_splicing(vs)])

            _ ->
              unquote(Defk.Bitstring.decode(ret, nif_call(sig, vs)))
          end
        end
      end
    end
  end

  defp spec(:i64, _), do: quote(do: integer())
  defp spec(:u64, _), do: quote(do: non_neg_integer())
  defp spec(:f64, :in), do: quote(do: number())
  defp spec(:f64, :out), do: quote(do: float())
  defp spec(:bool, _), do: quote(do: boolean())
  defp spec({:arr, _}, _), do: quote(do: binary())
  defp spec(:bitstring, _), do: quote(do: bitstring())
  defp spec({:tuple, ts}, dir), do: {:{}, [], Enum.map(ts, &spec(&1, dir))}

  # `@doc` and `@impl` ahead of the public `def` of a kernel that had them
  # before its `defk`; the generated helpers and renamed NIFs never get them
  defp attrs_before(stubs, attrs) do
    Enum.map(stubs, fn
      {:__block__, meta, exprs} -> {:__block__, meta, Enum.flat_map(exprs, &put_attrs(&1, attrs))}
      expr -> put_attrs(expr, attrs) |> then(&{:__block__, [], &1})
    end)
  end

  defp put_attrs({:def, _, [{name, _, args}, _]} = expr, attrs) when is_list(args) do
    case Map.fetch(attrs, {name, length(args)}) do
      {:ok, a} -> doc_attr(a[:doc]) ++ impl_attr(a[:impl]) ++ [expr]
      :error -> [expr]
    end
  end

  defp put_attrs(expr, _attrs), do: [expr]

  defp doc_attr(nil), do: []

  defp doc_attr(doc),
    do: [quote(do: Module.put_attribute(__MODULE__, :doc, unquote(Macro.escape(doc))))]

  defp impl_attr(nil), do: []
  defp impl_attr(impl), do: [quote(do: @impl(unquote(Macro.escape(impl))))]
end
