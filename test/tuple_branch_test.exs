# An `if`, `cond` or `case` whose arms are tuples gives a tuple (defk-uew):
# natively one branch per element position, the conditions evaluated once,
# with a select per element when the arms are pure; in Elixir mode the same
# branch. Each position has its own type; an array inside such tuples is
# tested in test/array_branch_test.exs (defk-gqk).

defmodule Defk.TupleBranchTest.K do
  use Defk

  defk if2(c :: bool, x :: i64, y :: i64) :: i64 do
    {a, b} = if c, do: {x + 1, y}, else: {y, x * 2}
    a - b
  end

  # returned as the kernel's tuple, mixed element types
  defk if_mixed(c :: bool, x :: i64, f :: f64) :: {i64, f64} do
    if c, do: {x, f * 2.0}, else: {-x, f}
  end

  # a block arm (statements before its value), a 3-tuple and an unused element
  defk if3(c :: bool, x :: i64, f :: f64) :: f64 do
    {n, g, _} =
      if c do
        y = x * 3
        {y, f + 1.0, true}
      else
        {x, f, false}
      end

    float(n) + g
  end

  defk cond3(x :: i64, f :: f64) :: {i64, f64, bool} do
    cond do
      x > 100 -> {x - 100, f, true}
      x < -100 -> {x + 100, -f, false}
      true -> {0, 0.5, x == 0}
    end
  end

  defk case2(x :: i64, y :: i64) :: i64 do
    {q, r} =
      case x do
        0 -> {y, 0}
        1 -> {0, y}
        n when n > 0 -> {div(y, n), rem(y, n)}
        _ -> {-y, 1}
      end

    q * 10 + r
  end

  # no catch-all: CaseClauseError for any other subject
  defk case3(x :: i64, f :: f64) :: {f64, i64, f64} do
    case x do
      0 -> {f, 1, 2.0}
      1 -> {1.0, x, f}
    end
  end

  defk pair(x :: i64) :: {i64, i64} do
    {x * 2, x + 1}
  end

  # an arm that calls a kernel returning a tuple
  defk call_arm(c :: bool, x :: i64) :: i64 do
    {a, b} = if c, do: pair(x), else: {x, x}
    a * 1000 + b
  end

  # a tuple branch as a reduce body: the next accumulator; pure arms, so a
  # select per element
  defk select_loop(xs :: [i64], step :: i64) :: {i64, i64} do
    for x <- xs, reduce: {0, 0} do
      {n, s} -> if x > 0, do: {n + 1, s + step}, else: {n, s - x}
    end
  end

  defk cond_loop(xs :: [i64]) :: {i64, f64} do
    for x <- xs, reduce: {0, 0.0} do
      {n, s} ->
        cond do
          rem(x, 3) == 0 -> {n + 1, s}
          rem(x, 3) == 1 -> {n, s + 1.5}
          true -> {n - 1, s * 0.5}
        end
    end
  end

  # a bitstring element: appended in one arm, kept in the other
  defk bits_count(xs :: [i64]) :: {bitstring, i64} do
    for x <- xs, reduce: {<<>>, 0} do
      {acc, n} ->
        if x > 0, do: {<<acc::bitstring, band(x, 7)::3>>, n + 1}, else: {acc, n}
    end
  end

  # `<<>>` beside a bitstring arm in the same position is the empty bitstring
  defk bits_reset(xs :: [i64]) :: {bitstring, i64} do
    acc = <<>>

    acc =
      for x <- xs, reduce: acc do
        acc -> <<acc::bitstring, band(x, 1)::1>>
      end

    n = length(xs)
    if n > 3, do: {<<>>, 0}, else: {acc, bit_size(acc)}
  end
end

defmodule Defk.TupleBranchTest.Select do
  use Defk

  # pure arithmetic arms only, so the C is the select's
  defk step(c :: bool, x :: i64, y :: i64) :: {i64, i64} do
    if c, do: {x + y, y}, else: {x, y * 2}
  end

  # a division in one element keeps the whole tuple a branch (defk-id9)
  defk step_rem(c :: bool, x :: i64, y :: i64) :: {i64, i64} do
    if c, do: {x + y, y}, else: {x, rem(y, 7)}
  end

  defk step_fdiv(c :: bool, x :: f64, y :: f64) :: {f64, f64} do
    if c, do: {x + y, y}, else: {x, x / y}
  end
end

