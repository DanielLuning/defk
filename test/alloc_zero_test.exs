# alloc/2 gives an array of zeros (Elixir mode: a binary of zeros), but the
# zeroing is not one memset (defk-ktw): one memset held the scheduler for
# ~5 ms on an 85 MB alloc before the kernel's first loop ran. An alloc whose
# length is not known to be small zeroes its buffer in strips of
# DEFK_ZERO_STRIP bytes with a safepoint after each, a loop like any other: a
# yield in the middle spills the array and the bytes zeroed so far, and the
# resume carries on from there.
#
# The allocator hands out memory it used before, so a buffer can come back
# holding another call's bytes: `dirty/1` fills a buffer of the same size with
# 255 and drops it first, and every alloc'd byte not written must still read
# back 0 (no uninitialised memory reaches Elixir).

defmodule Defk.AllocZeroTest.K do
  use Defk

  # leaves n bytes of 255 to the allocator
  defk dirty(n :: i64) :: i64 do
    a = alloc(u8, n)

    for i <- 0..(n - 1)//1 do
      a[i] = 255
    end

    len(a)
  end

  defk zeros(n :: i64) :: [u8] do
    alloc(u8, n)
  end

  defk zeros_f64(n :: i64) :: [f64] do
    alloc(f64, n)
  end

  defk zeros_i32(n :: i64) :: [i32] do
    alloc(i32, n)
  end

  defk zeros_len(n :: i64) :: i64 do
    len(alloc(u8, n))
  end

  # a constant length of at most 4 KiB: zeroed at once, no safepoint
  defk small(i :: i64) :: i64 do
    w = alloc(i64, 64)
    w[i]
  end

  # writes [lo, hi) only
  defk partial(n :: i64, lo :: i64, hi :: i64) :: [u8] do
    out = alloc(u8, n)

    for i <- lo..(hi - 1)//1 do
      out[i] = 7
    end

    out
  end

  # an alloc in each iteration of a loop, then a flat loop over it
  defk in_loop(n :: i64, reps :: i64) :: i64 do
    for r <- 1..reps//1, reduce: 0 do
      acc ->
        b = alloc(i64, n + r)
        b[0] = r

        s =
          for x <- b, reduce: 0 do
            z -> z + x
          end

        acc + s + len(b)
    end
  end

  # an alloc two loops deep, and one in an if-branch
  defk nested(n :: i64, m :: i64) :: i64 do
    for a <- 1..m//1, reduce: 0 do
      acc ->
        for b <- 1..2//1, reduce: acc do
          acc2 ->
            buf = alloc(u8, n)
            buf[0] = a

            more =
              if b == 1 do
                t = alloc(u8, n + a)
                t[n] = a
                t[0] + t[n + a - 1] + len(t)
              else
                0
              end

            acc2 + buf[0] + buf[div(n, 2)] + buf[n - 1] + len(buf) + more
        end
    end
  end

  # two large allocs in one kernel, the second after the first is written
  defk two(n :: i64) :: {[i64], [u8]} do
    a = alloc(i64, n)
    a[0] = 1
    b = alloc(u8, 3 * n)
    b[3 * n - 1] = 2
    {a, b}
  end
end

