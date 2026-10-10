# An error inside a case guard (defk-7a6). Elixir treats a guard that raises
# as a guard that failed and tries the next clause: a division by zero (div,
# rem, /) or a float operation giving inf fails the clause, in both modes.
# An i64 overflow is not an Elixir error (Elixir has no i64 limit), so it
# stays a limit: the kernel raises, with the message of the unguarded
# operation, rather than answering differently from Elixir.

defmodule Defk.CaseGuardErrorsTest.K do
  use Defk

  defk rem_guard(x :: i64, y :: i64) :: i64 do
    case x do
      n when rem(n, y) == 0 -> 1
      _ -> 2
    end
  end

  defk div_guard(x :: i64, y :: i64) :: i64 do
    case x do
      n when div(n, y) > 1 -> 1
      _ -> 2
    end
  end

  # a / b is a float division: zero fails the clause
  defk fdiv_guard(x :: i64, y :: i64) :: i64 do
    case x do
      n when n / y > 1.0 -> 1
      _ -> 2
    end
  end

  # the float product leaves f64: inf is an error in Elixir too
  defk float_guard(x :: i64, f :: f64) :: i64 do
    case x do
      n when f * 1.0e300 > n -> 1
      _ -> 2
    end
  end

  # u64 operands
  defk u64_guard(x :: i64, u :: u64, v :: u64) :: i64 do
    case x do
      n when rem(u, v) == n -> 1
      n when div(u, v) == n -> 3
      _ -> 2
    end
  end

  # the error in the last clause, no catch-all: CaseClauseError
  defk last_clause(x :: i64) :: i64 do
    case x do
      1 -> 10
      n when div(100, n) > 5 -> 20
    end
  end

  # the first clause's guard errors, the second matches
  defk then_match(x :: i64, y :: i64) :: i64 do
    case x do
      n when rem(n, y) == 1 -> 1
      n when n >= 0 -> 2
      _ -> 3
    end
  end

  # `or` short-circuits: an error on the left fails the whole guard, a true
  # left side never evaluates the right
  defk or_guard(x :: i64) :: i64 do
    case x do
      n when n == 0 or div(10, n) > 1 -> 1
      _ -> 2
    end
  end

  defk or_error_first(x :: i64) :: i64 do
    case x do
      n when div(10, n) > 1 or n == 0 -> 1
      _ -> 2
    end
  end

  defk and_not_guard(x :: i64, y :: i64) :: i64 do
    case x do
      n when y != 0 and not (rem(n, y) == 0) -> 1
      _ -> 2
    end
  end

  # a literal pattern in front of a guard that errors only when reached
  defk lit_then_guard(x :: i64, y :: i64) :: i64 do
    case x do
      0 -> 0
      n when rem(y, n) == 0 -> 1
      _ -> 2
    end
  end

  # pure-arithmetic arms: a select. The guard errors only when reached
  defk sel_guard(x :: i64, y :: i64) :: i64 do
    case x do
      n when rem(n, y) == 0 -> n + 1
      _ -> x - 1
    end
  end

  defk sel_second(x :: i64, y :: i64) :: i64 do
    case x do
      0 -> y
      n when div(y, n) > 1 -> n + 1
      _ -> 7
    end
  end

  # a statement form in a loop
  defk loop_guard(n :: i64, y :: i64) :: i64 do
    for i <- 1..n//1, reduce: 0 do
      acc ->
        case rem(i, 3) do
          k when div(y, k) > 2 ->
            acc = acc + 1
            acc * 2

          _ ->
            acc + 5
        end
    end
  end

  # a bool subject
  defk bool_guard(b :: bool, y :: i64) :: i64 do
    case b do
      v when v and rem(10, y) == 0 -> 1
      _ -> 2
    end
  end

  # limits: the exact result leaves i64, where Elixir has bignums
  defk ovf_guard(x :: i64) :: i64 do
    case x do
      n when n * n > 100 -> 1
      _ -> 2
    end
  end

  defk abs_guard(x :: i64) :: i64 do
    case x do
      n when abs(n) > 5 -> 1
      _ -> 2
    end
  end

  defk trunc_guard(x :: i64, f :: f64) :: i64 do
    case x do
      n when trunc(f) > n -> 1
      _ -> 2
    end
  end

  defk div_min_guard(x :: i64, y :: i64) :: i64 do
    case x do
      n when div(n, y) > 0 -> 1
      _ -> 2
    end
  end

  # a zero divisor and an overflow in one guard
  defk both_guard(x :: i64, y :: i64) :: i64 do
    case x do
      n when n * n > 100 and rem(n, y) == 0 -> 1
      _ -> 2
    end
  end

  # no operation that can fail: nothing to flag
  defk plain_guard(x :: i64, y :: i64) :: i64 do
    case x do
      n when n > 3 and n != y -> 1
      n when min(n, y) == 0 or max(n, y) < -4 -> 2
      _ -> 3
    end
  end

  # The same guards in plain Elixir, which is what a guard error means there
  def ex_rem_guard(x, y) do
    case x do
      n when rem(n, y) == 0 -> 1
      _ -> 2
    end
  end

  def ex_div_guard(x, y) do
    case x do
      n when div(n, y) > 1 -> 1
      _ -> 2
    end
  end

  def ex_fdiv_guard(x, y) do
    case x do
      n when n / y > 1.0 -> 1
      _ -> 2
    end
  end

  def ex_float_guard(x, f) do
    case x do
      n when f * 1.0e300 > n -> 1
      _ -> 2
    end
  end

  def ex_u64_guard(x, u, v) do
    case x do
      n when rem(u, v) == n -> 1
      n when div(u, v) == n -> 3
      _ -> 2
    end
  end

  def ex_last_clause(x) do
    case x do
      1 -> 10
      n when div(100, n) > 5 -> 20
    end
  end

  def ex_then_match(x, y) do
    case x do
      n when rem(n, y) == 1 -> 1
      n when n >= 0 -> 2
      _ -> 3
    end
  end

  def ex_or_guard(x) do
    case x do
      n when n == 0 or div(10, n) > 1 -> 1
      _ -> 2
    end
  end

  def ex_or_error_first(x) do
    case x do
      n when div(10, n) > 1 or n == 0 -> 1
      _ -> 2
    end
  end

  def ex_and_not_guard(x, y) do
    case x do
      n when y != 0 and not (rem(n, y) == 0) -> 1
      _ -> 2
    end
  end

  def ex_lit_then_guard(x, y) do
    case x do
      0 -> 0
      n when rem(y, n) == 0 -> 1
      _ -> 2
    end
  end

  def ex_sel_guard(x, y) do
    case x do
      n when rem(n, y) == 0 -> n + 1
      _ -> x - 1
    end
  end

  def ex_sel_second(x, y) do
    case x do
      0 -> y
      n when div(y, n) > 1 -> n + 1
      _ -> 7
    end
  end

  def ex_loop_guard(n, y) do
    for i <- 1..n//1, reduce: 0 do
      acc ->
        case rem(i, 3) do
          k when div(y, k) > 2 ->
            acc = acc + 1
            acc * 2

          _ ->
            acc + 5
        end
    end
  end

  def ex_bool_guard(b, y) do
    case b do
      v when v and rem(10, y) == 0 -> 1
      _ -> 2
    end
  end
