# Runs every example and prints the scoreboard:
#
#   elixir examples/run_all.exs
#
# Examples run one at a time (parallel runs would distort the timings).
# Exits 1 if any example is incorrect, crashes, or measures a verdict that
# differs from the one it claims.

dir = __DIR__

files =
  dir
  |> File.ls!()
  |> Enum.filter(&(String.ends_with?(&1, ".exs") and &1 != "run_all.exs" and not String.starts_with?(&1, "_")))
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
        %{"example" => Path.rootname(file), "expected" => "?", "verdict" => "crashed", "correct" => false}
    end
  end

pad = fn v, n -> String.pad_trailing(to_string(v), n) end
num = fn nil -> "-"; x -> to_string(x) end

IO.puts("\n" <> pad.("example", 26) <> pad.("expected", 14) <> pad.("measured", 14) <> pad.("speedup", 10) <> pad.("elixir ms", 11) <> pad.("defk ms", 10) <> "ok")

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
          if(ok, do: "yes", else: "NO")
      )

      if ok, do: acc, else: acc + 1
  end

IO.puts("\n#{length(results) - bad}/#{length(results)} examples behave as claimed")
if bad > 0, do: System.halt(1)
