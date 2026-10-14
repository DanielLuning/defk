# Loads the kernel modules of the catalogue (examples/, bench/) into a Mix
# run, without running the example scripts: only the top-level `defmodule`
# forms, `name = quote do ... end` bindings and `Module.create/3` calls are
# evaluated (`Mix.install`, the timed runs and reports are skipped). Modules
# that need a dependency defk does not have (Nx, the anchor NIFs) fail to
# compile and are skipped: none of them is a kernel module.
#
# `Simd.Load.variant/3` evaluates one kernel module again under another
# name, with `CC` set to a wrapper that adds target flags, and with
# `elixir_mode: true`, so each target build can be checked against Elixir mode.
# Research tooling for the SIMD study (docs/research/simd.md), not part of defk.
defmodule Simd.Load do
  @root Path.expand("../..", __DIR__)

  @sources ~w(examples/*.exs examples/fuzzy_search/lib/fuzzy_search/*.ex bench/float_checks.exs bench/tick_gap.exs)

  def root, do: @root

  @doc "Every kernel module: [%{mod, file, form, binding}] (Examples.Kernels too)."
  def all do
    files =
      @sources
      |> Enum.flat_map(&Path.wildcard(Path.join(@root, &1)))
      |> Enum.reject(&(Path.basename(&1) in ["_template.exs"]))
      |> Enum.sort()

    ex = %{mod: Examples.Kernels, file: "test/support/examples.ex", form: nil, binding: []}
    [ex | Enum.flat_map(files, &file/1)]
  end

  defp file(path) do
    rel = Path.relative_to(path, @root)
    {:ok, ast} = Code.string_to_quoted(File.read!(path), file: path, columns: false)

    forms =
      case ast do
        {:__block__, _, fs} -> fs
        f -> [f]
      end

    {mods, _binding} =
      Enum.reduce(forms, {[], []}, fn form, {mods, binding} ->
        case kind(form) do
          :skip ->
            {mods, binding}

          k ->
            try do
              {_, binding2} =
                Code.eval_quoted(form, binding, file: path, line: 1)

              case k do
                {:mod, name} when is_atom(name) ->
                  if kernel?(name),
                    do:
                      {[%{mod: name, file: rel, form: form, binding: binding} | mods], binding2},
                    else: {mods, binding2}

                _ ->
                  {mods, binding2}
              end
            rescue
              e ->
                IO.puts(
                  :stderr,
                  "skip #{rel}: #{inspect(k)} #{Exception.message(e) |> String.slice(0, 120)}"
                )

                {mods, binding}
            end
        end
      end)

    Enum.reverse(mods)
  end

  defp kernel?(mod),
    do: Code.ensure_loaded?(mod) and function_exported?(mod, :__defk_c_source__, 0)

  # which top-level forms to evaluate
  defp kind({:defmodule, _, [name, [do: body]]}) do
    cond do
      uses?(body, [:Mix, :Project]) -> :skip
      true -> {:mod, alias_atom(name)}
    end
  end

  defp kind({:=, _, [{v, _, ctx}, {:quote, _, _}]}) when is_atom(v) and is_atom(ctx), do: :quote

  defp kind({{:., _, [{:__aliases__, _, [:Module]}, :create]}, _, [name | _]}),
    do: {:mod, alias_atom(name)}

  defp kind(_), do: :skip

  defp alias_atom({:__aliases__, _, parts}), do: Module.concat(parts)
  defp alias_atom(_), do: nil

  defp uses?(ast, parts) do
    {_, found} =
      Macro.prewalk(ast, false, fn
        {:use, _, [{:__aliases__, _, ^parts} | _]} = n, _ -> {n, true}
        n, acc -> {n, acc}
      end)

    found
  end

  @doc """
  Compile kernel module `k` again as `name` with `CC=cc` and elixir_mode: true.
  Examples.Kernels (no form) is recompiled from its source file.
  """
  def variant(k, name, cc) do
    old = System.get_env("CC")
    System.put_env("CC", cc)

    try do
      Code.compiler_options(ignore_module_conflict: true)
      form = k.form || examples_form()
      form = rename(form, k.mod, name)
      binding = Enum.map(k.binding, fn {v, val} -> {v, elixir_mode(val)} end)
      Code.eval_quoted(elixir_mode(form), binding, file: Path.join(@root, k.file), line: 1)
      name
    after
      if old, do: System.put_env("CC", old), else: System.delete_env("CC")
    end
  end

  defp examples_form do
    {:ok, ast} = Code.string_to_quoted(File.read!(Path.join(@root, "test/support/examples.ex")))
    ast
  end

  defp rename({:defmodule, m, [_name, body]}, _old, new),
    do: {:defmodule, m, [{:__aliases__, [], [new]}, body]}

  defp rename({call, m, [_name | rest]}, _old, new), do: {call, m, [new | rest]}

  defp elixir_mode(ast) do
    Macro.prewalk(ast, fn
      {:use, m, [{:__aliases__, _, [:Defk]} = d]} ->
        {:use, m, [d, [elixir_mode: true]]}

      {:use, m, [{:__aliases__, _, [:Defk]} = d, opts]} when is_list(opts) ->
        {:use, m, [d, Keyword.put(opts, :elixir_mode, true) |> Keyword.delete(:report)]}

      n ->
        n
    end)
  end
end
