# raise in a kernel: `raise Module, "literal"`, `raise Module` and
# `raise "literal"`, a statement that raises the exception Elixir would, with
# the same message natively and in Elixir mode.

defmodule Defk.RaiseTest.K do
  use Defk

  defk arg(x :: i64) :: i64 do
    if x < 0, do: raise(ArgumentError, "x must not be negative")
    x * 2
  end

  defk arith(x :: i64) :: i64 do
    if x == 0, do: raise(ArithmeticError, "x is zero")
    div(100, x)
  end

  defk runtime(x :: i64) :: i64 do
    if x > 9, do: raise("x is too big")
    x
  end

  defk runtime_mod(x :: i64) :: i64 do
    if x > 9, do: raise(RuntimeError, "x is too big")
    x
  end

  defk default_arg(x :: i64) :: i64 do
    if x < 0, do: raise(ArgumentError)
    x
  end

  defk default_arith(x :: i64) :: i64 do
    if x < 0, do: raise(ArithmeticError)
    x
  end

  defk default_runtime(x :: i64) :: i64 do
    if x < 0, do: raise(RuntimeError)
    x
  end

  # bytes C would reinterpret: quotes, backslashes, ?? trigraphs, a NUL,
  # % (the message is not a format), UTF-8, and longer than ctx->msg (200)
  defk odd_message(x :: i64) :: i64 do
    if x < 0 do
      raise ArgumentError, """
      a "quoted" \\ back??=slash %s %d \0 nul, é ünïcode, and a long tail .........................................
      ........................................................................................................ end\
      """
    end

    x
  end

  # a power-of-two check written the way Elixir would, raise in the else arm
  defk pow2(n :: i64) :: i64 do
    if n < 1 or band(n, n - 1) != 0 do
      raise ArgumentError, "n must be a power of two"
    else
      n
    end

    n
  end

  defk in_case(x :: i64) :: i64 do
    case rem(x, 3) do
      0 -> raise ArgumentError, "multiple of three"
      1 -> x
      _ -> x
    end

    x + 1
  end

  defk in_cond_arm(x :: i64) :: i64 do
    cond do
      x > 100 ->
        raise ArgumentError, "too big"
        0

      x < -100 ->
        raise ArgumentError, "too small"
        0

      true ->
        x
    end
  end

  # a raise before the value in a value-if arm
  defk value_if(x :: i64) :: i64 do
    if x >= 0 do
      x * 3
    else
      raise ArithmeticError, "negative"
      0
    end
  end

  defk in_reduce_while(a :: [i64]) :: i64 do
    Enum.reduce_while(0..(length(a) - 1)//1, 0, fn i, acc ->
      if a[i] < 0, do: raise(ArgumentError, "negative element")
      if a[i] == 0, do: {:halt, acc}, else: {:cont, acc + a[i]}
    end)
  end

  # a yielding loop: the raise happens after many safepoints
  defk in_loop(n :: i64, at :: i64) :: i64 do
    for i <- 0..(n - 1)//1, reduce: 0 do
      acc ->
        if i == at, do: raise(RuntimeError, "reached at")
        rem(acc + i * i, 1_000_003)
    end
  end

  # interpolated integers: the native message is formatted when it raises
  defk interp(x :: i64) :: i64 do
    if x != 0, do: raise(ArgumentError, "bad offset #{x} (twice: #{x * 2})")
    x
  end

  defk interp_u64(x :: u64) :: u64 do
    if x > 0x7FFFFFFFFFFFFFFF, do: raise(ArgumentError, message: "#{x} is above i64")
    x
  end

  defk interp_only(x :: i64) :: i64 do
    if x < 0, do: raise("#{x}")
    x
  end

  defk interp_byte(a :: [u8], i :: i64) :: i64 do
    if a[i] > 127, do: raise(ArithmeticError, "byte #{a[i]} at #{i} is not ASCII")
    a[i]
  end

  # each value is evaluated in order: a[i] out of range raises before div/2
  # divides by zero
  defk interp_order(a :: [i64], i :: i64) :: i64 do
    if i != 1, do: raise(ArgumentError, "#{a[i]} then #{div(1, i - 1)}")
    i
  end

  # longer than ctx->msg (200 bytes), with bytes C would reinterpret
  defk interp_long(x :: i64) :: i64 do
    if x < 0 do
      raise ArgumentError,
            "%s \"#{x}\" ??= \\ é \0 #{-x} ........................................................................................................................................................................................................ end"
    end

    x
  end

  defk interp_in_loop(n :: i64, at :: i64) :: i64 do
    for i <- 0..(n - 1)//1, reduce: 0 do
      acc ->
        if i == at, do: raise(RuntimeError, "reached #{i} with acc #{acc}")
        rem(acc + i * i, 1_000_003)
    end
  end

  defk callee(x :: i64) :: i64 do
    if x == 7, do: raise(ArgumentError, "seven")
    x
  end

  defk caller(x :: i64) :: i64 do
    callee(x) + 1
  end
