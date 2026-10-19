defmodule Defk.FormsTest do
  # The shape of a body form, parsed once for both modes (Defk.Forms): what
  # a for holds, what a case clause holds, the parts of the Enum forms, and
  # the rewrite of Enum.reduce/3 and Enum.find/3 into them. A shape outside
  # the subset reaches `err` with its code. What each form means in each
  # mode is tested where that mode is (the for, case and
  # enum_reduce_find tests, in both modes).
  use ExUnit.Case, async: true

  alias Defk.Forms

  # the rejection, caught the way the compiler catches its own
  defp err(node, code, what, opts), do: throw({:reject, node, code, what, opts})

  defp rejected(fun) do
    fun.()
    flunk("accepted")
  catch
    {:reject, node, code, what, opts} -> {node, code, what, opts}
  end

  describe "for/3" do
    test "a plain for: its qualifiers and body" do
      {:for, _, args} = quote(do: for(i <- 0..n, rem(i, 2) == 0, do: out[i] = 1))
      assert {[{:<-, _, _}, {:==, _, _}], nil, {:=, _, _}} = Forms.for(args, nil, &err/4)
    end

    test "a reduce: its init and the accumulator clauses" do
      {:for, _, args} = quote(do: for(x <- a, reduce: 0, do: (acc -> acc + x)))
      assert {[{:<-, _, _}], {:reduce, 0}, [{:->, _, _}]} = Forms.for(args, nil, &err/4)
    end

    test "into: is handed back whole, for the compiler to lower before it rejects" do
      {:for, _, args} = quote(do: for(x <- a, into: <<>>, do: <<x>>))

      assert {:into, [{:<-, _, _}], {:<<>>, _, [_]}, {:<<>>, _, []}} =
               Forms.for(args, nil, &err/4)
    end

    test "any other option is rejected, before the generators are looked at" do
      {:for, _, args} = quote(do: for(uniq: true, do: 1))

      assert {:node, "for-option", "for ..., uniq: is not in the kernel subset", []} =
               rejected(fn -> Forms.for(args, :node, &err/4) end)
    end

    test "a bitstring generator is rejected with the array walk as its rewrite" do
      {:for, _, args} = quote(do: for(<<b <- bin>>, do: b))

      assert {{:<<>>, _, _}, "generator-pattern", what, opts} =
               rejected(fn -> Forms.for(args, :node, &err/4) end)

      assert what =~ "bitstring generator"
      assert opts[:rewrite] == "b <- bin"
    end

    test "a for with no generator, or no do block" do
      {:for, _, args} = quote(do: for(x == 1, do: x))

      assert {:node, "for-form", "this for has no generator", []} =
               rejected(fn -> Forms.for(args, :node, &err/4) end)

      {:for, _, args} = quote(do: for(x <- a))

      assert {:node, "for-form", "this for has no do block", [hint: _]} =
               rejected(fn -> Forms.for(args, :node, &err/4) end)
    end
  end

  describe "case_clause/2" do
    test "the pattern, its guard or nil, the body and the clause's meta" do
      [plain] = quote(line: 4, do: (0 -> 1))
      assert {0, nil, 1, [line: 4]} = Forms.case_clause(plain, &err/4)

      [guarded] = quote(do: (n when n > 0 -> n))
      assert {{:n, _, _}, {:>, _, _}, {:n, _, _}, _} = Forms.case_clause(guarded, &err/4)
    end

    test "a clause with several patterns is rejected" do
      [cl] = quote(do: (a, b -> 1))

      assert {^cl, "case-pattern", "a case clause with 2 patterns is not in the kernel subset",
              []} = rejected(fn -> Forms.case_clause(cl, &err/4) end)
    end
  end

  describe "the Enum forms" do
    test "reduce_while with a literal two-parameter fn, else :error" do
      {_, _, args} = quote(do: Enum.reduce_while(a, 0, fn x, acc -> {:cont, acc + x} end))

      assert {:ok, {:a, _, _}, 0, {:x, _, _}, {:acc, _, _}, {:cont, _}} =
               Forms.reduce_while(args)

      {_, _, args} = quote(do: Enum.reduce_while(a, 0, &step/2))
      assert Forms.reduce_while(args) == :error
    end

    test "all?/any? with a literal one-parameter fn, keeping the fn's metas, else :error" do
      {_, _, args} = quote(line: 3, do: Enum.all?(a, fn x -> x > 0 end))
      assert {:ok, {:a, _, _}, {:x, _, _}, {:>, _, _}, {fm, am}} = Forms.predicate(args)
      assert fm[:line] == 3 and am[:line] == 3

      {_, _, args} = quote(do: Enum.any?(a, &(&1 > 0)))
      assert Forms.predicate(args) == :error
    end
  end

  describe "desugar/1" do
    test "Enum.reduce/3 with a literal fn is the for ..., reduce: it stands for" do
      ast = quote(do: Enum.reduce(a, 0, fn x, acc -> max(acc, x) end))

      assert {:for, _,
              [
                {:<-, _, [{:x, _, _}, {:a, _, _}]},
                [reduce: 0, do: [{:->, _, [[{:acc, _, _}], {:max, _, _}]}]]
              ]} = Forms.desugar(ast)
    end

    test "Enum.find/3 with a literal fn is a reduce_while that halts on the element" do
      ast = quote(do: Enum.find(a, 0, fn x -> x > 0 end))
      d = Forms.find_default()

      assert {{:., _, [{:__aliases__, _, [:Enum]}, :reduce_while]}, _,
              [
                {:a, _, _},
                0,
                {:fn, _,
                 [
                   {:->, _,
                    [
                      [{:x, _, _}, {^d, _, _}],
                      {:if, _, [{:>, _, _}, [do: {:halt, {:x, _, _}}, else: {:cont, {^d, _, _}}]]}
                    ]}
                 ]}
              ]} = Forms.desugar(ast)
    end

    test "fn _ -> ... end: the element found still has a name to be returned" do
      ast = quote(do: Enum.find(a, 0, fn _ -> true end))

      assert {_, _, [_, 0, {:fn, _, [{:->, _, [[{x, _, _}, _], {:if, _, [true, kw]}]}]}]} =
               Forms.desugar(ast)

      assert x != :_
      assert kw[:do] == {:halt, {x, [], nil}}
    end

    test "any other fn stays as written, for the compiler to reject" do
      for ast <- [
            quote(do: Enum.reduce(a, 0, &+/2)),
            quote(do: Enum.find(a, 0, &(&1 > 0))),
            quote(do: Enum.find(a, 0, fn {x, _} -> x > 0 end))
          ] do
        assert Forms.desugar(ast) == ast
      end
    end

    test "a kernel: its body is rewritten, the rest kept" do
      k = %{head: :h, body: quote(do: Enum.reduce(a, 0, fn x, acc -> max(acc, x) end))}
      assert %{head: :h, body: {:for, _, _}} = Forms.desugar(k)
    end
  end
end
