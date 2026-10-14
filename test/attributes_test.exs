# Module attributes as constants in kernel bodies: an integer,
# float or boolean attribute is inlined as its literal, a binary attribute is
# a [u8] (a write copies it first), and any other value is a compile error.

defmodule Defk.AttributesTest.K do
  use Defk

  @s16_max 32_767
  @s16_min -32_768
  @scale 0.5
  @offset -1.5
  @mask 255
  @size 256
  @lim 10
  @step 3
  @strict true
  @table for i <- 0..255, into: <<>>, do: <<rem(i * 37 + 11, 256)>>
  @alphabet "0123456789bcdefghjkmnpqrstuvwxyz"

  defk clip(x :: i64) :: i64 do
    min(max(x, @s16_min), @s16_max)
  end

  defk scaled(x :: f64) :: f64 do
    x * @scale + @offset
  end

  # a literal mask's range: the read of the 256-element array keeps no check
  defk masked_sum(hs :: [i64]) :: i64 do
    t = alloc(i64, @size)

    for i <- 0..(@size - 1)//1 do
      t[i] = i * 3
    end

    for h <- hs, reduce: 0 do
      acc -> acc + t[band(h, @mask)]
    end
  end

  # the same through a 256-byte binary attribute
  defk table_sum(hs :: [i64]) :: i64 do
    for h <- hs, reduce: 0 do
      acc -> acc + @table[band(h, @mask)]
    end
  end

  defk classify(x :: i64) :: i64 do
    case x do
      @lim -> 1
      @s16_min -> 2
      y when @strict and y > @lim -> 3
      _ -> 0
    end
  end

  defk above?(x :: i64) :: bool do
    x > @lim == @strict
  end

  defk stepped(n :: i64) :: i64 do
    for i <- @lim..n//@step, reduce: 0 do
      acc -> acc + i
    end
  end

  # indexed, measured with length, raises out of range like any array read
  defk char_at(i :: i64) :: i64 do
    @alphabet[rem(i, length(@alphabet))]
  end

  defk count_byte(s :: [u8], b :: i64) :: i64 do
    for c <- s, reduce: 0 do
      acc -> if c == b, do: acc + 1, else: acc
    end
  end

  # passed to a kernel, bound to a variable
  defk alphabet_count(b :: i64) :: i64 do
    a = @alphabet
    count_byte(a, b) + count_byte(@alphabet, b + 1)
  end

  defk byte_sum(k :: i64) :: i64 do
    for c <- @alphabet, reduce: k do
      acc -> acc + c
    end
  end

  # a long loop over a binary attribute, for forced yields
  defk table_rounds(n :: i64) :: i64 do
    for i <- 0..(n - 1)//1, reduce: 0 do
      acc -> band(acc * 31 + @table[band(i, @mask)], 0xFFFFFFFF)
    end
  end

  # a def would see the value where it is defined; so does a kernel
  defk lim_before(x :: i64) :: i64 do
    x + @lim
  end

  @lim 20

  defk lim_after(x :: i64) :: i64 do
    x + @lim
  end

  # returned unwritten: a new binary of its bytes
  defk alphabet_or(c :: bool, b :: [u8]) :: [u8] do
    if c, do: @alphabet, else: b
  end
end

