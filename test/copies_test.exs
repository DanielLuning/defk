# Defk.Copies is one home for the copy analysis: the rules deciding whether
# an array write reuses its buffer or copies first. Each rule an earlier
# regression fix established is restated here as a one-assertion unit case against the rule itself — what used to need a
# compiled module and a grep of its C. value_semantics_test.exs stays the
# end-to-end net proving the lowering applies these decisions and the
# runtime contract holds.
defmodule Defk.CopiesTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Defk.Copies

  # reads_outside(taken(stmt, node), node): the names statement `stmt` still
  # reads, as it runs when `node` runs, outside node itself
  defp still_read(stmt, node) do
    Copies.reads_outside(Copies.taken(stmt, node), node)
  end

  describe "what counts as a read after a write (taken/other_arms_out)" do
    test "a sibling arm's reads do not count: they run instead" do
      node = quote do: helper(a)
      stmt = quote do: if(keep, do: unquote(node), else: g(b))

      refute "b" in Enum.map(still_read(stmt, node), &to_string/1)
    end

    test "the branch's own condition ran before the arm and does not count" do
      node = quote do: helper(a)
      stmt = quote do: if(a[0] > lim, do: unquote(node), else: 0)

      assert still_read(stmt, node) == MapSet.new()
    end

    test "a case subject and the clause heads that chose the arm do not count" do
      node = quote do: helper(a)

      stmt =
        quote do
          case probe(a) do
            x when x > lim -> unquote(node)
            _ -> fallback(b)
          end
        end

      refute :a in still_read(stmt, node)
      refute :b in still_read(stmt, node)
    end

    test "a read beside the arm, in the same statement, still counts" do
      node = quote do: helper(a)
      stmt = quote do: f(if(keep, do: unquote(node), else: 0), peek(c))

      assert :c in still_read(stmt, node)
    end

    test "a node appearing twice is not an arm: the whole statement counts" do
      node = quote do: helper(a)
      stmt = quote do: if(keep, do: unquote(node), else: unquote(node))

      refute Copies.arm?(stmt, node)
      assert Copies.taken(stmt, node) == stmt
    end
  end

  describe "a loop's first range is read before the first write" do
    # `for k <- 0..(st[0] - 1)//1, reduce: st`: the range is evaluated once,
    # before the body writes anything, so st is not read during the loop
    test "the first generator's range does not read during the loop" do
      [gen] = extract_quals("for k <- 0..(st[0] - 1)//1, reduce: st, do: (acc -> acc)")
      assert Copies.quals_reads([gen]) == MapSet.new()
    end

    test "an array the first generator walks is read during the loop" do
      [gen] = extract_quals("for x <- st, reduce: st, do: (acc -> acc)")
      assert :st in Copies.quals_reads([gen])
    end

    test "later generators and filters are read during the loop" do
      quals = extract_quals("for k <- 0..9//1, x <- other, x > lim, reduce: st, do: (acc -> acc)")
      reads = Copies.quals_reads(quals)
      assert :other in reads and :lim in reads
    end

    defp extract_quals(src) do
      {:for, _, args} = Code.string_to_quoted!(src)
      Enum.reject(args, &(is_list(&1) and Keyword.keyword?(&1)))
    end
  end

  describe "liveness by name, per block (live_after/binds/stmt_reads)" do
    test "a name is live until read for the last time, and a rebind kills it" do
      es =
        quote do
          a = f(x)
          a = g(a)
          h(a)
        end
        |> elem(2)

      [l1, l2, l3] = Copies.live_after(es)
      assert :a in l1 and :a in l2
      refute :a in l3
    end

    test "an array write is not a bind: the name stays the same binding" do
      write = Code.string_to_quoted!("a[i] = v")
      assert Copies.write?(write)
      assert Copies.binds(write) == MapSet.new()
      # the write reads a, i and v
      assert Copies.stmt_reads(write) == MapSet.new([:a, :i, :v])
    end
  end

  describe "nested writes (hoist's targets)" do
    test "a variable written in a branch, bound outside, is a nested write" do
      stmt = Code.string_to_quoted!("if keep do st[0] = 1 end")
      assert Copies.nested_writes(stmt) == [:st]
    end

    test "a name bound again inside before the write is not (its buffer is the block's)" do
      stmt = Code.string_to_quoted!("if keep do st = alloc(f64, 3); st[0] = 1 end")
      assert Copies.nested_writes(stmt) == []
    end

    test "the statement's own write is not a nested write" do
      assert Copies.nested_writes(Code.string_to_quoted!("a[i] = v")) == []
    end
  end

  describe "the tracking state (alias classes, carrying, the writes log)" do
    # Defk.Copies is pure: state in, state out (the compiler keeps the
    # current state as one field of its lowering ctx)

    test "merge_bufs makes the arms' buffers one class, transitively" do
      [b1, b2, b3] = [make_ref(), make_ref(), make_ref()]
      {merged, st} = Copies.merge_bufs(Copies.new(), [b1, b2])

      assert Copies.same_buf?(st, b1, b2)
      assert Copies.same_buf?(st, b1, merged)
      refute Copies.same_buf?(st, b1, b3)

      # merging a class with a third buffer carries the earlier members along
      {_, st} = Copies.merge_bufs(st, [b2, b3])
      assert Copies.same_buf?(st, b1, b3)
    end

    test "shared?: another live binding of the same class, and only another" do
      [buf, id, other] = [make_ref(), make_ref(), make_ref()]
      a = %{buf: buf, id: id}
      st = Copies.new()

      refute Copies.shared?(st, a, MapSet.new([{id, buf}]))
      assert Copies.shared?(st, a, MapSet.new([{other, buf}]))
      refute Copies.shared?(st, a, MapSet.new([{other, make_ref()}]))
    end

    test "carried buffers carry transitively until cut" do
      [b1, b2, b3] = [make_ref(), make_ref(), make_ref()]
      {^b2, st} = Copies.carried(Copies.new(), b2, b1)
      {^b3, st} = Copies.carried(st, b3, b2)

      assert Copies.carries?(st, b3, b1)
      st = Copies.cut_carry(st, b3)
      refute Copies.carries?(st, b3, b1)
      assert Copies.carries?(st, b2, b1)
    end

    test "the writes log swaps around an inlined callee" do
      [id, buf] = [make_ref(), make_ref()]
      st = Copies.record_write(Copies.new(), id, buf, :w1)

      {outer, st} = Copies.swap_writes(st, [])
      st = Copies.record_write(st, id, buf, :w2)
      assert [{^id, ^buf, :w2}] = Copies.writes(st)

      {_, st} = Copies.swap_writes(st, outer)
      assert [{^id, ^buf, :w1}] = Copies.writes(st)
    end
  end

  describe "the liveness scope (where the lowering is, asked before a write)" do
    # bindings of two owned arrays; `b` shares `a`'s buffer, as `b = a` binds
    defp bindings do
      a = %{id: make_ref(), buf: make_ref(), owned: true, depth: 1}
      b = %{id: make_ref(), buf: a.buf, owned: true, depth: 1}
      %{a: a, b: b}
    end

    defp stmts({:__block__, _, es}), do: es

    # the scope at statement `e` of the kernel's body block `es`
    defp at(es, e, vars) do
      body = Copies.nested(Copies.scope(MapSet.new()), {:__block__, [], es}, vars)
      live = es |> Copies.live_after() |> Enum.at(Enum.find_index(es, &(&1 == e)))
      Copies.enter_stmt(body, e, Copies.live_names(e, live), vars)
    end

    # the scope at the one statement of a nested block, `inner` its scope
    defp in_block(inner, e, vars), do: Copies.enter_stmt(inner, e, MapSet.new(), vars)

    test "a write copies when another binding of the buffer is read later" do
      vars = bindings()

      es =
        stmts(
          quote do:
                  (
                    b = a
                    a[0] = 1
                    b[0]
                  )
        )

      [_, write, _] = es
      assert Copies.must_copy?(Copies.new(), at(es, write, vars), vars.a)
    end

    test "a write is in place when nothing else reads the buffer later" do
      vars = bindings()

      es =
        stmts(
          quote do:
                  (
                    b = a
                    a[0] = 1
                    a[0]
                  )
        )

      [_, write, _] = es
      refute Copies.must_copy?(Copies.new(), at(es, write, vars), vars.a)
    end

    test "an input array always copies" do
      vars = bindings()

      es =
        stmts(
          quote do:
                  (
                    a[0] = 1
                    a[0]
                  )
        )

      assert Copies.must_copy?(Copies.new(), at(es, hd(es), vars), %{vars.a | owned: false})
    end

    test "an arm leaves out what its other arms read" do
      vars = bindings()

      es =
        stmts(
          quote do
            b = a

            if c do
              a[0] = 1
            else
              b[0]
            end
          end
        )

      [_, {:if, _, [_, [do: arm, else: _]]} = stmt] = es
      inner = Copies.nested(at(es, stmt, vars), arm, vars)
      refute Copies.must_copy?(Copies.new(), in_block(inner, arm, vars), vars.a)
    end

    test "a loop body sees what its statement reads, for the next iteration" do
      vars = bindings()

      es =
        stmts(
          quote do
            b = a

            for _ <- 0..1 do
              a[0] = b[0]
            end
          end
        )

      [_, {:for, _, [_, [do: body]]} = stmt] = es
      inner = Copies.nested(at(es, stmt, vars), body, vars)
      assert Copies.must_copy?(Copies.new(), in_block(inner, body, vars), vars.a)
    end

    test "a nested block is one deeper; leave_block/3 rebinds what it bound at the outer depth" do
      vars = bindings()

      es =
        stmts(
          quote do:
                  (
                    a[0] = 1
                    a[0]
                  )
        )

      outer = at(es, hd(es), vars)
      inner = Copies.nested(outer, hd(es), vars)
      assert Copies.depth(outer) == 1
      assert Copies.depth(inner) == 2

      bound = Map.put(vars, :c, %{vars.a | depth: Copies.depth(inner)})
      left = Copies.leave_block(bound, inner, outer)
      assert left.c.depth == Copies.depth(outer)
      assert left.a.depth == 1
    end

    test "a loop guards the arrays read after it, until one is unguarded" do
      vars = bindings()

      es =
        stmts(
          quote do
            for _ <- 0..1 do
              b[0]
            end

            a[0]
          end
        )

      scope = Copies.loop(at(es, hd(es), vars), hd(es), vars)
      assert Copies.guarded?(scope, :a)
      refute Copies.guarded?(scope, :b)
      refute Copies.guarded?(Copies.unguard(scope, :a), :a)
      assert Copies.loop_of(scope) == hd(es)
    end

    test "an inlined callee starts with what the caller reads after and beside the call" do
      vars = bindings()

      es =
        stmts(
          quote do:
                  (
                    x = f(a) + b[0]
                    x
                  )
        )

      [{:=, _, [_, {:+, _, [call, _]}]} = stmt, _] = es
      callee = Copies.inline_call(at(es, stmt, vars), call, vars)
      assert {vars.b.id, vars.b.buf} in Copies.live(callee)
      refute {vars.a.id, vars.a.buf} in Copies.live(callee)
    end
  end

  describe "arm_reads/2, nested/3's one pass" do
    # the spec: arm?/2, then reads_outside(taken(stmt, node), node)
    defp spec(stmt, node),
      do: if(Copies.arm?(stmt, node), do: Copies.reads_outside(Copies.taken(stmt, node), node))

    # statements of variables, calls, matches, blocks and nested if, cond
    # and case; few names, so equal subterms (a node twice) are common
    defp stmt_gen do
      leaf = StreamData.member_of([:a, :b, :c, :d] |> Enum.map(&{&1, [], nil}))

      StreamData.tree(leaf, fn inner ->
        StreamData.one_of([
          StreamData.map(StreamData.list_of(inner, max_length: 2), &{:f, [], &1}),
          StreamData.map({leaf, inner}, fn {v, e} -> {:=, [], [v, e]} end),
          StreamData.map(
            StreamData.list_of(inner, min_length: 1, max_length: 3),
            &{:__block__, [], &1}
          ),
          StreamData.map({inner, inner, inner}, fn {c, t, e} ->
            {:if, [], [c, [do: t, else: e]]}
          end),
          StreamData.map({inner, inner}, fn {c, t} -> {:if, [], [c, [do: t]]} end),
          StreamData.map({inner, inner, inner}, fn {c, t, e} ->
            {:cond, [], [[do: [{:->, [], [[c], t]}, {:->, [], [[true], e]}]]]}
          end),
          StreamData.map({inner, leaf, inner, inner}, fn {s, p, t, e} ->
            {:case, [], [s, [do: [{:->, [], [[p], t]}, {:->, [], [[{:_, [], nil}], e]}]]]}
          end)
        ])
      end)
    end

    defp subterms(ast) do
      {_, acc} = Macro.prewalk(ast, [], &{&1, [&1 | &2]})
      acc
    end

    property "gives what the spec gives, for every subterm of a statement" do
      check all(stmt <- stmt_gen(), max_runs: 300) do
        for node <- subterms(stmt) do
          assert Copies.arm_reads(stmt, node) == spec(stmt, node),
                 "stmt #{Macro.to_string(stmt)}, node #{inspect(node)}"
        end
      end
    end

    test "an arm read beside a branch in an expression, and an arm twice" do
      node = quote do: helper(a)
      stmt = quote do: f(if(keep, do: unquote(node), else: g(b)), peek(c))
      # keep chose the arm, g(b) runs instead of it: only c is read beside it
      assert Copies.arm_reads(stmt, node) == MapSet.new([:c])
      assert Copies.arm_reads(stmt, node) == spec(stmt, node)

      twice = quote do: if(keep, do: unquote(node), else: unquote(node))
      assert Copies.arm_reads(twice, node) == nil
    end
  end
end