defmodule Defk.AllocZeroTest do
  # async: false: the forced-yield tests flip a flag of K's library
  use ExUnit.Case, async: false
  use Defk.Properties

  alias Defk.AllocZeroTest.K
  alias Defk.Bench.TickGap

  # DEFK_ZERO_STRIP in priv/defk_runtime.h
  @strip 1024 * 1024
  # an i64 length whose buffer is just over one strip
  @i64_strip div(@strip, 8) + 1

  defp agree(fun, args), do: Defk.Test.assert_agrees(K, fun, args)

  defp forced(fun) do
    K.__defk_force_yields__(true)

    try do
      fun.()
    after
      K.__defk_force_yields__(false)
    end
  end

  defp yields(fun) do
    y0 = K.__defk_stats__().yields
    res = fun.()
    {res, K.__defk_stats__().yields - y0}
  end

  defp kernel_c(name) do
    [_ | chunks] = String.split(K.__defk_c_source__(), "/* ---- ")
    Enum.find(chunks, &String.starts_with?(&1, "#{name}/")) || flunk("no kernel #{name}")
  end

  defp zero_bytes(n), do: :binary.copy(<<0>>, n)

  describe "the generated C" do
    test "an alloc of unknown length zeroes in strips, a safepoint per strip" do
      c = kernel_c(:zeros)
      assert c =~ "defk_alloc_raw_u8(ctx, "
      assert c =~ "defk_zero_strip("
      assert c =~ ~r/DEFK_SP\(\d+, DEFK_ZERO_TICKS\(/
      assert c =~ "(yielding)"
    end

    test "a constant length of at most 4 KiB is zeroed at once" do
      c = kernel_c(:small)
      assert c =~ "defk_alloc_i64(ctx, "
      refute c =~ "defk_zero_strip("
      refute c =~ "(yielding)"
    end
  end

  describe "zeros where nothing was written" do
    test "after the allocator held other bytes, in both modes" do
      for n <- [0, 1, 4095, 4096, @strip - 1, @strip, @strip + 1, 3 * @strip + 17, 3_000_000] do
        K.dirty(n)
        assert agree(:zeros, [n]) == {:ok, zero_bytes(n)}, "n = #{n}"
        K.dirty(8 * n)
        assert agree(:zeros_f64, [n]) == {:ok, zero_bytes(8 * n)}, "n = #{n}"
        K.dirty(4 * n)
        assert agree(:zeros_i32, [n]) == {:ok, zero_bytes(4 * n)}, "n = #{n}"
      end
    end

    test "a resume in the middle of zeroing carries on where it left off" do
      n = 4 * @strip + 5

      {res, ys} =
        forced(fn ->
          K.dirty(n)
          yields(fn -> K.zeros(n) end)
        end)

      assert res == zero_bytes(n)
      # one safepoint per strip, each yielding: the zeroing was resumed
      assert ys >= 4
      assert %{frames_live: 0} = K.__defk_stats__()
    end

    test "under forced yields, every kernel agrees with Elixir mode" do
      forced(fn ->
        for {f, args} <- [
              zeros: [@strip * 5 + 3],
              zeros_f64: [@strip + 1],
              zeros_i32: [3 * @strip],
              zeros_len: [@strip * 2],
              small: [63],
              partial: [3 * @strip, @strip - 5, @strip + 5],
              in_loop: [@i64_strip, 3],
              nested: [@strip + 1, 2],
              two: [@i64_strip]
            ] do
          K.dirty(@strip * 9)
          assert {:ok, _} = agree(f, args), "#{f}"
        end
      end)
    end

    test "a partly written alloc keeps zeros around the writes" do
      n = 3 * @strip
      K.dirty(n)
      assert {:ok, bin} = agree(:partial, [n, @strip - 100, @strip + 100])

      assert bin ==
               zero_bytes(@strip - 100) <>
                 :binary.copy(<<7>>, 200) <> zero_bytes(2 * @strip - 100)
    end

    test "a raise in the middle of zeroing frees the buffers" do
      assert {:raise, %ArgumentError{}} = agree(:zeros, [-1])
      assert {:raise, %Enum.OutOfBoundsError{}} = forced(fn -> agree(:nested, [0, 1]) end)
      assert %{frames_live: 0} = K.__defk_stats__()
    end
  end

  # The kernel's responsiveness promise: an 85 MB alloc holds the scheduler no
  # longer than a yielding loop does. One memset of 85 MB was ~4 ms cold and
  # ~0.3 ms warm, so twenty warm ones in a row (one kernel call each) held it
  # ~6.5 ms; in strips each call yields as a loop does.
  @tag :timing
  test "an 85 MB alloc keeps the tick gap of a yielding loop" do
    loop = TickGap.run(fn -> Examples.Kernels.count_primes(300_000) end, 3)
    one = TickGap.run(fn -> K.zeros_len(85_000_000) end, 3)
    many = TickGap.run(fn -> for _ <- 1..20, do: K.zeros_len(85_000_000) end, 3)
    bound = loop.max * 1.5 + 0.5
    assert one.max <= bound, "one alloc: #{inspect(one)}, yielding loop: #{inspect(loop)}"
    assert many.max <= bound, "20 allocs: #{inspect(many)}, yielding loop: #{inspect(loop)}"
  end

  # ---------------------------------------------------- agreement properties --

  # a length up to three strips and a window of at most 64 writes (Elixir
  # mode copies the binary at each write)
  defp len_range do
    bind(integer(0..(3 * @strip)), fn n ->
      bind(integer(-2..(n + 2)), fn lo ->
        fixed_list([constant(n), constant(lo), integer(lo..min(lo + 64, n + 2))])
      end)
    end)
  end

  agreement(K,
    dirty: [args: fixed_list([G.alloc_len(1)])],
    zeros: [args: fixed_list([G.alloc_len(1, 0..(3 * @strip))])],
    zeros_f64: [args: fixed_list([G.alloc_len(8, 0..@i64_strip)])],
    zeros_i32: [args: fixed_list([G.alloc_len(4, 0..(2 * @i64_strip))])],
    zeros_len: [args: fixed_list([G.alloc_len(1, 0..(3 * @strip))])],
    small: [args: fixed_list([integer(-2..66)])],
    partial: [args: len_range()],
    in_loop: [args: fixed_list([integer(-2..@i64_strip), integer(0..3)])],
    nested: [args: fixed_list([integer(-1..(@strip + 2)), integer(0..2)])],
    two: [args: fixed_list([G.alloc_len(8, 0..@i64_strip)])]
  )

  property "a partly written alloc agrees under forced yields, after the allocator held 255s" do
    check all([n, lo, hi] <- len_range(), max_runs: 50) do
      forced(fn ->
        K.dirty(n)
        agree(:partial, [n, lo, hi])
      end)
    end
  end
end
