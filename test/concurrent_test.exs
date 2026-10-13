# The runtime contract, entry: concurrent calls of the same kernel from many
# processes (defk-5fc). Every call has its own frame and its own owned buffers
# (ctx->owned is per call, and frames_live counts the frames of this library),
# so calls that yield and interleave must not share state: each caller gets
# the result it would get alone (the one rule), and once every caller is done
# no frame of the kernel is left live.

defmodule Defk.ConcurrentTest.K do
  use Defk

  # a call with more than DEFK_STRIP trips runs in strips and yields between
  # them; a call below that returns without ever suspending
  defk work(n :: i64) :: i64 do
    for i <- 1..n//1, reduce: 0 do
      acc -> acc + rem(i * 7919, 100_003)
    end
  end
end

defmodule Defk.ConcurrentTest do
  use ExUnit.Case, async: true
  import Defk.Test.Frames

  alias Defk.ConcurrentTest.K

  @timeout 30_000
  @callers 16

  defp reference(n), do: Enum.reduce(1..n, 0, fn i, acc -> acc + rem(i * 7919, 100_003) end)

  defp run_all(specs) do
    specs
    |> Task.async_stream(fn {n, expected} -> {n, K.work(n), expected} end,
      max_concurrency: @callers,
      ordered: false,
      timeout: @timeout
    )
    |> Enum.map(fn {_task, result} -> result end)
  end

  test "many processes calling the same kernel at once all get the right result" do
    long = 3_000_000
    short = 100
    ref_long = reference(long)
    ref_short = reference(short)

    # half the calls are long enough to yield and be suspended, half return
    # within one timeslice: both kinds run at the same time
    specs =
      List.duplicate({long, ref_long}, div(@callers, 2)) ++
        List.duplicate({short, ref_short}, div(@callers, 2))

    y0 = K.__defk_stats__().yields
    p0 = K.__defk_stats__().promotions

    for {n, got, expected} <- run_all(specs) do
      assert got == expected, "work(#{n})"
    end

    assert K.__defk_stats__().yields > y0, "no call yielded, so nothing was suspended"
    assert K.__defk_stats__().promotions > p0, "no call promoted a frame"

    assert_frames_live(K)

    # the same again with a yield at every safepoint, so the callers interleave
    # at their densest
    K.__defk_force_yields__(true)

    try do
      n = 50_000
      ref = reference(n)
      y1 = K.__defk_stats__().yields
      specs = List.duplicate({n, ref}, @callers)

      for {n2, got, expected} <- run_all(specs) do
        assert got == expected, "work(#{n2}) under forced yields"
      end

      assert K.__defk_stats__().yields > y1, "no call yielded"
    after
      K.__defk_force_yields__(false)
    end

    assert_frames_live(K)
  end
end
