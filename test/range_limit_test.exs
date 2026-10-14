# A range loop whose last element is within one step of the i64 limit.
# Stepping past that element overflowed the loop counter:
# it wrapped, the exit test never passed, the loop spun without a safepoint
# (hanging its scheduler), and an index proven in range from the counter was
# written out of bounds with no check. Such a range now raises
# ArithmeticError before the loop starts, a limit; every other range runs
# as in Elixir, including ones that end right next to the limit. Elixir mode
# applies the same limit; every case here runs in both modes.

defmodule Defk.RangeLimitTest.K do
  use Defk

  # the index min(i, 9) has its bounds check removed (0 <= i, 9 < length(out))
  defk wrap(n :: i64) :: i64 do
    out = alloc(i64, 10)

    for i <- 0..9_223_372_036_854_775_807//4_611_686_018_427_387_904, reduce: 0 do
      acc ->
        j = min(i, length(out) - 1)
        out[j] = n
        acc + 1
    end
  end

  defk count_up(a :: i64, b :: i64) :: i64 do
    for _ <- a..b//3, reduce: 0 do
      acc -> acc + 1
    end
  end

  defk count_down(a :: i64, b :: i64) :: i64 do
    for _ <- a..b//-3, reduce: 0 do
      acc -> acc + 1
    end
  end

  defk count_step(a :: i64, b :: i64, k :: i64) :: i64 do
    for _ <- a..b//k, reduce: 0 do
      acc -> acc + 1
    end
  end

  defk count_auto(a :: i64, b :: i64) :: i64 do
    for _ <- a..b, reduce: 0 do
      acc -> acc + 1
    end
  end

  defk first_over(a :: i64, b :: i64) :: i64 do
    Enum.reduce_while(a..b//1, 0, fn i, _ ->
      if i > 100, do: {:halt, i}, else: {:cont, 0}
    end)
  end

  # ends tied to an array length: no test is emitted, and none is needed
  defk sum_len(a :: [i64]) :: i64 do
    for i <- 0..(length(a) - 1)//1, reduce: 0 do
      acc -> acc + a[i]
    end
  end
end

defmodule Defk.RangeLimitTest do
  use ExUnit.Case, async: true
  use Defk.Properties
  alias Defk.RangeLimitTest.K

  @max 0x7FFF_FFFF_FFFF_FFFF
  @min -0x8000_0000_0000_0000

  defp limit(fun), do: assert_raise(ArithmeticError, ~r/within one step of the i64 limit/, fun)

  # runs native and Elixir mode, asserts they agree (same value, or the same
  # exception and message), and returns or re-raises the native outcome
  defp both(fun, args) do
    native = outcome(fn -> Defk.ElixirMode.with_mode(:native, fn -> apply(K, fun, args) end) end)
    assert native == outcome(fn -> K.__defk_elixir__(fun, args) end), "#{fun}#{inspect(args)}"

    case native do
      {:ok, v} -> v
      {:raise, e} -> raise e
    end
  end

  defp outcome(f) do
    {:ok, f.()}
  rescue
    e -> {:raise, e}
  end

  test "the wrapping loop with an unchecked index raises instead of hanging" do
    limit(fn -> both(:wrap, [1]) end)
  end

  test "ranges whose last element can be stepped past run as in Elixir" do
    for {a, b} <- [{@max - 20, @max - 3}, {@max - 2, @max - 3}, {0, 100}, {@max - 3, @max - 3}] do
      assert both(:count_up, [a, b]) == Enum.count(a..b//3)
      assert both(:count_step, [a, b, 3]) == Enum.count(a..b//3)
    end

    for {a, b} <- [{@min + 20, @min + 3}, {@min + 3, @min + 3}, {100, 0}] do
      assert both(:count_down, [a, b]) == Enum.count(a..b//-3)
      assert both(:count_step, [a, b, -3]) == Enum.count(a..b//-3)
    end

    # the end is past the limit but the last element is not
    assert both(:count_up, [@max - 9, @max - 1]) == Enum.count((@max - 9)..(@max - 1)//3)
    assert both(:count_down, [@min + 9, @min + 1]) == Enum.count((@min + 9)..(@min + 1)//-3)
    assert both(:count_step, [@max - 9, @max - 1, 3]) == 3
    # an empty range never steps
    assert both(:count_up, [@max, @max - 1]) == 0
    assert both(:count_auto, [@max - 5, @max - 1]) == 5
    assert both(:first_over, [1, @max - 1]) == 101
    assert both(:sum_len, [<<1::64-native, 2::64-native>>]) == 3
  end

  test "ranges whose last element is within one step of the limit" do
    limit(fn -> both(:count_up, [@max - 20, @max]) end)
    limit(fn -> both(:count_up, [@max - 5, @max - 1]) end)
    limit(fn -> both(:count_step, [@max - 20, @max, 3]) end)
    limit(fn -> both(:count_step, [0, @max, @max]) end)
    limit(fn -> both(:count_down, [@min + 20, @min]) end)
    limit(fn -> both(:count_step, [@min + 20, @min, -3]) end)
    limit(fn -> both(:count_step, [-1, @min, @min]) end)
    limit(fn -> both(:count_auto, [@max - 5, @max]) end)
    limit(fn -> both(:count_auto, [@min + 5, @min]) end)
    # a limit even when a halt would end the loop first
    limit(fn -> both(:first_over, [1, @max]) end)
  end

  # ---------------------------------------------------- agreement properties --
  # Every kernel here against its Elixir mode. A range runs at
  # most a few thousand steps, anywhere in the i64 range: the far end is the
  # near one plus a bounded number of steps, clamped to the i64 limits, so
  # ranges ending at or next to them come up often.

  defp clamp(x), do: x |> max(@min) |> min(@max)

  # [a, b] with b = a + d, |d| <= span (d's sign from `dir`: 1, -1 or either)
  defp near(dir, span) do
    bind(G.i64(), fn a ->
      d =
        case dir do
          1 -> integer(0..span)
          -1 -> integer(-span..0)
          0 -> integer(-span..span)
        end

      fixed_list([constant(a), map(d, &clamp(a + &1))])
    end)
  end

  # [a, b, k]: about m steps of k (any i64, 0 included) from a
  defp stepped do
    bind(tuple({G.i64(), G.i64(), integer(-3..3_000), integer(-2..2)}), fn {a, k, m, j} ->
      fixed_list([constant(a), constant(clamp(a + k * m + j)), constant(k)])
    end)
  end

  # a reduce_while that halts past 100: a from where it gets there soon
  defp first_over do
    fixed_list([G.i64(-3_000..3_000, [@max, @max - 1, 2 ** 62, 2 ** 53 + 1, 2 ** 31]), G.i64()])
  end

  agreement(K,
    wrap: [],
    count_up: [args: near(1, 9_000)],
    count_down: [args: near(-1, 9_000)],
    count_step: [args: stepped()],
    count_auto: [args: near(0, 3_000)],
    first_over: [args: first_over()],
    sum_len: []
  )
end
