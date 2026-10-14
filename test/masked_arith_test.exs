# Masked arithmetic (CONTEXT.md): the + - * neg bsl tree directly
# under band(expr, 2^k - 1) is computed with wrapping machine arithmetic and
# masked once, which gives Elixir's exact result (band of the bignum) and
# never raises (band bor bxor bnot join the tree, k = 64 and u64 are in
# test/u64_test.exs); wrap64(expr) wraps the same tree to the 64-bit pattern
# (Defk.Bits.wrap64/1), while band(expr, -1) is Elixir's identity, checked
# like any band whose operand is not a 2^k - 1 mask. Anything else in
# the tree is a leaf and is checked as usual; a mask that is not 2^k - 1 gets
# the checked form.

defmodule Defk.MaskedArithTest.K do
  use Defk

  # FNV-1a 64: offset basis 0xCBF29CE484222325 as its i64 bit pattern
  defk fnv1a64(b :: [u8]) :: i64 do
    for x <- b, reduce: -3_750_763_034_362_895_579 do
      h -> wrap64(bxor(h, x) * 1_099_511_628_211)
    end
  end

  defk fnv1a32(b :: [u8]) :: i64 do
    for x <- b, reduce: 2_166_136_261 do
      h -> band(bxor(h, x) * 16_777_619, 0xFFFFFFFF)
    end
  end

  # FNV-style mixing a word at a time, tail bytes ignored
  defk word_hash(b :: [u8]) :: i64 do
    for i <- 0..(length(b) - 8)//8, reduce: -3_750_763_034_362_895_579 do
      h -> wrap64(bxor(h, u64_le(b, i)) * 1_099_511_628_211 + bsl(h, 5))
    end
  end

  defk(mul32(x :: i64, y :: i64) :: i64, do: band(x * y, 0xFFFFFFFF))
  defk(mul_plain(x :: i64, y :: i64) :: i64, do: x * y)
  defk(add8(x :: i64, y :: i64) :: i64, do: band(x + y, 255))
  defk(add8_left(x :: i64, y :: i64) :: i64, do: band(255, x + y))
  defk(add8_op(x :: i64, y :: i64) :: i64, do: x + y &&& 255)
  defk(add8_remote(x :: i64, y :: i64) :: i64, do: Bitwise.band(x - y, 0xFF))
  defk(wrap_poly(x :: i64, y :: i64) :: i64, do: wrap64(x * y + x - y * y))
  defk(wrap_leaf(x :: i64) :: i64, do: wrap64(x))
  # band with -1 is Elixir's identity: the product is checked
  defk(band_ones(x :: i64, y :: i64) :: i64, do: band(x * y, -1))
  defk(wrap63(x :: i64, y :: i64) :: i64, do: band(x * y - x, 0x7FFFFFFFFFFFFFFF))
  defk(neg_shift(x :: i64, y :: i64) :: i64, do: band(-x + (y <<< 13) - bsl(x, 64) + +y, 0xFFFF))
  defk(k1(x :: i64, y :: i64) :: i64, do: band(x * y, 1))

  defk nested(x :: i64, y :: i64) :: i64 do
    band(band(x * y, 0xFFFF) * band(x + y, 0xFF) * x + 1, 0xFFFFFF)
  end

  # a leaf is checked: div by zero raises, and the product inside rem/2 is
  # outside the tree (it overflows and raises)
  defk(leaf_div(x :: i64, y :: i64) :: i64, do: band(div(x, y) * 3, 255))
  defk(leaf_rem(x :: i64, y :: i64) :: i64, do: band(x * y + rem(x * y, 7), 255))
  # bsr is a leaf, exact
  defk(leaf_bsr(x :: i64, y :: i64) :: i64, do: band(bsr(x, 3) * y, 0xFFFF))
  # a bsl by a non-literal count is in the tree: it wraps, and a
  # negative count raises
  defk(var_bsl(x :: i64, n :: i64) :: i64, do: band(bsl(x, n) + 1, 255))

  # not masks: checked
  defk(not_mask(x :: i64, y :: i64) :: i64, do: band(x * y, 254))
  defk(var_mask(x :: i64, y :: i64, m :: i64) :: i64, do: band(x * y, m))

  # in the arms of a select
  defk pick(c :: bool, x :: i64, y :: i64) :: i64 do
    if c, do: band(x * y, 255), else: x + y
  end

  # a module attribute is its literal
  @mask32 0xFFFFFFFF
  @all_ones -1
  defk(attr_mask(x :: i64, y :: i64) :: i64, do: band(x * y, @mask32))
  defk(attr_ones(x :: i64, y :: i64) :: i64, do: band(x * y, @all_ones))

  # the masked result's range drops the bounds check
  defk lookup(x :: i64, y :: i64) :: i64 do
    table = alloc(u8, 256)
    table[band(x * y + 7, 255)]
  end
