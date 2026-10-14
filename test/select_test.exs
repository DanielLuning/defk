# An `if` or `cond` value whose arms are pure arithmetic is compiled as a
# select: every arm is computed, overflow is flagged instead of raised, and
# only an overflow in the taken arm (or a reached condition) raises.

# A division is not speculated: an arm with div, rem or a float
# division compiles to a branch, so the untaken one is skipped.
defmodule Defk.SelectTest.Cost do
  use Defk

  defk rem_arm(pow2 :: bool, v :: i64, n :: i64) :: i64 do
    if pow2, do: band(v, n - 1), else: rem(v, n)
  end

  defk div_arm(c :: bool, v :: i64, n :: i64) :: i64 do
    if c, do: v + n, else: div(v, n)
  end

  defk fdiv_arm(c :: bool, x :: f64, y :: f64) :: f64 do
    if c, do: x + y, else: x / y
  end

  defk cond_rem(v :: i64, n :: i64) :: i64 do
    cond do
      v < 0 -> v + n
      v == 0 -> 1
      true -> rem(v, n)
    end
  end

  defk add_arm(c :: bool, x :: i64, y :: i64) :: i64 do
    if c, do: x + y, else: x - y
  end
end

defmodule Defk.SelectTest.K do
  use Defk

  defk count_if(n :: i64, step :: i64) :: i64 do
    for i <- 1..n//1, reduce: 0 do
      acc -> if rem(i, 3) == 0, do: acc + step, else: acc - 1
    end
  end

  defk square_unless(keep :: bool, x :: i64) :: i64 do
    if keep, do: x, else: x * x
  end

  defk next_or_neg(c :: bool, x :: i64) :: i64 do
    if c, do: x + 1, else: -x
  end

  defk cmp_arms(c :: bool, x :: i64, y :: i64) :: bool do
    if c, do: x + 1 > y, else: x * 2 < y
  end

  defk cond_count(n :: i64, step :: i64) :: i64 do
    for i <- 1..n//1, reduce: 0 do
      acc ->
        cond do
          rem(i, 3) == 0 -> acc + step
          rem(i, 5) == 0 -> acc * 2
          true -> acc - 1
        end
    end
  end

  # a one-branch cond is a distinct kernel shape (the else branch can still
  # overflow); the minimal form is the point of the fixture
  defk cond_square(keep :: bool, x :: i64) :: i64 do
    # credo:disable-for-next-line Credo.Check.Refactor.CondStatements
    cond do
      keep -> x
      true -> x * x
    end
  end

  # the second condition overflows only when it is reached
  defk cond_later(c :: bool, x :: i64) :: i64 do
    cond do
      c -> x
      x * x > 0 -> x + 1
      true -> -x
    end
  end

  defk odd?(x :: i64) :: bool do
    rem(x, 2) == 1
  end

  # first condition calls a kernel; a later one does too and stays a branch
  defk cond_calls(x :: i64) :: i64 do
    cond do
      odd?(x) -> x * x
      odd?(x + 1) and x > 0 -> x + 1
      true -> -x
    end
  end
end

