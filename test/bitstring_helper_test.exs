# The bitstring accumulator through helper kernels (defk-ooq): a kernel may
# take a `bitstring` parameter, append to it and return it, alone or in a
# tuple. Kernel calls are inlined, so the accumulator stays one append-only
# local of the caller. Such a helper has no NIF and no Elixir function: a
# bitstring comes only from a kernel, so only a kernel can call it, and one no
# other kernel calls is a compile error.

defmodule Defk.BitstringHelperTest.K do
  use Defk

  # Gorilla's delta-of-delta timestamp bits, the anchor's dod_bits as one
  # clause. Its ranges end at 64, 256 and 2048, one past what a signed
  # segment holds, so the top of each range is masked to its two's complement
  # bits (what Elixir's dod::7-signed writes for it); so is a dod beyond 32
  # bits, which Elixir's dod::32-signed truncates.
  defk dod_bits(acc :: bitstring, dod :: i64) :: bitstring do
    cond do
      dod == 0 -> <<acc::bitstring, 0::1>>
      dod >= -63 and dod <= 64 -> <<acc::bitstring, 0b10::2, band(dod, 0x7F)::7>>
      dod >= -255 and dod <= 255 -> <<acc::bitstring, 0b110::3, dod::9-signed>>
      dod == 256 -> <<acc::bitstring, 0b110::3, band(dod, 0x1FF)::9>>
      dod >= -2047 and dod <= 2047 -> <<acc::bitstring, 0b1110::4, dod::12-signed>>
      dod == 2048 -> <<acc::bitstring, 0b1110::4, band(dod, 0xFFF)::12>>
      true -> <<acc::bitstring, 0b1111::4, band(dod, 0xFFFFFFFF)::32>>
    end
  end

  # the first timestamp in 64 bits, then dod_bits for each one after it
  defk timestamps(ts :: [i64]) :: bitstring do
    n = length(ts)

    if n == 0 do
      <<>>
    else
      t0 = ts[0]
      acc = <<>>
      acc = <<acc::bitstring, band(bsr(t0, 32), 0xFFFFFFFF)::32, band(t0, 0xFFFFFFFF)::32>>

      {acc, _, _} =
        for i <- 1..(n - 1)//1, reduce: {acc, 0, t0} do
          {acc, prev_delta, prev} ->
            delta = ts[i] - prev
            {dod_bits(acc, delta - prev_delta), delta, ts[i]}
        end

      acc
    end
  end

  # `<<>>` as the argument, and a helper's result passed to it again
  defk(one_dod(dod :: i64) :: bitstring, do: dod_bits(<<>>, dod))
  defk(two_dods(a :: i64, b :: i64) :: bitstring, do: dod_bits(dod_bits(<<>>, a), b))

  # an Enum.reduce_while accumulator passed to the helper, until a zero dod
  defk dods_until_zero(ds :: [i64]) :: bitstring do
    Enum.reduce_while(ds, <<>>, fn d, acc ->
      if d == 0, do: {:halt, acc}, else: {:cont, dod_bits(acc, d)}
    end)
  end

  # a helper returning the accumulator in a tuple, beside a count
  defk put_nibble(acc :: bitstring, x :: i64) :: {bitstring, i64} do
    acc = <<acc::bitstring, band(x, 15)::4>>
    {acc, bit_size(acc)}
  end

  defk nibbles(xs :: [i64]) :: {bitstring, i64} do
    for x <- xs, reduce: {<<>>, 0} do
      {acc, _} -> put_nibble(acc, x)
    end
  end

  # a helper that calls a helper, and gives its parameter back unchanged
  defk maybe_flag(acc :: bitstring, k :: i64) :: bitstring do
    if k > 0, do: put_flag(acc), else: acc
  end

  defk(put_flag(acc :: bitstring) :: bitstring, do: <<acc::bitstring, 1::1>>)

  defk flags(xs :: [i64]) :: bitstring do
    for x <- xs, reduce: <<>> do
      acc -> maybe_flag(acc, x)
    end
  end

  # value semantics: the helper appends to its parameter while the caller
  # still holds the value it passed, and the caller appends to that value
  # again afterwards
  defk keeps_old(x :: i64) :: {bitstring, bitstring, bitstring} do
    a = <<>>
    a = <<a::bitstring, band(x, 7)::3>>
    b = dod_bits(a, x)
    c = <<a::bitstring, 0::2>>
    b = <<b::bitstring, 1::1>>
    {a, b, c}
  end

  # the same, where the helper also appends twice to its parameter and the
  # caller passes one value to it twice
  defk twice(acc :: bitstring, x :: i64) :: bitstring do
    once = <<acc::bitstring, band(x, 3)::2>>
    _ = <<acc::bitstring, 7::3>>
    <<once::bitstring, band(x, 3)::2>>
  end

  defk passes_twice(x :: i64) :: {bitstring, bitstring, bitstring} do
    a = <<>>
    a = <<a::bitstring, 1::1, 0::2>>
    b = twice(a, x)
    c = twice(a, x + 1)
    {a, b, c}
  end

  # a helper with a loop, so it yields with the accumulator half built
  defk append_run(acc :: bitstring, x :: i64, n :: i64) :: bitstring do
    for _ <- 1..n//1, reduce: acc do
      acc -> <<acc::bitstring, band(x, 7)::3>>
    end
  end

  defk runs(xs :: [i64], n :: i64) :: bitstring do
    for x <- xs, reduce: <<>> do
      acc -> append_run(acc, x, n)
    end
  end

  # the caller keeps the value it passed while the helper's loop yields
  defk run_beside(x :: i64, n :: i64) :: {bitstring, bitstring} do
    a = <<>>
    a = <<a::bitstring, 1::1, 0::1>>
    b = append_run(a, x, n)
    {<<a::bitstring, 1::1>>, b}
  end
