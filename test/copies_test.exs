# Defk.Copies is one home for the copy analysis: the rules deciding whether
# an array write reuses its buffer or copies first (defk-z8y). Each rule the
# regression tickets defk-33b, defk-tif and defk-8tw fixed is restated here
# as a one-assertion unit case against the rule itself — what used to need a
# compiled module and a grep of its C. value_semantics_test.exs stays the
# end-to-end net proving the lowering applies these decisions and the
# runtime contract holds.
defmodule Defk.CopiesTest do
  use ExUnit.Case, async: true

  alias Defk.Copies

  # reads_outside(taken(stmt, node), node): the names statement `stmt` still
  # reads, as it runs when `node` runs, outside node itself
  defp still_read(stmt, node) do
    Copies.reads_outside(Copies.taken(stmt, node), node)
  end

  describe "what counts as a read after a write (taken/other_arms_out)" do
    test "a sibling arm's reads do not count: they run instead (defk-33b)" do
      node = quote do: helper(a)
      stmt = quote do: if(keep, do: unquote(node), else: g(b))

      refute "b" in Enum.map(still_read(stmt, node), &to_string/1)
    end

    test "the branch's own condition ran before the arm and does not count (defk-tif)" do
      node = quote do: helper(a)
      stmt = quote do: if(a[0] > lim, do: unquote(node), else: 0)

      assert still_read(stmt, node) == MapSet.new()
    end

    test "a case subject and the clause heads that chose the arm do not count (defk-tif)" do
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

  describe "a loop's first range is read before the first write (defk-8tw)" do
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
end