defmodule Defk.SelectTest do
  use ExUnit.Case, async: true
  use Defk.Properties

  alias Defk.SelectTest.K

  @big 1_099_511_627_776
  @min -9_223_372_036_854_775_808

  test "matches Elixir" do
    expect =
      Enum.reduce(1..10_000, 0, fn i, acc -> if rem(i, 3) == 0, do: acc + 7, else: acc - 1 end)

    assert K.count_if(10_000, 7) == expect
    assert K.cmp_arms(true, 3, 3) and not K.cmp_arms(false, 3, 3)
  end

  test "overflow in the untaken arm does not raise" do
    assert K.square_unless(true, @big) == @big
    assert K.next_or_neg(true, @min) == @min + 1
  end

  test "overflow in the taken arm raises the checked error" do
    assert_raise ArithmeticError, "i64 overflow in #{@big} * #{@big}", fn ->
      K.square_unless(false, @big)
    end

    assert_raise ArithmeticError, "i64 overflow in 0 - #{@min}", fn ->
      K.next_or_neg(false, @min)
    end

    assert_raise ArithmeticError, ~r/i64 overflow in -?\d+ \+ \d+/, fn ->
      K.count_if(10, 9_223_372_036_854_775_000)
    end
  end

  test "cond matches Elixir" do
    expect =
      Enum.reduce(1..200, 0, fn i, acc ->
        cond do
          rem(i, 3) == 0 -> acc + 7
          rem(i, 5) == 0 -> acc * 2
          true -> acc - 1
        end
      end)

    assert K.cond_count(200, 7) == expect
    assert K.cond_later(false, 3) == 4 and K.cond_later(false, 0) == 0
    assert Enum.map([3, 4, 0, -4], &K.cond_calls/1) == [9, 5, 0, 4]
  end

  test "cond: overflow in an untaken arm or unreached condition does not raise" do
    assert K.cond_square(true, @big) == @big
    assert K.cond_later(true, @big) == @big
    assert K.cond_later(true, @min) == @min
  end

  test "cond: overflow in the taken arm or a reached condition raises the checked error" do
    assert_raise ArithmeticError, "i64 overflow in #{@big} * #{@big}", fn ->
      K.cond_square(false, @big)
    end

    assert_raise ArithmeticError, "i64 overflow in #{@big} * #{@big}", fn ->
      K.cond_later(false, @big)
    end

    assert_raise ArithmeticError, ~r/i64 overflow in -?\d+ [+*] \d+/, fn ->
      K.cond_count(10, 9_223_372_036_854_775_000)
    end
  end

  test "pure arithmetic arms compile to a select" do
    c = File.read!(String.replace_suffix(K.__defk_lib__(), ".so", ".c"))
    assert c =~ "defk_add_i64_s(&"
  end

  describe "cost heuristic" do
    defp cost_c,
      do: File.read!(String.replace_suffix(Defk.SelectTest.Cost.__defk_lib__(), ".so", ".c"))

    # the C of one kernel: from its marker comment to the next kernel's
    defp body_of(name) do
      [_, rest] = String.split(cost_c(), "/* ---- #{name}/", parts: 2)
      rest |> String.split("/* ---- ", parts: 2) |> hd()
    end

    test "a rem, div or float division arm compiles to a branch, not a select" do
      for name <- ~w(rem_arm div_arm fdiv_arm cond_rem) do
        c = body_of(name)
        assert c =~ ~r/if \(/, name
        refute c =~ "_s(&", name
        refute c =~ ~r/= v_cond_\d+ \? /, name
      end
    end

    test "an add arm still compiles to a select" do
      assert cost_c() =~ ~r/defk_add_i64_s\(&/
    end

    test "the branches agree with Elixir, including a division by zero in the taken arm" do
      alias Defk.SelectTest.Cost
      assert Cost.rem_arm(true, 13, 8) == 5
      assert Cost.rem_arm(false, 13, 5) == 3
      assert Cost.div_arm(true, 1, 0) == 1
      assert Cost.fdiv_arm(true, 1.0, 0.0) == 1.0
      assert_raise ArithmeticError, fn -> Cost.rem_arm(false, 1, 0) end
      assert_raise ArithmeticError, fn -> Cost.div_arm(false, 1, 0) end
    end
  end

  # ---------------------------------------------------- agreement properties --
  # Every kernel here against its Elixir mode: arms that overflow
  # only when taken, on any i64; loop counts bounded (the i64 maximum raises
  # before the loop starts).

  defp counted, do: fixed_list([G.i64(-5..2_000, [@min, 0x7FFFFFFFFFFFFFFF]), G.i64()])

  agreement(K,
    count_if: [args: counted()],
    square_unless: [],
    next_or_neg: [],
    cmp_arms: [],
    cond_count: [args: counted()],
    cond_square: [],
    cond_later: [],
    odd?: [],
    cond_calls: []
  )
end
