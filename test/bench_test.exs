defmodule Defk.BenchTest do
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

  test "verdict thresholds" do
    assert Bench.verdict(2.0) == :good
    assert Bench.verdict(1.99) == :marginal
    assert Bench.verdict(1.0) == :marginal
    assert Bench.verdict(0.99) == :poor
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

    assert r.verdict == :good
  end

  test "native adds native_ms, native_label and the speedup of defk over it" do
    {_, out, json} = report(native: {spin(4), "pkg 1.0"})
    assert json["native_label"] == "pkg 1.0"
    assert json["native_ms"] >= 4
    assert json["native_speedup"] > 1
    assert json["verdict"] == "good"
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
    assert s < 1
    assert Enum.map(json["sweep"], & &1["size"]) == ["small", "mid", "big"]
    assert Enum.all?(json["sweep"], &(&1["elixir_ms"] && &1["defk_ms"]))
    assert json["crossover"] == "mid"
  end

  test "sweep as {sizes, fun} and a sweep without crossover" do
    {_, _, json} = report(sweep: {[1, 2], fn n -> {spin(n), spin(n * 2)} end}, sweep_runs: 1)
    assert Enum.map(json["sweep"], & &1["size"]) == [1, 2]
    assert json["crossover"] == nil
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

  test "a busy loop that never yields shows up as one big gap" do
    g = TickGap.run(fn -> :timer.sleep(1) && busy(60_000) end)
    assert g.max >= 1
  end

  defp busy(us) do
    t = System.monotonic_time(:microsecond)
    Stream.repeatedly(fn -> System.monotonic_time(:microsecond) end) |> Enum.find(&(&1 - t > us))
  end
end
