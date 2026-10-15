# Enum.reduce/3 and Enum.find/3 in kernels: the same fold as for ..., reduce:,
# and the first element that satisfies a predicate or the default, with the
# same results natively and in Elixir mode, also when the kernel yields.
# Enum.find/2 and Enum.find_index/2 (nil when nothing matches) stay rejected.

defmodule Defk.EnumReduceFindTest.K do
  use Defk

  defk sum_range(n :: i64) :: i64 do
    Enum.reduce(0..(n - 1)//1, 0, fn i, acc -> acc + i * i end)
  end

  defk sum_stepped(n :: i64) :: i64 do
    Enum.reduce(n..0//-3, 0, fn i, acc -> rem(acc * 3 + i, 1_000_003) end)
  end

  defk sum_array(a :: [f64]) :: f64 do
    Enum.reduce(a, 0.0, fn x, acc -> acc + x end)
  end

  defk min_max(a :: [i64]) :: {i64, i64} do
    Enum.reduce(a, {1_000_000, -1_000_000}, fn x, {lo, hi} ->
      {min(lo, x), max(hi, x)}
    end)
  end

  # an array accumulator, with statements before the new value
  defk doubled(a :: [i64]) :: [i64] do
    Enum.reduce(0..(length(a) - 1)//1, alloc(i64, length(a)), fn i, o ->
      o[i] = a[i] * 2
      o
    end)
  end

  defk nested(n :: i64) :: i64 do
    Enum.reduce(0..(n - 1)//1, 0, fn i, acc ->
      acc + Enum.reduce(0..i//1, 0, fn j, s -> s + j end)
    end)
  end

  # as a statement, its value unused: the array writes stay
  defk fill(n :: i64) :: [i64] do
    out = alloc(i64, n)

    Enum.reduce(0..(n - 1)//1, 0, fn i, acc ->
      out[i] = acc
      acc + i
    end)

    out
  end

  defk find_above(a :: [i64], t :: i64) :: i64 do
    Enum.find(a, -1, fn x -> x > t end)
  end

  defk find_f64(a :: [f64], t :: f64) :: f64 do
    Enum.find(a, 0.0, fn x -> x > t end)
  end

  defk find_range(n :: i64, d :: i64) :: i64 do
    Enum.find(1..n//2, 0, fn i -> rem(i, d) == 0 end)
  end

  defk find_any(n :: i64) :: i64 do
    Enum.find(n..0//-1, -1, fn _ -> true end)
  end

  # the predicate raises (a zero divisor) before any match
  defk find_div(a :: [i64], d :: i64) :: i64 do
    Enum.find(a, -1, fn x -> div(x, d) > 2 end)
  end

  # a long search, so the kernel yields before it finds
  defk find_late(n :: i64, t :: i64) :: i64 do
    Enum.find(0..(n - 1)//1, -1, fn i -> rem(i * 7919, 1_000_003) == t end)
  end
end

defmodule Defk.EnumReduceFindTest do
  use ExUnit.Case, async: true

  import Defk.TestKit

  alias Defk.EnumReduceFindTest.K

  defp agrees(fun, args), do: Defk.Test.assert_agrees(K, fun, args)

  test "Enum.reduce/3 over ranges, stepped ranges and arrays" do
    for n <- [0, 1, 2, 10, 1000] do
      assert {:ok, v} = agrees(:sum_range, [n])
      assert v == Enum.reduce(0..(n - 1)//1, 0, fn i, acc -> acc + i * i end)
      assert {:ok, w} = agrees(:sum_stepped, [n])
      assert w == Enum.reduce(n..0//-3, 0, fn i, acc -> rem(acc * 3 + i, 1_000_003) end)
    end

    assert {:ok, 6.5} = agrees(:sum_array, [f64s([1.0, 2.0, 3.5])])
    assert {:ok, +0.0} = agrees(:sum_array, [<<>>])
  end

  test "Enum.reduce/3 with tuple and array accumulators, nested, and as a statement" do
    assert {:ok, {-4, 9}} = agrees(:min_max, [i64s([3, -4, 9, 0])])
    assert {:ok, ""} = agrees(:doubled, [<<>>])
    assert {:ok, bin} = agrees(:doubled, [i64s([1, -2, 3])])
    assert bin == i64s([2, -4, 6])
    assert {:ok, 10} = agrees(:nested, [4])
    assert {:ok, bin} = agrees(:fill, [5])
    assert bin == i64s([0, 0, 1, 3, 6])
  end

  test "Enum.reduce/3 raises where Elixir would" do
    # i * i overflows
    assert {:raise, %ArithmeticError{}} = agrees(:sum_range, [5_000_000_000])
  end

  test "Enum.find/3: the first match, or the default" do
    a = i64s([1, 5, 2, 8, 9])
    assert {:ok, 1} = agrees(:find_above, [a, 0])
    assert {:ok, 8} = agrees(:find_above, [a, 5])
    assert {:ok, 9} = agrees(:find_above, [a, 8])
    assert {:ok, -1} = agrees(:find_above, [a, 9])
    assert {:ok, -1} = agrees(:find_above, [<<>>, 0])
    assert {:ok, 2.5} = agrees(:find_f64, [f64s([1.0, 2.5, 3.0]), 2.0])
    assert {:ok, +0.0} = agrees(:find_f64, [f64s([1.0]), 2.0])

    for n <- [0, 1, 10, 99], d <- [1, 3, 7, 200] do
      assert {:ok, v} = agrees(:find_range, [n, d])
      assert v == Enum.find(1..n//2, 0, &(rem(&1, d) == 0))
    end

    assert {:ok, 4} = agrees(:find_any, [4])
    assert {:ok, -1} = agrees(:find_any, [-1])
  end

  test "Enum.find/3 stops at the first match: a later raise does not happen" do
    a = i64s([9, 1, 2])
    assert {:ok, 9} = agrees(:find_div, [a, 1])
    assert {:raise, %ArithmeticError{}} = agrees(:find_div, [a, 0])
    assert {:ok, -1} = agrees(:find_div, [<<>>, 0])
  end

  for mode <- [:natural, :forced] do
    test "Enum.reduce/3 and Enum.find/3 in yielding loops (#{mode} yields)" do
      K.__defk_force_yields__(unquote(mode) == :forced)
      n = if unquote(mode) == :forced, do: 3000, else: 3_000_000
      t = rem((n - 5) * 7919, 1_000_003)

      try do
        y0 = K.__defk_stats__().yields
        assert {:ok, i} = agrees(:find_late, [n, t])
        assert i == Enum.find(0..(n - 1)//1, -1, &(rem(&1 * 7919, 1_000_003) == t))
        assert {:ok, _} = agrees(:sum_range, [n])

        # an array written in the loop: Elixir mode copies it on every write,
        # so only the small forced-yield size
        if unquote(mode) == :forced do
          assert {:ok, _} = agrees(:fill, [n])
          assert K.__defk_stats__().yields - y0 > 0, "never yielded"
        end
      after
        K.__defk_force_yields__(false)
      end
    end
  end

  describe "rejections" do
    defp compile_error(body), do: reject(__MODULE__, body)

    test "Enum.find/2 and Enum.find_index/2 point to Enum.find/3" do
      for {call, arity} <- [
            {"Enum.find(a, fn x -> x > 0 end)", 2},
            {"Enum.find_index(a, fn x -> x > 0 end)", 2}
          ] do
        msg = compile_error("defk f(a :: [i64]) :: i64 do\n  #{call}\nend")
        assert msg =~ "(defk enum-find", msg
        assert msg =~ "/#{arity} is not in the kernel subset"
        assert msg =~ "use Enum.find(enum, default, fn x -> ... end)"
      end
    end

    test "Enum.reduce/2 asks for the initial value" do
      msg =
        compile_error(
          "defk f(a :: [i64]) :: i64 do\n  Enum.reduce(a, fn x, acc -> acc + x end)\nend"
        )

      assert msg =~ "(defk enum-reduce", msg
      assert msg =~ "give the initial value"
    end

    test "a function other than a literal fn" do
      msg = compile_error("defk f(a :: [i64]) :: i64 do\n  Enum.reduce(a, 0, &+/2)\nend")
      assert msg =~ "(defk fn-argument", msg
      assert msg =~ "Enum.reduce/3 with &+/2"
      assert msg =~ "fn x, acc -> x + acc end"

      msg = compile_error("defk f(a :: [i64]) :: i64 do\n  Enum.find(a, 0, &(&1 > 2))\nend")
      assert msg =~ "(defk fn-argument", msg
      assert msg =~ "fn x -> x > 2 end"
    end

    test "the default and the elements of Enum.find/3 have one type" do
      msg =
        compile_error(
          "defk f(a :: [f64]) :: f64 do\n  Enum.find(a, -1, fn x -> x > 0.0 end)\nend"
        )

      assert msg =~ "Enum.find/3's default has type i64 and the elements have type f64", msg
      assert msg =~ "give a default of the element type, f64"

      # no widening: Elixir would return the integer element, not a float
      msg =
        compile_error(
          "defk f(a :: [i64]) :: f64 do\n  Enum.find(a, -1.0, fn x -> x > 0 end)\nend"
        )

      assert msg =~ "Enum.find/3's default has type f64 and the elements have type i64", msg
    end
  end
end
