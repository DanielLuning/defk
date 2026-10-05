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

  @runtime_h Path.expand("../priv/defk_runtime.h", __DIR__)

  defmacro __using__(_opts) do
    quote do
      import Defk, only: [defk: 2, defk: 3]
      Module.register_attribute(__MODULE__, :defk_kernels, accumulate: true)
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
    {c_src, sigs} = Defk.Compiler.compile(env.module, kernels, env.file)
    lib = Defk.Build.build!(env.module, c_src, env.file)

    stubs =
      for %{name: name, params: params, ret: ret} <- sigs do
        args = for {p, _} <- params, do: Macro.var(:"_#{p}", nil)
        specs = for {_, t} <- params, do: spec(t, :in)

        quote do
          @spec unquote(name)(unquote_splicing(specs)) :: unquote(spec(ret, :out))
          def unquote(name)(unquote_splicing(args)), do: :erlang.nif_error(:defk_not_loaded)
        end
      end

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
      unquote_splicing(stubs)
    end
  end

  defp spec(:i64, _), do: quote(do: integer())
  defp spec(:f64, :in), do: quote(do: number())
  defp spec(:f64, :out), do: quote(do: float())
  defp spec(:bool, _), do: quote(do: boolean())
  defp spec({:arr, _}, _), do: quote(do: binary())
  defp spec({:tuple, ts}, dir), do: {:{}, [], Enum.map(ts, &spec(&1, dir))}
end
