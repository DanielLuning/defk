# The bitstring accumulator: a local that starts as <<>> and is
# only appended to, acc = <<acc::bitstring, v::size(n)>>, returned as a real
# bitstring. Natively a growable buffer kept in the frame across yields and
# freed on an exception or process death; in Elixir mode the bitstring
# itself, with the same limits (a value that doesn't fit its size, or a size
# outside 0..64, raises).

defmodule Defk.BitstringTest.K do
  use Defk

  # each element of xs in n bits
  defk pack(xs :: [i64], n :: i64) :: bitstring do
    for x <- xs, reduce: <<>> do
      acc -> <<acc::bitstring, x::size(n)>>
    end
  end

  # each element of a [u64] in n bits: 2^63 and up included
  defk pack_u64(xs :: [u64], n :: i64) :: bitstring do
    for x <- xs, reduce: <<>> do
      acc -> <<acc::bitstring, x::size(n)>>
    end
  end

  # each element of xs as a signed n-bit integer
  defk pack_signed(xs :: [i64], n :: i64) :: bitstring do
    for x <- xs, reduce: <<>> do
      acc -> <<acc::bitstring, x::size(n)-signed>>
    end
  end

  # the anchor of Gorilla's timestamp encoding: two flag bits, then a signed
  # 7-bit delta of deltas (written with the type first, and a literal size)
  defk anchor(dod :: i64) :: bitstring do
    acc = <<>>
    <<acc::bitstring, 1::1, 0::1, dod::signed-7>>
  end

  # signed beside unsigned, a literal-size and a default-size signed segment
  defk mixed_signed(x :: i64, y :: i64) :: bitstring do
    acc = <<>>
    <<acc::bitstring, x::5-signed, y::3, x::signed-integer-big-size(5), y::signed-8>>
  end

  # lead set bits, then x in n bits twice
  defk at_offset(lead :: i64, x :: i64, n :: i64) :: bitstring do
    acc =
      for _ <- 1..lead//1, reduce: <<>> do
        acc -> <<acc::bitstring, 1::1>>
      end

    <<acc::bitstring, x::size(n), x::size(n)>>
  end

  # a set bit and 7 bits per positive element, a clear bit for any other,
  # padded to whole bytes; and the length before the padding
  defk flags(xs :: [i64]) :: {bitstring, i64} do
    acc = <<>>

    acc =
      for x <- xs, reduce: acc do
        acc ->
          if x > 0, do: <<acc::bitstring, 1::1, band(x, 127)::7>>, else: <<acc::bitstring, 0::1>>
      end

    bits = bit_size(acc)
    pad = rem(8 - rem(bits, 8), 8)
    {<<acc::bitstring, 0::size(pad)>>, bits}
  end

  # literal sizes, several segments in one append, a bare (8-bit) segment and
  # 64-bit segments at odd offsets
  defk header(a :: i64, b :: i64) :: bitstring do
    acc = <<>>
    acc = <<acc::bitstring, 1::1, 0::1, band(a, 31)::5, b::64>>
    acc = <<acc::bitstring, band(a, 255)>>
    <<acc::bitstring, b::unsigned-big-integer-size(64), 1::size(1)-unsigned>>
  end

  # an older value appended to again keeps its own bits (value semantics)
  defk forks(x :: i64) :: {bitstring, bitstring, bitstring} do
    a = <<>>
    a = <<a::bitstring, band(x, 7)::3>>
    b = <<a::bitstring, 1::1>>
    c = <<a::bitstring, 0::2>>
    b = <<b::bitstring, x::64>>
    {a, b, c}
  end

  defk empty(k :: i64) :: {bitstring, i64} do
    {<<>>, k}
  end

  # bound to a variable that is never appended to, and returned
  defk unappended(k :: i64) :: bitstring do
    acc = <<>>
    _ = k
    acc
  end

  # zero-width segments, and a branch whose other arm is <<>>
  defk zero_width(x :: i64) :: bitstring do
    acc = <<>>
    acc = <<acc::bitstring, 0::0, x::size(0)>>
    if bit_size(acc) == 0, do: <<>>, else: acc
  end

  defk until_negative(xs :: [i64]) :: bitstring do
    Enum.reduce_while(xs, <<>>, fn x, acc ->
      if x < 0, do: {:halt, acc}, else: {:cont, <<acc::bitstring, band(x, 15)::4>>}
    end)
  end

  # an array accumulator beside a bitstring accumulator in one tuple
  defk evens_and_bits(xs :: [i64]) :: {[i64], bitstring} do
    {out, bits, _} =
      for x <- xs, reduce: {alloc(i64, length(xs)), <<>>, 0} do
        {out, bits, i} ->
          out[i] = band(x, 0xFFFF) * 2
          {out, <<bits::bitstring, band(x, 1)::1>>, i + 1}
      end

    {out, bits}
  end

  # the same, where the new array loses the initial one's length fact, so
  # the loop body is lowered twice (with_acc_facts in the compiler)
  defk regrown(xs :: [i64]) :: {[i64], bitstring} do
    for x <- xs, reduce: {alloc(i64, 4), <<>>} do
      {a, bits} ->
        b = alloc(i64, length(a) + 1)
        b[0] = band(x, 0xFFFF)
        {b, <<bits::bitstring, band(x, 3)::2>>}
    end
  end

  # a called kernel returns a bitstring; the caller appends to it
  defk unary(n :: i64) :: bitstring do
    for _ <- 1..n//1, reduce: <<>> do
      acc -> <<acc::bitstring, 1::1>>
    end
  end

  defk unary_then(n :: i64, x :: i64) :: bitstring do
    acc = unary(n)
    <<acc::bitstring, 0::1, band(x, 255)::8>>
  end

  # gorilla_stream's XOR value encoder (Defk.GorillaReference), over the f64
  # bit patterns: the [f64] binary read as a [u64], so a pattern with the top
  # bit set is one u64 segment value, as in gorilla_stream's own code
  defk gorilla(vs :: [u64]) :: bitstring do
    n = length(vs)

    if n == 0 do
      <<>>
    else
      first = vs[0]
      acc = <<>>
      acc = <<acc::bitstring, first::64>>

      {acc, _, _, _} =
        for i <- 1..(n - 1)//1, reduce: {acc, first, 0, 0} do
          {acc, prev, plz, ptz} ->
            v = vs[i]
            x = bxor(v, prev)
            lz = clz(x)
            tz = ctz(x)
            ml = 64 - plz - ptz
            # the previous window holds the meaningful bits
            same = x != 0 and lz >= plz and tz >= ptz and ml > 0
            k = if x == 0, do: 0, else: if(same, do: ml, else: 64 - lz - tz)
            # the k meaningful bits; a logical shift, as x is a u64
            w = bsr(x, if(same, do: ptz, else: tz))

            acc =
              cond do
                x == 0 ->
                  <<acc::bitstring, 0::1>>

                same ->
                  <<acc::bitstring, 2::2, w::size(k)>>

                true ->
                  <<acc::bitstring, 3::2, min(31, lz)::5, k - 1::6, w::size(k)>>
              end

            keep = x == 0 or same
            {acc, v, if(keep, do: plz, else: min(31, lz)), if(keep, do: ptz, else: tz)}
        end

      acc
    end
  end
