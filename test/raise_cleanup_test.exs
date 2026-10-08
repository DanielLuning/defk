# The runtime contract, entry: a raise after alloc frees every owned buffer
# (defk-5fc). Buffers an array alloc/2 makes are owned by the call (ctx->owned
# in priv/defk_runtime.h): they are freed by defk_finish on the normal return,
# on the error path of both frames (the stack frame of the first call and the
# promoted frame of a yielded kernel), and by the frame destructor when the
# process dies. This test raises mid-computation after allocating, checks that
# frames_live comes back to 0, and checks that the bytes are really gone:
# if defk_finish did not run, the buffers would still be counted by
# :erlang.memory(:binary) after every call.

defmodule Defk.RaiseCleanupTest.K do
  use Defk

  # one owned buffer, no loop, so this kernel never yields: the raise runs on
  # the stack frame of the first call (the nif_ wrapper's defk_finish)
  defk raise_one(n :: i64, at :: i64) :: i64 do
    buf = alloc(i64, n)
    buf[at]
  end

  # one owned buffer per iteration, a nested loop so every iteration has a
  # safepoint: under forced yields the frame is promoted on the first
  # iteration, and the raise runs in the step_ wrapper on the promoted frame
  defk raise_in_loop(n :: i64, stop :: i64, at :: i64) :: i64 do
    for i <- 1..n//1, reduce: 0 do
      acc ->
        buf = alloc(i64, 4096)

        for j <- 0..3//1 do
          buf[j] = i
        end

        if i == stop, do: buf[at], else: acc + buf[0]
    end
  end
end

defmodule Defk.RaiseCleanupTest do
  use ExUnit.Case, async: false

  alias Defk.RaiseCleanupTest.K

  # a leak of any of these would be far above this: 50 MiB from the stack
  # frame phase plus 256 MiB from the promoted frame phase
  @leak_slack 16 * 1024 * 1024
  @stack_bufs 131_072
  @stack_calls 50
  @loop_n 2_000

  defp binary_bytes, do: :erlang.memory(:binary)

  test "a raise after alloc frees every owned buffer" do
    before = binary_bytes()

    # the stack frame: no yield, so the raise is answered by the first call's
    # own defk_finish
    promotions0 = K.__defk_stats__().promotions

    for _ <- 1..@stack_calls do
      assert_raise Enum.OutOfBoundsError,
                   "index #{@stack_bufs} out of bounds for array of length #{@stack_bufs}",
                   fn -> K.raise_one(@stack_bufs, @stack_bufs) end
    end

    assert K.__defk_stats__().promotions == promotions0,
           "raise_one yielded; it has no loop, so its raise must leave the stack frame"

    assert %{frames_live: 0} = K.__defk_stats__()

    # the promoted frame: forced yields, so the frame is a resource when the
    # raise happens and defk_finish runs on the promoted frame
    K.__defk_force_yields__(true)

    try do
      y0 = K.__defk_stats__().yields
      promotions1 = K.__defk_stats__().promotions

      for _ <- 1..4 do
        assert_raise Enum.OutOfBoundsError,
                     "index 4096 out of bounds for array of length 4096",
                     fn -> K.raise_in_loop(@loop_n, @loop_n, 4096) end
      end

      assert K.__defk_stats__().yields > y0, "the kernel never yielded"
      assert K.__defk_stats__().promotions > promotions1, "the frame was never promoted"
    after
      K.__defk_force_yields__(false)
    end

    # the resource frames are garbage in this process now
    :erlang.garbage_collect(self())
    wait_until(fn -> K.__defk_stats__().frames_live == 0 end)
    assert %{frames_live: 0} = K.__defk_stats__()

    grown = binary_bytes() - before
    assert grown < @leak_slack,
           "#{grown} bytes still counted after the raising calls " <>
             "(#{@stack_calls} * #{@stack_bufs * 8} + 4 * #{@loop_n * 4096 * 8} were allocated)"

    # every raising call left a working kernel behind
    assert K.raise_one(8, 0) == 0
    assert K.raise_in_loop(10, 0, 0) == 55
    assert %{frames_live: 0} = K.__defk_stats__()
  end

  defp wait_until(f, deadline \\ System.monotonic_time(:millisecond) + 30_000) do
    cond do
      f.() -> :ok
      System.monotonic_time(:millisecond) > deadline -> flunk("timed out")
      true ->
        Process.sleep(1)
        wait_until(f, deadline)
    end
  end
end