end

defmodule Defk.MaskedArithTest do
  use ExUnit.Case, async: true
  use Defk.Properties

  import Bitwise
  import Defk.TestKit

  alias Defk.MaskedArithTest.K

  @min -0x8000000000000000
  @max 0x7FFFFFFFFFFFFFFF
  @values [0, 1, -1, 2, 255, 256, -256, 2 ** 32, 2 ** 32 - 1, 2 ** 62, -(2 ** 62)] ++
            [@min, @min + 1, @max, @max - 1, 0x5555555555555555, 3_037_000_500]

  doctest Defk.Bits

  defp agrees(fun, args), do: Defk.Test.assert_agrees(K, fun, args)

  # the signed 64-bit pattern of the low 64 bits of an exact integer
  defp s64(x) do
    <<s::signed-64>> = <<x::64>>
    s
  end

  # FNV-1a over bignums, as written without a kernel: unsigned, masked
  defp fnv1a(bytes, basis, prime, mask) do
    for <<b <- bytes>>, reduce: basis do
      h -> band(bxor(h, b) * prime, mask)
    end
  end

  test "FNV-1a 64 agrees with Bitwise on bignums masked to 64 bits" do
    for bytes <- ["", "a", "foobar", :crypto.strong_rand_bytes(1000)] do
      expect = fnv1a(bytes, 0xCBF29CE484222325, 0x100000001B3, 0xFFFFFFFFFFFFFFFF)
      assert agrees(:fnv1a64, [bytes]) == {:ok, s64(expect)}
    end

    # the published test vector: FNV-1a 64 of "a" is 0xaf63dc4c8601ec8c
    assert K.fnv1a64("a") == s64(0xAF63DC4C8601EC8C)
  end

  test "FNV-1a 32 with the 2^32 - 1 mask" do
    for bytes <- ["", "a", "foobar", :crypto.strong_rand_bytes(1000)] do
      assert agrees(:fnv1a32, [bytes]) ==
               {:ok, fnv1a(bytes, 2_166_136_261, 16_777_619, 0xFFFFFFFF)}
    end

    assert K.fnv1a32("a") == 0xE40C292C
  end

  test "a word-at-a-time hash agrees" do
    for n <- [0, 7, 8, 9, 64, 1001] do
      bytes = :crypto.strong_rand_bytes(n)

      expect =
        for <<w::little-64 <- binary_part(bytes, 0, n - rem(n, 8))>>,
          reduce: 0xCBF29CE484222325 do
          h -> band(bxor(h, w) * 0x100000001B3 + (h <<< 5), 0xFFFFFFFFFFFFFFFF)
        end

      assert agrees(:word_hash, [bytes]) == {:ok, s64(expect)}
    end
  end

  test "overflowing arithmetic inside a mask gives Elixir's exact result, outside it raises" do
    for x <- @values, y <- @values do
      assert agrees(:mul32, [x, y]) == {:ok, band(x * y, 0xFFFFFFFF)}
      assert agrees(:add8, [x, y]) == {:ok, band(x + y, 255)}
      assert agrees(:add8_left, [x, y]) == {:ok, band(x + y, 255)}
      assert agrees(:add8_op, [x, y]) == {:ok, band(x + y, 255)}
      assert agrees(:add8_remote, [x, y]) == {:ok, band(x - y, 255)}
      assert agrees(:wrap_poly, [x, y]) == {:ok, Defk.Bits.wrap64(x * y + x - y * y)}
      assert agrees(:wrap_leaf, [x]) == {:ok, x}

      expect = if (x * y) in @min..@max, do: {:ok, x * y}, else: :overflow

      for f <- [:band_ones, :attr_ones] do
        case {agrees(f, [x, y]), expect} do
          {{:raise, %ArithmeticError{} = e}, :overflow} ->
            assert Defk.Test.agreement_reason(e) == :overflow

          {got, want} ->
            assert got == want
        end
      end

      assert agrees(:wrap63, [x, y]) == {:ok, band(x * y - x, @max)}
      assert agrees(:k1, [x, y]) == {:ok, band(x * y, 1)}

      assert agrees(:neg_shift, [x, y]) ==
               {:ok, band(-x + (y <<< 13) - (x <<< 64) + y, 0xFFFF)}

      assert agrees(:nested, [x, y]) ==
               {:ok, band(band(x * y, 0xFFFF) * band(x + y, 0xFF) * x + 1, 0xFFFFFF)}

      agrees(:mul_plain, [x, y])
    end

    for x <- @values, y <- @values do
      assert agrees(:attr_mask, [x, y]) == {:ok, band(x * y, 0xFFFFFFFF)}
    end

    assert K.add8(@max, 1) == 0
    assert K.mul32(@max, @max) == 1
    # 2^63 + -2^63 - 1, though 2^63 alone is not an i64
    assert K.wrap_poly(@min, -1) == -1

    assert_raise ArithmeticError, "i64 overflow in #{@max} * #{@max}", fn ->
      K.mul_plain(@max, @max)
    end
  end

  test "leaves are checked: div, rem; a bsl by a variable count wraps" do
    assert {:raise, %ArithmeticError{message: "div/2 by zero"}} = agrees(:leaf_div, [1, 0])
    assert agrees(:leaf_div, [@min, 1]) == {:ok, band(@min * 3, 255)}
    assert {:raise, %ArithmeticError{} = e} = agrees(:leaf_rem, [@max, 2])
    assert Defk.Test.agreement_reason(e) == :overflow
    assert agrees(:leaf_rem, [3, 5]) == {:ok, band(15 + rem(15, 7), 255)}
    assert agrees(:leaf_bsr, [@min, @max]) == {:ok, band((@min >>> 3) * @max, 0xFFFF)}
    assert agrees(:var_bsl, [1, 63]) == {:ok, 1}
    assert agrees(:var_bsl, [3, 7]) == {:ok, band((3 <<< 7) + 1, 255)}
    assert agrees(:var_bsl, [@max, 200]) == {:ok, 1}
    assert {:raise, %ArithmeticError{} = e} = agrees(:var_bsl, [1, -1])
    assert Defk.Test.agreement_reason(e) == :negative_shift
  end

  test "a mask that is not 2^k - 1, or not a literal, gets the checked form" do
    assert_raise ArithmeticError, fn -> K.not_mask(@max, 2) end
    assert_raise ArithmeticError, fn -> K.var_mask(@max, 2, 255) end
    assert agrees(:not_mask, [7, 3]) == {:ok, band(21, 254)}
    assert agrees(:var_mask, [7, 3, 255]) == {:ok, 21}

    for x <- @values, y <- @values do
      agrees(:not_mask, [x, y])
      agrees(:var_mask, [x, y, 0xFFFF])
    end
  end

  test "masked arithmetic needs no overflow flag in a select, and its range drops a bounds check" do
    for c <- [true, false], x <- @values, y <- @values, do: agrees(:pick, [c, x, y])
    assert K.pick(true, @max, @max) == 1

    src = K.__defk_c_source__()
    refute src =~ "defk_get_u8("
    for x <- @values, y <- @values, do: assert(agrees(:lookup, [x, y]) == {:ok, 0})
  end

  # ------------------------------------------------------------ rejections --

  defp rejection(body, sig), do: reject(__MODULE__, kernel(sig, "i64", body))

  test "a float or bool in masked arithmetic gets the error it gets without the mask" do
    msg = rejection("band(x + 1.5, 255)", "x :: i64")
    assert codes(msg) == ["operand-type"]
    assert whats(msg) == ["band/2 takes integers, and x + 1.5 is f64"]

    msg = rejection("band(x * b, 255)", "x :: i64, b :: bool")
    assert codes(msg) == ["operand-type"]
    assert whats(msg) == ["* takes numbers, and b is bool"]

    msg = rejection("band(bsl(y, 3) + x, 255)", "x :: i64, y :: f64")
    assert whats(msg) == ["bsl/2 takes integers, and y is f64"]

    msg = rejection("wrap64(x * 1.5)", "x :: i64")
    assert whats(msg) == ["wrap64/1 takes integers, and x * 1.5 is f64"]
  end

  # ---------------------------------------------------- agreement properties --

  defp bytes, do: G.array(:u8, max_length: 200)

  agreement(K,
    fnv1a64: [args: fixed_list([bytes()])],
    fnv1a32: [args: fixed_list([bytes()])],
    word_hash: [args: fixed_list([bytes()])],
    mul32: [],
    mul_plain: [],
    add8: [],
    add8_left: [],
    add8_op: [],
    add8_remote: [],
    wrap_poly: [],
    wrap_leaf: [],
    band_ones: [],
    wrap63: [],
    neg_shift: [],
    k1: [],
    nested: [],
    leaf_div: [],
    leaf_rem: [],
    leaf_bsr: [],
    var_bsl: [args: fixed_list([G.i64(), G.i64(-70..70, [@min, @max])])],
    not_mask: [],
    var_mask: [],
    pick: [],
    lookup: [],
    attr_mask: [],
    attr_ones: []
  )
end
