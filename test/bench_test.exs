defmodule Defk.BenchTest do
  # Nothing here depends on how fast the machine is. Verdict and speedup
  # arithmetic is tested on fixed inputs (Bench.compare/2 and friends); the
  # report tests assert the shape of the JSON only. The one wall-clock
  # assertion is tagged :timing and excluded by default:
  #
  #     mix test test/bench_test.exs --include timing
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Defk.Bench
  alias Defk.Bench.TickGap

  defp spin(ms), do: fn -> Process.sleep(ms) end

  defp report(opts) do
    base = [name: "t", expected: :good, elixir: spin(8), defk: spin(1), runs: 1]
    parent = self()

    out =
      capture_io(fn -> send(parent, {:r, Bench.report(Keyword.merge(base, opts))}) end)

    assert_received {:r, r}
    json = out |> String.split("\n") |> Enum.find(&String.starts_with?(&1, "DEFK_RESULT "))
    {r, out, JSON.decode!(String.replace_prefix(json, "DEFK_RESULT ", ""))}
  end

  # The timed fun allocates enough garbage to force minor GCs.
  defp churn, do: Enum.each(1..100_000, fn i -> {i, i, i} end)

  defp old_heap do
    :erlang.process_info(self(), :garbage_collection_info)
    |> elem(1)
    |> Keyword.fetch!(:old_heap_size)
  end

  defp u64_list(n),
    do: Enum.map(1..n, &((&1 * 0x9E3779B97F4A7C15) |> Bitwise.band(0xFFFFFFFFFFFFFFFF)))

  defp in_fresh_process(fun) do
    parent = self()
    {pid, ref} = spawn_monitor(fn -> send(parent, {:done, self(), fun.()}) end)

    receive do
      {:done, ^pid, r} -> r
      {:DOWN, ^ref, _, _, reason} -> flunk("process died: #{inspect(reason)}")
    end
  end

  test "settle puts the caller's live list in the old heap; a full sweep alone does not" do
    {size, full_only, settled} =
      in_fresh_process(fn ->
        list = u64_list(50_000)
        size = :erts_debug.flat_size(list)

        # the old behaviour: the next minor GC copies the list into the old heap
        :erlang.garbage_collect()
        before_full = old_heap()
        churn()
        after_full = old_heap()

        # settle: the list is already old, and GCs in the timed run leave it
        Bench.settle()
        {c0, _, _} = :erlang.statistics(:garbage_collection)
        before_settled = old_heap()
        churn()
        {c1, _, _} = :erlang.statistics(:garbage_collection)
        after_settled = old_heap()
        # keep the list live through both
        true = :erts_debug.flat_size(list) == size

        {size, {before_full, after_full}, {before_settled, after_settled, c1 - c0}}
      end)

    {before_full, after_full} = full_only
    assert before_full < size / 2
    assert after_full >= size * 0.9

    {before, after_, gcs} = settled
    assert before >= size * 0.9
    assert gcs > 0
    assert after_ - before < size / 100
  end

  test "report starts each timed run from the settled heap" do
    {size, seen} =
      in_fresh_process(fn ->
        list = u64_list(20_000)
        {:ok, agent} = Agent.start_link(fn -> [] end)

        capture_io(fn ->
          Bench.report(
            name: "t",
            expected: :poor,
            elixir: fn ->
              old = old_heap()
              Agent.update(agent, &[old | &1])
              length(list)
            end,
            runs: 3
          )
        end)

        {:erts_debug.flat_size(list), Agent.get(agent, & &1)}
      end)

    # seen is newest first: the three timed runs, then the warm-up call
    assert [_, _, _, _] = seen
    assert Enum.all?(Enum.take(seen, 3), &(&1 >= size * 0.9))
  end

  test "verdict thresholds" do
    assert Bench.verdict(2.0) == :good
    assert Bench.verdict(1.99) == :good
    assert Bench.verdict(1.0) == :marginal
    assert Bench.verdict(1.5) == :marginal
    assert Bench.verdict(0.5) == :poor
  end

  test "verdict tie band: 5% below each threshold counts as reaching it" do
    # 2x line
    assert Bench.verdict(1.9) == :good
    assert Bench.verdict(1.899) == :marginal
    # 1x line
    assert Bench.verdict(0.95) == :marginal
    assert Bench.verdict(0.949) == :poor
    # compare/2 uses the unrounded speedup
    assert Bench.compare(1000, 1000).verdict == :marginal
    assert Bench.compare(1900, 1000).verdict == :good
    assert Bench.compare(949, 1000).verdict == :poor
  end

  test "crossover is the first size with defk >= 2x, or nil" do
    rows = [
      %{size: "64", speedup: 0.5},
      %{size: "512", speedup: 1.9},
      %{size: "4096", speedup: 2.0},
      %{size: "32768", speedup: 9.0}
    ]

    assert Bench.crossover(rows) == "4096"
    assert Bench.crossover(Enum.take(rows, 2)) == nil
    assert Bench.crossover([]) == nil
  end

  test "old keys are unchanged and new keys are absent without options" do
    {r, _out, json} = report([])

    assert Enum.sort(Map.keys(json)) ==
             Enum.sort(
               ~w(baseline correct defk_ms elixir_ms example expected reason speedup verdict)
             )

    assert r.verdict in [:good, :marginal, :poor]
    assert json["verdict"] == Atom.to_string(r.verdict)
    assert is_number(json["speedup"]) and is_number(json["elixir_ms"])
  end

  test "compare is the arithmetic on fixed times" do
    assert %{elixir_ms: 8.0, defk_ms: 1.0, speedup: 8.0, verdict: :good} =
             Bench.compare(8000, 1000)

    assert %{speedup: 1.5, verdict: :marginal} = Bench.compare(3000, 2000)
    assert %{speedup: 0.5, verdict: :poor} = Bench.compare(1000, 2000)
    # unrounded speedup decides: 1.8999 rounds to 1.9 but is below the band edge
    assert %{speedup: 1.9, verdict: :marginal} = Bench.compare(18_999, 10_000)
    # a zero defk time cannot divide by zero
    assert %{verdict: :good} = Bench.compare(5, 0)
  end

  test "native_speedup and sweep_row on fixed times" do
    assert Bench.native_speedup(4.0, 1.0) == 4.0
    assert Bench.native_speedup(1.0, 0) == 1000.0

    assert Bench.sweep_row("s", 10.0, 2.0) ==
             %{size: "s", elixir_ms: 10.0, defk_ms: 2.0, speedup: 5.0}
  end

  test "native adds native_ms, native_label and the speedup of defk over it" do
    {_, out, json} = report(native: {spin(4), "pkg 1.0"})
    assert json["native_label"] == "pkg 1.0"
    assert is_number(json["native_ms"])
    assert is_number(json["native_speedup"])
    assert out =~ "pkg 1.0"

    {_, _, kw} = report(native: [fun: spin(1), label: :kw])
    assert kw["native_label"] == "kw"
  end

  test "realistic_size is recorded and printed" do
    {_, out, json} = report(realistic_size: "n = 4096")
    assert json["realistic_size"] == "n = 4096"
    assert out =~ "n = 4096"
  end

  test "sweep records per-size times, speedups and the crossover" do
    sweep = [{"small", spin(1), spin(2)}, {"mid", spin(10), spin(2)}, {"big", spin(20), spin(1)}]
    {_, _, json} = report(sweep: sweep, sweep_runs: 1)

    assert [%{"size" => "small", "speedup" => s} | _] = json["sweep"]
    assert is_number(s)
    assert Enum.map(json["sweep"], & &1["size"]) == ["small", "mid", "big"]
    assert Enum.all?(json["sweep"], &(&1["elixir_ms"] && &1["defk_ms"]))

    rows = Enum.map(json["sweep"], &%{size: &1["size"], speedup: &1["speedup"]})
    assert json["crossover"] == Bench.crossover(rows)
  end

  test "sweep as {sizes, fun} and a sweep without crossover" do
    {_, _, json} = report(sweep: {[1, 2], fn n -> {spin(n), spin(n * 2)} end}, sweep_runs: 1)
    assert Enum.map(json["sweep"], & &1["size"]) == [1, 2]
    assert Map.has_key?(json, "crossover")
  end

  test "responsiveness measures each side and restores schedulers_online" do
    online = :erlang.system_info(:schedulers_online)
    {_, out, json} = report(responsiveness: true, native: {spin(2), "n"})

    for k <- ~w(elixir_gap_ms defk_gap_ms native_gap_ms) do
      assert %{"max" => max, "p99" => p99} = json[k]
      assert max >= p99 and p99 >= 0
    end

    assert out =~ "gap elixir"
    assert :erlang.system_info(:schedulers_online) == online
  end

  test "responsiveness accepts funs for other sizes" do
    {_, _, json} = report(responsiveness: [elixir: spin(30)])
    assert json["elixir_gap_ms"]["max"] >= 0
    assert Map.has_key?(json, "elixir_gap_ms")
    assert json["defk_gap_ms"]["max"] >= 0
    refute Map.has_key?(json, "native_gap_ms")
  end

  test "TickGap summary and percentile" do
    assert TickGap.summary([]) == %{max: 0.0, p99: 0.0}
    assert TickGap.summary([1000, 2000, 50_000]) == %{max: 50.0, p99: 50.0}
    assert TickGap.percentile(Enum.to_list(1..100), 0.99) == 100
    assert TickGap.percentile([5], 0.99) == 5
  end

  @tag :timing
  test "a busy loop that never yields shows up as one big gap" do
    g = TickGap.run(fn -> :timer.sleep(1) && busy(60_000) end)
    assert g.max >= 1
  end

  defp busy(us) do
    t = System.monotonic_time(:microsecond)
    Stream.repeatedly(fn -> System.monotonic_time(:microsecond) end) |> Enum.find(&(&1 - t > us))
  end
end