end

defmodule Defk.BitstringTest do
  use ExUnit.Case, async: false
  import Defk.Test.Frames
  use Defk.Properties

  import Defk.TestKit,
    only: [codes: 1, f64s: 1, forced: 2, i64s: 1, reject: 2, wait_until: 2, yields: 2]

  alias Defk.BitstringTest.K

  @timeout 10_000

  defp agrees(fun, args), do: Defk.Test.assert_agrees(K, fun, args)

  # what pack/2 gives, built in Elixir
  defp packed(xs, n), do: for(x <- xs, into: <<>>, do: <<x::size(n)>>)

  describe "building" do
    test "segments are unsigned and big-endian, and the result need not be whole bytes" do
      assert K.pack(i64s([1, 0, 1]), 1) == <<5::3>>
      assert K.pack(i64s([1, 2, 3]), 5) == <<1::5, 2::5, 3::5>>
      assert bit_size(K.pack(i64s([1, 2, 3]), 5)) == 15
      assert K.pack(i64s([0x0102030405060708]), 64) == <<1, 2, 3, 4, 5, 6, 7, 8>>

      for {xs, n} <- [{[1, 0, 1], 1}, {[1, 2, 3], 5}, {[7, 0, 255], 8}, {[2 ** 62, 1], 64}] do
        assert {:ok, packed(xs, n)} == agrees(:pack, [i64s(xs), n])
      end
    end

    test "every size from 0 to 64 at every offset in a byte" do
      for n <- 0..64,
          lead <- 0..7,
          x <- Enum.uniq([0, min(n, 1), Bitwise.bsl(1, min(n, 63)) - 1]) do
        expect = <<Bitwise.bsl(1, lead) - 1::size(lead), x::size(n), x::size(n)>>
        assert K.at_offset(lead, x, n) == expect
      end

      for n <- [0, 1, 7, 8, 9, 31, 32, 33, 56, 57, 63, 64], lead <- [0, 3, 7] do
        assert {:ok, _} = agrees(:at_offset, [lead, min(n, 1), n])
      end
    end

    test "several segments in one append, bare and modified segments" do
      for {a, b} <- [{5, 0}, {31, 2 ** 63 - 1}, {200, 12_345}, {0, 1}] do
        b64 = <<b::64>>

        expect =
          <<1::1, 0::1, Bitwise.band(a, 31)::5, b64::bitstring, Bitwise.band(a, 255),
            b64::bitstring, 1::1>>

        assert {:ok, ^expect} = agrees(:header, [a, b])
      end
    end

    test "the empty bitstring, alone and in a tuple" do
      assert K.pack(<<>>, 3) == <<>>
      assert K.empty(4) == {<<>>, 4}
      assert K.zero_width(0) == <<>>
      assert agrees(:pack, [<<>>, 3]) == {:ok, <<>>}
      assert agrees(:empty, [4]) == {:ok, {<<>>, 4}}
      assert agrees(:unappended, [4]) == {:ok, <<>>}
      assert agrees(:zero_width, [0]) == {:ok, <<>>}
      assert agrees(:unary, [0]) == {:ok, <<>>}
    end

    test "a bitstring through a branch, a tuple accumulator and padding" do
      xs = [3, -1, 0, 100, 1]
      bits = for x <- xs, into: <<>>, do: if(x > 0, do: <<1::1, x::7>>, else: <<0::1>>)
      pad = rem(8 - rem(bit_size(bits), 8), 8)
      assert K.flags(i64s(xs)) == {<<bits::bitstring, 0::size(pad)>>, bit_size(bits)}
      assert {:ok, {bin, 26}} = agrees(:flags, [i64s(xs)])
      assert is_binary(bin)
    end

    test "an older value appended to again keeps its bits" do
      for x <- [0, 5, 7, 2 ** 40] do
        a = <<Bitwise.band(x, 7)::3>>
        assert {:ok, {^a, b, c}} = agrees(:forks, [x])
        assert b == <<a::bitstring, 1::1, x::64>>
        assert c == <<a::bitstring, 0::2>>
      end
    end

    test "a bitstring accumulator beside an array accumulator" do
      xs = [3, 4, 7, 10, 1]
      evens = i64s(Enum.map(xs, &(&1 * 2)))
      bits = for x <- xs, into: <<>>, do: <<Bitwise.band(x, 1)::1>>
      assert K.evens_and_bits(i64s(xs)) == {evens, bits}
      assert agrees(:evens_and_bits, [i64s(xs)]) == {:ok, {evens, bits}}

      out = i64s([1 | List.duplicate(0, 8)])
      bits2 = for x <- xs, into: <<>>, do: <<Bitwise.band(x, 3)::2>>
      assert K.regrown(i64s(xs)) == {out, bits2}
      assert agrees(:regrown, [i64s(xs)]) == {:ok, {out, bits2}}
      assert agrees(:regrown, [<<>>]) == {:ok, {i64s([0, 0, 0, 0]), <<>>}}
      assert K.__defk_c_source__() =~ "regrown"
    end

    test "Enum.reduce_while and a called kernel's bitstring" do
      assert K.until_negative(i64s([1, 2, -1, 3])) == <<1::4, 2::4>>
      assert agrees(:until_negative, [i64s([1, 2, -1, 3])]) == {:ok, <<1::4, 2::4>>}
      assert agrees(:until_negative, [i64s([15, 14, 13])]) == {:ok, <<15::4, 14::4, 13::4>>}
      assert K.unary_then(3, 255) == <<0b1110::4, 255::8>>
      assert agrees(:unary_then, [3, 255]) == {:ok, <<0b1110::4, 255::8>>}
    end
  end

  describe "limits" do
    test "a value that does not fit its size raises in both modes" do
      for {x, n} <- [{4, 2}, {-1, 8}, {256, 8}, {1, 0}, {-1, 64}, {2, 1}] do
        assert {:raise, %ArgumentError{} = e} = agrees(:pack, [i64s([x]), n])
        assert Defk.Test.agreement_reason(e) == :segment_fit
        assert Exception.message(e) =~ "bitstring segment value #{x} does not fit in #{n} bits"
      end

      # Elixir itself would keep the low bits
      assert <<4::2>> == <<0::2>>
    end

    test "a u64 segment value takes the whole unsigned range" do
      top = 2 ** 64 - 1
      xs = for x <- [2 ** 63, top, 5], into: <<>>, do: <<x::64-native>>
      assert agrees(:pack_u64, [xs, 64]) == {:ok, <<2 ** 63::64, top::64, 5::64>>}

      for {x, n} <- [{2 ** 63, 32}, {top, 63}, {6, 2}] do
        assert {:raise, %ArgumentError{} = e} = agrees(:pack_u64, [<<x::64-native>>, n])
        assert Defk.Test.agreement_reason(e) == :segment_fit
        assert Exception.message(e) =~ "bitstring segment value #{x} does not fit in #{n} bits"
      end

      assert {:raise, %ArgumentError{} = e} = agrees(:pack_u64, [<<top::64-native>>, 65])
      assert Defk.Test.agreement_reason(e) == :segment_size
    end

    test "a size outside 0..64 raises in both modes" do
      for n <- [65, -1, 1000, -(2 ** 63)] do
        assert {:raise, %ArgumentError{} = e} = agrees(:pack, [i64s([0]), n])
        assert Defk.Test.agreement_reason(e) == :segment_size
      end

      # also with no element to append: the check is per segment
      assert agrees(:pack, [<<>>, 65]) == {:ok, <<>>}
    end

    test "the largest values that fit" do
      assert agrees(:pack, [i64s([2 ** 63 - 1]), 64]) == {:ok, <<2 ** 63 - 1::64>>}
      assert agrees(:pack, [i64s([2 ** 63 - 1]), 63]) == {:ok, <<2 ** 63 - 1::63>>}
      assert agrees(:pack, [i64s([255]), 8]) == {:ok, <<255>>}
    end

    test "an error mid-build frees the buffer and leaves no frame" do
      xs = List.duplicate(1, 5000) ++ [2]
      assert {:raise, %ArgumentError{}} = agrees(:pack, [i64s(xs), 1])
      assert_frames_live(K)
    end
  end

  describe "signed segments" do
    defp bounds(n), do: {-Bitwise.bsl(1, n - 1), Bitwise.bsl(1, n - 1) - 1}

    test "the boundary values of every width 1..64 agree with Elixir" do
      for n <- 1..64 do
        {lo, hi} = bounds(n)
        xs = Enum.uniq(Enum.filter([lo, lo + 1, -1, 0, 1, hi - 1, hi], &(&1 in lo..hi)))
        expect = for x <- xs, into: <<>>, do: <<x::signed-size(n)>>
        assert {:ok, expect} == agrees(:pack_signed, [i64s(xs), n])
        assert K.pack_signed(i64s(xs), n) == expect
      end
    end

    test "a value just outside the signed range raises in both modes" do
      for n <- 1..64 do
        {lo, hi} = bounds(n)

        for x <- [lo - 1, hi + 1], x in -(2 ** 63)..(2 ** 63 - 1) do
          assert {:raise, %ArgumentError{} = e} = agrees(:pack_signed, [i64s([x]), n])
          assert Defk.Test.agreement_reason(e) == :segment_fit

          assert Exception.message(e) =~
                   "bitstring segment value #{x} does not fit in #{n} signed bits"
        end
      end

      # Elixir itself would keep the low bits
      assert <<128::signed-8>> == <<-128::signed-8>>
    end

    test "a width of 0 holds no bits, and only 0 fits" do
      assert agrees(:pack_signed, [i64s([0, 0]), 0]) == {:ok, <<>>}

      for x <- [1, -1] do
        assert {:raise, %ArgumentError{}} = agrees(:pack_signed, [i64s([x]), 0])
      end
    end

    test "a size outside 0..64 raises, as for unsigned segments" do
      for n <- [65, -1] do
        assert {:raise, %ArgumentError{} = e} = agrees(:pack_signed, [i64s([0]), n])
        assert Defk.Test.agreement_reason(e) == :segment_size
      end
    end

    test "a negative value stores its two's complement bits" do
      assert agrees(:pack_signed, [i64s([-1, -2, 3]), 4]) == {:ok, <<0b1111_1110_0011::12>>}
      assert agrees(:anchor, [-64]) == {:ok, <<0b10_1000000::9>>}
      assert agrees(:anchor, [63]) == {:ok, <<0b10_0111111::9>>}
      assert {:raise, %ArgumentError{}} = agrees(:anchor, [64])
      assert {:raise, %ArgumentError{}} = agrees(:anchor, [-65])
    end

    test "signed beside unsigned, with the specifiers in any order" do
      assert agrees(:mixed_signed, [-3, 5]) ==
               {:ok, <<-3::signed-5, 5::3, -3::signed-5, 5::signed-8>>}

      assert {:raise, %ArgumentError{}} = agrees(:mixed_signed, [16, 5])
      assert {:raise, %ArgumentError{}} = agrees(:mixed_signed, [0, 8])
    end

    test "a signed build grows across forced yields" do
      xs = for i <- 1..20_000, do: rem(i * 37, 128) - 64

      forced(K, fn ->
        assert {:ok, packed} = agrees(:pack_signed, [i64s(xs), 7])
        assert packed == for(x <- xs, into: <<>>, do: <<x::signed-7>>)
      end)
    end

    property "(width, value) pairs, in range or just outside, agree with Elixir" do
      check all(
              n <- StreamData.integer(1..64),
              pick <- StreamData.integer(0..5),
              r <- StreamData.integer(0..0xFFFFFFFFFFFFFFFF),
              max_runs: 300
            ) do
        {lo, hi} = bounds(n)

        x =
          case pick do
            0 -> lo - 1
            1 -> hi + 1
            2 -> lo
            3 -> hi
            _ -> lo + rem(r, hi - lo + 1)
          end

        if x in -(2 ** 63)..(2 ** 63 - 1) do
          result = agrees(:pack_signed, [i64s([x]), n])

          if x in lo..hi,
            do: assert(result == {:ok, <<x::signed-size(n)>>}),
            else: assert({:raise, %ArgumentError{}} = result)
        end
      end
    end
  end

  describe "the runtime contract" do
    test "an output that grows across forced yields" do
      xs = for i <- 0..199_999, do: rem(i * 7919, 8192)

      forced(K, fn ->
        {out, n} = yields(K, fn -> K.pack(i64s(xs), 13) end)
        assert n > 10, "the kernel never yielded"
        assert out == packed(xs, 13)
        assert bit_size(out) == 13 * 200_000

        assert agrees(:pack, [i64s(Enum.take(xs, 20_000)), 13]) ==
                 {:ok, packed(Enum.take(xs, 20_000), 13)}
      end)
    end

    @tag :erlang_memory
    test "a process killed mid-build frees the buffer" do
      # 32 MB of output when done
      xs = i64s(List.duplicate(12_345, 4_000_000))

      forced(K, fn ->
        :erlang.garbage_collect()
        base = :erlang.memory(:binary)
        kill_mid_build(xs, base)

        # the frame, and the buffer it owned, are gone
        assert_frames_live(K)
        wait_until(fn -> :erlang.memory(:binary) < base + 8_000_000 end, @timeout)
      end)
    end

    # Spawns the build and kills it once a 16 MB buffer is built. Under heavy load
    # this process can be starved until the kernel has already finished; that
    # attempt proves nothing, so try again (the finished one has freed its frame).
    defp kill_mid_build(xs, base, attempts \\ 20) do
      pid = spawn(fn -> K.pack(xs, 64) end)
      ref = Process.monitor(pid)

      # suspended between two steps with a buffer of at least 16 MB built
      wait_until(fn -> :erlang.memory(:binary) > base + 16_000_000 end, @timeout)

      if Process.alive?(pid) do
        Process.exit(pid, :kill)
        assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, @timeout
      else
        assert_receive {:DOWN, ^ref, :process, ^pid, _}, @timeout
        assert attempts > 1, "the kernel finished before it could be killed, every time"
        assert_frames_live(K)
        wait_until(fn -> :erlang.memory(:binary) < base + 8_000_000 end, @timeout)
        kill_mid_build(xs, base, attempts - 1)
      end
    end
  end

  describe "Gorilla" do
    defp gorilla_cases do
      walk = Enum.scan(1..500, 20.0, fn i, acc -> Float.round(acc + :math.sin(i) * 0.5, 2) end)

      [
        [],
        [1.5],
        [1.0, 1.0],
        [1.0, -1.0, 1.0],
        [0.0, -0.0, 0.0],
        [1.0e300, 1.0e-300, -2.5, 3.75, 3.75, 3.76],
        [12.0, 12.0, 12.5, 13.0, 12.5, 12.5, 11.0],
        walk,
        Enum.map(1..300, &(&1 * 1.0)),
        Enum.map(1..300, fn i -> :math.sin(i) * 1000 end)
      ]
    end

    test "the kernel gives gorilla_stream's encoder output, bit for bit" do
      for vs <- gorilla_cases() do
        expect = Defk.GorillaReference.compress(vs)
        assert {:ok, ^expect} = agrees(:gorilla, [f64s(vs)])
      end
    end

    property "random series agree with gorilla_stream's encoder" do
      check all(
              vs <- StreamData.list_of(G.f64(), max_length: 80),
              max_runs: 100
            ) do
        expect = Defk.GorillaReference.compress(vs)
        assert {:ok, ^expect} = agrees(:gorilla, [f64s(vs)])
      end
    end

    test "a long series under forced yields" do
      vs = Enum.scan(1..50_000, 100.0, fn i, acc -> Float.round(acc + :math.cos(i) * 0.25, 3) end)
      expect = Defk.GorillaReference.compress(vs)
      forced(K, fn -> assert K.gorilla(f64s(vs)) == expect end)
    end
  end

  describe "compile errors" do
    defp rejected(body), do: reject(__MODULE__, body)

    defp appends(seg, ret \\ "bitstring"),
      do: "defk f(x :: i64) :: #{ret} do\n  acc = <<>>\n  #{seg}\nend"

    test "float, binary, signed, little-endian and other segments" do
      for {seg, why} <- [
            {"x::float-64", "segments are integers, and float is not"},
            {"1.5::64", "segments are integers"},
            {"x::binary", "segments are integers, and binary is not"},
            {"acc::bitstring", "segments are integers, and bitstring is not"},
            {"\"ab\"", "segments are integers"},
            {"x::little-16", "segments are big-endian"},
            {"x::utf8", "segments are integers, and utf8 is not"},
            {"x::size(8)-unit(2)", "unit(2) is not a segment size or type"},
            {"x::8-size(4)", "two sizes"}
          ] do
        msg = rejected(appends("<<acc::bitstring, #{seg}>>"))
        assert codes(msg) == ["bitstring-segment"], "#{seg}: #{msg}"
        assert msg =~ "the bitstring segment #{seg} is not supported yet", msg
        assert msg =~ why, msg
      end
    end

    test "signed with unsigned, or either endianness conflict" do
      for seg <- ["x::signed-unsigned-8", "x::unsigned-signed-8"] do
        msg = rejected(appends("<<acc::bitstring, #{seg}>>"))
        assert codes(msg) == ["bitstring-segment"], msg
        assert msg =~ "both signed and unsigned", msg
      end
    end

    test "appending to acc::binary names the bitstring form" do
      msg = rejected(appends("<<acc::binary, x::8>>"))
      assert codes(msg) == ["bitstring-segment"]
      assert msg =~ "<<acc::bitstring, x::8>>"
    end

    test "a segment value or size that is not an i64" do
      msg =
        rejected(
          "defk f(x :: f64) :: bitstring do\n  acc = <<>>\n  <<acc::bitstring, x::8>>\nend"
        )

      assert codes(msg) == ["type-mismatch"]
      assert msg =~ "a bitstring segment value x has type f64, expected i64"
    end

    test "starting from an input binary" do
      msg = rejected("defk f(b :: [u8]) :: bitstring do\n  <<b::bitstring, 1::1>>\nend")
      assert codes(msg) == ["bitstring-use"]
      assert msg =~ "starting from an input bitstring is not supported yet"
    end

    test "reading the accumulator: indexing, length/1, a generator" do
      for {read, what} <- [
            {"acc[0]", "acc[0] reads the bitstring acc"},
            {"length(acc)", "length(acc) reads the bitstring acc"},
            {"for b <- acc, reduce: 0 do\n    n -> n + b\n  end", "reads the bitstring acc"}
          ] do
        msg = rejected(appends("acc = <<acc::bitstring, x::8>>\n  #{read}", "i64"))
        assert codes(msg) == ["bitstring-use"], "#{read}: #{msg}"
        assert msg =~ what
      end

      assert rejected(appends("acc = <<acc::bitstring, x::8>>\n  length(acc)", "i64")) =~
               "bit_size(acc)"
    end
  end

  agreement(K,
    pack: [args: StreamData.fixed_list([G.array(:i64, of: G.i64(0..300)), G.i64(-2..70)])],
    pack_u64: [args: StreamData.fixed_list([G.array(:u64), G.i64(-2..70)])],
    pack_signed: [
      args: StreamData.fixed_list([G.array(:i64, of: G.i64(-300..300)), G.i64(-2..70)])
    ],
    anchor: [args: StreamData.fixed_list([G.i64(-70..70)])],
    mixed_signed: [args: StreamData.fixed_list([G.i64(-20..20), G.i64(-3..10)])],
    at_offset: [args: StreamData.fixed_list([G.i64(-1..9), G.i64(0..3), G.i64(0..65)])],
    flags: [],
    evens_and_bits: [],
    regrown: [],
    header: [],
    forks: [],
    empty: [],
    unappended: [],
    zero_width: [],
    until_negative: [],
    unary: [args: StreamData.fixed_list([G.i64(-3..200)])],
    unary_then: [args: StreamData.fixed_list([G.i64(-3..200), G.i64()])],
    gorilla: [args: StreamData.fixed_list([G.array(:f64)])]
  )
end