defmodule Defk.AttributesTest do
  use ExUnit.Case, async: true
  use Defk.Properties

  import Defk.TestKit, only: [codes: 1, forced: 2, i64s: 1, kernel_c: 2, reject: 2, whats: 1]

  alias Defk.AttributesTest.K

  @table for i <- 0..255, into: <<>>, do: <<rem(i * 37 + 11, 256)>>
  @alphabet "0123456789bcdefghjkmnpqrstuvwxyz"

  defp agrees(fun, args), do: Defk.Test.assert_agrees(K, fun, args)

  test "integer and float attributes in arithmetic" do
    assert K.clip(40_000) == 32_767
    assert K.clip(-40_000) == -32_768
    assert K.clip(5) == 5
    assert K.scaled(3.0) == 0.0
    for x <- [40_000, -40_000, 5], do: agrees(:clip, [x])
    for x <- [3.0, -1.0e300, 0.1], do: agrees(:scaled, [x])
  end

  test "a band mask attribute indexes a 256-element array without a bounds check" do
    hs = [0, 1, 255, 256, -1, 1_000_000]
    expect = Enum.sum(for h <- hs, do: Bitwise.band(h, 255) * 3)
    assert K.masked_sum(i64s(hs)) == expect
    agrees(:masked_sum, [i64s(hs)])
    refute kernel_c(K, "masked_sum") =~ "defk_get_"
  end

  test "a binary attribute is a [u8] whose masked read keeps no bounds check" do
    hs = [0, 7, 255, 256, -3]
    expect = Enum.sum(for h <- hs, do: :binary.at(@table, Bitwise.band(h, 255)))
    assert K.table_sum(i64s(hs)) == expect
    agrees(:table_sum, [i64s(hs)])
    refute kernel_c(K, "table_sum") =~ "defk_get_"
  end

  test "attributes as case literals and in guards" do
    assert Enum.map([10, -32_768, 11, 3], &K.classify/1) == [1, 2, 3, 0]
    for x <- [10, -32_768, 11, 3], do: agrees(:classify, [x])
    assert K.above?(11) and not K.above?(10)
  end

  test "attributes as range bounds and step" do
    assert K.stepped(20) == Enum.sum(10..20//3)
    assert K.stepped(5) == 0
    agrees(:stepped, [20])
  end

  test "a binary attribute is indexed, measured, bound and passed to a kernel" do
    assert K.char_at(0) == ?0
    assert K.char_at(33) == ?1
    assert_raise Enum.OutOfBoundsError, fn -> K.char_at(-1) end
    for i <- [0, 33, -1], do: agrees(:char_at, [i])
    assert K.alphabet_count(?b) == 2
    assert K.alphabet_count(?a) == 1
    agrees(:alphabet_count, [?z])
    assert K.byte_sum(1) == Enum.sum(:binary.bin_to_list(@alphabet)) + 1
    agrees(:byte_sum, [1])
  end

  test "a binary attribute read survives forced yields" do
    expect =
      Enum.reduce(0..9_999, 0, fn i, acc ->
        Bitwise.band(acc * 31 + :binary.at(@table, Bitwise.band(i, 255)), 0xFFFFFFFF)
      end)

    forced(K, fn -> assert K.table_rounds(10_000) == expect end)

    agrees(:table_rounds, [10_000])
  end

  test "a kernel reads an attribute's value where it is defined, as a def does" do
    assert K.lim_before(0) == 10
    assert K.lim_after(0) == 20
    agrees(:lim_before, [1])
    agrees(:lim_after, [1])
    assert @alphabet == "0123456789bcdefghjkmnpqrstuvwxyz"
  end

  agreement(K,
    clip: [args: StreamData.fixed_list([G.i64(-70_000..70_000)])],
    scaled: [],
    masked_sum: [],
    table_sum: [],
    classify: [args: StreamData.fixed_list([G.i64(-40_000..40_000, [10, -32_768])])],
    above?: [],
    stepped: [args: StreamData.fixed_list([G.i64(-100..5_000)])],
    char_at: [],
    count_byte: [],
    alphabet_count: [args: StreamData.fixed_list([G.i64(0..300)])],
    byte_sum: [],
    table_rounds: [args: StreamData.fixed_list([G.i64(0..2_000)])],
    lim_before: [],
    lim_after: [],
    alphabet_or: []
  )

  test "a binary attribute is returned unwritten, also from a branch" do
    assert K.alphabet_or(true, "x") == @alphabet
    b = :binary.copy("x", 100)
    assert :erts_debug.same(K.alphabet_or(false, b), b)
    agrees(:alphabet_or, [true, "x"])
  end

  describe "compile errors" do
    defp rejected(body), do: reject(__MODULE__, body)

    defp kernel(attr, expr, sig \\ "i :: i64", ret \\ "i64"),
      do: "#{attr}\n\ndefk f(#{sig}) :: #{ret} do\n  #{expr}\nend"

    test "a list attribute, with a binary rewrite for a list of bytes" do
      msg = rejected(kernel("@items [1, 2, 3]", "i + @items"))
      assert codes(msg) == ["attribute-value"]
      assert whats(msg) == ["@items is a list, which is not in the kernel subset"]
      assert msg =~ "pack it into a binary attribute"
      assert msg =~ "@items <<1, 2, 3>>"

      msg = rejected(kernel("@weights [0.5, 2.0]", "i + @weights"))
      assert codes(msg) == ["attribute-value"]
      assert msg =~ "pass it as an array parameter"
    end

    test "an undefined attribute" do
      msg = rejected(kernel("", "i + @nope"))
      assert codes(msg) == ["undefined-attribute"]
      assert whats(msg) == ["@nope is not defined where this kernel is defined"]
    end

    test "an atom, nil, a tuple and a map" do
      for {attr, what} <- [
            {":fast", "the atom :fast"},
            {"nil", "nil"},
            {"{1, 2}", "a tuple"},
            {"%{a: 1}", "a map"}
          ] do
        msg = rejected(kernel("@mode #{attr}", "i + @mode"))
        assert codes(msg) == ["attribute-value"], msg
        assert whats(msg) == ["@mode is #{what}, which is not in the kernel subset"]
      end
    end

    test "an accumulating attribute is a list" do
      body =
        "Module.register_attribute(__MODULE__, :acc, accumulate: true)\n@acc 1\n\n" <>
          kernel("", "i + @acc")

      assert codes(rejected(body)) == ["attribute-value"]
    end

    test "a bignum attribute is the integer-literal error" do
      msg = rejected(kernel("@big 18_446_744_073_709_551_616", "i + @big"))
      assert codes(msg) == ["integer-literal"]
      assert whats(msg) == ["@big is 18446744073709551616, which does not fit in i64 or u64"]
    end

    test "a bad attribute in a case pattern or guard names the attribute" do
      msg = rejected(kernel("@k [1]", "case i do\n    @k -> 1\n    _ -> 0\n  end"))
      assert codes(msg) == ["attribute-value"]

      msg = rejected(kernel("@k :a", "case i do\n    y when y > @k -> 1\n    _ -> 0\n  end"))
      assert codes(msg) == ["attribute-value"]

      msg = rejected(kernel("@k \"ab\"", "case i do\n    @k -> 1\n    _ -> 0\n  end"))
      assert codes(msg) == ["case-pattern"]
    end

    test "a bitstring that is not a binary" do
      msg = rejected(kernel("@b <<1::3>>", "i + @b"))
      assert codes(msg) == ["attribute-value"]
      assert whats(msg) == ["@b is a bitstring of 3 bits, which is not in the kernel subset"]
    end
  end
end
