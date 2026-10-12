defmodule Defk.InlineSize do
  @moduledoc false
  # The size of an entry kernel with its calls inlined, and the compile
  # warning past a threshold (defk-6ag).
  #
  # Every kernel call is inlined (defk-jaj), so an entry kernel's C holds a
  # copy of each callee per call site along every call chain: a helper called
  # from two sites of a helper called from three sites is compiled six times,
  # and a diamond doubles per level. argon2's first draft gave 26.6 MB of C
  # that clang -O3 had not compiled after 10 minutes (docs/performance.md
  # 6.20). This warns past a size, naming the chains that multiply it, so the
  # author hears it before the C compiler runs.
  #
  # The measure: the lines of C generated for the entry kernel (its frame,
  # its function, its NIF wrapper), counted after lowering and before the C
  # compiler runs: lowering argon2's first draft took ~4 s, clang over 10
  # minutes. The chains the warning names come from the call graph: how many
  # copies of each kernel the entry inlines, weighted by the AST nodes of the
  # kernel's own body. Measured against every kernel in test/support and
  # examples, and argon2's first draft: docs/performance.md 6.26.

  # well above the largest kernel in test/support and examples (argon2's
  # entries, ~29k lines), well below argon2's first draft (224k-296k)
  @threshold 80_000
  # how many of the heaviest repeated callees the warning names
  @chains 3

  @doc false
  # Warn for each entry kernel whose generated C (`{kernel, c}` in `entries`)
  # has more than `threshold` lines. `kernels` are all the parsed kernels (a
  # map with :name, :arity, :head and :body), for the call graph.
  def check(entries, kernels, file, threshold \\ @threshold) do
    big = for {k, c} <- entries, (n = lines(c)) > threshold, do: {k, n, byte_size(c)}

    if big != [] do
      graph = graph(kernels)

      for {k, n, bytes} <- big do
        IO.warn(message({k.name, k.arity}, n, bytes, threshold, graph),
          file: file,
          line: line(k.head)
        )
      end
    end

    :ok
  end

  defp lines(c), do: c |> :binary.matches("\n") |> length()

  @doc false
  # %{key => {own size, %{callee key => call sites}}} for every kernel
  def graph(kernels) do
    keys = MapSet.new(kernels, &{&1.name, &1.arity})
    Map.new(kernels, &{{&1.name, &1.arity}, {nodes(&1.body), sites(&1.body, keys)}})
  end

  @doc false
  # How many copies of each kernel the entry `key` inlines (itself once):
  # the copies of each caller times its call sites, summed over the callers,
  # in topological order. A call back into the chain (recursion, which the
  # compiler rejects) is dropped.
  def copies(key, graph) do
    order = topo(key, graph)

    Enum.reduce(order, %{key => 1}, fn k, copies ->
      {_, callees} = graph[k]

      Enum.reduce(callees, copies, fn {callee, sites}, copies ->
        if callee in order and before?(order, k, callee),
          do: Map.update(copies, callee, copies[k] * sites, &(&1 + copies[k] * sites)),
          else: copies
      end)
    end)
  end

  defp before?(order, a, b),
    do: Enum.find_index(order, &(&1 == a)) < Enum.find_index(order, &(&1 == b))

  # the kernels `key` reaches, callers before callees (reverse post-order);
  # an edge back into the current chain is skipped
  defp topo(key, graph) do
    {_, post} = visit(key, graph, [], {MapSet.new(), []})
    post
  end

  defp visit(key, graph, chain, {seen, post}) do
    if MapSet.member?(seen, key) do
      {seen, post}
    else
      {_, callees} = graph[key]

      {seen, post} =
        callees
        |> Map.keys()
        |> Enum.reject(&(&1 in [key | chain]))
        |> Enum.reduce({MapSet.put(seen, key), post}, &visit(&1, graph, [key | chain], &2))

      {seen, [key | post]}
    end
  end

  defp message({name, arity} = key, lines, bytes, threshold, graph) do
    copies = copies(key, graph)

    heavy =
      copies
      |> Enum.filter(fn {k, n} -> n > 1 and k != key end)
      |> Enum.map(fn {k, n} -> {k, n, n * elem(graph[k], 0)} end)
      |> Enum.sort_by(fn {k, _, weight} -> {-weight, k} end)
      |> Enum.take(@chains)

    chains =
      Enum.map_join(heavy, "", fn {{n, a} = k, times, weight} ->
        path = path_back(k, key, copies, graph, [])
        along = path |> Enum.map(&(elem(&1, 1) || 1)) |> Enum.product()
        via = if along == times, do: " via", else: ", #{along} of them via"

        "\n  * #{n}/#{a} is inlined #{times} times (#{count(weight)} AST nodes)#{via} #{chain(path)}"
      end)

    what =
      if heavy == [],
        do:
          " No kernel is inlined more than once: the size is in the kernels' own bodies; split the work over several kernels called from Elixir.",
        else:
          " The kernels inlined most (copies times the AST nodes of their own body):" <>
            chains <>
            "\nGive each helper one call site: call it from one loop over its inputs, or copy the inputs into a buffer and call it once (docs/performance.md 6.20)."

    "#{name}/#{arity} compiles to #{count(lines)} lines of C (#{mb(bytes)} MB), past the #{count(threshold)} at which defk warns: " <>
      "every kernel call is inlined, once per call site along each call chain, and the C compiler may take many minutes on this much code." <>
      what
  end

  defp mb(bytes), do: :erlang.float_to_binary(bytes / 1_000_000, decimals: 1)

  defp chain(path) do
    Enum.map_join(path, " -> ", fn
      {{n, a}, nil} -> "#{n}/#{a}"
      {{n, a}, 1} -> "#{n}/#{a} (1 call site)"
      {{n, a}, s} -> "#{n}/#{a} (#{s} call sites)"
    end)
  end

  # the chain from `entry` to `k` along which the most copies come, as
  # [{kernel, call sites in the one before}]: walking back from `k`, the
  # caller giving it the most copies
  defp path_back(entry, entry, _copies, _graph, acc), do: [{entry, nil} | acc]

  defp path_back(k, entry, copies, graph, acc) do
    caller =
      copies
      |> Enum.flat_map(fn {c, n} ->
        case graph[c] do
          {_, %{^k => s}} -> [{c, s, n * s}]
          _ -> []
        end
      end)
      |> Enum.reject(fn {c, _, _} -> Enum.any?(acc, &(elem(&1, 0) == c)) or c == k end)
      |> Enum.max_by(fn {c, _, w} -> {w, c} end, fn -> nil end)

    case caller do
      {c, s, _} -> path_back(c, entry, copies, graph, [{k, s} | acc])
      nil -> [{k, nil} | acc]
    end
  end

  defp count(n) when n < 1000, do: Integer.to_string(n)

  defp count(n) do
    rest = n |> rem(1000) |> Integer.to_string() |> String.pad_leading(3, "0")
    "#{count(div(n, 1000))},#{rest}"
  end

  # every term Macro.prewalk visits: calls, variables, literals, lists
  defp nodes(body) do
    {_, n} = Macro.prewalk(body, 0, fn node, n -> {node, n + 1} end)
    n
  end

  # call sites of other kernels in `body`, by callee
  defp sites(body, keys) do
    {_, sites} =
      Macro.prewalk(body, %{}, fn
        {name, _, args} = node, acc when is_atom(name) and is_list(args) ->
          key = {name, length(args)}

          {node, if(MapSet.member?(keys, key), do: Map.update(acc, key, 1, &(&1 + 1)), else: acc)}

        node, acc ->
          {node, acc}
      end)

    sites
  end

  defp line(head) do
    {_, line} =
      Macro.prewalk(head, nil, fn
        {_, m, _} = node, nil when is_list(m) -> {node, m[:line]}
        node, acc -> {node, acc}
      end)

    line || 0
  end
end
