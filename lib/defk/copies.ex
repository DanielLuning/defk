defmodule Defk.Copies do
  # The copy analysis: how the compiler decides whether a kernel's array
  # write reuses the buffer or copies it first. This module is one home for
  # the rules — what counts as a read after a write (three fixes landed in
  # three different shards of this concept when it lived in two compiler
  # sections 3,300 lines apart) — and,
  # from phase B on, for the write/alias tracking state. Decisions out: the
  # C emission of the copies it calls for stays in the lowering.
  @moduledoc false

  # ------------------------------------------------- the tracking state ---
  # What one kernel's lowering has recorded so far: the writes log (for
  # unreturned_writes!), buffer carrying (:from, a copy or accumulator holds
  # what its source held) and alias classes (buffers an if/cond/case made
  # indistinguishable). The module is pure: state in, state out; the
  # compiler keeps the current state as one field of its lowering ctx, so
  # its backtracking snapshot covers it.

  defstruct writes: [], from: %{}, alias: %{}

  def new, do: %__MODULE__{}

  # an array write `a[i] = v` happened on binding `id` of buffer `buf`
  def record_write(st, id, buf, target),
    do: %{st | writes: [{id, buf, target} | st.writes]}

  # every write so far, oldest first
  def writes(st), do: Enum.reverse(st.writes)

  # replace the writes log, giving back the old one: inlining lowers the
  # callee under its own log and restores the caller's after
  def swap_writes(st, new), do: {st.writes, %{st | writes: new}}

  # Buffers that may be one buffer. The array an if, cond or case
  # gives is one of its arms' arrays, which the compiler can't tell apart, so
  # their buffers are merged into one alias class, and bindings of any of
  # them may share a buffer from then on (flow-insensitively, for the rest of
  # the kernel: conservative, it may copy where it need not). A buffer not
  # in the map is its own class.
  def alias_class(_st, nil), do: nil
  def alias_class(st, buf), do: Map.get(st.alias, buf, buf)

  def same_buf?(st, a, b), do: a != nil and alias_class(st, a) == alias_class(st, b)

  # one alias class for buffers `bufs` (nil for an array of no binding's,
  # such as alloc/2's): returns it, a new buffer for the merged value
  def merge_bufs(st, bufs) do
    new = make_ref()
    classes = for b <- bufs, b != nil, uniq: true, do: alias_class(st, b)
    m = Map.new(st.alias, fn {b, c} -> {b, if(c in classes, do: new, else: c)} end)
    {new, %{st | alias: Enum.reduce(classes, m, &Map.put(&2, &1, new))}}
  end

  # another live binding may see array a's buffer
  def shared?(st, a, live) do
    buf = alias_class(st, a[:buf])
    buf != nil and Enum.any?(live, fn {id, b} -> alias_class(st, b) == buf and id != a[:id] end)
  end

  # Buffer `new` holds what buffer `old` held (a copy of it, or a loop
  # accumulator started from it): a write to `old` is carried into `new`.
  # Recorded for unreturned_writes!/3; `new` is returned.
  def carried(st, new, nil), do: {new, st}

  def carried(st, new, old),
    do: {new, %{st | from: Map.update(st.from, new, [old], fn l -> [old | l] end)}}

  # buffer `buf` is `old`, or holds what `old` held
  def carries?(st, buf, old), do: carries?(st, [buf], old, %{})

  defp carries?(_st, [], _old, _seen), do: false
  defp carries?(_st, [old | _], old, _seen), do: true

  defp carries?(st, [b | rest], old, seen) do
    if b == nil or Map.has_key?(seen, b),
      do: carries?(st, rest, old, seen),
      else: carries?(st, Map.get(st.from, b, []) ++ rest, old, Map.put(seen, b, true))
  end

  # A loop accumulator that may take a new value not carrying its buffer
  # before (an alloc/2 array, say) no longer carries its initial value.
  def cut_carry(st, buf), do: %{st | from: Map.delete(st.from, buf)}

  # ----------------------------------------------------- reads and arms ---

  # `ast` is one arm of an if, cond or case in `stmt`, and nowhere else in it
  def arm?(nil, _ast), do: false

  def arm?(stmt, ast) do
    occurrences(stmt, ast) == 1 and
      elem(Macro.prewalk(stmt, false, &{&1, &2 or ast in arms(&1)}), 1)
  end

  def occurrences(ast, node) do
    {_, n} = Macro.prewalk(ast, 0, fn x, n -> {x, if(x == node, do: n + 1, else: n)} end)
    n
  end

  # Statement `stmt` as it runs when `node` does, from the arm holding it on:
  # every if, cond and case arm that is an alternative to that arm is left
  # out, and so are the conditions, subjects and clause heads that chose it
  # (evaluated before it, in the same run of the statement; a later iteration
  # reads the arm's new bindings, not the buffers it had). `stmt` whole when
  # `node` is not exactly once in it.
  def taken(stmt, node) do
    if occurrences(stmt, node) == 1,
      do: Macro.prewalk(stmt, &if(holds_arm?(&1, node), do: other_arms_out(&1, node), else: &1)),
      else: stmt
  end

  # `x` is an if, cond or case with `node` in one of its arms
  def holds_arm?(x, node), do: Enum.any?(arms(x), &(occurrences(&1, node) > 0))

  # the arm bodies of an if, cond or case node
  def arms({:if, _, [_c, kw]}) when is_list(kw), do: for({k, b} <- kw, k in [:do, :else], do: b)

  def arms({:cond, _, [[do: clauses]]}) when is_list(clauses),
    do: for({:->, _, [_, body]} <- clauses, do: body)

  def arms({:case, _, [_subject, [do: clauses]]}) when is_list(clauses),
    do: for({:->, _, [_, body]} <- clauses, do: body)

  def arms(_ast), do: []

  def other_arms_out({:if, m, [_c, kw]}, node),
    do: {:if, m, [nil, for({k, b} <- kw, do: {k, arm_or_nil(b, node)})]}

  def other_arms_out({:cond, m, [[do: clauses]]}, node),
    do: {:cond, m, [[do: clauses_out(clauses, node)]]}

  def other_arms_out({:case, m, [_subject, [do: clauses]]}, node),
    do: {:case, m, [nil, [do: clauses_out(clauses, node)]]}

  def clauses_out(clauses, node) do
    for {:->, cm, [_head, body]} <- clauses, do: {:->, cm, [[nil], arm_or_nil(body, node)]}
  end

  def arm_or_nil(body, node), do: if(occurrences(body, node) == 0, do: nil, else: body)

  # The names read in `ast`, over-approximated: every variable in it, in any
  # branch or loop body, except the ones a match binds.
  def reads(ast), do: ast |> read_counts() |> Map.keys() |> MapSet.new()

  def read_counts(ast) do
    {_, counts} =
      Macro.prewalk(ast, %{}, fn
        # the variables a match binds are not read
        {:=, m, [_lhs, rhs]} = e, acc ->
          {if(write?(e), do: e, else: {:__block__, m, [rhs]}), acc}

        {n, _, ctx} = v, acc when is_atom(n) and is_atom(ctx) ->
          {v, Map.update(acc, n, 1, &(&1 + 1))}

        other, acc ->
          {other, acc}
      end)

    counts
  end

  # names read in statement `stmt` outside `node`, a part of it
  def reads_outside(nil, _node), do: MapSet.new()

  def reads_outside(stmt, node) do
    inner = read_counts(node)
    for {n, c} <- read_counts(stmt), c > Map.get(inner, n, 0), into: MapSet.new(), do: n
  end

  def write?({:=, _, [{{:., _, [Access, :get]}, _, _}, _]}), do: true
  def write?(_), do: false

  # the names statement `e` binds in its block
  def binds({:=, _, [lhs, _]} = e), do: if(write?(e), do: MapSet.new(), else: reads(lhs))
  def binds(_e), do: MapSet.new()

  def stmt_reads({:=, _, [_, rhs]} = e), do: if(write?(e), do: reads(e), else: reads(rhs))
  def stmt_reads(e), do: reads(e)

  # for each statement of a block, the names read after it in the block
  def live_after(es) do
    {lives, _} =
      List.foldr(es, {[], MapSet.new()}, fn e, {acc, live} ->
        {[live | acc], live |> MapSet.difference(binds(e)) |> MapSet.union(stmt_reads(e))}
      end)

    lives
  end

  # the names of the arrays written inside statement `e`, not by `e` itself,
  # leaving out a name bound again inside before the write
  def nested_writes(e) do
    if write?(e), do: [], else: e |> writes_in(MapSet.new()) |> Enum.uniq()
  end

  def writes_in({:__block__, _, es}, shadow) when is_list(es) do
    {ws, _} =
      Enum.flat_map_reduce(es, shadow, fn e, sh ->
        ws = writes_in(e, sh)
        {ws, if(match?({:=, _, _}, e), do: MapSet.union(sh, binds(e)), else: sh)}
      end)

    ws
  end

  def writes_in({:=, _, [{{:., _, [Access, :get]}, _, [arr, idx]}, rhs]}, shadow) do
    own =
      case arr do
        {n, _, ctx} when is_atom(n) and is_atom(ctx) -> if n in shadow, do: [], else: [n]
        _ -> []
      end

    own ++ writes_in([arr, idx, rhs], shadow)
  end

  def writes_in({:->, _, [pats, body]}, shadow),
    do: writes_in(body, MapSet.union(shadow, reads(pats)))

  def writes_in({a, b}, shadow), do: writes_in(a, shadow) ++ writes_in(b, shadow)
  def writes_in(l, shadow) when is_list(l), do: Enum.flat_map(l, &writes_in(&1, shadow))
  def writes_in({h, _, args}, shadow) when is_list(args), do: writes_in([h | args], shadow)
  def writes_in(_ast, _shadow), do: []

  # The outer names a loop's generators and filters read while it runs. The
  # first generator's range (start, end and step) is evaluated once, before
  # the first iteration and so before the body writes anything:
  # `for k <- 0..(st[0] - 1)//1, reduce: st` reads st's buffer before the
  # accumulator takes it, and later iterations read the accumulator. An array
  # the first generator walks, later generators (evaluated again for each
  # value of the ones before) and filters are read during the loop.
  def quals_reads([{:<-, _, [_pat, {op, _, [_ | _]}]} | rest]) when op in [:.., :..//],
    do: reads(rest)

  def quals_reads(quals), do: reads(quals)
end