end

defmodule Defk.RaiseTest do
  use ExUnit.Case, async: true

  import Defk.TestKit

  alias Defk.RaiseTest.K

  defp agrees(fun, args), do: Defk.Test.assert_agrees(K, fun, args)

  test "raise Module, \"message\" for each module, both modes" do
    assert {:ok, 6} = agrees(:arg, [3])
    assert {:raise, %ArgumentError{message: "x must not be negative"}} = agrees(:arg, [-1])
    assert {:ok, 50} = agrees(:arith, [2])
    assert {:raise, %ArithmeticError{message: "x is zero"}} = agrees(:arith, [0])
    assert {:raise, %RuntimeError{message: "x is too big"}} = agrees(:runtime, [10])
    assert {:raise, %RuntimeError{message: "x is too big"}} = agrees(:runtime_mod, [10])
    assert {:ok, 9} = agrees(:runtime, [9])
  end

  test "raise Module gives the module's default message" do
    for {fun, mod} <- [
          default_arg: ArgumentError,
          default_arith: ArithmeticError,
          default_runtime: RuntimeError
        ] do
      assert {:raise, e} = agrees(fun, [-1])
      assert e == mod.exception([])
      assert {:ok, 1} = agrees(fun, [1])
    end
  end

  test "the message reaches Exception.message/1 natively, byte for byte" do
    expected =
      "a \"quoted\" \\ back??=slash %s %d \0 nul, é ünïcode, and a long tail " <>
        String.duplicate(".", 41) <> "\n" <> String.duplicate(".", 104) <> " end"

    e = assert_raise ArgumentError, fn -> K.odd_message(-1) end
    assert Exception.message(e) == expected
    assert {:raise, ^e} = agrees(:odd_message, [-1])
    assert Exception.message(assert_raise(ArgumentError, fn -> K.arg(-5) end)) =~ "negative"
  end

  test "raise in if/else, case, cond and value-if arms" do
    for n <- [-4, 0, 1, 3, 6, 8, 64] do
      agrees(:pow2, [n])
    end

    assert {:raise, %ArgumentError{message: "n must be a power of two"}} = agrees(:pow2, [6])

    for x <- [-300, -3, 0, 1, 2, 3, 4, 5, 300],
        f <- [:in_case, :in_cond_arm, :value_if],
        do: agrees(f, [x])

    assert {:raise, %ArgumentError{message: "multiple of three"}} = agrees(:in_case, [3])
    assert {:raise, %ArgumentError{message: "too big"}} = agrees(:in_cond_arm, [101])
    assert {:raise, %ArgumentError{message: "too small"}} = agrees(:in_cond_arm, [-101])
    assert {:raise, %ArithmeticError{message: "negative"}} = agrees(:value_if, [-1])
  end

  test "raise in a reduce_while fn body and in an inlined callee" do
    arr = fn l -> for v <- l, into: <<>>, do: <<v::signed-native-64>> end
    assert {:ok, 6} = agrees(:in_reduce_while, [arr.([1, 2, 3])])
    assert {:ok, 3} = agrees(:in_reduce_while, [arr.([1, 2, 0, -1])])

    assert {:raise, %ArgumentError{message: "negative element"}} =
             agrees(:in_reduce_while, [arr.([1, -2, 3])])

    assert {:raise, %ArgumentError{message: "seven"}} = agrees(:caller, [7])
    assert {:ok, 9} = agrees(:caller, [8])
  end

  test "a message with interpolated integers, both modes" do
    assert {:ok, 0} = agrees(:interp, [0])
    assert {:raise, %ArgumentError{message: "bad offset 21 (twice: 42)"}} = agrees(:interp, [21])
    assert {:raise, %ArgumentError{message: "bad offset -5 (twice: -10)"}} = agrees(:interp, [-5])

    # the second value overflows: ArithmeticError, before any message
    assert {:raise, %ArithmeticError{}} = agrees(:interp, [-0x8000000000000000])

    assert {:raise, %ArgumentError{message: "18446744073709551615 is above i64"}} =
             agrees(:interp_u64, [0xFFFFFFFFFFFFFFFF])

    assert {:raise, %ArgumentError{message: "9223372036854775808 is above i64"}} =
             agrees(:interp_u64, [0x8000000000000000])

    assert {:raise, %RuntimeError{message: "-9223372036854775808"}} =
             agrees(:interp_only, [-0x8000000000000000])

    assert {:raise, %ArithmeticError{message: "byte 200 at 1 is not ASCII"}} =
             agrees(:interp_byte, [<<65, 200>>, 1])

    assert {:ok, 65} = agrees(:interp_byte, [<<65, 200>>, 0])
  end

  test "interpolated values are evaluated in order" do
    a = <<7::signed-native-64, 8::signed-native-64>>
    assert {:raise, %Enum.OutOfBoundsError{}} = agrees(:interp_order, [a, 5])
    assert {:raise, %ArgumentError{message: "7 then -1"}} = agrees(:interp_order, [a, 0])
    assert {:ok, 1} = agrees(:interp_order, [a, 1])
  end

  test "an interpolated message longer than the runtime's message buffer, byte for byte" do
    expected = "%s \"-3\" ??= \\ é \0 3 " <> String.duplicate(".", 200) <> " end"
    e = assert_raise ArgumentError, fn -> K.interp_long(-3) end
    assert Exception.message(e) == expected
    assert {:raise, ^e} = agrees(:interp_long, [-3])
  end

  for mode <- [:natural, :forced] do
    test "an interpolated raise inside a yielding loop (#{mode} yields)" do
      K.__defk_force_yields__(unquote(mode) == :forced)
      n = if unquote(mode) == :forced, do: 3000, else: 3_000_000

      try do
        y0 = K.__defk_stats__().yields
        assert {:raise, %RuntimeError{message: msg}} = agrees(:interp_in_loop, [n, n - 2])
        assert msg =~ ~r/^reached #{n - 2} with acc \d+$/

        if unquote(mode) == :forced,
          do: assert(K.__defk_stats__().yields - y0 > 0, "never yielded before the raise")
      after
        K.__defk_force_yields__(false)
      end
    end
  end

  for mode <- [:natural, :forced] do
    test "raise inside a yielding loop (#{mode} yields)" do
      K.__defk_force_yields__(unquote(mode) == :forced)
      n = if unquote(mode) == :forced, do: 3000, else: 3_000_000

      try do
        y0 = K.__defk_stats__().yields

        assert {:raise, %RuntimeError{message: "reached at"}} =
                 agrees(:in_loop, [n, n - 2])

        if unquote(mode) == :forced,
          do: assert(K.__defk_stats__().yields - y0 > 0, "never yielded before the raise")

        assert {:ok, _} = agrees(:in_loop, [n, n])
      after
        K.__defk_force_yields__(false)
      end
    end
  end

  describe "rejections" do
    defp compile_error(body), do: reject(__MODULE__, body)

    test "a computed message, or an interpolated value that is not an integer" do
      for {param, value, type} <- [
            {"x :: f64", "x", "f64"},
            {"x :: i64", "x > 0", "bool"},
            {"a :: [u8]", "a", "[u8]"}
          ] do
        msg =
          compile_error("""
          defk f(#{param}, n :: i64) :: i64 do
            if n < 1, do: raise(ArgumentError, "bad \#{#{value}}")
            n
          end
          """)

        assert msg =~ "(defk raise-message", msg
        assert msg =~ "a #{type}, into a raise message", msg
        assert msg =~ "only integers can be interpolated"
        assert msg =~ "put any other value in Elixir, before or after the call"
      end

      msg =
        compile_error(~S"""
        defk f(n :: i64) :: i64 do
          if n < 1, do: raise(ArgumentError, "a" <> "b")
          n
        end
        """)

      assert msg =~ "(defk raise-message"
    end

    test "raise as a value" do
      for body <- [
            "x = raise ArgumentError, \"no\"\n  n + x",
            "raise ArgumentError, \"no\"",
            "if n > 0, do: n, else: raise(ArgumentError, \"no\")"
          ] do
        msg = compile_error("defk f(n :: i64) :: i64 do\n  #{body}\nend")
        assert msg =~ "(defk raise-value", msg
        assert msg =~ "raise is a statement; put it before the value"
      end

      msg =
        compile_error("""
        defk f(a :: [i64]) :: i64 do
          Enum.reduce_while(0..(length(a) - 1)//1, 0, fn i, acc ->
            if a[i] < 0, do: raise(ArgumentError, "no"), else: {:cont, acc + a[i]}
          end)
        end
        """)

      assert msg =~ "(defk raise-value", msg
    end

    test "another module" do
      msg =
        compile_error("""
        defk f(n :: i64) :: i64 do
          if n < 1, do: raise(KeyError, "no")
          n
        end
        """)

      assert msg =~ "(defk raise-module"
      assert msg =~ "use ArgumentError, ArithmeticError or RuntimeError"
      assert msg =~ ~s{raise ArgumentError, "no"}
    end
  end
end
