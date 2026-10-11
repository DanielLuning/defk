# A binary attribute or literal is emitted once per module (defk-qx3): one
# `static const uint8_t` array named by a hash of its contents, referenced
# from every use site, however often a helper that reads it is inlined.

defmodule Defk.StaticBinariesTest.K do
  use Defk

  @t for i <- 0..63, into: <<>>, do: <<rem(i * 29 + 7, 256)>>
  @u "a different table, 0123456789"

  defk at(k :: i64, i :: i64) :: i64 do
    @t[band(i + k, 63)]
  end

  # the helper above is inlined at each call
  defk rounds(x :: i64) :: i64 do
    at(1, x) + at(2, x) + at(3, x) + at(4, x) + at(5, x)
  end

  defk other(i :: i64) :: i64 do
    @t[band(i, 63)] + @u[i]
  end

  defk lits(i :: i64) :: i64 do
    "shared literal"[i] + "shared literal"[i + 1] + len("shared literal")
  end

  defk lits2(i :: i64) :: i64 do
    "shared literal"[i]
  end

  defk empty(k :: i64) :: i64 do
    len("") + k
  end

  # writes go to a copy, never to the static data
  defk write_copy(i :: i64) :: i64 do
    s = @t
    s[i] = 200
    s[i] + @t[i]
  end

  defk write_copy2(i :: i64) :: i64 do
    s = "shared literal"
    s[i] = 1
    s[i] + "shared literal"[i]
  end
end

defmodule Defk.StaticBinariesTest do
  use ExUnit.Case, async: true

  alias Defk.StaticBinariesTest.K

  @t for i <- 0..63, into: <<>>, do: <<rem(i * 29 + 7, 256)>>

  defp count(c, pat), do: length(String.split(c, pat)) - 1

  defp arrays(c),
    do: for([_, n] <- Regex.scan(~r/static const uint8_t (defk_lit_\w+)\[\]/, c), do: n)

  # the octal-escaped text of a binary, as c_bytes writes it
  defp escaped(b),
    do:
      Enum.map_join(
        :binary.bin_to_list(b),
        &("\\" <> String.pad_leading(Integer.to_string(&1, 8), 3, "0"))
      )

  test "a repeated attribute is one array, referenced at every use" do
    c = K.__defk_c_source__()
    assert count(c, escaped(@t)) == 1

    [_, name] =
      Regex.run(
        ~r/static const uint8_t (defk_lit_\w+)\[\] =\n"#{Regex.escape(escaped(@t) |> binary_part(0, 12))}/,
        c
      )

    # five inlined uses in rounds/1, one in other/1, one in write_copy/1 twice
    assert count(c, "(uint8_t *)#{name}") >= 8
  end

  test "a repeated identical literal is one array" do
    c = K.__defk_c_source__()
    assert count(c, escaped("shared literal")) == 1
  end

  test "two different attributes give two arrays, the empty binary a third" do
    c = K.__defk_c_source__()
    assert count(c, escaped("a different table, 0123456789")) == 1
    names = arrays(c)
    assert [_, _, _, _] = names
    assert names == Enum.uniq(names)
    assert c =~ ~r/static const uint8_t defk_lit_\w+\[\] =\n"";/
  end

  test "declarations come before the first function that uses them" do
    c = K.__defk_c_source__()
    [{decl, _}] = :binary.matches(c, "static const uint8_t") |> Enum.take(1)
    {fun, _} = :binary.match(c, "/* ---- ")
    assert decl < fun
  end

  test "results are unchanged, in both modes" do
    for x <- [0, 1, 5, 63, 64, -3], do: Defk.Test.assert_agrees(K, :rounds, [x])
    for i <- [0, 5, 20], do: Defk.Test.assert_agrees(K, :other, [i])
    for i <- [0, 3, 12], do: Defk.Test.assert_agrees(K, :lits, [i])
    Defk.Test.assert_agrees(K, :lits2, [2])
    Defk.Test.assert_agrees(K, :empty, [7])
    assert K.empty(7) == 7
  end

  test "a write copies; the static data is untouched" do
    for _ <- 1..3, i <- [0, 1, 13] do
      assert K.write_copy(i) == 200 + :binary.at(@t, i)
      Defk.Test.assert_agrees(K, :write_copy, [i])
    end

    for _ <- 1..2, i <- [0, 4] do
      Defk.Test.assert_agrees(K, :write_copy2, [i])
      assert K.write_copy2(i) == 1 + :binary.at("shared literal", i)
    end
  end
end