end

defmodule Defk.CaseGuardErrorsTest do
  use ExUnit.Case, async: true
  use Defk.Properties

  alias Defk.CaseGuardErrorsTest.K

  @min -0x8000000000000000
  @max 0x7FFFFFFFFFFFFFFF
  @nums [0, 1, -1, 2, 3, -3, 7, 10, 11, 100, -100, 101, @max, @min, @min + 1]

  defp agrees(fun, args), do: Defk.Test.assert_agrees(K, fun, args)

  # native result, Elixir mode result and plain Elixir all equal
  defp same_as_elixir(fun, args) do
    expected =
      try do
        {:ok, apply(K, :"ex_#{fun}", args)}
      rescue
        e in CaseClauseError -> {:raise, e}
      end

    case agrees(fun, args) do
      # an i64 limit (Elixir has bignums): both modes raise, Elixir answers
      {:raise, %ArithmeticError{message: "i64 overflow" <> _}} -> :ok
      native -> assert expected == native, "#{fun}(#{inspect(args)})"
    end
  end

  describe "a guard error fails the clause" do
    test "rem and div by zero, i64 and u64" do
      for x <- @nums, y <- @nums do
        same_as_elixir(:rem_guard, [x, y])
        same_as_elixir(:div_guard, [x, y])
        same_as_elixir(:fdiv_guard, [x, y])
        same_as_elixir(:then_match, [x, y])
        same_as_elixir(:and_not_guard, [x, y])
        same_as_elixir(:lit_then_guard, [x, y])
        same_as_elixir(:sel_guard, [x, y])
        same_as_elixir(:sel_second, [x, y])
      end

      assert K.rem_guard(5, 0) == 2
      assert K.div_guard(5, 0) == 2
      assert K.fdiv_guard(5, 0) == 2
      assert K.then_match(5, 0) == 2
      assert K.then_match(-5, 0) == 3
      assert K.sel_guard(5, 0) == 4
      assert K.sel_second(5, 0) == 7

      for x <- [0, 1, 5, 6], u <- [0, 3, 7, 2 ** 64 - 1], v <- [0, 1, 3] do
        same_as_elixir(:u64_guard, [x, u, v])
      end
    end

    test "a float operation giving inf fails the clause" do
      for x <- @nums, f <- [0.0, 1.0, -1.0e10, 1.0e10, 1.0e-300, 1.0e8, -1.0e8] do
        same_as_elixir(:float_guard, [x, f])
      end

      assert K.float_guard(1, 1.0e10) == 2
      assert K.float_guard(1, 1.0e-299) == 1
    end

    test "the error in the last clause is a CaseClauseError" do
      for x <- [1, 2, 5, 100, 101, -1, 0], do: same_as_elixir(:last_clause, [x])
      assert {:raise, %CaseClauseError{term: 0}} = agrees(:last_clause, [0])

      e = assert_raise CaseClauseError, fn -> K.last_clause(0) end
      assert e == assert_raise(CaseClauseError, fn -> K.ex_last_clause(0) end)
      assert e == %CaseClauseError{term: 0}
    end

    test "an error is followed by the next matching clause" do
      assert K.then_match(7, 0) == 2
      assert K.then_match(-7, 0) == 3
      assert K.then_match(8, 7) == 1
    end

    test "or and and: an error fails the whole guard, and short-circuits like Elixir" do
      for x <- @nums do
        same_as_elixir(:or_guard, [x])
        same_as_elixir(:or_error_first, [x])
      end

      assert K.or_guard(0) == 1
      assert K.or_error_first(0) == 2
    end

    test "a statement form in a loop, and a bool subject" do
      for n <- [0, 1, 5, 40], y <- [0, 1, 2, 7, -3] do
        same_as_elixir(:loop_guard, [n, y])
      end

      for b <- [true, false], y <- [0, 1, 5, 10, -2] do
        same_as_elixir(:bool_guard, [b, y])
      end
    end

    test "a guard of a select fails its clause too" do
      c = File.read!(String.replace_suffix(K.__defk_lib__(), ".so", ".c"))
      assert c =~ "defk_rem_i64_g(&"
    end
  end

  describe "an i64 limit in a guard still raises" do
    test "overflow, abs of the minimum, trunc out of range, the minimum div -1" do
      assert {:ok, 2} == agrees(:ovf_guard, [5])
      assert {:ok, 1} == agrees(:ovf_guard, [11])

      # Elixir has no i64 limit (n * n > 100 is true): the kernel raises
      assert {:raise, %ArithmeticError{message: msg}} = agrees(:ovf_guard, [@max])
      assert msg == "i64 overflow in #{@max} * #{@max}"

      assert {:ok, 1} == agrees(:abs_guard, [-6])
      assert {:raise, %ArithmeticError{}} = agrees(:abs_guard, [@min])

      assert {:ok, 1} == agrees(:trunc_guard, [3, 1.0e3])
      assert {:raise, %ArithmeticError{}} = agrees(:trunc_guard, [3, 1.0e30])

      assert {:ok, 1} == agrees(:div_min_guard, [@max, 2])
      assert {:ok, 2} == agrees(:div_min_guard, [5, 0])
      assert {:raise, %ArithmeticError{}} = agrees(:div_min_guard, [@min, -1])
    end

    test "a zero divisor and an overflow in one guard agree" do
      for x <- @nums, y <- @nums, do: agrees(:both_guard, [x, y])
    end
  end

  test "a guard with nothing that can fail has no flags in its C" do
    c = File.read!(String.replace_suffix(K.__defk_lib__(), ".so", ".c"))
    [_, fun] = String.split(c, "plain_guard", parts: 2)
    body = fun |> String.split("\n}\n", parts: 2) |> hd()
    refute body =~ "_s(&"
    refute body =~ "_g(&"
    assert body =~ "defk_min_i64"
  end

  agreement(K, [
    :rem_guard,
    :div_guard,
    :fdiv_guard,
    :float_guard,
    :u64_guard,
    :last_clause,
    :then_match,
    :or_guard,
    :or_error_first,
    :and_not_guard,
    :lit_then_guard,
    :sel_guard,
    :sel_second,
    :bool_guard,
    :ovf_guard,
    :abs_guard,
    :trunc_guard,
    :div_min_guard,
    :both_guard,
    :plain_guard,
    loop_guard: [args: StreamData.fixed_list([StreamData.integer(0..60), G.i64()])]
  ])
end
