# Range copies (defk-52v.16): copy(out, at, src, from, n) gives out with
# out[at..at+n-1] replaced by src[from..from+n-1] (src as it was before the
# call, so src may be out itself), and copy_back(out, at, off, n) gives out
# with out[at + j] = out[at + j - off] for j = 0..n-1 in that order: an LZ
# match, which repeats the off elements before `at` when off < n (not what
# memmove does). One check covers the range; the write is in place when
# nothing reads the old array after it, as for a kernel that writes and
# returns its array parameter. A copy over DEFK_COPY_STRIP bytes runs in
# strips with a safepoint after each.

defmodule Defk.RangeCopyTest.K do
  use Defk

  defk copy_u8(out :: [u8], at :: i64, src :: [u8], from :: i64, n :: i64) :: [u8] do
    out = copy(out, at, src, from, n)
    out
  end

  defk back_u8(out :: [u8], at :: i64, off :: i64, n :: i64) :: [u8] do
    out = copy_back(out, at, off, n)
    out
  end

  defk copy_f64(out :: [f64], at :: i64, src :: [f64], from :: i64, n :: i64) :: [f64] do
    out = copy(out, at, src, from, n)
    out
  end

  defk back_i32(out :: [i32], at :: i64, off :: i64, n :: i64) :: [i32] do
    out = copy_back(out, at, off, n)
    out
  end

  # u64 arguments are checked into i64, as everywhere
  defk copy_u(out :: [u8], at :: u64, src :: [u8], from :: u64, n :: u64) :: [u8] do
    out = copy(out, at, src, from, n)
    out
  end

  # src is out itself: overlapping ranges move as memmove does
  defk move_self(a :: [u8], at :: i64, from :: i64, n :: i64) :: [u8] do
    a = copy(a, at, a, from, n)
    a
  end

  # ... in a buffer the kernel owns, so the move is in place
  defk move_owned(a :: [u8], at :: i64, from :: i64, n :: i64) :: [u8] do
    b = alloc(u8, len(a))
    b = copy(b, 0, a, 0, len(a))
    b = copy(b, at, b, from, n)
    b
  end

  # value semantics: another binding of the buffer keeps its array
  defk snapshot(n :: i64, at :: i64, off :: i64, k :: i64) :: {[u8], [u8]} do
    a = alloc(u8, n)

    a =
      for i <- 0..(n - 1)//1, reduce: a do
        a ->
          a[i] = rem(i, 251)
          a
      end

    b = a
    a = copy_back(a, at, off, k)
    {a, b}
  end

  # a copy in one branch, a read of the old array in the other: in place
  defk branch(flag :: bool, n :: i64) :: i64 do
    a = alloc(u8, n)
    a[0] = 9

    if flag do
      a = copy_back(a, 1, 1, n - 1)
      a[n - 1]
    else
      a[n - 1]
    end
  end

  # ... and a read of the old array after the branch: copied first
  defk branch_after(flag :: bool, n :: i64) :: i64 do
    a = alloc(u8, n)
    a[0] = 9

    s =
      if flag do
        a = copy_back(a, 1, 1, n - 1)
        a[n - 1]
      else
        a[n - 1]
      end

    s * 10 + a[n - 1]
  end

  # an LZ-style decode of (literal length, offset, match length) triples: the
  # output is a loop accumulator, written in place
  defk decode(lits :: [u8], ops :: [i64], size :: i64) :: [u8] do
    out = alloc(u8, size)

    {out, _ip, _op} =
      for t <- 0..(div(len(ops), 3) - 1)//1, reduce: {out, 0, 0} do
        {out, ip, op} ->
          ln = ops[3 * t]
          off = ops[3 * t + 1]
          ml = ops[3 * t + 2]
          out = copy(out, op, lits, ip, ln)
          out = copy_back(out, op + ln, off, ml)
          {out, ip + ln, op + ln + ml}
      end

    out
  end

  # a big source made in the kernel, copied in strips, then copied back
  defk big(n :: i64, at :: i64, off :: i64, k :: i64) :: i64 do
    a = alloc(u8, n)

    a =
      for i <- 0..(n - 1)//1, reduce: a do
        a ->
          a[i] = rem(i * 7, 256)
          a
      end

    b = alloc(u8, n)
    b = copy(b, 0, a, 0, n)
    b = copy_back(b, at, off, k)

    for x <- b, reduce: 0 do
      acc -> rem(acc * 31 + x, 1_000_000_007)
    end
  end
end

