defmodule Defk do
  @moduledoc """
  `defk` compiles a typed subset of Elixir to a native NIF.

      defmodule Stats do
        use Defk

        defk dot(a :: [f64], b :: [f64]) :: f64 do
          for i <- 0..(len(a) - 1)//1, reduce: 0.0 do
            acc -> acc + a[i] * b[i]
          end
        end
      end

  Types: `i64`, `f64`, `bool`, packed arrays `[f64]`, `[i64]`, `[u8]`
  (passed as binaries in native byte order), tuples as return values.
  """

  # compile-time attribute: the defk app is not loaded when this module is
  # compiled, so Application.app_dir/2 (which reads :code.priv_dir) cannot
  # answer yet; a source-relative path is the only honest option.
  # credo:disable-for-next-line ExSlop.Check.Warning.PathExpandPriv
  @runtime_h Path.expand("../priv/defk_runtime.h", __DIR__)

  defmacro __using__(_opts) do
    quote do
      import Defk, only: [defk: 2, defk: 3]
      Module.register_attribute(__MODULE__, :defk_kernels, accumulate: true)
      @defk_mode Application.compile_env(:defk, :mode, :native)
      @external_resource unquote(@runtime_h)
      @before_compile Defk
    end
  end

  defmacro defk(head, opts \\ [], body) do
    kernel = %{head: head, opts: opts, body: Keyword.get(body, :do), line: __CALLER__.line}

    quote do
      @defk_kernels unquote(Macro.escape(kernel))
    end
  end

  defmacro __before_compile__(env) do
    kernels = env.module |> Module.get_attribute(:defk_kernels) |> Enum.reverse()
    # Elixir mode: compiled in :test, and wherever it is the configured mode
    {mode, elixir?} = Defk.ElixirMode.setup!(Module.get_attribute(env.module, :defk_mode), env)
    nif_name = if elixir?, do: &Defk.ElixirMode.native_name/1, else: & &1
    {c_src, sigs} = Defk.Compiler.compile(env.module, kernels, env.file, nif_name: nif_name)
    lib = Defk.Build.build!(env.module, c_src, env.file)

    stubs =
      if elixir?,
        do: native_stubs(sigs, nif_name) ++ dispatch_defs(sigs, mode, nif_name),
        else: render_stubs(sigs)

    elixir_mode = if elixir?, do: Defk.ElixirMode.definitions(kernels, sigs, env.file), else: []

    quote do
      @on_load :__defk_load__
      @doc false
      def __defk_load__, do: :erlang.load_nif(unquote(String.to_charlist(lib)), 0)
      @doc "Generated C source."
      def __defk_source__, do: unquote(c_src)
      @doc "Path of the compiled NIF library."
      def __defk_lib__, do: unquote(lib <> ".so")
      @doc "Runtime counters: frames_live, promotions, yields."
      def __defk_stats__, do: :erlang.nif_error(:defk_not_loaded)
      @doc "The kernels' signatures: name, arity, `params` as `[{name, type}]`, and `ret`."
      def __defk_kernels__, do: unquote(Macro.escape(sigs))
      @doc "Testing: `true` makes this module's kernels yield at every clock read."
      def __defk_force_yields__(_on), do: :erlang.nif_error(:defk_not_loaded)
      unquote_splicing(stubs)
      unquote_splicing(elixir_mode)
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

  # Elixir mode: the NIF keeps its own name, so each kernel gets a bare native
  # stub plus a kernel-name def that dispatches on the process mode.
  defp native_stubs(sigs, nif_name) do
    for %{name: name, params: params} <- sigs do
      args = for {p, _} <- params, do: Macro.var(:"_#{p}", nil)

      quote do
        @doc false
        def unquote(nif_name.(name))(unquote_splicing(args)),
          do: :erlang.nif_error(:defk_not_loaded)
      end
    end
  end

  defp dispatch_defs(sigs, mode, nif_name) do
    for %{name: name, params: params, ret: ret} <- sigs do
      specs = for {_, t} <- params, do: spec(t, :in)
      vs = for {p, _} <- params, do: Macro.var(p, nil)

      quote do
        @spec unquote(name)(unquote_splicing(specs)) :: unquote(spec(ret, :out))
        def unquote(name)(unquote_splicing(vs)) do
          case Process.get(unquote(Defk.ElixirMode.process_mode_key()), unquote(mode)) do
            :elixir -> __defk_elixir__(unquote(name), [unquote_splicing(vs)])
            _ -> unquote(nif_name.(name))(unquote_splicing(vs))
          end
        end
      end
    end
  end

  defp spec(:i64, _), do: quote(do: integer())
  defp spec(:f64, :in), do: quote(do: number())
  defp spec(:f64, :out), do: quote(do: float())
  defp spec(:bool, _), do: quote(do: boolean())
  defp spec({:arr, _}, _), do: quote(do: binary())
  defp spec({:tuple, ts}, dir), do: {:{}, [], Enum.map(ts, &spec(&1, dir))}
end
