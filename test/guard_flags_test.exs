defmodule Defk.GuardFlagsTest do
  # Which flags a case guard's lowering uses (guard_expr in Defk.Compiler):
  # `bad` for an Elixir error (a zero divisor, a non-finite float), `ovf`
  # for an i64 overflow, `stop` for an overflowed left side of an and/or
  # that decides the guard. The flags are locals reset in front of the
  # guard, in the order bad, ovf, stop; a guard with no operation that can
  # fail has none and lowers as written. What the flags do at run time is
  # case_guard_errors_test.exs.
  use ExUnit.Case, async: true

  import Defk.TestKit, only: [kernel_c: 2]

  defmodule K do
    use Defk

    defk plain(x :: i64) :: i64 do
      case x do
        n when n > 0 -> 1
        _ -> 2
      end
    end

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

    defk add_guard(x :: i64) :: i64 do
      case x do
        n when n + 1 > 0 -> 1
        _ -> 2
      end
    end

    defk fdiv_guard(x :: i64, y :: i64) :: i64 do
      case x do
        n when n / y > 1.0 -> 1
        _ -> 2
      end
    end

    # an overflowed left side of an `or` decides the guard: stop
    defk or_guard(x :: i64, y :: i64) :: i64 do
      case x do
        n when n * 2 > 100 or rem(n, y) == 0 -> 1
        _ -> 2
      end
    end

    # an `and` whose false fails the guard runs its right side anyway: no stop
    defk and_guard(x :: i64, y :: i64) :: i64 do
      case x do
        n when n * 2 > 100 and rem(n, y) == 0 -> 1
        _ -> 2
      end
    end
  end

  # the flags reset in front of kernel `name`'s guard, in order
  defp flags(name) do
    case Regex.run(~r/\(((?:v_g(?:bad|ovf|stop)_\d+ = 0, )+)v_guard_\d+ = /, kernel_c(K, name)) do
      [_, resets] ->
        for [_, f] <- Regex.scan(~r/v_g(bad|ovf|stop)_/, resets), do: String.to_atom(f)

      nil ->
        []
    end
  end

  test "a guard with no operation that can fail has no flags" do
    assert flags(:plain) == []
    refute kernel_c(K, :plain) =~ ~r/v_g(bad|ovf|stop|uard)_/
  end

  test "a zero divisor is an error: bad" do
    assert flags(:rem_guard) == [:bad]
  end

  test "div can also overflow: bad and ovf" do
    assert flags(:div_guard) == [:bad, :ovf]
  end

  test "i64 + - * can only overflow: ovf" do
    assert flags(:add_guard) == [:ovf]
  end

  test "a non-finite float result is an error: bad" do
    assert flags(:fdiv_guard) == [:bad]
  end

  test "an overflowed left side that decides the guard: stop" do
    assert flags(:or_guard) == [:bad, :ovf, :stop]
  end

  test "an and whose false fails the guard needs no stop" do
    assert flags(:and_guard) == [:bad, :ovf]
  end
end
