defmodule Defk.Contract.FaultContractTest do
  # The runtime contract's fault promise (runtime_contract.obligations.md,
  # I4): a fault inside kernel native code is a RuntimeError in the calling
  # process and the node keeps running. The faults are injected on purpose
  # (Defk.ContractKit.inject_fault/2, MIX_ENV=test only). How the handler is
  # built and chained, and the faults that must still kill the node, are not
  # promised behaviour and stay in test/fault_containment_test.exs.
  use Covenant.Case, component: "defk.runtime_contract", async: false

  alias Defk.ContractKit, as: Kit

  # a loop with a safepoint per iteration and an owned buffer to free
  defmodule K do
    @moduledoc false
    use Defk

    defk spin(n :: i64) :: i64 do
      buf = alloc(i64, 64)

      for i <- 0..(n - 1)//1, reduce: 0 do
        acc ->
          buf[rem(i, 64)] = i
          acc + buf[rem(i, 64)]
      end
    end
  end

  # a second library: its handler sits in front of K's
  defmodule K2 do
    @moduledoc false
    use Defk

    defk spin2(n :: i64) :: i64 do
      for i <- 0..(n - 1)//1, reduce: 0 do
        acc -> acc + rem(i, 3)
      end
    end
  end

  @n 1_000_000
  @sum Enum.sum(0..(@n - 1))
  @bug ~r/^defk bug: segmentation fault inside kernel native code/

  setup do
    Kit.inject_fault(K, 0)
    Kit.inject_fault(K2, 0)
    :ok
  end

  @tag obligation: "defk.runtime_contract.I4"
  test "a segmentation fault raises RuntimeError in the caller, and the library works on" do
    live0 = Kit.stats(K).frames_live
    assert K.spin(@n) == @sum

    Kit.inject_fault(K, 1)
    assert_raise RuntimeError, @bug, fn -> K.spin(@n) end

    assert K.spin(@n) == @sum
    Kit.assert_frames_live(K, live0)
  end

  @tag obligation: "defk.runtime_contract.I4"
  test "an illegal instruction is contained the same way" do
    Kit.inject_fault(K, 2)
    assert_raise RuntimeError, ~r/^defk bug: illegal instruction/, fn -> K.spin(@n) end
    assert K.spin(@n) == @sum
  end

  @tag obligation: "defk.runtime_contract.I4"
  test "a fault after the kernel yielded is contained and its frame freed" do
    live0 = Kit.stats(K).frames_live

    Kit.forced(K, fn ->
      # let three clock reads pass: under forced yields each one yields
      Kit.inject_fault(K, 1 + 256 * 3)
      assert_raise RuntimeError, @bug, fn -> K.spin(@n) end
      assert K.spin(1000) == Enum.sum(0..999)
    end)

    Kit.assert_frames_live(K, live0)
    assert Kit.stats(K).promotions > 0
  end

  @tag obligation: "defk.runtime_contract.I4"
  test "other processes and other kernels keep running while one faults" do
    expected = Enum.sum(for i <- 0..(@n - 1), do: rem(i, 3))
    other = Task.async(fn -> for _ <- 1..20, do: K2.spin2(@n) end)

    for _ <- 1..5 do
      Kit.inject_fault(K, 1)
      assert_raise RuntimeError, @bug, fn -> K.spin(@n) end
    end

    assert Task.await(other, 30_000) == List.duplicate(expected, 20)

    Kit.inject_fault(K2, 1)
    assert_raise RuntimeError, @bug, fn -> K2.spin2(@n) end
    assert K2.spin2(@n) == expected
  end

  @tag obligation: "defk.runtime_contract.I4"
  test "the fault is raised in the calling process only" do
    parent = self()

    spawn(fn ->
      Kit.inject_fault(K, 1)

      try do
        K.spin(@n)
        send(parent, :no_raise)
      rescue
        e in RuntimeError -> send(parent, {:raised, Exception.message(e)})
      end
    end)

    assert_receive {:raised, msg}, 10_000
    assert msg =~ "segmentation fault"
    assert K.spin(100) == Enum.sum(0..99)
  end
end
