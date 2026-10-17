defmodule Defk.Contract.RuntimeContractTest do
  # The runtime contract (test/contracts/defk/runtime_contract.obligations.md,
  # docs/guides/runtime-contract.md): preemption, concurrent calls, errors as
  # exceptions and cleanup. Faults are in fault_contract_test.exs, hot code
  # upgrade in upgrade_contract_test.exs. Like every contract test it calls
  # only defk's public API and Defk.ContractKit (test/contracts/README.md).
  #
  # async: false: frame counts are per library and the cleanup test reads
  # :erlang.memory(:binary), which other tests' allocations would move.
  use Covenant.Case, component: "defk.runtime_contract", async: false

  alias Defk.ContractKit, as: Kit

  defmodule K do
    @moduledoc false
    use Defk

    # a call with more than one slice of work yields between slices
    defk work(n :: i64) :: i64 do
      for i <- 1..n//1, reduce: 0 do
        acc -> acc + rem(i * 7919, 100_003)
      end
    end

    defk work_noyield(n :: i64) :: i64, yield: false do
      for i <- 1..n//1, reduce: 0 do
        acc -> acc + rem(i * 7919, 100_003)
      end
    end

    defk straight(x :: i64, y :: i64) :: i64 do
      x * 3 + y
    end

    defk add(x :: i64, y :: i64) :: i64 do
      x + y
    end

    defk bump(a :: [i64], i :: i64) :: [i64] do
      a[i] = a[i] + 1
      a
    end

    defk checked(x :: i64) :: i64 do
      if x < 0, do: raise(ArgumentError, "x must not be negative")
      x
    end

    defk big(n :: i64) :: i64 do
      a = alloc(u8, n)
      length(a)
    end

    # long enough (~0.5 s) to be caught suspended
    defk spin(n :: i64) :: i64 do
      for i <- 0..(n - 1)//1, reduce: 0 do
        acc -> acc + rem(i, 7)
      end
    end

    # one owned buffer and yield: false (zeroing a large alloc has
    # safepoints), so this kernel never yields: the raise runs on the stack
    # frame of the first call
    defk raise_one(n :: i64, at :: i64) :: i64, yield: false do
      buf = alloc(i64, n)
      buf[at]
    end

    # one owned buffer per iteration, a nested loop so every iteration has a
    # safepoint: under forced yields the frame is promoted on the first
    # iteration, and the raise runs on the promoted frame
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

  @timeout 30_000
  @callers 16

  defp reference(n), do: Enum.reduce(1..n, 0, fn i, acc -> acc + rem(i * 7919, 100_003) end)

  describe "I1: a long kernel yields, and yielding never changes a result" do
    @tag obligation: "defk.runtime_contract.I1"
    test "a long call yields and gives the result a forced-yield call gives" do
      n = 3_000_000
      {result, yields} = Kit.yields(K, fn -> K.work(n) end)
      assert result == reference(n)
      assert yields > 0, "a #{n}-iteration call never yielded"

      m = 20_000
      {forced, forced_yields} = Kit.forced(K, fn -> Kit.yields(K, fn -> K.work(m) end) end)
      assert forced == K.work(m)
      assert forced == reference(m)
      assert forced_yields > 0
    end

    @tag obligation: "defk.runtime_contract.I1"
    test "a kernel without a loop, and one with yield: false, never yield" do
      Kit.forced(K, fn ->
        assert {11, 0} = Kit.yields(K, fn -> K.straight(3, 2) end)
        assert {result, 0} = Kit.yields(K, fn -> K.work_noyield(20_000) end)
        assert result == reference(20_000)
      end)
    end
  end

  describe "I2: concurrent calls share nothing" do
    defp run_all(specs) do
      specs
      |> Task.async_stream(fn {n, expected} -> {n, K.work(n), expected} end,
        max_concurrency: @callers,
        ordered: false,
        timeout: @timeout
      )
      |> Enum.map(fn {_task, result} -> result end)
    end

    @tag obligation: "defk.runtime_contract.I2"
    test "many processes calling the same kernel at once all get the right result" do
      long = 3_000_000
      short = 100

      # half the calls are long enough to yield and be suspended, half return
      # within one timeslice: both kinds run at the same time
      specs =
        List.duplicate({long, reference(long)}, div(@callers, 2)) ++
          List.duplicate({short, reference(short)}, div(@callers, 2))

      %{yields: y0, promotions: p0} = Kit.stats(K)

      for {n, got, expected} <- run_all(specs), do: assert(got == expected, "work(#{n})")

      assert Kit.stats(K).yields > y0, "no call yielded, so nothing was suspended"
      assert Kit.stats(K).promotions > p0, "no call promoted a frame"
      Kit.assert_frames_live(K)

      # the same again with a yield at every safepoint, so the callers
      # interleave at their densest
      Kit.forced(K, fn ->
        n = 50_000
        specs = List.duplicate({n, reference(n)}, @callers)
        {results, count} = Kit.yields(K, fn -> run_all(specs) end)

        for {n2, got, expected} <- results,
            do: assert(got == expected, "work(#{n2}) under forced yields")

        assert count > 0, "no call yielded"
      end)

      Kit.assert_frames_live(K)
    end
  end

  describe "I3: a runtime error is an ordinary exception in the caller" do
    @tag obligation: "defk.runtime_contract.I3"
    test "a write to an input array writes a copy; an index out of range raises" do
      a = <<1::signed-64-native, 2::signed-64-native>>
      assert K.bump(a, 1) == <<1::signed-64-native, 3::signed-64-native>>
      assert a == <<1::signed-64-native, 2::signed-64-native>>

      assert_raise Enum.OutOfBoundsError, fn -> K.bump(a, 2) end
      assert_raise Enum.OutOfBoundsError, fn -> K.bump(a, -1) end
    end

    @tag obligation: "defk.runtime_contract.I3"
    test "an overflow raises ArithmeticError and a kernel's raise its exception, both rescuable" do
      assert_raise ArithmeticError, fn -> K.add(0x7FFFFFFFFFFFFFFF, 1) end
      assert_raise ArgumentError, "x must not be negative", fn -> K.checked(-1) end

      rescued =
        try do
          K.checked(-1)
        rescue
          e in ArgumentError -> {:rescued, e.message}
        end

      assert rescued == {:rescued, "x must not be negative"}
      assert K.checked(4) == 4
    end
  end

  describe "I5: a call frees its memory, however it ends" do
    # a leak of any of these would be far above this: 50 MiB from the stack
    # frame phase plus 256 MiB from the promoted frame phase
    @leak_slack 16 * 1024 * 1024
    @stack_bufs 131_072
    @stack_calls 50
    @loop_n 2_000

    @tag :erlang_memory
    @tag obligation: "defk.runtime_contract.I5"
    test "a raise after alloc frees every owned buffer" do
      before = :erlang.memory(:binary)

      # the stack frame: no yield, so the raise is answered by the first call
      promotions0 = Kit.stats(K).promotions

      for _ <- 1..@stack_calls do
        assert_raise Enum.OutOfBoundsError,
                     "index #{@stack_bufs} out of bounds for array of length #{@stack_bufs}",
                     fn -> K.raise_one(@stack_bufs, @stack_bufs) end
      end

      assert Kit.stats(K).promotions == promotions0,
             "raise_one yielded; it has yield: false, so its raise must leave the stack frame"

      Kit.assert_frames_live(K)

      # the promoted frame: forced yields, so the frame is a resource when the
      # raise happens
      Kit.forced(K, fn ->
        %{yields: y0, promotions: p1} = Kit.stats(K)

        for _ <- 1..4 do
          assert_raise Enum.OutOfBoundsError,
                       "index 4096 out of bounds for array of length 4096",
                       fn -> K.raise_in_loop(@loop_n, @loop_n, 4096) end
        end

        assert Kit.stats(K).yields > y0, "the kernel never yielded"
        assert Kit.stats(K).promotions > p1, "the frame was never promoted"
      end)

      # the resource frames are garbage in this process now
      :erlang.garbage_collect(self())
      Kit.assert_frames_live(K)

      grown = :erlang.memory(:binary) - before

      assert grown < @leak_slack,
             "#{grown} bytes still counted after the raising calls " <>
               "(#{@stack_calls} * #{@stack_bufs * 8} + 4 * #{@loop_n * 4096 * 8} were allocated)"

      # every raising call left a working kernel behind
      assert K.raise_one(8, 0) == 0
      assert K.raise_in_loop(10, 0, 0) == 55
      Kit.assert_frames_live(K)
    end

    @tag obligation: "defk.runtime_contract.I5"
    test "a process killed while its kernel is suspended frees its frame" do
      Kit.assert_frames_live(K)
      pid = spawn(fn -> K.spin(1_000_000_000) end)
      Kit.wait_until(fn -> Kit.stats(K).frames_live == 1 end)

      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, _, _, :killed}, @timeout
      Kit.assert_frames_live(K)
    end

    @tag obligation: "defk.runtime_contract.I5"
    test "alloc/2 raises ArgumentError for a length over 2^48 bytes" do
      assert_raise ArgumentError, fn -> K.big(2 ** 48 + 1) end
      assert K.big(16) == 16
    end
  end
end
