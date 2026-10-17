# The runtime contract for whole-buffer work: a value-semantics copy, the
# aligned copy of a misaligned input and a bitstring result used to be one
# memcpy or memset with no safepoint, so a 256 MB buffer held the scheduler
# for its whole copy (4-94 ms, bench/tick_gap.exs style). A yielding kernel
# now copies in 1 MiB strips with a safepoint after each, like alloc/2's
# zeroing; a bitstring result over a strip is handed over instead of copied
# out; and a grown accumulator is no longer zeroed. The results are the ones
# Elixir mode gives, also under forced yields, and a killed call frees its
# buffers.

defmodule Defk.StripCopiesTest.K do
  use Defk

  # `b` aliases the caller's binary, then is written: a copy of `a` first
  defk copy_first(a :: [u8]) :: i64 do
    b = a
    b[0] = 1
    a[0] + b[0] + b[length(b) - 1]
  end

  # an owned array copied in place: `c` still sees the buffer after the write
  defk copy_owned(n :: i64) :: i64 do
    out = alloc(u8, n)
    out[n - 1] = 7
    c = out
    out[0] = 1
    c[0] + out[0] + c[n - 1]
  end

  # the accumulator starts as a copy of the input (loop_owned/2's copy)
  defk acc_copy(a :: [u8], reps :: i64) :: i64 do
    out =
      for r <- 1..reps//1, reduce: a do
        acc ->
          acc[0] = r
          acc
      end

    out[0] + out[length(out) - 1]
  end

  # a copy every iteration: `b` still sees `a`'s buffer when `a` is written
  defk copy_each(a :: [u8], n :: i64) :: i64 do
    for i <- 0..(n - 1)//1, reduce: 0 do
      acc ->
        b = a
        a[0] = i
        acc + b[0] + a[0]
    end
  end

  # a misaligned [i64] input is copied at entry
  defk ends(a :: [i64]) :: i64 do
    a[0] + a[length(a) - 1]
  end

  # a misaligned input read after a yield, so the copy must survive resumes
  defk sum_after(a :: [i64]) :: i64 do
    for i <- 0..(length(a) - 1)//1, reduce: 0 do
      acc -> acc + a[i]
    end
  end

  defk bits(n :: i64) :: bitstring do
    for i <- 0..(n - 1)//1, reduce: <<>> do
      acc -> <<acc::bitstring, band(i, 255)::8>>
    end
  end

  # a bitstring result that is not a whole number of bytes
  defk bits_odd(n :: i64) :: bitstring do
    acc = <<>>
    acc = <<acc::bitstring, 1::1>>

    for i <- 0..(n - 1)//1, reduce: acc do
      acc -> <<acc::bitstring, band(i, 255)::8>>
    end
  end

  # an older, shorter value appended past: a new buffer holding its bits
  defk bits_fork(n :: i64) :: {bitstring, bitstring} do
    a =
      for i <- 0..(n - 1)//1, reduce: <<>> do
        acc -> <<acc::bitstring, band(i, 255)::8>>
      end

    b = <<a::bitstring, 1::1>>
    c = <<a::bitstring, 0::1, 255::8>>
    {b, c}
  end
end

