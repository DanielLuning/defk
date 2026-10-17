defmodule Defk.ContractKitTest do
  # A contract test calls only defk's promised API and Defk.ContractKit
  # (test/contracts/README.md): a release freezes its contract tests and every
  # later commit runs them, so a call into any other defk module would tie an
  # old release's check to code that may change. Each contract test file, and
  # each frozen one, is read as source and every reference to a module under
  # Defk is checked: a call must name a function the API snapshots
  # (test/stability/<version>/api.exs) list for its module, or any function
  # of the kit; a bare reference must name such a module.
  use ExUnit.Case, async: true

  @files Path.wildcard("test/contracts/**/*_test.exs") ++
           Path.wildcard("test/stability/*/contracts/**/*_test.exs")

  # {module, name} of every promised function and macro, every release
  defp promised do
    for api <- Defk.ContractKit.api_snapshots(),
        {mod, items} <- api.modules,
        {_kind, name, _arity} <- items,
        into: MapSet.new(),
        do: {mod, name}
  end

  defp allowed_module?(mod, promised),
    do: mod == Defk.ContractKit or Enum.any?(promised, &(elem(&1, 0) == mod))

  defp allowed_call?(Defk.ContractKit, _name, _promised), do: true
  defp allowed_call?(:hook, name, _promised), do: name in promised_hooks()
  defp allowed_call?(mod, name, promised), do: {mod, name} in promised

  # every `{module, function | nil, line}` under Defk the file names, with
  # its aliases expanded; nil for a reference that is not a call
  defp references(source) do
    ast = Code.string_to_quoted!(source)
    aliases = aliases(ast)

    {_, refs} =
      Macro.prewalk(ast, [], fn
        # the test module's own name is not a reference
        {:defmodule, meta, [{:__aliases__, _, _}, body]}, acc ->
          {{:defmodule, meta, [nil, body]}, acc}

        # a call, counted once: its module part is not walked again
        {{:., dot, [{:__aliases__, meta, parts}, fun]}, call, args}, acc when is_atom(fun) ->
          mod = if hook?(fun), do: :hook, else: expand(parts, aliases)
          {{{:., dot, [nil, fun]}, call, args}, [{mod, fun, meta[:line]} | acc]}

        # a defk hook called on a kernel module held in a variable
        {{:., _, [_receiver, fun]}, meta, _} = node, acc when is_atom(fun) ->
          if hook?(fun), do: {node, [{:hook, fun, meta[:line]} | acc]}, else: {node, acc}

        # an alias names its module once; its `as:` name is not a reference
        {:alias, _, [{:__aliases__, meta, parts} | _]}, acc ->
          {nil, [{Module.concat(parts), nil, meta[:line]} | acc]}

        {:__aliases__, meta, parts} = node, acc ->
          {node, [{expand(parts, aliases), nil, meta[:line]} | acc]}

        node, acc ->
          {node, acc}
      end)

    refs |> Enum.reverse() |> Enum.filter(fn {mod, _, _} -> mod == :hook or defk_module?(mod) end)
  end

  # a function `use Defk` generates in a kernel module: `__defk_<name>__`
  defp hook?(fun), do: String.starts_with?(Atom.to_string(fun), "__defk_")

  # the generated functions every release promised
  defp promised_hooks do
    for api <- Defk.ContractKit.api_snapshots(),
        {_, name, _} <- api.generated,
        into: MapSet.new(),
        do: name
  end

  defp defk_module?(mod), do: mod == Defk or String.starts_with?(inspect(mod), "Defk.")

  # `alias A.B, as: C` and `alias A.B` as %{[:C] => A.B}
  defp aliases(ast) do
    {_, acc} =
      Macro.prewalk(ast, %{}, fn
        {:alias, _, [{:__aliases__, _, parts} | opts]} = node, acc ->
          as =
            case opts do
              [[as: {:__aliases__, _, as}]] -> as
              _ -> [List.last(parts)]
            end

          {node, Map.put(acc, as, Module.concat(parts))}

        node, acc ->
          {node, acc}
      end)

    acc
  end

  defp expand([head | rest] = parts, aliases) do
    case Map.fetch(aliases, [head]) do
      {:ok, mod} -> Module.concat([mod | rest])
      :error -> Module.concat(parts)
    end
  end

  defp what(:hook, fun), do: "#{fun}"
  defp what(mod, nil), do: inspect(mod)
  defp what(mod, fun), do: "#{inspect(mod)}.#{fun}"

  # the references of `source` the rule forbids, as "line <n>: <what>"
  defp violations(source) do
    promised = promised()

    for {mod, fun, line} <- references(source),
        not if(fun,
          do: allowed_call?(mod, fun, promised),
          else: allowed_module?(mod, promised)
        ),
        do: "line #{line}: #{what(mod, fun)}"
  end

  test "there are contract tests to check" do
    assert Path.wildcard("test/contracts/**/*_test.exs") != []
  end

  test "an unpromised function, a hidden module and an alias of one are caught" do
    source = """
    defmodule Defk.Contract.SampleTest do
      alias Defk.StabilityCorpus, as: Corpus
      alias Defk.ContractKit, as: Kit

      def ok, do: {Defk.Errors.entries(), Kit.codes(""), Defk.Bits.popcount(1)}
      def bad, do: {Defk.Errors.fetch!("x"), Corpus.files(:kernels), Defk.Compiler}
      def hooks(mod), do: {K.__defk_elixir__(:f, []), K.__defk_stats__(), mod.__defk_lib__()}
    end
    """

    assert violations(source) == [
             "line 2: Defk.StabilityCorpus",
             "line 6: Defk.Errors.fetch!",
             "line 6: Defk.StabilityCorpus.files",
             "line 6: Defk.Compiler",
             "line 7: __defk_stats__",
             "line 7: __defk_lib__"
           ]
  end

  for path <- @files do
    @path path
    @external_resource path

    test "#{path} calls only the promised API and the kit" do
      wrong = violations(File.read!(@path))

      assert wrong == [],
             "#{@path} reaches defk outside the promised API and Defk.ContractKit:\n  " <>
               Enum.join(wrong, "\n  ")
    end
  end
end
