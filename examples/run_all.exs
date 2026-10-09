# Runs every example and prints the scoreboard:
#
#   elixir examples/run_all.exs
#
# Examples run one at a time (parallel runs would distort the timings).
#   elixir examples/run_all.exs --snapshot
#
# `--snapshot` also prints the collected results as a markdown table for
# docs/verdict.md's "Workload results" section.
#
# Exits 1 if any example is incorrect, crashes, or measures a verdict that
# differs from the one it claims. A `good` verdict whose Elixir baseline is
# not yet optimised is reported as provisional (it does not fail the run).

dir = __DIR__
snapshot? = "--snapshot" in System.argv()

files =
  dir
  |> File.ls!()
  |> Enum.filter(
    &(String.ends_with?(&1, ".exs") and &1 != "run_all.exs" and not String.starts_with?(&1, "_"))
  )
  |> Enum.sort()

results =
  for file <- files do
    IO.write("running #{file} ... ")
    {out, status} = System.cmd("elixir", [Path.join(dir, file)], stderr_to_stdout: true)

    case Regex.run(~r/^DEFK_RESULT (.*)$/m, out) do
      [_, json] when status == 0 ->
        r = JSON.decode!(json)
        IO.puts("done")
        r

      _ ->
        IO.puts("FAILED (exit #{status})\n" <> out)

        %{
          "example" => Path.rootname(file),
          "expected" => "?",
          "verdict" => "crashed",
          "correct" => false
        }
    end
  end

pad = fn v, n -> String.pad_trailing(to_string(v), n) end

num = fn
  nil -> "-"
  x -> to_string(x)
end

gap = fn
  nil -> nil
  %{"max" => m, "p99" => p} -> "max #{m} / p99 #{p}"
end

gaps = fn r ->
  for {k, label} <- [
        {"elixir_gap_ms", "elixir"},
        {"defk_gap_ms", "defk"},
        {"native_gap_ms", "native"}
      ],
      g = gap.(r[k]) do
    "#{label} #{g}"
  end
end

# second line per example, only for the keys a script reports
extra_lines = fn r ->
  parts =
    [
      r["realistic_size"] && "realistic size #{r["realistic_size"]}",
      r["native_speedup"] &&
        "vs #{r["native_label"]}: defk #{r["native_speedup"]}x (native #{r["native_ms"]} ms)",
      r["native_ms"] && is_nil(r["native_speedup"]) &&
        "native #{r["native_ms"]} ms [#{r["native_label"]}]",
      gaps.(r) != [] && "tick gap ms: " <> Enum.join(gaps.(r), "; "),
      Map.has_key?(r, "crossover") && "crossover #{r["crossover"] || "none"}"
    ]
    |> Enum.filter(& &1)

  if parts == [], do: "", else: "    " <> Enum.join(parts, " | ")
end

IO.puts(
  "\n" <>
    pad.("example", 26) <>
    pad.("expected", 14) <>
    pad.("measured", 14) <>
    pad.("speedup", 10) <>
    pad.("elixir ms", 11) <> pad.("defk ms", 10) <> pad.("baseline", 12) <> "ok"
)

bad =
  for r <- results, reduce: 0 do
    acc ->
      ok = r["correct"] == true and r["verdict"] == r["expected"]

      IO.puts(
        pad.(r["example"], 26) <>
          pad.(r["expected"], 14) <>
          pad.(r["verdict"], 14) <>
          pad.(if(r["speedup"], do: "#{r["speedup"]}x", else: "-"), 10) <>
          pad.(num.(r["elixir_ms"]), 11) <>
          pad.(num.(r["defk_ms"]), 10) <>
          pad.(r["baseline"] || "?", 12) <>
          if(ok, do: "yes", else: "NO")
      )

      extra = extra_lines.(r)
      if extra != "", do: IO.puts(extra)

      if ok, do: acc, else: acc + 1
  end

IO.puts("\n#{length(results) - bad}/#{length(results)} examples behave as claimed")

provisional = Enum.filter(results, &(&1["verdict"] == "good" and &1["baseline"] != "optimized"))

if provisional != [] do
  IO.puts(
    "#{length(provisional)} 'good' claim(s) are provisional: the Elixir baseline is not optimised yet " <>
      "(#{Enum.map_join(provisional, ", ", & &1["example"])})"
  )
end

if snapshot? do
  cell = fn
    nil -> "-"
    x -> to_string(x)
  end

  worst = fn r ->
    case gaps.(r) do
      [] -> "-"
      l -> Enum.join(l, "; ")
    end
  end

  IO.puts(
    "\n| Example | Realistic size | Verdict | Speedup | Elixir ms | defk ms | vs native | " <>
      "Tick gap ms, max / p99 | Crossover |\n|---|---|---|---|---|---|---|---|---|"
  )

  for r <- results do
    native =
      case r["native_speedup"] do
        nil -> "-"
        x -> "#{x}x (#{r["native_label"]})"
      end

    IO.puts(
      "| " <>
        Enum.join(
          [
            r["example"],
            cell.(r["realistic_size"]),
            r["verdict"],
            if(r["speedup"], do: "#{r["speedup"]}x", else: "-"),
            cell.(r["elixir_ms"]),
            cell.(r["defk_ms"]),
            native,
            worst.(r),
            if(Map.has_key?(r, "crossover"), do: r["crossover"] || "none", else: "-")
          ],
          " | "
        ) <> " |"
    )
  end
end

if bad > 0, do: System.halt(1)