defmodule Defk.StripCopiesTest do
  use ExUnit.Case, async: false
  import Defk.Test.Frames
  import Defk.TestKit
  alias Defk.StripCopiesTest.K

  @mib 1024 * 1024
  @timeout 30_000

  defp elixir(fun, args), do: K.__defk_elixir__(fun, args)

  test "a large copy before a write yields per strip and gives Elixir's result" do
    a = :binary.copy(<<9>>, 4 * @mib + 3)

    forced(K, fn ->
      {res, yields} = yields(K, fn -> K.copy_first(a) end)
      assert res == elixir(:copy_first, [a])
      assert yields >= 4
      assert K.copy_owned(3 * @mib) == elixir(:copy_owned, [3 * @mib])
    end)

    assert_frames_live(K)
  end

  test "an accumulator copied every iteration yields in its copies" do
    a = :binary.copy(<<5>>, 2 * @mib)

    forced(K, fn ->
      {res, yields} = yields(K, fn -> K.acc_copy(a, 3) end)
      assert res == elixir(:acc_copy, [a, 3])
      # the initial copy: two strips
      assert yields >= 2

      {res, yields} = yields(K, fn -> K.copy_each(a, 3) end)
      assert res == elixir(:copy_each, [a, 3])
      # the input copied before the loop, then a copy per iteration
      assert yields >= 8
    end)

    assert_frames_live(K)
  end

  test "a large misaligned input is copied in strips, and read after a yield" do
    big = i64s(Enum.to_list(1..(512 * 1024)))
    odd = binary_part(<<0>> <> big, 1, byte_size(big))
    assert K.ends(odd) == K.ends(big)
    assert K.sum_after(odd) == K.sum_after(big)

    forced(K, fn ->
      # a kernel with a loop copies the input in strips before it
      {res, yields} = yields(K, fn -> K.sum_after(odd) end)
      assert res == elixir(:sum_after, [odd])
      assert yields >= 4
      # a kernel without a loop copies it at once: no safepoint to pay for
      {res, yields} = yields(K, fn -> K.ends(odd) end)
      assert res == 1 + 512 * 1024
      assert yields == 0
    end)

    assert_frames_live(K)
  end

  test "small copies and aligned inputs are unchanged" do
    a = <<3, 4, 5>>
    assert K.copy_first(a) == elixir(:copy_first, [a])
    assert K.copy_owned(2) == elixir(:copy_owned, [2])
    assert K.acc_copy(a, 2) == elixir(:acc_copy, [a, 2])
    big = i64s([1, 2, 3])
    assert K.ends(big) == 4
    assert K.ends(binary_part(<<0>> <> big, 1, 24)) == 4
  end

  test "bitstring results across the copy-out limit, and an odd bit length" do
    for n <- [0, 1, 63, 64, 65, 4096, @mib - 1, @mib, @mib + 1, 3 * @mib] do
      expect = :binary.list_to_bin(for i <- 0..(n - 1)//1, do: Bitwise.band(i, 255))
      assert K.bits(n) == expect, "bits(#{n})"
      assert K.bits_odd(n) == <<1::1, expect::binary>>, "bits_odd(#{n})"
      {b, c} = K.bits_fork(n)
      assert b == <<expect::binary, 1::1>>
      assert c == <<expect::binary, 0::1, 255::8>>
    end

    forced(K, fn ->
      assert K.bits(2 * @mib) == elixir(:bits, [2 * @mib])
      assert K.bits_odd(2 * @mib) == elixir(:bits_odd, [2 * @mib])
      assert K.bits_fork(@mib + 5) == elixir(:bits_fork, [@mib + 5])
    end)

    assert_frames_live(K)
  end

  test "a call killed mid-copy frees its buffers" do
    a = :binary.copy(<<1>>, 64 * @mib)
    odd = binary_part(<<0>> <> i64s(List.duplicate(1, 4 * @mib)), 1, 32 * @mib)

    forced(K, fn ->
      kill_mid_copy(fn -> K.copy_first(a) end)
      kill_mid_copy(fn -> K.sum_after(odd) end)
    end)

    assert_frames_live(K)
  end

  # Spawns the call and kills it once its frame is a resource (the first
  # strip's yield), while the copy is under way; the frame's destructor
  # then frees the buffer, which frames_live back at 0 shows (it is
  # decremented after the release). Binary memory is no signal here: ERTS
  # frees a block from another scheduler's allocator later, on that
  # allocator's next allocation. Under heavy load the process can be starved
  # until the kernel finished; that attempt proves nothing, so try again.
  defp kill_mid_copy(fun, attempts \\ 20) do
    pid = spawn(fun)
    ref = Process.monitor(pid)

    wait_until(
      fn -> K.__defk_stats__().frames_live > 0 or not Process.alive?(pid) end,
      @timeout
    )

    if Process.alive?(pid) do
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, @timeout
      assert_frames_live(K)
    else
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, @timeout
      assert attempts > 1, "the kernel finished before it could be killed, every time"
      assert_frames_live(K)
      kill_mid_copy(fun, attempts - 1)
    end
  end
end
