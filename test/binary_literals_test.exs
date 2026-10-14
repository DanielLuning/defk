# Binary literals in kernel bodies (defk-n4r.5): "abc" and <<1, 2, 3>> are a
# read-only [u8] in static storage, as a binary module attribute is: indexed,
# measured with length, walked by `for`, passed to a helper, compared byte by
# byte. Elixir mode is the binary itself.

defmodule Defk.BinaryLiteralsTest.K do
  use Defk

  defk hex_digit(x :: i64) :: i64 do
    "0123456789abcdef"[band(x, 15)]
  end

  defk char_at(i :: i64) :: i64 do
    "hello"[i]
  end

  defk lens(k :: i64) :: i64 do
    length("Hamburg") * 100 + length(<<1, 2, 3>>) * 10 + length("") + k
  end

  defk sum_literal(k :: i64) :: i64 do
    for x <- "abc", reduce: k do
      acc -> acc + x
    end
  end

  defk sum_bytes(k :: i64) :: i64 do
    for x <- <<1, 2::8, 3::size(8), 255>>, reduce: k do
      acc -> acc + x
    end
  end

  # a byte-compare loop against a [u8] parameter
  defk starts_with?(s :: [u8], p :: [u8]) :: bool do
    if length(p) > length(s) do
      false
    else
      for i <- 0..(length(p) - 1)//1, reduce: true do
        acc -> acc and s[i] == p[i]
      end
    end
  end

  defk is_hamburg?(s :: [u8]) :: bool do
    starts_with?(s, "Ham")
  end

  defk is_prefix_lit?(s :: [u8]) :: bool do
    starts_with?(s, <<72, 97>>)
  end

  defk count_byte(s :: [u8], b :: i64) :: i64 do
    for c <- s, reduce: 0 do
      acc -> if c == b, do: acc + 1, else: acc
    end
  end

  defk bound(b :: i64) :: i64 do
    s = "banana"
    count_byte(s, b) + count_byte("bandana", b)
  end

  defk empty_len(k :: i64) :: i64 do
    length("") + length(<<>>) + k
  end

  defk empty_at(i :: i64) :: i64 do
    ""[i]
  end

  defk empty_sum(k :: i64) :: i64 do
    for x <- <<>>, reduce: k do
      acc -> acc + x
    end
  end

  defk lit_rounds(n :: i64) :: i64 do
    for i <- 0..(n - 1)//1, reduce: 0 do
      acc -> band(acc * 31 + "0123456789abcdef"[band(i, 15)], 0xFFFFFFFF)
    end
  end

  # returned unwritten: a new binary of its bytes (defk-gqk)
  defk literal_back(c :: bool) :: [u8] do
    if c, do: "abc", else: <<1, 2>>
  end
end

