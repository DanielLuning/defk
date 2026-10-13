defmodule Defk.Examples.Scoreboard do
  @moduledoc false
  # The `--bench` scoreboard: what `examples/run_all.exs` printed, over the
  # first `DEFK_RESULT` line of each example (defk-30c.3). Also the check-only
  # summary.

  @doc "The check-only summary: one line per outcome."
  def print_check(outcomes) do
    IO.puts("\n" <> pad("example", 34) <> pad("result", 20) <> pad("secs", 9) <> "note")

    for o <- outcomes do
      IO.puts(pad(o.name, 34) <> pad(label(o.status), 20) <> pad(secs(o.secs), 9) <> o.note)
    end

    print_skipped(outcomes)
  end

  @doc """
  The bench scoreboard over example outcomes (the app's tests are not in it),
  and, with `snapshot?`, the markdown table for docs/verdict.md.
  """
  def print_bench(outcomes, snapshot?) do
    results = Enum.map(outcomes, &row/1)

    IO.puts(
      "\n" <>
        pad("example", 26) <>
        pad("expected", 14) <>
        pad("measured", 14) <>
        pad("speedup", 10) <>
        pad("elixir ms", 11) <> pad("defk ms", 10) <> pad("baseline", 12) <> "ok"
    )

    for {o, r} <- Enum.zip(outcomes, results) do
      IO.puts(
        pad(r["example"], 26) <>
          pad(r["expected"], 14) <>
          pad(r["verdict"], 14) <>
          pad(speedup(r), 10) <>
          pad(num(r["elixir_ms"]), 11) <>
          pad(num(r["defk_ms"]), 10) <>
          pad(r["baseline"] || "?", 12) <> if(o.status == :ok, do: "yes", else: "NO")
      )

      case extra_line(r) do
        "" -> :ok
        line -> IO.puts(line)
      end
    end

    good = Enum.count(outcomes, &(&1.status == :ok))
    IO.puts("\n#{good}/#{length(outcomes)} examples behave as claimed")
    print_provisional(results)
    print_cache(outcomes)
    print_skipped(outcomes)
    if snapshot?, do: print_snapshot(results)
  end

  # every report's cache outcome (Defk.Bench.Cache, defk-30c.5), not only
  # the first report's
  defp print_cache(outcomes) do
    reports = for o <- outcomes, r <- o.results, do: r
    reused = Enum.filter(reports, &(&1["cache"] == "reused"))
    unstored = Enum.filter(reports, &(&1["cache"] == "not_stored"))

    if reused != [] do
      IO.puts(
        "#{length(reused)} report(s) reused a cached result (inputs unchanged; --fresh measures them): " <>
          Enum.map_join(reused, ", ", &"#{&1["example"]} (#{measured_on(&1)})")
      )
    end

    if unstored != [] do
      IO.puts(
        "#{length(unstored)} report(s) not cached, the machine was not quiet: " <>
          Enum.map_join(unstored, ", ", & &1["example"])
      )
    end
  end

  defp measured_on(r), do: String.slice(r["measured_at"] || "?", 0, 10)

  # the first result line, or a stand-in for an example that crashed
  defp row(%{results: [first | _], status: status}) when status != :crashed, do: first

  defp row(%{name: name}),
    do: %{"example" => name, "expected" => "?", "verdict" => "crashed", "correct" => false}

  defp print_provisional(results) do
    provisional =
      Enum.filter(results, &(&1["verdict"] == "good" and &1["baseline"] != "optimized"))

    if provisional != [] do
      IO.puts(
        "#{length(provisional)} 'good' claim(s) are provisional: the Elixir baseline is not optimised yet " <>
          "(#{Enum.map_join(provisional, ", ", & &1["example"])})"
      )
    end
  end

  defp print_skipped(outcomes) do
    skipped =
      for o <- outcomes, r <- o.results, r["correct"] == "skipped", do: r

    if skipped != [] do
      IO.puts(
        "#{length(skipped)} check(s) skipped by their examples:\n" <>
          Enum.map_join(skipped, "\n", &"  #{&1["example"]}: #{&1["reason"]}")
      )
    end
  end

  # second line per example, only for the keys a script reports
  defp extra_line(r) do
    parts =
      Enum.filter(
        [
          r["realistic_size"] && "realistic size #{r["realistic_size"]}",
          r["native_speedup"] &&
            "vs #{r["native_label"]}: defk #{r["native_speedup"]}x (native #{r["native_ms"]} ms)",
          r["native_ms"] && is_nil(r["native_speedup"]) &&
            "native #{r["native_ms"]} ms [#{r["native_label"]}]",
          gaps(r) != [] && "tick gap ms: " <> Enum.join(gaps(r), "; "),
          Map.has_key?(r, "crossover") && "crossover #{r["crossover"] || "none"}"
        ],
        & &1
      )

    if parts == [], do: "", else: "    " <> Enum.join(parts, " | ")
  end

  defp gaps(r) do
    for {k, label} <- [
          {"elixir_gap_ms", "elixir"},
          {"defk_gap_ms", "defk"},
          {"native_gap_ms", "native"}
        ],
        %{"max" => m, "p99" => p} <- [r[k]] do
      "#{label} max #{m} / p99 #{p}"
    end
  end

  defp print_snapshot(results) do
    IO.puts(
      "\n| Example | Realistic size | Verdict | Speedup | Elixir ms | defk ms | vs native | " <>
        "Tick gap ms, max / p99 | Crossover |\n|---|---|---|---|---|---|---|---|---|"
    )

    for r <- results do
      cells = [
        if(r["cache"] == "reused",
          do: "#{r["example"]} (reused, measured #{measured_on(r)})",
          else: r["example"]
        ),
        cell(r["realistic_size"]),
        r["verdict"],
        speedup(r),
        cell(r["elixir_ms"]),
        cell(r["defk_ms"]),
        native_cell(r),
        gap_cell(r),
        if(Map.has_key?(r, "crossover"), do: r["crossover"] || "none", else: "-")
      ]

      IO.puts("| " <> Enum.join(cells, " | ") <> " |")
    end
  end

  defp native_cell(%{"native_speedup" => nil}), do: "-"
  defp native_cell(%{"native_speedup" => x, "native_label" => l}), do: "#{x}x (#{l})"
  defp native_cell(_), do: "-"

  defp gap_cell(r) do
    case gaps(r) do
      [] -> "-"
      l -> Enum.join(l, "; ")
    end
  end

  defp speedup(%{"speedup" => nil}), do: "-"
  defp speedup(%{"speedup" => s}), do: "#{s}x"
  defp speedup(_), do: "-"

  defp cell(nil), do: "-"
  defp cell(x), do: to_string(x)
  defp num(x), do: cell(x)

  defp pad(v, n), do: String.pad_trailing(to_string(v), n)

  defp secs(s), do: :erlang.float_to_binary(s * 1.0, decimals: 1)

  defp label(:ok), do: "ok"
  defp label(:incorrect), do: "INCORRECT"
  defp label(:unexpected_verdict), do: "UNEXPECTED VERDICT"
  defp label(:crashed), do: "FAILED"
  defp label(:timeout), do: "TIMEOUT"
end
