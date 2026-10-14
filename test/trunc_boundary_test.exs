defmodule Defk.TruncBoundaryTest.K do
  use Defk

  defk trunc_f(x :: f64) :: i64 do
    trunc(x)
  end

  defk round_f(x :: f64) :: i64 do
    round(x)
  end
end

defmodule Defk.TruncBoundaryTest do
  use ExUnit.Case, async: true
  use Defk.Properties

  alias Defk.TruncBoundaryTest.K

  @i64_min -9_223_372_036_854_775_808
  # Exact doubles: -2^63, the next double below it, 2^63, and the largest
  # double below 2^63.
  @neg_2p63 -9_223_372_036_854_775_808 * 1.0
  @neg_2p63_below -9_223_372_036_854_777_856 * 1.0
  @pos_2p63 9_223_372_036_854_775_808 * 1.0
  @pos_2p63_below 9_223_372_036_854_774_784 * 1.0

  for fun <- [:trunc_f, :round_f] do
    test "#{fun} accepts -2^63, the i64 minimum" do
      assert {:ok, @i64_min} =
               Defk.Test.assert_agrees(K, unquote(fun), [@neg_2p63])
    end

    test "#{fun} rejects the double below -2^63" do
      assert {:raise, %ArithmeticError{}} =
               Defk.Test.assert_agrees(K, unquote(fun), [@neg_2p63_below])
    end

    test "#{fun} rejects 2^63" do
      assert {:raise, %ArithmeticError{}} =
               Defk.Test.assert_agrees(K, unquote(fun), [@pos_2p63])
    end

    test "#{fun} accepts the largest double below 2^63" do
      assert {:ok, 9_223_372_036_854_774_784} =
               Defk.Test.assert_agrees(K, unquote(fun), [@pos_2p63_below])
    end
  end

  # every f64, including the doubles either side of -2^63 and 2^63
  agreement(K, [:trunc_f, :round_f])
end
