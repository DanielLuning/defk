# Bitwise operators on i64: band/bor/bxor/bnot in two's
# complement, bsl/bsr exact as Elixir computes them over bignums, raising
# ArithmeticError where bsl's result leaves i64. Both spellings (band(a, b)
# and a &&& b), against Elixir mode and against Bitwise itself.

defmodule Defk.BitwiseTest.K do
  use Defk

  defk band_f(a :: i64, b :: i64) :: i64 do
    band(a, b)
  end

  defk bor_f(a :: i64, b :: i64) :: i64 do
    bor(a, b)
  end

  defk bxor_f(a :: i64, b :: i64) :: i64 do
    bxor(a, b)
  end

  defk bnot_f(a :: i64) :: i64 do
    bnot(a)
  end

  defk bsl_f(a :: i64, n :: i64) :: i64 do
    bsl(a, n)
  end

  defk bsr_f(a :: i64, n :: i64) :: i64 do
    bsr(a, n)
  end

  defk band_op(a :: i64, b :: i64) :: i64 do
    a &&& b
  end

  defk bor_op(a :: i64, b :: i64) :: i64 do
    a ||| b
  end

  defk bsl_op(a :: i64, n :: i64) :: i64 do
    a <<< n
  end

  defk bsr_op(a :: i64, n :: i64) :: i64 do
    a >>> n
  end

  defk band_remote(a :: i64, b :: i64) :: i64 do
    Bitwise.band(a, b)
  end

  defk bsl_erlang(a :: i64, n :: i64) :: i64 do
    :erlang.bsl(a, n)
  end

  # a shift by a non-negative amount cannot overflow (defk_bsr_nn)
  defk bsr_nonneg(a :: i64, n :: i64) :: i64 do
    a >>> band(n, 127)
  end

  # bitwise arms stay a select: only the + - and the shift's flag can raise
  defk pick(c :: bool, a :: i64, b :: i64, n :: i64) :: i64 do
    if c, do: band(a, b) + n, else: (a >>> n) - bxor(a, bnot(b))
  end

  defk pick_shift(c :: bool, a :: i64, n :: i64) :: i64 do
    if c, do: a <<< n, else: a ||| n
  end
end

# `~~~` and `^^^` (deprecated by Elixir 1.20 in favour of bnot/1 and bxor/2,
# which the parser warns about) are parsed here without the warning
[{_, _}] =
  """
  defmodule Defk.BitwiseTest.Deprecated do
    use Defk

    defk bnot_op(a :: i64) :: i64 do
      ~~~a
    end

    defk bxor_op(a :: i64, b :: i64) :: i64 do
      a ^^^ b
    end
  end
  """
  |> Code.string_to_quoted!(emit_warnings: false, file: "bitwise_deprecated")
  |> Code.compile_quoted("bitwise_deprecated")

# indexes proven in range by the bitwise range facts: no bounds check
defmodule Defk.BitwiseTest.Lookup do
  use Defk

  defk low_byte(h :: i64) :: i64 do
    table = alloc(u8, 256)
    table[band(h, 255)]
  end

  defk second_byte(h :: i64) :: i64 do
    table = alloc(u8, 256)
    table[band(h, 0xFFFF) >>> 8]
  end

  defk mixed_byte(h :: i64) :: i64 do
    table = alloc(u8, 256)
    table[bxor(band(h, 0x0F), bor(band(h >>> 4, 0xF0), 3))]
  end

  defk not_byte(h :: i64) :: i64 do
    table = alloc(u8, 256)
    table[bnot(band(h, 255)) + 256]
  end
end

# a mask one past the table keeps its bounds check
defmodule Defk.BitwiseTest.Wide do
  use Defk

  defk wide(h :: i64) :: i64 do
    table = alloc(u8, 256)
    table[band(h, 256)]
  end
end

