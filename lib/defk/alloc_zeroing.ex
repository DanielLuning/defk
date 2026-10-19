defmodule Defk.AllocZeroing do
  # The unzeroed-allocation recogniser (CONTEXT.md, "Unzeroed allocation"):
  # whether the loop after an `alloc` provably writes every element before
  # anything reads it, so the runtime can skip the zero fill. Pure AST
  # analysis: statements in, the same statements out with each such alloc
  # marked. The compiler (alloc_zeroed/4) emits the raw alloc for a marked
  # one; the decision itself is here, in one place, with its own test.
  @moduledoc false

  @doc """
  The statements `es` of a block, each `x = alloc(e, len)` marked (meta
  `:defk_unzeroed`, `{loop_meta, extents}`) when a later statement writes
  every element of x before anything reads it. `loop_meta` is the writing
  loop's AST metadata (its line is for the fast-path report); `extents` are
  those of a nested form (`nested_all?/3`), `[]` for the strided one. Only
  one form is accepted:

      x = alloc(e, k * n)              # or alloc(e, n), k = 1
      ...                              # statements that do not mention x
      for i <- 0..(n - 1)//1 do        # or 0..(n - 1); length(x) - 1 for k = 1
        ...
        x[k * i + c] = v               # for each c in 0..k-1 exactly once
        ...
      end

  where the statements in between do not mention x and bind no variable of
  n (so the range's n is the alloc's), the writes are statements of the
  loop body itself (not in a branch), x is not otherwise mentioned in the
  body (no read, no alias, no length/1), n does not mention x, and nothing in
  the body binds i (so each write's i is the loop's). Then each trip i
  writes k * i .. k * i + k - 1, and the trips 0..n-1 write all k * n
  elements; nothing reads x until the loop is done. Every way out before
  that is a raise, which frees the buffer, and a yield resumes where it
  left off with x unread, so no unwritten element is ever seen. With
  `0..(n - 1)` (step -1 when n < 1) a trip writes x[0] first, which raises
  for n < 1 (k * n < k). Anything else is zeroed.
  """
  @spec mark([Macro.t()]) :: [Macro.t()]
  def mark(es) do
    es
    |> Enum.with_index(1)
    |> Enum.map(fn {e, j} ->
      case {e, unzeroed_by(e, Enum.drop(es, j))} do
        {{:=, m, [x, {:alloc, am, args}]}, {_, _} = unzeroed} ->
          {:=, m, [x, {:alloc, [{:defk_unzeroed, unzeroed} | am], args}]}

        _ ->
          e
      end
    end)
  end

  # {loop_meta, extents} of the loop in `rest` (the statements after the
  # alloc `e`) that writes every element of e's array first, or nil; the
  # extents are those of a nested form (nested_all?/3), [] for the strided
  # one
  defp unzeroed_by({:=, _, [{x, _, xc}, {:alloc, _, [{_, _, ec}, len]}]}, rest)
       when is_atom(x) and is_atom(xc) and is_atom(ec) do
    {between, from} = Enum.split_while(rest, &(not mentions?(&1, x)))
    len_vars = vars(len)

    with [loop | _] <- from,
         false <- Enum.any?(between, fn s -> Enum.any?(len_vars, &binds?(s, &1)) end) do
      writes_all(loop, x, len)
    else
      _ -> nil
    end
  end

  defp unzeroed_by(_e, _rest), do: nil

  # the meta of `loop` if it writes all of x: the strided single loop above,
  # plain or `reduce:` (the loop may be the right side of a match whose left
  # side does not mention x, as `{h, t} = for ..., reduce: {h, t}`), or a
  # nest of range loops writing a row-major index (nested_all?/3)
  defp writes_all({:=, _, [lhs, {:for, _, _} = loop]}, x, len) do
    if mentions?(lhs, x), do: nil, else: writes_all(loop, x, len)
  end

  defp writes_all({:for, fm, args} = loop, x, len) do
    with {:ok, gens, [], init, pat, body} <- loop_parts(args),
         false <- mentions?(len, x) or mentions?(init, x) or mentions?(pat, x),
         {:ok, extents} <-
           if(strided_all?(gens, pat, body, x, len),
             do: {:ok, []},
             else: nested_all?(loop, x, len)
           ) do
      {fm, extents}
    else
      _ -> nil
    end
  end

  defp writes_all(_loop, _x, _len), do: nil

  # {:ok, generators, filters, init, pattern, body statements} of a for's
  # arguments: a plain `do:` (init and pattern nil) or a `reduce:` with one
  # clause whose pattern is bound per trip. A generator binds a plain
  # variable; anything else among the qualifiers is a filter here.
  defp loop_parts(args) do
    # `reduce: init` is a keyword list of its own, before the do block's
    {quals, opts} = Enum.split_with(args, &(not Keyword.keyword?(&1)))
    opts = Enum.concat(opts)

    {gens, filters} =
      Enum.split_with(quals, &match?({:<-, _, [{v, _, c}, _]} when is_atom(v) and is_atom(c), &1))

    case {Enum.sort(Keyword.keys(opts)), opts[:do]} do
      {[:do], body} ->
        {:ok, gens, filters, nil, nil, block_stmts(body)}

      {[:do, :reduce], [{:->, _, [[pat], body]}]} ->
        {:ok, gens, filters, opts[:reduce], pat, block_stmts(body)}

      _ ->
        :error
    end
  end

  defp block_stmts({:__block__, _, ss}), do: ss
  defp block_stmts(s), do: [s]

  # one generator over 0..(n - 1)//1 whose body writes x[k * i + c] for every
  # c in 0..k-1 at its top level and mentions x nowhere else (for a reduce:
  # the clause pattern binds neither x nor i; the fold's value may be
  # anything, as the writes are statements of the clause body, which runs
  # every trip)
  defp strided_all?([{:<-, _, [{i, _, _}, range]}], pat, body, x, len) when i != x do
    {k, n} =
      case len do
        {:*, _, [k, n]} when is_integer(k) and k >= 1 -> {k, n}
        n -> {1, n}
      end

    cs = for s <- body, c = unzeroed_write(s, x, i, k), do: c

    zero_based_to(range, n, x, k) and Enum.sort(cs) == Enum.to_list(0..(k - 1)) and
      count_var(body, x) == k and not binds?(body, i) and not mentions?(pat, i)
  end

  defp strided_all?(_gens, _pat, _body, _x, _len), do: false

  # Nested range loops: at every level `for v <- 0..(n - 1)//1` (several
  # generators in one for are successive levels), the inner for a statement
  # of the outer body, and the innermost body writing
  # x[((v1 * n2 + v2) * n3 + v3) ...] once, as a statement of its own. The
  # alloc's length is the product of the extents, in any order. Every trip
  # writes one element, the trips write the elements 0..n1*...*nm-1 each
  # once (an extent of 0 makes both empty; a negative one makes the alloc
  # raise), nothing else in the nest mentions x, and no body binds a loop
  # variable or a variable of the length, so the extents are the alloc's.
  defp nested_all?(loop, x, len) do
    with {:ok, levels, body} <- nest_levels(loop, x, len, []),
         extents = Enum.map(levels, &elem(&1, 1)),
         true <- permutation?(product_factors(len), extents),
         [idx] <-
           for(
             {:=, _, [{{:., _, [Access, :get]}, _, [{^x, _, c}, idx]}, _]} <- body,
             is_atom(c),
             do: idx
           ),
         true <- row_major?(idx, levels) and count_var(loop, x) == 1 do
      {:ok, extents}
    else
      _ -> :error
    end
  end

  # {:ok, [{var, extent}] outermost first, innermost body statements}
  defp nest_levels({:for, _, args}, x, len, acc) do
    with {:ok, gens, [], nil, nil, body} <- loop_parts(args),
         {:ok, vars} <- level_vars(gens, x),
         levels = acc ++ vars,
         names = Enum.map(levels, &elem(&1, 0)),
         true <- Enum.uniq(names) == names,
         false <- Enum.any?(names ++ MapSet.to_list(vars(len)), &binds?(body, &1)) do
      case Enum.split_with(body, &match?({:for, _, _}, &1)) do
        {[inner], others} ->
          if mentions?(others, x), do: :error, else: nest_levels(inner, x, len, levels)

        {[], _} ->
          {:ok, levels, body}

        _ ->
          :error
      end
    else
      _ -> :error
    end
  end

  defp level_vars(gens, x) do
    vars =
      for {:<-, _, [{v, _, _}, {:..//, _, [0, {:-, _, [n, 1]}, 1]}]} <- gens,
          v != x and not mentions?(n, x),
          do: {v, n}

    if length(vars) == length(gens), do: {:ok, vars}, else: :error
  end

  # idx is the row-major index of the levels' variables with their extents
  defp row_major?({v, _, c}, [{v, _}]) when is_atom(c), do: true

  defp row_major?({:+, _, [{:*, _, [inner, n]}, {v, _, c}]}, levels) when is_atom(c) do
    case List.pop_at(levels, -1) do
      {{^v, extent}, outer} when outer != [] -> same_ast?(n, extent) and row_major?(inner, outer)
      _ -> false
    end
  end

  defp row_major?(_idx, _levels), do: false

  defp product_factors({:*, _, [a, b]}), do: product_factors(a) ++ product_factors(b)
  defp product_factors(t), do: [t]

  # the same terms, in any order
  defp permutation?(as, bs) when length(as) == length(bs) do
    Enum.reduce_while(bs, as, fn b, rest ->
      case Enum.find_index(rest, &same_ast?(&1, b)) do
        nil -> {:halt, :no}
        i -> {:cont, List.delete_at(rest, i)}
      end
    end) == []
  end

  defp permutation?(_as, _bs), do: false

  # `range` is 0..(n - 1)//1 or 0..(n - 1), or for k = 1 also with length(x) - 1
  defp zero_based_to({:..//, _, [0, stop, 1]}, n, x, k), do: stop_at(stop, n, x, k)
  defp zero_based_to({:.., _, [0, stop]}, n, x, k), do: stop_at(stop, n, x, k)
  defp zero_based_to(_range, _n, _x, _k), do: false

  defp stop_at({:-, _, [m, 1]}, n, x, k) do
    same_ast?(m, n) or (k == 1 and match?({:length, _, [{^x, _, c}]} when is_atom(c), m))
  end

  defp stop_at(_stop, _n, _x, _k), do: false

  # c when `s` is x[k * i + c] = v (x[i] = v for k = 1, x[k * i] for c = 0)
  defp unzeroed_write({:=, _, [{{:., _, [Access, :get]}, _, [{x, _, xc}, idx]}, _]}, x, i, k)
       when is_atom(xc) do
    case idx do
      {^i, _, c} when is_atom(c) and k == 1 -> 0
      {:*, _, [^k, {^i, _, c}]} when is_atom(c) -> 0
      {:+, _, [{:*, _, [^k, {^i, _, c}]}, d]} when is_atom(c) and is_integer(d) -> d
      _ -> nil
    end
  end

  defp unzeroed_write(_s, _x, _i, _k), do: nil

  defp same_ast?(a, b), do: strip_meta(a) == strip_meta(b)
  defp strip_meta(ast), do: Macro.prewalk(ast, &Macro.update_meta(&1, fn _ -> [] end))

  defp mentions?(ast, x), do: count_var(ast, x) > 0

  defp vars(ast) do
    {_, vs} =
      Macro.prewalk(ast, MapSet.new(), fn
        {v, _, c} = t, vs when is_atom(v) and is_atom(c) -> {t, MapSet.put(vs, v)}
        t, vs -> {t, vs}
      end)

    vs
  end

  defp count_var(ast, x) do
    {_, n} =
      Macro.prewalk(ast, 0, fn
        {^x, _, c} = v, n when is_atom(c) -> {v, n + 1}
        t, n -> {t, n}
      end)

    n
  end

  # whether anything in `ast` binds a variable named `i`: a match (other than
  # an array write), a generator, or a clause pattern (case, reduce arms)
  defp binds?(ast, i) do
    {_, found} =
      Macro.prewalk(ast, false, fn
        {:=, _, [{{:., _, [Access, :get]}, _, _}, _]} = t, f -> {t, f}
        {:=, _, [lhs, _]} = t, f -> {t, f or mentions?(lhs, i)}
        {:<-, _, [pat, _]} = t, f -> {t, f or mentions?(pat, i)}
        {:->, _, [pats, _]} = t, f -> {t, f or mentions?(pats, i)}
        t, f -> {t, f}
      end)

    found
  end
end