defmodule Defk.BinaryLiteralsTest do
  use ExUnit.Case, async: true
  use Defk.Properties

  import Defk.TestKit, only: [codes: 1, forced: 2, kernel_c: 2, reject: 2]

  alias Defk.BinaryLiteralsTest.K

  defp agrees(fun, args), do: Defk.Test.assert_agrees(K, fun, args)

  test "a string literal is indexed" do
    assert K.char_at(0) == ?h
    assert K.char_at(4) == ?o
    assert_raise Enum.OutOfBoundsError, fn -> K.char_at(5) end
    assert_raise Enum.OutOfBoundsError, fn -> K.char_at(-1) end
    for i <- [0, 4, 5, -1], do: agrees(:char_at, [i])
  end

  test "a masked read of a 16-byte literal keeps no bounds check" do
    assert K.hex_digit(11) == ?b
    assert K.hex_digit(-1) == ?f
    for x <- [0, 11, 16, -1], do: agrees(:hex_digit, [x])
    refute kernel_c(K, "hex_digit") =~ "defk_get_u8("
    assert kernel_c(K, "char_at") =~ "defk_get_u8("
  end

  test "length of a literal, UTF-8 bytes and integer segments" do
    assert K.lens(1) == 731
    agrees(:lens, [1])
    assert K.sum_literal(1) == ?a + ?b + ?c + 1
    agrees(:sum_literal, [1])
    assert K.sum_bytes(0) == 261
    agrees(:sum_bytes, [0])
  end

  test "a literal is passed to a helper and compared byte by byte" do
    assert K.is_hamburg?("Hamburg")
    refute K.is_hamburg?("Hx")
    assert K.is_prefix_lit?("Hat")
    refute K.is_prefix_lit?("H")

    for s <- ["Hamburg", "Ham", "Ha", "", "Hamlet", "hamburg"] do
      agrees(:is_hamburg?, [s])
      agrees(:is_prefix_lit?, [s])
    end

    assert K.bound(?a) == 3 + 3
    agrees(:bound, [?n])
  end

  test "an empty literal is a zero-length array" do
    assert K.empty_len(5) == 5
    assert K.empty_sum(7) == 7
    assert_raise Enum.OutOfBoundsError, fn -> K.empty_at(0) end
    agrees(:empty_len, [5])
    agrees(:empty_sum, [7])
    agrees(:empty_at, [0])
    agrees(:empty_at, [-1])
  end

  test "a long loop over a literal survives forced yields" do
    expect =
      Enum.reduce(0..9_999, 0, fn i, acc ->
        Bitwise.band(acc * 31 + :binary.at("0123456789abcdef", Bitwise.band(i, 15)), 0xFFFFFFFF)
      end)

    forced(K, fn -> assert K.lit_rounds(10_000) == expect end)

    agrees(:lit_rounds, [10_000])
  end

  agreement(K,
    hex_digit: [],
    char_at: [args: StreamData.fixed_list([G.i64(-3..8)])],
    lens: [],
    sum_literal: [],
    sum_bytes: [],
    starts_with?: [],
    is_hamburg?: [],
    is_prefix_lit?: [],
    count_byte: [],
    bound: [args: StreamData.fixed_list([G.i64(90..120)])],
    empty_len: [],
    empty_at: [],
    empty_sum: [],
    lit_rounds: [args: StreamData.fixed_list([G.i64(0..500)])],
    literal_back: []
  )

  test "a literal is returned unwritten" do
    assert agrees(:literal_back, [true]) == {:ok, "abc"}
    assert agrees(:literal_back, [false]) == {:ok, <<1, 2>>}
  end

  describe "compile errors" do
    defp rejected(body), do: reject(__MODULE__, body)

    defp kernel(expr, ret \\ "i64"),
      do: "defk f(i :: i64) :: #{ret} do\n  #{expr}\nend"

    test "interpolation is rejected with the rewrite hint" do
      msg = rejected(kernel(~S|s = "a#{i}"| <> "\n  length(s)"))
      assert codes(msg) == ["binary-literal"]
      assert msg =~ "interpolation"

      assert msg =~
               "build it in Elixir and pass it as a [u8] parameter, or use a module attribute"
    end

    test "a charlist is rejected with the string-literal hint" do
      for src <- [~S('abc'), ~S(~c"abc")] do
        # 'abc' also gets Elixir's deprecation warning for single quotes
        {msg, _warning} =
          ExUnit.CaptureIO.with_io(:stderr, fn -> rejected(kernel("s = #{src}\n  length(s)")) end)

        assert codes(msg) == ["binary-literal"], msg
        assert msg =~ ~s(use a string literal, "abc")
      end
    end

    test "other segments are rejected" do
      for seg <- ["1.5", "i", "300", "-1", "256", "1::16", "1::float", "\"ab\""] do
        msg = rejected(kernel("s = <<#{seg}>>\n  length(s)"))
        assert codes(msg) == ["binary-literal"], "#{seg}: #{msg}"
        assert msg =~ "build it in Elixir and pass it as a [u8] parameter"
      end
    end
  end
end