defmodule Defk.BitwiseTest do
  use ExUnit.Case, async: true
  use Defk.Properties

  import Bitwise
  import Defk.TestKit

  alias Defk.BitwiseTest.{Deprecated, K, Lookup, Wide}

  @min -0x8000000000000000
  @max 0x7FFFFFFFFFFFFFFF

  @values [
    0,
    1,
    -1,
    2,
    -2,
    3,
    255,
    -256,
    0x5555555555555555,
    -0x5555555555555556,
    2 ** 31,
    2 ** 62 - 1,
    2 ** 62,
    -(2 ** 62),
    -(2 ** 62) - 1,
    @min,
    @min + 1,
    @max,
    @max - 1
  ]

  @shifts [0, 1, 2, 31, 32, 61, 62, 63, 64, 65, 127, -1, -2, -62, -63, -64, -65, -127] ++
            [@min, @min + 1, @max, @max - 1]

  # Elixir's own answer limited to i64: the value, or :overflow. A shift past
  # 127 is decided by its sign alone (Bitwise would build a huge bignum).
  defp elixir_shift(f, a, n) do
    n = if f == :bsr, do: -n, else: n
    n = n |> max(-128) |> min(128)
    r = Bitwise.bsl(a, n)
    if r in @min..@max, do: r, else: :overflow
  end

  defp agrees(mod \\ K, fun, args) do
    Defk.Test.assert_agrees(mod, fun, args)
  end

  defp expect(outcome, :overflow) do
    assert {:raise, %ArithmeticError{message: "i64 overflow in " <> _} = e} = outcome
    assert Defk.Test.agreement_reason(e) == :overflow
  end

  defp expect(outcome, value), do: assert(outcome == {:ok, value})

  test "band, bor, bxor and bnot match Bitwise in both spellings" do
    for a <- @values, b <- @values do
      expect(agrees(:band_f, [a, b]), band(a, b))
      expect(agrees(:band_op, [a, b]), band(a, b))
      expect(agrees(:band_remote, [a, b]), band(a, b))
      expect(agrees(:bor_f, [a, b]), bor(a, b))
      expect(agrees(:bor_op, [a, b]), bor(a, b))
      expect(agrees(:bxor_f, [a, b]), bxor(a, b))
      expect(agrees(Deprecated, :bxor_op, [a, b]), bxor(a, b))
    end

    for a <- @values do
      expect(agrees(:bnot_f, [a]), bnot(a))
      expect(agrees(Deprecated, :bnot_op, [a]), bnot(a))
    end
  end

  test "bsl and bsr are exact in i64, and bsl raises where the result leaves it" do
    for a <- @values, n <- @shifts do
      expect(agrees(:bsl_f, [a, n]), elixir_shift(:bsl, a, n))
      expect(agrees(:bsl_op, [a, n]), elixir_shift(:bsl, a, n))
      expect(agrees(:bsl_erlang, [a, n]), elixir_shift(:bsl, a, n))
      expect(agrees(:bsr_f, [a, n]), elixir_shift(:bsr, a, n))
      expect(agrees(:bsr_op, [a, n]), elixir_shift(:bsr, a, n))
    end
  end

  test "bsl at the boundary bits" do
    assert K.bsl_f(1, 62) == 2 ** 62
    assert K.bsl_f(-1, 63) == @min
    assert K.bsl_f(-(2 ** 62), 1) == @min
    assert K.bsl_f(2 ** 62 - 1, 1) == @max - 1
    assert K.bsl_f(3, 61) == 3 * 2 ** 61
    assert K.bsl_f(0, @max) == 0
    assert K.bsr_f(-5, @max) == -1

    for {a, n} <- [{1, 63}, {2 ** 62, 1}, {-(2 ** 62) - 1, 1}, {3, 62}, {-1, 64}, {1, @max}] do
      assert_raise ArithmeticError, "i64 overflow in bsl(#{a}, #{n})", fn -> K.bsl_f(a, n) end
      expect(agrees(:bsl_f, [a, n]), :overflow)
    end

    # a negative bsr shift is a bsl
    assert_raise ArithmeticError, "i64 overflow in bsr(1, -63)", fn -> K.bsr_f(1, -63) end
    assert_raise ArithmeticError, "i64 overflow in bsr(1, #{@min})", fn -> K.bsr_f(1, @min) end
    assert K.bsr_f(0, @min) == 0
  end

  test "a bsr by a non-negative shift never raises" do
    for a <- @values, n <- @shifts do
      expect(agrees(:bsr_nonneg, [a, n]), bsr(a, band(n, 127)))
    end
  end

  test "bitwise expressions in if arms compile to a select" do
    # only pick and pick_shift have if arms: the flagged forms are theirs
    c = K.__defk_c_source__()
    assert c =~ "defk_add_i64_s(&"
    assert c =~ "defk_bsr_i64_s(&"
    assert c =~ "defk_bsl_i64_s(&"

    for c <- [true, false], a <- @values, b <- [0, -1, 7], n <- [0, 3, 64, -1, @max] do
      agrees(:pick, [c, a, b, n])
      agrees(:pick_shift, [c, a, n])
    end

    # the untaken arm's overflow does not raise
    assert K.pick_shift(false, 1, 64) == 65
    assert_raise ArithmeticError, fn -> K.pick_shift(true, 1, 64) end
  end

  test "masked indexes into a 256-element table have no bounds check" do
    refute Lookup.__defk_c_source__() =~ "defk_get_u8("
    assert Wide.__defk_c_source__() =~ "defk_get_u8("

    for h <- @values do
      expect(agrees(Lookup, :low_byte, [h]), 0)
      expect(agrees(Lookup, :second_byte, [h]), 0)
      expect(agrees(Lookup, :mixed_byte, [h]), 0)
      expect(agrees(Lookup, :not_byte, [h]), 0)
    end

    assert {:raise, %Enum.OutOfBoundsError{}} = agrees(Wide, :wide, [256])
  end

  # ------------------------------------------------------------ rejections --

  defp rejection(body, sig), do: reject(__MODULE__, kernel(sig, "i64", body))

  test "a float operand is an operand-type error" do
    msg = rejection("band(x, 1)", "x :: f64")
    assert codes(msg) == ["operand-type"]
    assert whats(msg) == ["band/2 takes integers, and x is f64"]
    assert msg =~ "trunc(x)"

    msg = rejection("x <<< 1", "x :: f64")
    assert whats(msg) == ["<<< takes integers, and x is f64"]
  end

  test "a bool operand is an operand-type error" do
    msg = rejection("Bitwise.bxor(1, b)", "b :: bool")
    assert codes(msg) == ["operand-type"]
    assert whats(msg) == ["Bitwise.bxor/2 takes integers, and b is bool"]
    assert msg =~ "if b, do: 1, else: 0"
  end

  test "a mask beyond u64 is rejected as an integer literal" do
    msg = rejection("band(x, 0x1FFFFFFFFFFFFFFFF)", "x :: i64")
    assert codes(msg) == ["integer-literal"]

    # 2 ** 64 - 1 is not a literal: ** is outside the subset
    msg = rejection("band(x, 2 ** 64 - 1)", "x :: i64")
    assert codes(msg) == ["unsupported-expression"]
  end

  test "a literal shift that overflows i64 is rejected" do
    msg = rejection("(1 <<< 64) - 1", "x :: i64")
    assert codes(msg) == ["shift-overflow"]
    assert whats(msg) == ["1 <<< 64 does not fit in i64"]

    msg = rejection("bsr(1, -63)", "x :: i64")
    assert whats(msg) == ["bsr(1, -63) does not fit in i64"]
  end

  # ---------------------------------------------------- agreement properties --
  # Values from the edge-biased i64 generator; shifts around 0, ±63, ±64 and
  # the i64 limits.

  defp shift do
    one_of([
      G.i64(-130..130, [@min, @max, @min + 1, @max - 1]),
      member_of([-65, -64, -63, 62, 63, 64, 65]),
      G.i64()
    ])
  end

  defp shifted, do: fixed_list([G.i64(), shift()])

  agreement(K,
    band_f: [],
    bor_f: [],
    bxor_f: [],
    bnot_f: [],
    bsl_f: [args: shifted()],
    bsr_f: [args: shifted()],
    band_op: [],
    bor_op: [],
    bsl_op: [args: shifted()],
    bsr_op: [args: shifted()],
    band_remote: [],
    bsl_erlang: [args: shifted()],
    bsr_nonneg: [args: shifted()],
    pick: [args: fixed_list([boolean(), G.i64(), G.i64(), shift()])],
    pick_shift: [args: fixed_list([boolean(), G.i64(), shift()])]
  )

  agreement(Deprecated, [:bnot_op, :bxor_op])
  agreement(Lookup, [:low_byte, :second_byte, :mixed_byte, :not_byte])
  agreement(Wide, [:wide])
end
