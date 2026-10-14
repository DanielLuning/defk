# The runtime contract, entry: a yield with small heap-binary inputs
# (<= 64 bytes) and a forced GC between steps (defk-5fc). Binaries of at most
# 64 bytes live on the caller's heap, so a GC between two steps can move them.
# The runtime re-binds every array argument from the rescheduled argv on every
# entry (defk_bind in priv/defk_runtime.h), so a resume must read the moved
# binary, not the address the previous step held. The test forces that GC: a
# child process churns its heap, starts a yielding kernel, and the parent
# garbage-collects it while it is suspended between two steps. That the GC
# landed mid-kernel is observed (the churned heap is reclaimed while the call
# is still running, and the kernel keeps yielding afterwards), and the result
# must still be the one Elixir gives (the one rule).

defmodule Defk.HeapBinaryYieldTest.K do
  use Defk

  # three heap binaries: 32, 16 and 8 bytes, each under the 64-byte limit
  defk weigh(a :: [i64], b :: [u8], c :: [f64], reps :: i64) :: i64 do
    for r <- 1..reps//1, reduce: 0 do
      acc ->
        s =
          for i <- 0..(length(a) - 1)//1, reduce: 0 do
            z -> z + a[i] * r
          end

        t =
          for i <- 0..(length(b) - 1)//1, reduce: 0 do
            z -> z + b[i]
          end

        f =
          for i <- 0..(length(c) - 1)//1, reduce: 0.0 do
            z -> z + c[i]
          end

        acc + s + t + trunc(f)
    end
  end
end

defmodule Defk.HeapBinaryYieldTest do
  use ExUnit.Case, async: true
  import Defk.Test.Frames
  import Defk.TestKit

  alias Defk.HeapBinaryYieldTest.K

  @timeout 30_000
  # ~150 ms of yields at every safepoint: far longer than the forced GC needs
  @reps 8_000_000

  defp heap_binary_inputs do
    a = i64s([1, 2, 3, 4])
    b = <<1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16>>
    c = f64s([0.5, 1.5, 2.5])

    assert byte_size(a) <= 64 and byte_size(b) <= 64 and byte_size(c) <= 64,
           "the inputs must stay heap binaries"

    {a, b, c}
  end

  # per rep r: 10 * r from a, 136 from b, trunc(4.5) = 4 from c
  defp closed_form(reps), do: 10 * div(reps * (reps + 1), 2) + 140 * reps

  # {minor_gcs, heap_size}: a GC of the child shows up as a change of either
  # (the churned heap is reclaimed, and minor_gcs resets on a full sweep)
  defp gc_state(pid) do
    case :erlang.process_info(pid, [:garbage_collection, :heap_size]) do
      [{:garbage_collection, gc}, {:heap_size, hs}] -> {Keyword.get(gc, :minor_gcs), hs}
      _ -> :dead
    end
  end

  test "heap-binary inputs agree with Elixir mode while the kernel yields" do
    {a, b, c} = heap_binary_inputs()

    forced(K, fn ->
      {res, count} = yields(K, fn -> K.weigh(a, b, c, 2_000) end)
      assert res == closed_form(2_000)
      assert count > 0, "the kernel never yielded"
      assert K.weigh(a, b, c, 2_000) == K.__defk_elixir__(:weigh, [a, b, c, 2_000])
    end)
  end

  test "a forced GC between two steps of a yielding kernel keeps the result correct" do
    {a, b, c} = heap_binary_inputs()
    expected = closed_form(@reps)

    forced(K, fn ->
      parent = self()
      y0 = K.__defk_stats__().yields

      child =
        spawn(fn ->
          # a dead-on-arrival heap: a GC between two steps reclaims it
          churn = for i <- 1..10_000, do: {:churn, i, self()}
          _ = length(churn)
          send(parent, {:ready, self()})

          result =
            try do
              {:result, K.weigh(a, b, c, @reps)}
            rescue
              e -> {:raised, e}
            end

          send(parent, result)
        end)

      assert_receive {:ready, ^child}, @timeout
      first = gc_state(child)
      assert first != :dead, "the kernel finished before the GC could be forced"

      # the kernel is provably suspended between two steps: it has already
      # yielded and is still running
      wait_until(fn -> K.__defk_stats__().yields > y0 + 20 end)

      # force the GC now
      :erlang.garbage_collect(child)
      wait_until(fn -> gc_state(child) != first end)
      assert gc_state(child) != :dead, "the GC landed only after the call ended"
      after_gc = K.__defk_stats__().yields

      assert_receive {:result, ^expected}, @timeout
      refute_received {:raised, _}

      # the kernel kept yielding after the GC between its steps
      wait_until(fn -> K.__defk_stats__().yields > after_gc end)
      assert_frames_live(K)
    end)
  end
end
