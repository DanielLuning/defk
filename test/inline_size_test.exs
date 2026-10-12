defmodule Defk.InlineSizeTest do
  # defk-6ag: every kernel call is inlined, so a diamond call graph doubles
  # the code per level. Past 80,000 lines of C (Defk.InlineSize) an entry
  # kernel gets a compile warning naming the chain. The kernels go through
  # Defk.Compiler.compile/3 (lowering, no C compiler): the point is the
  # warning, not minutes of clang.
  use ExUnit.Case, async: false

  # not async: capture_io(:stderr) sees every test's warnings
  import ExUnit.CaptureIO

  # d0 calls d1 twice, d1 calls d2 twice, ...: d<levels> is inlined
  # 2^levels times into d0
  defp diamond(levels) do
    src =
      Enum.map_join(0..(levels - 1)//1, "\n", fn l ->
        "defk d#{l}(x :: i64) :: i64 do\n  d#{l + 1}(x) + d#{l + 1}(x + 1)\nend\n"
      end) <>
        "\ndefk d#{levels}(x :: i64) :: i64 do\n  for i <- 0..x//1, reduce: 0 do\n    acc -> acc + i * i\n  end\nend\n"

    forms =
      case Code.string_to_quoted!(src) do
        {:__block__, _, forms} -> forms
        form -> [form]
      end

    for {:defk, m, [head, [do: body]]} <- forms,
        do: %{head: head, opts: [], body: body, line: m[:line]}
  end

  defp compile(kernels, file \\ "diamond.ex") do
    capture_io(:stderr, fn -> Defk.Compiler.compile(Defk.InlineSizeTest.M, kernels, file) end)
  end

  test "a diamond seven levels deep warns, naming the entry, its size and the chain" do
    out = compile(diamond(7))

    assert out =~
             ~r/d0\/1 compiles to [\d,]+ lines of C \([\d.]+ MB\), past the 80,000 at which defk warns/

    assert out =~ "d7/1 is inlined 128 times"

    assert out =~
             "via d0/1 -> d1/1 (2 call sites) -> d2/1 (2 call sites) -> d3/1 (2 call sites) -> " <>
               "d4/1 (2 call sites) -> d5/1 (2 call sites) -> d6/1 (2 call sites) -> d7/1 (2 call sites)"

    assert out =~ "Give each helper one call site"
    # at the entry kernel's head
    assert out =~ "diamond.ex:1"
    # d1 inlines half as much and stays under the threshold
    refute out =~ "d1/1 compiles to"
  end

  test "a diamond five levels deep compiles without a warning" do
    assert compile(diamond(5)) == ""
  end

  test "past the threshold with nothing inlined twice, the warning says so" do
    [k] = diamond(0)
    k = Map.merge(k, %{name: :d0, arity: 1})

    out =
      capture_io(:stderr, fn ->
        Defk.InlineSize.check([{k, "line\nline\n"}], [k], "diamond.ex", 1)
      end)

    assert out =~ "d0/1 compiles to 2 lines of C (0.0 MB), past the 1 at which defk warns"
    assert out =~ "No kernel is inlined more than once"
  end

  test "the copies of a kernel multiply call sites along every path" do
    kernels =
      for {head, body} <- [
            {quote(do: a(x :: i64) :: i64), quote(do: b(x) + b(x) + c(x))},
            {quote(do: b(x :: i64) :: i64), quote(do: c(x) + c(x) + c(x))},
            {quote(do: c(x :: i64) :: i64), quote(do: x)}
          ] do
        {name, args} = Defk.Clauses.key(head)
        %{name: name, arity: args, head: head, body: body}
      end

    graph = Defk.InlineSize.graph(kernels)
    assert Defk.InlineSize.copies({:a, 1}, graph) == %{{:a, 1} => 1, {:b, 1} => 2, {:c, 1} => 7}
  end
end
