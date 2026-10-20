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

  # ---------------------------------------------------- the liveness scope --
  # Where the lowering is, for the copy decisions: the bindings live after
  # the current statement and after its block, the statement itself, the
  # innermost loop and the block depth. The compiler carries one scope in its
  # env (`env.scope`), replaced as it enters a statement, a nested block, a
  # loop or an inlined call; it is lexical, so a block's end restores the
  # scope around it. The bindings themselves (`vars`: name -> %{id, buf, ..})
  # stay the compiler's; a transition takes them where it resolves names to
  # {id, buf} pairs.

  defmodule Scope do
    @moduledoc false
    #   out        - {id, buf} live after the current block
    #   live       - {id, buf} live after the current statement
    #   nest       - {id, buf} live for blocks nested in the current statement
    #   live_names - the names read after the current statement in its block
    #   stmt       - the current statement
    #   guard      - array names a loop body must not bind again (read after it)
    #   loop       - the innermost loop construct
    #   depth      - block nesting, to check that an input array is copied in
    #                the block it is bound in
    defstruct out: MapSet.new(),
              live: MapSet.new(),
              nest: MapSet.new(),
              live_names: MapSet.new(),
              stmt: nil,
              guard: MapSet.new(),
              loop: nil,
              depth: 0
  end

  # The scope a kernel's body starts in: `outer` the {id, buf} live after the
  # whole body (none for a kernel; an inlined call's caller still reads some).
  def scope(outer), do: %Scope{out: outer, nest: outer, live: outer}

  def depth(%Scope{depth: d}), do: d
  def live(%Scope{live: l}), do: l
  def loop_of(%Scope{loop: l}), do: l

  # the loop around the scope reads array `name` after it: binding it again
  # inside is a rebind of the outer variable
  def guarded?(%Scope{guard: g}, name), do: name in g
  def unguard(%Scope{} = s, name), do: %{s | guard: MapSet.delete(s.guard, name)}

  # {id, buf} of the array bindings of `names` in `vars`
  def pairs(vars, names) do
    for n <- names, %{buf: buf, id: id} <- [vars[n]], into: MapSet.new(), do: {id, buf}
  end

  # the names read after statement `e` of its block, `live` the names read
  # after it (live_after/1): what `e` binds is a new binding, not one of them
  def live_names(e, live), do: MapSet.difference(live, binds(e))

  # Entering statement `e`, `names` the names read after it (live_names/2),
  # with `vars` the bindings after the copies hoisted before `e`: what is
  # live after `e`, and for the blocks nested in it (which also see what `e`
  # reads, as a later iteration or a later arm does).
  def enter_stmt(%Scope{} = s, e, names, vars) do
    live = MapSet.union(pairs(vars, names), s.out)
    nest = MapSet.union(live, pairs(vars, reads(e)))
    %{s | stmt: e, live: live, live_names: names, nest: nest}
  end

  # The scope of block `ast` nested in the statement `s` is at. An arm of an
  # if, cond or case runs instead of its other arms, so what they read is not
  # read after it, and the condition, subject and clause heads that chose it
  # ran before it: its live set is what is read after the statement, and what
  # the statement reads outside those. Any other nested block (a loop or fn
  # body, run again) keeps what is live for nested blocks.
  def nested(%Scope{} = s, ast, vars) do
    out =
      case arm_reads(s.stmt, ast) do
        nil -> s.nest
        names -> MapSet.union(s.live, pairs(vars, names))
      end

    %{s | out: out, depth: s.depth + 1}
  end

  # What nested/3 asks of statement `stmt`, in three linear walks: nil when
  # `node` is not an arm of it (arm?/2), else the names
  # reads_outside(taken(stmt, node), node) gives, the spec (copies_test
  # compares the two). taken/2 changes only the if, cond and case nodes on
  # the path to `node`, so cut/2 rebuilds that path with `node` cut out and
  # the rest shared, and what is read is what is left.
  def arm_reads(nil, _node), do: nil

  def arm_reads(stmt, node) do
    {_, found} =
      Macro.prewalk(stmt, {0, false}, fn x, {n, arm} ->
        {x, {if(x == node, do: n + 1, else: n), arm or node in arms(x)}}
      end)

    if found == {1, true}, do: stmt |> cut(node) |> elem(0) |> reads()
  end

  # {`x` with `node` (in it once) replaced by nil and each if, cond and case
  # holding it in an arm cut as other_arms_out/2 cuts it, whether `node` was
  # in `x`}; it walks what Macro.prewalk/3 walks
  defp cut(x, node) do
    if x == node, do: {nil, true}, else: cut_in(x, node)
  end

  # each part is walked once: an if, cond or case not holding `node` in an
  # arm is rebuilt from the parts already cut
  defp cut_in({:if, m, [c, kw]} = x, node) when is_list(kw) do
    {c2, in_c} = cut(c, node)
    parts = Enum.map(kw, &{&1, cut(&1, node)})

    cond do
      Enum.any?(parts, fn {e, {_, f}} -> f and match?({k, _} when k in [:do, :else], e) end) ->
        arms = for {{k, _}, {{_, b}, f}} <- parts, do: {k, if(f, do: b)}
        {{:if, m, [nil, arms]}, true}

      in_c or Enum.any?(parts, fn {_, {_, f}} -> f end) ->
        {{:if, m, [c2, Enum.map(parts, fn {_, {e, _}} -> e end)]}, true}

      true ->
        {x, false}
    end
  end

  defp cut_in({:cond, m, [[do: clauses]]} = x, node) when is_list(clauses) do
    case cut_clauses(clauses, node) do
      {:arm, out} -> {{:cond, m, [[do: out]]}, true}
      {:in, clauses2} -> {{:cond, m, [[do: clauses2]]}, true}
      :no -> {x, false}
    end
  end

  defp cut_in({:case, m, [subject, [do: clauses]]} = x, node) when is_list(clauses) do
    {subject2, in_s} = cut(subject, node)

    case cut_clauses(clauses, node) do
      {:arm, out} -> {{:case, m, [nil, [do: out]]}, true}
      {:in, clauses2} -> {{:case, m, [subject2, [do: clauses2]]}, true}
      :no when in_s -> {{:case, m, [subject2, [do: clauses]]}, true}
      :no -> {x, false}
    end
  end

  defp cut_in(x, node), do: cut_args(x, node)

  # {:arm, the clauses as clauses_out/2 gives them} when `node` is in a
  # clause body, {:in, the clauses cut} when it is elsewhere in them, :no
  defp cut_clauses(clauses, node) do
    parts =
      Enum.map(clauses, fn
        {:->, cm, [head, body]} -> {:clause, cm, cut(head, node), cut(body, node)}
        e -> {:other, cut(e, node)}
      end)

    cond do
      Enum.any?(parts, &match?({:clause, _, _, {_, true}}, &1)) ->
        {:arm, for({:clause, cm, _, {b, f}} <- parts, do: {:->, cm, [[nil], if(f, do: b)]})}

      Enum.any?(
        parts,
        &(match?({:clause, _, {_, true}, _}, &1) or match?({:other, {_, true}}, &1))
      ) ->
        {:in,
         Enum.map(parts, fn
           {:clause, cm, {h, _}, {b, _}} -> {:->, cm, [h, b]}
           {:other, {e, _}} -> e
         end)}

      true ->
        :no
    end
  end

  # Macro.prewalk/3's descent: a call's form (unless an atom) and its
  # arguments, both halves of a pair, every element of a list
  defp cut_args({form, m, args} = x, node) do
    {form2, f1} = if is_atom(form), do: {form, false}, else: cut(form, node)
    {args2, f2} = if is_list(args), do: cut_list(args, node), else: {args, false}
    if f1 or f2, do: {{form2, m, args2}, true}, else: {x, false}
  end

  defp cut_args({a, b} = x, node) do
    {a2, f1} = cut(a, node)
    {b2, f2} = cut(b, node)
    if f1 or f2, do: {{a2, b2}, true}, else: {x, false}
  end

  defp cut_args(l, node) when is_list(l), do: cut_list(l, node)
  defp cut_args(x, _node), do: {x, false}

  defp cut_list(l, node) do
    {l2, found} =
      Enum.map_reduce(l, false, fn e, f ->
        {e2, f2} = cut(e, node)
        {e2, f or f2}
      end)

    if found, do: {l2, true}, else: {l, false}
  end

  # Leaving a nested plain block, which binds into the scope around it as in
  # Elixir: `vars` the bindings at the block's end, now bound in the outer
  # block and so at its depth.
  def leave_block(vars, %Scope{depth: inner}, %Scope{depth: outer}) do
    Map.new(vars, fn
      {n, %{depth: ^inner} = b} -> {n, %{b | depth: outer}}
      kv -> kv
    end)
  end

  # The scope a loop's generators, filters and body are lowered in: what its
  # statement reads stays live (for the next iteration), and the arrays read
  # after the loop must not be bound again inside it.
  def loop(%Scope{} = s, node, vars) do
    live = MapSet.new(s.live, &elem(&1, 0))
    guard = for {n, %{id: id}} <- vars, id in live, into: s.guard, do: n
    %{s | live: s.nest, guard: guard, loop: node}
  end

  # {id, buf} live around `node`, a part of the current statement: what is
  # live after the statement, what the statement reads outside `node`, and
  # the names `more` (what a loop's generators read while it runs).
  def live_around(%Scope{} = s, node, vars, more \\ MapSet.new()) do
    MapSet.union(s.live, pairs(vars, MapSet.union(more, reads_outside(s.stmt, node))))
  end

  # the scope an inlined callee's body starts in: the bindings the caller
  # still reads after the call `node` stay live in the callee
  def inline_call(%Scope{} = s, node, vars), do: scope(live_around(s, node, vars))

  # Array `a` is written: in place when it is owned and no other binding
  # that may see its buffer is read later; else it is copied first.
  def must_copy?(st, %Scope{live: live}, a), do: not a.owned or shared?(st, a, live)

  # Binding `b` is bound outside the branches and loop bodies of the current
  # statement and written in them: it is copied before the statement if it
  # is an input array, or if another binding of its buffer is read in the
  # statement (`seen`, names) or after its block.
  def must_hoist?(st, %Scope{out: out}, b, seen, vars),
    do: not b.owned or shared?(st, b, MapSet.union(pairs(vars, seen), out))
end
