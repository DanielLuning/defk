defmodule Defk.Properties do
  @moduledoc false
  # Agreement properties (defk-ne6): for each kernel of a module, a property
  # that draws its arguments and runs Defk.Test.assert_agrees, so the kernel
  # and its Elixir mode are checked on generated inputs, not only on the
  # hand-picked ones in the tests. In a test module:
  #
  #     use Defk.Properties
  #
  #     agreement K, [
  #       :add,
  #       count_primes: [args: fixed_list([G.i64(-10..3_000, [@max])])],
  #       scale: [args: ..., divergence: {"defk-xxx: ...", args}]
  #     ]
  #
  # A kernel with no options draws each argument from Defk.Generators by its
  # type. Options:
  #
  #   * `:args` - a generator of argument lists, for arguments that set a
  #     trip count or an alloc/2 size, or must fit together (`k <= len`)
  #   * `:max_runs` - default 100
  #   * `:deep` - `[args: ..., max_runs: ...]` for the `@tag :deep` twin
  #     (default: the same generator, 10_000 runs)
  #   * `:divergence` - `{why, args}`: one more property, over `args`, that
  #     finds a known divergence; tagged `:divergence` (excluded by default)
  #     with `why` naming its ticket
  #
  # `agreement/2` also defines a test that the list names every kernel of the
  # module (a new kernel without a property fails it), and a property that a
  # hostile argument raises ArgumentError for the same reason in both modes.

  @runs 100
  @deep_runs 10_000

  defmacro __using__(_opts) do
    quote do
      use ExUnitProperties
      import Defk.Properties, only: [agreement: 2]
      alias Defk.Generators, as: G
    end
  end

  defmacro agreement(mod, kernels) do
    entries = Enum.map(kernels, fn k -> if is_atom(k), do: {k, []}, else: k end)
    label = Macro.to_string(mod)

    props = Enum.map(entries, &kernel_properties(mod, label, &1))

    funs = Enum.map(entries, &elem(&1, 0))

    picks =
      for {fun, opts} <- entries do
        quote do:
                StreamData.tuple(
                  {StreamData.constant(unquote(fun)), unquote(args(mod, fun, opts))}
                )
      end

    quote do
      unquote_splicing(props)

      test "every kernel of #{unquote(label)} has an agreement property" do
        Defk.Properties.assert_covered(unquote(mod), unquote(funs))
      end

      property "#{unquote(label)}: a hostile argument raises ArgumentError in both modes" do
        check all(
                {fun, args} <- StreamData.one_of(unquote(picks)),
                pos <- StreamData.integer(0..(length(args) - 1)),
                bad <- Defk.Generators.hostile(Defk.Properties.param_type(unquote(mod), fun, pos)),
                max_runs: unquote(@runs)
              ) do
          Defk.Properties.assert_badarg(unquote(mod), fun, List.replace_at(args, pos, bad))
        end
      end
    end
  end

  defp args(mod, fun, opts) do
    Keyword.get(opts, :args, quote(do: Defk.Properties.args(unquote(mod), unquote(fun))))
  end

  defp kernel_properties(mod, label, {fun, opts}) do
    args = args(mod, fun, opts)
    deep = Keyword.get(opts, :deep, [])
    name = "#{label}.#{fun} agrees with Elixir mode"

    divergence =
      case Keyword.fetch(opts, :divergence) do
        {:ok, {why, div_args}} ->
          quote do
            @tag divergence: unquote(why)
            property unquote(name <> " (known divergence)") do
              check all(args <- unquote(div_args), max_runs: unquote(@runs)) do
                Defk.Test.assert_agrees(unquote(mod), unquote(fun), args)
              end
            end
          end

        :error ->
          nil
      end

    quote do
      property unquote(name) do
        check all(args <- unquote(args), max_runs: unquote(Keyword.get(opts, :max_runs, @runs))) do
          # forced yields by default: every agreement property covers every
          # resume path, instead of only where someone wrote the ceremony
          Defk.Test.assert_agrees(unquote(mod), unquote(fun), args, forced_yields: true)
        end
      end

      @tag deep: true, timeout: 600_000
      property unquote(name <> " (deep)") do
        check all(
                args <- unquote(Keyword.get(deep, :args, args)),
                max_runs: unquote(Keyword.get(deep, :max_runs, @deep_runs))
              ) do
          Defk.Test.assert_agrees(unquote(mod), unquote(fun), args, forced_yields: true)
        end
      end

      unquote(divergence)
    end
  end

  @doc "A generator of argument lists for `mod.fun`, each drawn by its parameter's type."
  def args(mod, fun) do
    StreamData.fixed_list(for {_, t} <- params(mod, fun), do: Defk.Generators.for_type(t))
  end

  def param_type(mod, fun, pos), do: mod |> params(fun) |> Enum.at(pos) |> elem(1)

  defp params(mod, fun) do
    case Enum.find(mod.__defk_kernels__(), &(&1.name == fun)) do
      %{params: params} -> params
      nil -> raise ArgumentError, "#{inspect(mod)} has no kernel #{fun}"
    end
  end

  @doc "Every kernel of `mod` is in `funs`, and every name in `funs` is a kernel."
  def assert_covered(mod, funs) do
    import ExUnit.Assertions
    kernels = mod.__defk_kernels__() |> Enum.map(& &1.name) |> Enum.uniq() |> Enum.sort()
    listed = Enum.sort(funs)

    assert kernels == listed,
           "#{inspect(mod)}: kernels without an agreement property: " <>
             "#{inspect(kernels -- listed)}; listed but not kernels: #{inspect(listed -- kernels)}"
  end

  @doc "`mod.fun(args)` raises ArgumentError for a bad argument, in both modes."
  def assert_badarg(mod, fun, args) do
    import ExUnit.Assertions

    case Defk.Test.assert_agrees(mod, fun, args) do
      {:raise, %ArgumentError{} = e} ->
        assert Defk.Test.agreement_reason(e) == :badarg, "#{fun}#{inspect(args)}: #{inspect(e)}"

      other ->
        flunk("#{fun}#{inspect(args, limit: 5)}: expected ArgumentError, got #{inspect(other)}")
    end
  end
end