end

defmodule Defk.BitstringHelperTest do
  use Defk.Case, async: false
  import Defk.Test.Frames
  use Defk.Properties

  import Defk.TestKit, only: [codes: 1, forced: 2, i64s: 1, reject: 2, yields: 2]

  alias Defk.BitstringHelperTest.K

  defp agrees(fun, args), do: Defk.Test.assert_agrees(K, fun, args)

  # the anchor's multi-clause dod_bits, in plain Elixir with signed segments
  defp dod_ref(acc, 0), do: <<acc::bitstring, 0::1>>
  defp dod_ref(acc, d) when d >= -63 and d <= 64, do: <<acc::bitstring, 0b10::2, d::7-signed>>
  defp dod_ref(acc, d) when d >= -255 and d <= 256, do: <<acc::bitstring, 0b110::3, d::9-signed>>

  defp dod_ref(acc, d) when d >= -2047 and d <= 2048,
    do: <<acc::bitstring, 0b1110::4, d::12-signed>>

  defp dod_ref(acc, d), do: <<acc::bitstring, 0b1111::4, d::32-signed>>

  defp timestamps_ref([]), do: <<>>

  defp timestamps_ref([t0 | rest]) do
    {acc, _, _} =
      Enum.reduce(rest, {<<t0::64>>, 0, t0}, fn t, {acc, prev_delta, prev} ->
        delta = t - prev
        {dod_ref(acc, delta - prev_delta), delta, t}
      end)

    acc
  end

  @dods [
    0,
    1,
    -1,
    63,
    -63,
    64,
    -64,
    65,
    255,
    -255,
    256,
    -256,
    257,
    2047,
    -2047,
    2048,
    -2048,
    2049,
    2 ** 31,
    -(2 ** 31),
    2 ** 40
  ]

  describe "Gorilla's dod_bits" do
    test "each range of dod gives the anchor's bits, in both modes" do
      in_both_modes do
        for d <- @dods do
          assert K.one_dod(d) == dod_ref(<<>>, d), "dod #{d}"
        end

        assert K.two_dods(5, -300) == dod_ref(dod_ref(<<>>, 5), -300)
        assert K.dods_until_zero(i64s([3, -70, 0, 9])) == dod_ref(dod_ref(<<>>, 3), -70)
      end

      for d <- @dods, do: assert({:ok, _} = agrees(:one_dod, [d]))
    end

    test "a timestamp series through dod_bits from a reduce loop" do
      regular = Enum.map(0..300, &(1_700_000_000 + &1 * 60))
      jitter = Enum.scan(1..300, 1_700_000_000, fn i, t -> t + 60 + rem(i * 7919, 41) - 20 end)
      gaps = [0, 10, 20, 20, 3_000, 3_010, 100_000, 100_000, 5, -2]

      for ts <- [[], [42], [1, 2], regular, jitter, gaps] do
        expect = timestamps_ref(ts)

        in_both_modes do
          assert K.timestamps(i64s(ts)) == expect
        end

        assert {:ok, ^expect} = agrees(:timestamps, [i64s(ts)])
      end
    end

    property "random series agree with the multi-clause Elixir form" do
      check all(ts <- StreamData.list_of(G.i64(-(2 ** 40)..(2 ** 40)), max_length: 60)) do
        expect = timestamps_ref(ts)
        assert {:ok, ^expect} = agrees(:timestamps, [i64s(ts)])
      end
    end
  end

  describe "passing the accumulator" do
    test "a helper returning it in a tuple, and one giving its parameter back" do
      xs = [1, 18, 3, 255, 0]
      bits = for x <- xs, into: <<>>, do: <<Bitwise.band(x, 15)::4>>

      in_both_modes do
        assert K.nibbles(i64s(xs)) == {bits, 20}
        assert K.nibbles(<<>>) == {<<>>, 0}
        assert K.flags(i64s([1, 0, -3, 2])) == <<1::1, 1::1>>
        assert K.flags(i64s([0])) == <<>>
      end

      assert agrees(:nibbles, [i64s(xs)]) == {:ok, {bits, 20}}
      assert agrees(:flags, [i64s([1, 0, -3, 2])]) == {:ok, <<1::1, 1::1>>}
    end

    test "a helper appending to a value the caller still holds and appends to again" do
      for x <- [0, 5, -100, 3_000, 2 ** 40] do
        a = <<Bitwise.band(x, 7)::3>>
        expect = {a, <<dod_ref(a, x)::bitstring, 1::1>>, <<a::bitstring, 0::2>>}

        in_both_modes do
          assert K.keeps_old(x) == expect
        end

        assert {:ok, ^expect} = agrees(:keeps_old, [x])
      end
    end

    test "one value passed twice to a helper that appends to its parameter twice" do
      for x <- [0, 1, 2, 7] do
        a = <<1::1, 0::2>>
        twice = fn v -> <<a::bitstring, Bitwise.band(v, 3)::2, Bitwise.band(v, 3)::2>> end
        expect = {a, twice.(x), twice.(x + 1)}

        in_both_modes do
          assert K.passes_twice(x) == expect
        end

        assert {:ok, ^expect} = agrees(:passes_twice, [x])
      end
    end

    test "a helper is not a function of the module" do
      kernels = Enum.map(K.__defk_kernels__(), & &1.name)
      assert :timestamps in kernels
      refute :dod_bits in kernels
      refute function_exported?(K, :dod_bits, 2)
      refute function_exported?(K, :__defk_native_dod_bits__, 2)
    end
  end

  describe "the runtime contract" do
    test "the accumulator survives yields inside the inlined helper" do
      xs = Enum.map(0..9, &rem(&1 * 5, 8))
      n = 20_000
      expect = for x <- xs, _ <- 1..n, into: <<>>, do: <<x::3>>

      forced(K, fn ->
        {res, y} = yields(K, fn -> K.runs(i64s(xs), n) end)
        assert res == expect
        assert y > 10, "the kernel never yielded"

        b = for _ <- 1..n, into: <<1::1, 0::1>>, do: <<5::3>>
        {res, y} = yields(K, fn -> K.run_beside(5, n) end)
        assert res == {<<1::1, 0::1, 1::1>>, b}
        assert y > 1, "the kernel never yielded"
      end)

      assert agrees(:runs, [i64s(xs), 2_000]) ==
               {:ok, for(x <- xs, _ <- 1..2_000, into: <<>>, do: <<x::3>>)}

      # the frames of the finished calls go with this process's garbage
      :erlang.garbage_collect()
      assert_frames_live(K)
    end
  end

  describe "compile errors" do
    defp rejected(body), do: reject(__MODULE__, body)

    test "a kernel taking a bitstring that no kernel calls is an entry kernel" do
      msg =
        rejected("defk f(acc :: bitstring, x :: i64) :: bitstring, do: <<acc::bitstring, x::8>>")

      assert codes(msg) == ["bitstring-use"], msg
      assert msg =~ "f/2 takes the bitstring acc, so only a kernel can call it", msg
      assert msg =~ "Elixir cannot pass a bitstring accumulator to an entry kernel", msg
      assert msg =~ "call f/2 from the kernel that builds the accumulator", msg
    end

    test "a helper called only by another such helper is not reached from Elixir" do
      msg =
        rejected("""
        defk f(acc :: bitstring) :: bitstring, do: g(acc)
        defk g(acc :: bitstring) :: bitstring, do: <<acc::bitstring, 1::1>>
        """)

      assert codes(msg) == ["bitstring-use", "bitstring-use"], msg
      assert msg =~ "f/1 takes the bitstring acc", msg
      assert msg =~ "g/1 takes the bitstring acc", msg
    end

    test "passing the accumulator as another type" do
      msg =
        rejected(
          "defk g(b :: [u8]) :: i64, do: length(b)\n\n" <>
            "defk f(x :: i64) :: i64 do\n  acc = <<>>\n  acc = <<acc::bitstring, x::8>>\n  g(acc)\nend"
        )

      assert codes(msg) == ["bitstring-use"], msg
      assert msg =~ "passing the bitstring acc to g/1 as b :: [u8] is not supported", msg

      msg =
        rejected(
          "defk g(acc :: bitstring) :: bitstring, do: acc\n\n" <>
            "defk f(x :: [u8]) :: bitstring, do: g(x)"
        )

      assert codes(msg) == ["type-mismatch"], msg
    end

    test "a rejection inside a helper is reported in the helper" do
      msg =
        rejected("""
        defk f(xs :: [i64]) :: bitstring do
          for x <- xs, reduce: <<>> do
            acc -> g(acc, x)
          end
        end

        defk g(acc :: bitstring, x :: i64) :: bitstring do
          _ = length(acc)
          <<acc::bitstring, x::8>>
        end
        """)

      assert codes(msg) == ["bitstring-use"], msg
      assert msg =~ "length(acc) reads the bitstring acc", msg
    end
  end

  agreement(K,
    timestamps: [args: StreamData.fixed_list([G.array(:i64, of: G.i64(-(2 ** 40)..(2 ** 40)))])],
    one_dod: [],
    two_dods: [],
    dods_until_zero: [],
    nibbles: [],
    flags: [],
    keeps_old: [],
    passes_twice: [],
    runs: [args: StreamData.fixed_list([G.array(:i64), G.i64(-2..40)])],
    run_beside: [args: StreamData.fixed_list([G.i64(), G.i64(-2..40)])]
  )
end