defmodule Defk.RangeCopyTest.NoYield do
  use Defk

  defk big(n :: i64, at :: i64, off :: i64, k :: i64) :: i64, yield: false do
    a = alloc(u8, n)

    a =
      for i <- 0..(n - 1)//1, reduce: a do
        a ->
          a[i] = rem(i * 7, 256)
          a
      end

    b = alloc(u8, n)
    b = copy(b, 0, a, 0, n)
    b = copy_back(b, at, off, k)

    for x <- b, reduce: 0 do
      acc -> rem(acc * 31 + x, 1_000_000_007)
    end
  end
end

defmodule Defk.RangeCopyTest do
  # async: false: the forced-yield test flips a flag of K's library
  use ExUnit.Case, async: false
  use Defk.Properties

  import Defk.TestKit

  alias Defk.RangeCopyTest.{K, NoYield}

  # DEFK_COPY_STRIP in priv/defk_runtime.h
  @strip 1024 * 1024

  defp agrees(fun, args), do: Defk.Test.assert_agrees(K, fun, args)

  # the meaning, written as the byte loop it is
  defp ref_back(out, at, off, n) do
    Enum.reduce(0..(n - 1)//1, out, fn j, acc ->
      i = at + j
      <<pre::binary-size(^i), _, post::binary>> = acc
      <<pre::binary, :binary.at(acc, at + j - off), post::binary>>
    end)
  end

  defp ref_copy(out, at, src, from, n) do
    <<pre::binary-size(^at), _::binary-size(^n), post::binary>> = out
    <<pre::binary, binary_part(src, from, n)::binary, post::binary>>
  end

  test "copy_back is the forward element loop, also when off < n" do
    out = :crypto.strong_rand_bytes(80)

    for at <- [1, 2, 7, 8, 9, 16, 33],
        off <- 1..at//1,
        n <- [0, 1, 2, 3, 7, 8, 9, 15, 16, 17, 31, 40] do
      if at + n <= 80 do
        assert agrees(:back_u8, [out, at, off, n]) == {:ok, ref_back(out, at, off, n)}
      end
    end

    # a run: offset 1 repeats one byte, offset 3 a three-byte pattern
    assert K.back_u8(<<1, 2, 3, 0, 0, 0, 0, 0, 0, 0>>, 3, 3, 7) ==
             <<1, 2, 3, 1, 2, 3, 1, 2, 3, 1>>

    assert K.back_u8(<<5, 0, 0, 0>>, 1, 1, 3) == <<5, 5, 5, 5>>
  end

  test "copy replaces the range from the source as it was" do
    out = :crypto.strong_rand_bytes(70)
    src = :crypto.strong_rand_bytes(50)

    for at <- [0, 1, 5, 30], from <- [0, 3, 17], n <- [0, 1, 3, 4, 7, 8, 9, 16, 17, 32, 33] do
      if at + n <= 70 and from + n <= 50 do
        assert agrees(:copy_u8, [out, at, src, from, n]) == {:ok, ref_copy(out, at, src, from, n)}
        assert agrees(:move_self, [out, at, from, n]) == {:ok, ref_copy(out, at, out, from, n)}
        assert agrees(:move_owned, [out, at, from, n]) == {:ok, ref_copy(out, at, out, from, n)}
      end
    end
  end

  test "element types other than u8 copy whole elements" do
    f = for x <- [1.5, -2.0, 3.25, 0.0, 9.0], into: <<>>, do: <<x::float-64-native>>
    g = for x <- [7.0, 8.0], into: <<>>, do: <<x::float-64-native>>

    assert {:ok, r} = agrees(:copy_f64, [f, 1, g, 0, 2])
    assert for(<<x::float-64-native <- r>>, do: x) == [1.5, 7.0, 8.0, 0.0, 9.0]

    i = for x <- [1, -2, 3, 0, 0, 0, 0], into: <<>>, do: <<x::signed-32-native>>
    assert {:ok, r} = agrees(:back_i32, [i, 3, 3, 4])
    assert for(<<x::signed-32-native <- r>>, do: x) == [1, -2, 3, 1, -2, 3, 1]

    # an inf in the source is copied without being read, and raises only
    # where an element is read (here: when the result is returned it is not)
    inf = <<0x7FF0000000000000::64-native>>
    assert {:ok, _} = agrees(:copy_f64, [f, 0, inf, 0, 1])
  end

  test "a range outside the array raises, checked in order" do
    out = <<0, 1, 2, 3, 4, 5, 6, 7, 8, 9>>

    assert {:raise, %ArgumentError{message: "copy/5: negative length -1"}} =
             agrees(:copy_u8, [out, 0, out, 0, -1])

    assert {:raise, %Enum.OutOfBoundsError{index: 8} = e} = agrees(:copy_u8, [out, 8, out, 0, 3])
    assert e.message == "copy/5: 3 elements at index 8 out of bounds for array of length 10"

    assert {:raise, %Enum.OutOfBoundsError{index: -1}} = agrees(:copy_u8, [out, -1, out, 0, 0])

    assert {:raise, %Enum.OutOfBoundsError{index: 4} = e} =
             agrees(:copy_u8, [out, 0, "abcde", 4, 2])

    assert e.message ==
             "copy/5: 2 elements from index 4 out of bounds for source array of length 5"

    assert {:raise, %ArgumentError{message: "copy_back/4: offset 0 is not positive"}} =
             agrees(:back_u8, [out, 3, 0, 1])

    assert {:raise, %Enum.OutOfBoundsError{index: -1} = e} = agrees(:back_u8, [out, 3, 4, 1])
    assert e.message == "copy_back/4: offset 4 from index 3 is before the start of the array"

    assert {:raise, %Enum.OutOfBoundsError{index: 9}} = agrees(:back_u8, [out, 9, 1, 2])

    # an empty copy still checks where it is
    assert {:ok, ^out} = agrees(:copy_u8, [out, 10, out, 10, 0])
    assert {:raise, %Enum.OutOfBoundsError{}} = agrees(:copy_u8, [out, 11, out, 0, 0])

    # the i64 limits
    max = 0x7FFFFFFFFFFFFFFF
    min = -0x8000000000000000

    for {at, x, n} <- [{max, 0, 1}, {0, max, 1}, {min, 0, 1}, {1, 0, max}, {max, max, max}] do
      agrees(:copy_u8, [out, at, out, x, n])
      agrees(:back_u8, [out, at, x, n])
    end

    assert {:raise, %ArithmeticError{}} =
             agrees(:copy_u, [out, 0x8000000000000000, out, 0, 1])
  end

  test "the old array is kept where it is read, and written in place where not" do
    assert {:ok, {a, b}} = agrees(:snapshot, [20, 10, 3, 10])
    assert a != b
    assert binary_part(a, 0, 10) == b |> binary_part(0, 10)

    assert agrees(:branch, [true, 6]) == {:ok, 9}
    assert agrees(:branch, [false, 6]) == {:ok, 0}
    assert agrees(:branch_after, [true, 6]) == {:ok, 90}
    assert agrees(:branch_after, [false, 6]) == {:ok, 0}
    assert for({{:branch, 2}, _, {:copy, :copied, _}} <- K.__defk_report__(), do: 1) == []
    assert for({{:branch_after, 2}, _, {:copy, :copied, _}} <- K.__defk_report__(), do: 1) == [1]

    # the loop's copies write the accumulator in place: no whole-array copy
    assert for({{:decode, 3}, _, {:copy, _, _} = f} <- K.__defk_report__(), do: f) == []
    assert for({{:snapshot, 4}, _, {:copy, :copied, _}} <- K.__defk_report__(), do: 1) == [1]
  end

  test "an LZ-style decode agrees, and its copies keep no per-element checks" do
    lits = "abcdefghij"
    ops = for x <- [3, 0, 0, 2, 3, 9, 5, 1, 4], into: <<>>, do: <<x::signed-64-native>>
    assert {:ok, out} = agrees(:decode, [lits, ops, 23])
    assert out == "abcde" <> "cdecdecde" <> "fghij" <> "jjjj"

    for {{:decode, 3}, _, {:bounds, :kept, text}} <- K.__defk_report__(),
        String.starts_with?(text, ["copy(", "copy_back("]) do
      assert text =~ "one range check for the whole copy"
    end
  end

  test "a copy over DEFK_COPY_STRIP bytes yields between strips, and resumes" do
    n = 3 * @strip + 5
    args = [n, 2 * @strip + 3, 3, @strip + 2]
    expect = NoYield.big(n, 2 * @strip + 3, 3, @strip + 2)
    assert K.big(n, 2 * @strip + 3, 3, @strip + 2) == expect

    forced(K, fn ->
      {res, n_yields} = yields(K, fn -> apply(K, :big, args) end)
      assert res == expect
      assert n_yields > 8

      # overlapping moves within one array, either way, over strip boundaries
      bin = :crypto.strong_rand_bytes(n)

      for {at, from} <- [{5, 0}, {0, 5}, {@strip + 1, 3}, {3, @strip + 1}] do
        k = n - max(at, from)
        assert K.move_self(bin, at, from, k) == ref_copy(bin, at, bin, from, k)
        assert K.move_owned(bin, at, from, k) == ref_copy(bin, at, bin, from, k)
      end
    end)

    # copy_back with an offset one byte over a strip boundary, and a long run
    for {at, off, k} <- [{@strip + 1, 1, 2 * @strip}, {2 * @strip, @strip + 7, @strip}] do
      assert K.big(n, at, off, k) == NoYield.big(n, at, off, k)
    end

    src = K.__defk_c_source__()
    assert src =~ "defk_move_strip("
    assert src =~ "defk_back_strip("
    refute NoYield.__defk_c_source__() =~ "_strip("
  end

  test "the report names the one range check" do
    texts = for {{:copy_u8, 5}, _, {:bounds, _, t}} <- K.__defk_report__(), do: t
    assert Enum.any?(texts, &(&1 =~ "copy(out, at, src, from, n): one range check"))
  end

  # ------------------------------------------------------------ rejections --

  defp rejection(body, sig), do: reject(__MODULE__, kernel(sig, "i64", body))

  test "mismatched element types and float positions are rejected" do
    msg = rejection("a = copy(a, 0, b, 0, 1)\nlen(a)", "a :: [u8], b :: [f64]")
    assert msg =~ "(defk builtin-arguments"
    assert msg =~ "copy/5 takes an array, an i64 index, a source array of the same element type"

    # a float position fails the signature table like any other wrong type
    # (defk-o49; it used to fail one step later, as a type-mismatch on the
    # coercion)
    msg = rejection("a = copy_back(a, x, 1, 1)\nlen(a)", "a :: [u8], x :: f64")
    assert msg =~ "(defk builtin-arguments"
    assert msg =~ "called here with ([u8], f64, i64, i64)"

    msg = rejection("a = copy_back(1, 1, 1, 1)\nlen(a)", "a :: [u8]")
    assert msg =~ "(defk builtin-arguments"
  end

  # ---------------------------------------------------- agreement properties --

  defp esize(:u8), do: 1
  defp esize(:i32), do: 4
  defp esize(:f64), do: 8

  defp pos(len) do
    one_of([integer(-2..(len + 2)), member_of([0, len, len - 1]), G.i64()])
  end

  defp copy_args(type \\ :u8) do
    bind(
      {G.array(type, max_length: 40, strip: false), G.array(type, max_length: 40, strip: false)},
      fn {o, s} ->
        esz = esize(type)
        {lo, ls} = {div(byte_size(o), esz), div(byte_size(s), esz)}
        fixed_list([constant(o), pos(lo), constant(s), pos(ls), pos(min(lo, ls))])
      end
    )
  end

  defp back_args(type \\ :u8) do
    bind(G.array(type, max_length: 60, strip: false), fn o ->
      l = div(byte_size(o), esize(type))
      fixed_list([constant(o), pos(l), one_of([integer(0..20), G.i64()]), pos(l)])
    end)
  end

  agreement(K,
    copy_u8: [args: copy_args()],
    back_u8: [args: back_args()],
    copy_f64: [args: copy_args(:f64)],
    back_i32: [args: back_args(:i32)],
    copy_u: [args: map(copy_args(), fn [o, a, s, f, n] -> [o, abs(a), s, abs(f), abs(n)] end)],
    move_self: [args: map(copy_args(), fn [o, a, _s, f, n] -> [o, a, f, n] end)],
    move_owned: [args: map(copy_args(), fn [o, a, _s, f, n] -> [o, a, f, n] end)],
    snapshot: [
      args: fixed_list([integer(0..40), integer(-1..41), integer(-1..41), integer(-1..41)])
    ],
    branch: [args: fixed_list([boolean(), integer(-1..20)])],
    branch_after: [args: fixed_list([boolean(), integer(-1..20)])],
    decode: [
      args:
        bind(
          list_of(fixed_list([integer(0..6), integer(-1..12), integer(0..12)]), max_length: 8),
          fn ts ->
            fixed_list([
              G.array(:u8, max_length: 30, strip: false),
              constant(for(t <- ts, x <- t, into: <<>>, do: <<x::signed-64-native>>)),
              integer(0..80)
            ])
          end
        )
    ],
    big: [args: fixed_list([integer(0..64), integer(-1..64), integer(-1..64), integer(-1..64)])]
  )
end
