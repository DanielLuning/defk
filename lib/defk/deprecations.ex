defmodule Defk.Deprecations do
  @moduledoc false
  # The deprecation table: one entry per promised name that a release
  # renamed, and the mechanism that keeps the old name working. The promise
  # (docs/guides/stability.md, "How a change is made"): an old name keeps
  # working until the next major version, with a warning at compile time
  # that names the replacement. docs/agents/deprecations.md says how to add
  # an entry; this module is hidden because the table is a maintainer's
  # tool, not an API.
  #
  # An entry is `%{kind:, old:, new:, since:}`, `since` the version that
  # deprecated the old name:
  #
  #   * `:builtin`: `old` and `new` are `{name, arity}`. A call of the old
  #     builtin in a kernel is renamed before either backend sees the
  #     kernel (rename_builtins/2), so both lower it as the new one.
  #   * `:option`: `old` and `new` are the key of a `use Defk` option
  #     (rename_options/2).
  #   * `:config`: `old` and `new` are a `config :defk` key (compile_env/2).
  #   * `:function`: `old` and `new` are `{module, name, arity}`. The old
  #     function is a `@deprecated` `defdelegate` to the new one, and Elixir
  #     itself warns at each call site; the entry records the rename so the
  #     test covers it.
  #
  # Each use site warns once per compile: the call in a kernel, the
  # `use Defk` line, or the module reading the configuration.

  @kinds [:builtin, :option, :config, :function]

  @released []

  # entries for the mechanism's own test: config/config.exs sets them in
  # defk's :test environment, and a project using defk never does
  @for_tests Application.compile_env(:defk, :deprecations_for_tests, [])

  @entries @released ++ @for_tests

  # an unset configuration key, told apart from one set to nil
  @unset :__defk_unset__

  def entries, do: @entries

  for e <- @entries do
    well_formed? =
      is_map(e) and Map.has_key?(e, :old) and Map.has_key?(e, :new) and e[:kind] in @kinds and
        is_binary(e[:since])

    if not well_formed?,
      do: raise(ArgumentError, "defk: malformed deprecation entry #{inspect(e)}")

    if Enum.any?(@entries, &(&1.kind == e.kind and &1.old == e.new)) do
      raise ArgumentError, "defk: deprecation entry #{inspect(e)} renames to a deprecated name"
    end
  end

  # The raw kernels of a module (before Defk.Attributes.inline/1) with
  # every call of a deprecated builtin renamed to its replacement, warning
  # once per call site. A kernel the module defines under the old name is
  # called as before: calls are looked up by name and arity, and the old
  # name is free once the builtin is gone.
  def rename_builtins(kernels, file) do
    defined = MapSet.new(kernels, &Defk.Clauses.key(&1.head))

    renames =
      for %{kind: :builtin} = e <- entries(), e.old not in defined, into: %{}, do: {e.old, e}

    if map_size(renames) == 0,
      do: kernels,
      else: Enum.map(kernels, &rename_kernel(&1, renames, file))
  end

  defp rename_kernel(kernel, renames, file) do
    walk = fn
      {name, meta, args} = node when is_atom(name) and is_list(args) ->
        case renames[{name, length(args)}] do
          nil ->
            node

          %{new: {new, _}} = e ->
            warn(e, file, meta[:line] || kernel.line)
            {new, meta, args}
        end

      node ->
        node
    end

    %{kernel | head: Macro.prewalk(kernel.head, walk), body: Macro.prewalk(kernel.body, walk)}
  end

  # The options of `use Defk` with each deprecated option renamed to its
  # replacement, warning once per `use Defk`.
  def rename_options(opts, caller) do
    if Keyword.keyword?(opts), do: Enum.map(opts, &rename_option(&1, caller)), else: opts
  end

  defp rename_option({key, value}, caller) do
    case Enum.find(entries(), &(&1.kind == :option and &1.old == key)) do
      nil ->
        {key, value}

      e ->
        warn(e, caller.file, caller.line)
        {e.new, value}
    end
  end

  # `Application.compile_env(:defk, key, default)` that also reads the
  # deprecated keys renamed to `key`: the new key wins when set, else the
  # first old key set, else `default`. Each old key set warns once per
  # module, at its `use Defk`.
  defmacro compile_env(key, default) do
    olds =
      for %{kind: :config, new: ^key} = e <- entries() do
        {Macro.escape(e),
         quote(do: Application.compile_env(:defk, unquote(e.old), unquote(@unset)))}
      end

    quote do
      Defk.Deprecations.__config__(
        Application.compile_env(:defk, unquote(key), unquote(@unset)),
        unquote(olds),
        unquote(default),
        unquote(__CALLER__.file),
        unquote(__CALLER__.line)
      )
    end
  end

  @doc false
  def __config__(value, olds, default, file, line) do
    set = for {e, v} <- olds, v != @unset, do: {e, v}
    Enum.each(set, fn {e, _} -> warn(e, file, line) end)

    case {value, set} do
      {v, _} when v != @unset -> v
      {_, [{_, v} | _]} -> v
      _ -> default
    end
  end

  # The warning's text: what is deprecated, since when, and its replacement.
  def message(%{kind: kind, old: old, new: new, since: since}) do
    "defk: #{describe(kind, old)} is deprecated since #{since}; use #{name(kind, new)} instead. " <>
      "The old name keeps working until the next major version."
  end

  defp warn(e, file, line), do: IO.warn(message(e), file: file, line: line)

  defp describe(:builtin, old), do: "builtin #{name(:builtin, old)}"
  defp describe(:option, old), do: "use Defk, #{name(:option, old)}"
  defp describe(:config, old), do: "config :defk, #{name(:config, old)}"
  defp describe(:function, old), do: name(:function, old)

  defp name(:builtin, {name, arity}), do: "#{name}/#{arity}"
  defp name(:function, {module, name, arity}), do: "#{inspect(module)}.#{name}/#{arity}"
  defp name(_, key), do: "#{key}:"
end
