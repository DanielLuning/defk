# The adaptive slice (defk-04y): a yielding kernel's function passes how many
# processes wait in the run queues (:erlang.statistics(:total_run_queue_lengths))
# to its NIF, renamed __defk_native_<name>__ with the hint as an extra last
# argument. A hint > 0 makes the call yield every 50 us instead of 250 us for
# its first millisecond (defk_slice_init in priv/defk_runtime.h), so short
# calls fanned out from one process spread over the schedulers. The slice
# never changes a result. `use Defk, adaptive_slice: false` keeps the plain
# NIF.

defmodule Defk.AdaptiveSliceTest.K do
  use Defk

  defk spin(n :: i64) :: i64 do
    for i <- 0..(n - 1)//1, reduce: 0 do
      acc -> rem(acc * 31 + i, 1_000_003)
    end
  end

  defk flat(n :: i64) :: i64, yield: false do
    for i <- 0..(n - 1)//1, reduce: 0 do
      acc -> acc + i
    end
  end

  # no loop: never yields
  defk add(a :: i64, b :: i64) :: i64 do
    a + b
  end
end

defmodule Defk.AdaptiveSliceTest.Off do
  use Defk, adaptive_slice: false

  defk spin(n :: i64) :: i64 do
    for i <- 0..(n - 1)//1, reduce: 0 do
      acc -> rem(acc * 31 + i, 1_000_003)
    end
  end
end

defmodule Defk.AdaptiveSliceTest do
  use ExUnit.Case, async: true

  alias Defk.AdaptiveSliceTest.{K, Off}

  defp ex_spin(n), do: Enum.reduce(0..(n - 1)//1, 0, &rem(&2 * 31 + &1, 1_000_003))

  defp yields(f) do
    y0 = K.__defk_stats__().yields
    r = f.()
    {r, K.__defk_stats__().yields - y0}
  end

  defp collect_hints(to, acc) do
    receive do
      {:trace, _, :call, {K, :__defk_native_spin__, [_, hint]}} -> collect_hints(to, [hint | acc])
      :done -> send(to, {:hints, acc})
    end
  end

  # n whose uncrowded call runs at least `us` microseconds
  defp calibrate(n, us) do
    {t, _} = :timer.tc(fn -> K.__defk_native_spin__(n, 0) end)
    if t >= us, do: n, else: calibrate(n * 2, us)
  end

  test "only a yielding kernel's NIF takes the run-queue hint" do
    assert function_exported?(K, :__defk_native_spin__, 2)
    refute function_exported?(K, :__defk_native_spin__, 1)
    # yield: false and a kernel without loops never yield: no hint
    refute function_exported?(K, :__defk_native_flat__, 2)
    refute function_exported?(K, :__defk_native_add__, 3)
    assert K.flat(10) == 45 and K.add(2, 3) == 5
    # the hint is not part of the kernel's signature
    assert Enum.find(K.__defk_kernels__(), &(&1.name == :spin)) ==
             %{name: :spin, arity: 1, params: [n: :i64], ret: :i64}
  end

  test "adaptive_slice: false keeps the plain NIF" do
    refute function_exported?(Off, :__defk_native_spin__, 2)
    assert Off.spin(1000) == ex_spin(1000)
  end

  test "a crowded hint yields more often in the call's first millisecond" do
    n = calibrate(50_000, 1_500)

    pairs =
      for _ <- 1..5 do
        {lone, y_lone} = yields(fn -> K.__defk_native_spin__(n, 0) end)
        {crowded, y_crowded} = yields(fn -> K.__defk_native_spin__(n, 5) end)
        assert lone == crowded
        {y_lone, y_crowded}
      end

    # a 1.5 ms call: ~6 yields at 250 us; 50 us for the first 1 ms adds ~16.
    # Summed over five pairs, so one call slowed by the OS does not decide.
    {lone, crowded} = Enum.unzip(pairs)

    assert Enum.sum(crowded) >= Enum.sum(lone) + 25,
           "lone #{inspect(lone)}, crowded #{inspect(crowded)}"
  end

  test "the slice never changes a result, also under forced yields" do
    for n <- [0, 1, 2047, 2048, 50_000] do
      want = ex_spin(n)
      assert K.__defk_native_spin__(n, 0) == want
      assert K.__defk_native_spin__(n, 3) == want
      # a hint that is not an integer is no hint
      assert K.__defk_native_spin__(n, :crowded) == want
    end

    K.__defk_force_yields__(true)

    try do
      assert K.__defk_native_spin__(5000, 1) == ex_spin(5000)
    after
      K.__defk_force_yields__(false)
    end
  end

  test "the kernel's function passes the run-queue length as the hint" do
    # busy processes beyond the schedulers keep the run queues non-empty
    busy =
      for _ <- 1..(2 * System.schedulers_online()) do
        spawn(fn ->
          Stream.repeatedly(fn -> :erlang.phash2(:rand.uniform()) end) |> Stream.run()
        end)
      end

    # a tracer of its own: the hint is the NIF call's last argument
    me = self()
    tracer = spawn(fn -> collect_hints(me, []) end)
    :erlang.trace_pattern({K, :__defk_native_spin__, 2}, true, [:local])
    :erlang.trace(self(), true, [:call, {:tracer, tracer}])

    try do
      for _ <- 1..20, do: assert(K.spin(20_000) == ex_spin(20_000))
    after
      :erlang.trace(self(), false, [:call])
      :erlang.trace_pattern({K, :__defk_native_spin__, 2}, false, [:local])
      Enum.each(busy, &Process.exit(&1, :kill))
    end

    send(tracer, :done)
    assert_receive {:hints, hints}, 5_000
    assert Enum.count(hints) == 20
    assert Enum.all?(hints, &is_integer/1)
    assert Enum.any?(hints, &(&1 > 0)), "no hint > 0 with busy processes: #{inspect(hints)}"
  end

  test "use Defk rejects a non-boolean adaptive_slice" do
    assert_raise ArgumentError, ~r/adaptive_slice: true \| false/, fn ->
      Code.compile_string("""
      defmodule Defk.AdaptiveSliceTest.Bad do
        use Defk, adaptive_slice: :sometimes
      end
      """)
    end
  end
end