defmodule Defk.TupleBranchTest do
  use ExUnit.Case, async: true
  use Defk.Properties

  import Defk.Test
  import Defk.TestKit

  alias Defk.TupleBranchTest.{K, Select}

  @big 1_099_511_627_776
  @max 9_223_372_036_854_775_807

  test "if, cond and case with 2- and 3-tuples agree with Elixir" do
    for c <- [true, false], x <- [-7, 0, 5], y <- [3, -2] do
      assert_agrees(K, :if2, [c, x, y])
      assert_agrees(K, :if_mixed, [c, x, 1.25])
      assert_agrees(K, :if3, [c, x, -0.5])
      assert_agrees(K, :call_arm, [c, x])
      assert_agrees(K, :case2, [x, y])
    end

    for x <- [-500, -101, -100, 0, 7, 100, 101, 500] do
      assert_agrees(K, :cond3, [x, 2.5])
      assert_agrees(K, :case3, [x, 2.5])
    end

    assert K.if2(true, 4, 9) == 5 - 9
    assert K.if_mixed(false, 3, 1.5) === {-3, 1.5}
    assert K.cond3(150, 1.0) === {50, 1.0, true}
    assert K.case2(3, 10) == 31
    assert K.call_arm(true, 4) == 8005
    assert_raise CaseClauseError, fn -> K.case3(2, 1.0) end
  end

  test "tuple branches as reduce bodies, with bitstring elements" do
    xs = [3, -1, 0, 9, 12, -4, 5]

    for k <- [:select_loop, :cond_loop, :bits_count, :bits_reset] do
      args = if k == :select_loop, do: [i64s(xs), 2], else: [i64s(xs)]
      assert_agrees(K, k, args)
      assert_agrees(K, k, [i64s([]) | tl(args)])
    end

    assert K.select_loop(i64s(xs), 2) == {4, 10 - 1 - 0 + 4 + 0}
    assert K.bits_count(i64s([1, -1, 7])) == {<<1::3, 7::3>>, 2}
    assert K.bits_reset(i64s([1, 0, 1])) == {<<1::1, 0::1, 1::1>>, 3}
    assert K.bits_reset(i64s([1, 0, 1, 1])) == {<<>>, 0}
  end

  test "overflow in an untaken arm does not raise; in the taken arm it does" do
    assert Select.step(false, @max, @big) == {@max, 2 * @big}
    assert Select.step(true, 1, @big) == {1 + @big, @big}
    assert_raise ArithmeticError, ~r/i64 overflow/, fn -> Select.step(true, @max, 1) end
    assert_raise ArithmeticError, ~r/i64 overflow/, fn -> Select.step(false, 0, @max) end

    for args <- [[true, @max, 1], [false, 0, @max], [false, @max, @big]] do
      assert_agrees(Select, :step, args)
    end
  end

  test "pure arms compile to a select per element, the condition once" do
    c = File.read!(String.replace_suffix(Select.__defk_lib__(), ".so", ".c"))
    assert c =~ "defk_add_i64_s(&"
    assert c =~ "defk_mul_i64_s(&"
    # one condition temporary, one ternary per element
    assert [_] = Regex.scan(~r/^v_cond_\d+ = /m, c)
    assert [_, _] = Regex.scan(~r/= v_cond_\d+ \? /, c)
  end

  test "a tuple arm with a division is a branch, not a select per element (defk-id9)" do
    c = File.read!(String.replace_suffix(Select.__defk_lib__(), ".so", ".c"))

    for name <- ~w(step_rem step_fdiv) do
      [_, rest] = String.split(c, "/* ---- #{name}/", parts: 2)
      body = rest |> String.split("/* ---- ", parts: 2) |> hd()
      assert body =~ "if (p_c)", name
      refute body =~ "_s(&", name
      refute body =~ ~r/= v_cond_\d+ \? /, name
    end

    assert Select.step_rem(false, 3, 15) == {3, 1}
    assert Select.step_fdiv(false, 1.0, 4.0) == {1.0, 0.25}
  end

  describe "compile errors" do
    defp compile_error(body, ret \\ "i64"),
      do:
        reject(__MODULE__, kernel("x :: i64, f :: f64, a :: [i64], b :: [i64]", ret, body, "bad"))

    test "each element position has one type" do
      msg = compile_error("{p, q} = if x > 0, do: {x, f}, else: {f, f}\nq + p", "f64")
      assert msg =~ "(defk branch-types"
      assert msg =~ "element 1 of the tuples"
      assert msg =~ "i64, f64"
    end

    test "every arm is a tuple of one size" do
      msg = compile_error("{p, q} = if x > 0, do: {x, x}, else: {x, x, x}\np + q")
      assert msg =~ "(defk branch-tuple"
      assert msg =~ "{i64, i64}"
      assert msg =~ "{i64, i64, i64}"

      msg = compile_error("{p, q} = if x > 0, do: {x, x}, else: x\np + q")
      assert msg =~ "(defk branch-tuple"
    end

    test "a tuple branch bound to one variable is tuple-binding" do
      msg = compile_error("t = if x > 0, do: {x, 1}, else: {2, x}\nx")
      assert msg =~ "(defk tuple-binding"
    end
  end

  # ---------------------------------------------------- agreement properties --

  defp small_list, do: map(list_of(G.i64(-1_000..1_000), max_length: 40), &i64s/1)

  agreement(K,
    if2: [],
    if_mixed: [],
    if3: [],
    cond3: [],
    case2: [],
    case3: [],
    pair: [],
    call_arm: [],
    select_loop: [],
    cond_loop: [args: fixed_list([small_list()])],
    bits_count: [],
    bits_reset: []
  )

  agreement(Select, step: [], step_rem: [], step_fdiv: [])
end
