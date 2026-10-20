defmodule Defk.Examples.Scoreboard do
  @moduledoc false
  # The `--bench` scoreboard: what `examples/run_all.exs` printed, over the
  # first report (Defk.Examples.Result) of each example. Also the check-only
  # summary.

  alias Defk.Examples.Result

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
        pad(r.example, 26) <>
          pad(r.expected, 14) <>
          pad(r.verdict, 14) <>
          pad(speedup(r), 10) <>
          pad(num(r.elixir_ms), 11) <>
          pad(num(r.defk_ms), 10) <>
          pad(r.baseline || "?", 12) <> if(o.status == :ok, do: "yes", else: "NO")
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

  # every report's cache outcome (Defk.Bench.Cache), not only
  # the first report's
  defp print_cache(outcomes) do
    reports = for o <- outcomes, r <- o.results, do: r
    reused = Enum.filter(reports, &Result.reused?/1)
    unstored = Enum.filter(reports, &Result.unstored?/1)

    if reused != [] do
      IO.puts(
        "#{length(reused)} report(s) reused a cached result (inputs unchanged; --fresh measures them): " <>
          Enum.map_join(reused, ", ", &"#{&1.example} (#{Result.measured_on(&1)})")
      )
    end

    if unstored != [] do
      IO.puts(
        "#{length(unstored)} report(s) not cached, the machine was not quiet: " <>
          Enum.map_join(unstored, ", ", & &1.example)
      )
    end
  end

  # the first report, or a stand-in for an example that crashed
  defp row(%{results: [first | _], status: status}) when status != :crashed, do: first
  defp row(%{name: name}), do: Result.crashed(name)

  defp print_provisional(results) do
    provisional = Enum.filter(results, &Result.provisional?/1)

    if provisional != [] do
      IO.puts(
        "#{length(provisional)} 'good' claim(s) are provisional: the Elixir baseline is not optimised yet " <>
          "(#{Enum.map_join(provisional, ", ", & &1.example)})"
      )
    end
  end

  defp print_skipped(outcomes) do
    skipped = for o <- outcomes, r <- o.results, Result.skipped?(r), do: r

    if skipped != [] do
      IO.puts(
        "#{length(skipped)} check(s) skipped by their examples:\n" <>
          Enum.map_join(skipped, "\n", &"  #{&1.example}: #{&1.reason}")
      )
    end
  end

  # second line per example, only for what a script reports
  defp extra_line(r) do
    parts =
      Enum.filter(
        [
          r.realistic_size && "realistic size #{r.realistic_size}",
          r.native_speedup &&
            "vs #{r.native_label}: defk #{r.native_speedup}x (native #{r.native_ms} ms)",
          r.native_ms && is_nil(r.native_speedup) &&
            "native #{r.native_ms} ms [#{r.native_label}]",
          gaps(r) != [] && "tick gap ms: " <> Enum.join(gaps(r), "; "),
          Result.crossover?(r) && "crossover #{r.crossover || "none"}"
        ],
        & &1
      )

    if parts == [], do: "", else: "    " <> Enum.join(parts, " | ")
  end

  defp gaps(r), do: for({side, m, p} <- r.gaps, do: "#{side} max #{m} / p99 #{p}")

  # The markdown table for the scoreboard pages (examples/README.md,
  # docs/verdict.md): the verdict mark first, rows sorted by verdict and
  # then by speedup, so the good, marginal and poor results read off at a
  # glance.
  defp print_snapshot(results) do
    IO.puts(
      "\n| | Example | Realistic size | Speedup | Elixir ms | defk ms | vs native | " <>
        "Tick gap ms, max / p99 | Crossover |\n|---|---|---|---|---|---|---|---|---|"
    )

    for r <- Enum.sort_by(results, &{Result.rank(&1), -(&1.speedup || 0)}) do
      cells = [
        verdict_mark(r),
        if(Result.reused?(r),
          do: "#{r.example} (reused, measured #{Result.measured_on(r)})",
          else: r.example
        ),
        cell(r.realistic_size),
        speedup(r),
        cell(r.elixir_ms),
        cell(r.defk_ms),
        native_cell(r),
        gap_cell(r),
        if(Result.crossover?(r), do: r.crossover || "none", else: "-")
      ]

      IO.puts("| " <> Enum.join(cells, " | ") <> " |")
    end
  end

  # a known verdict with its mark; another word as it is
  defp verdict_mark(r),
    do: if(Result.rank(r) < 4, do: "#{Result.mark(r)} #{Result.label(r)}", else: Result.label(r))

  defp native_cell(%Result{native_speedup: nil}), do: "-"
  defp native_cell(%Result{native_speedup: x, native_label: l}), do: "#{x}x (#{l})"

  defp gap_cell(r) do
    case gaps(r) do
      [] -> "-"
      l -> Enum.join(l, "; ")
    end
  end

  defp speedup(%Result{speedup: nil}), do: "-"
  defp speedup(%Result{speedup: s}), do: "#{s}x"

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
