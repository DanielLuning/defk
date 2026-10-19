defmodule Mix.Tasks.Defk.Examples do
  # Layout: repo-only Mix tasks live in dev/mix/tasks/ (with their
  # helpers under dev/defk/). mix.exs adds "dev" to elixirc_paths for :dev and
  # :test only, so a task that runs repo files (examples/, the fuzzy_search
  # app) is never compiled into a dependent's build, and "dev" is not among
  # the files a Hex package takes by default. `mix defk.verify`
  # goes in the same directory.
  @shortdoc "Runs every example that `mix test` does not (check-only by default)"

  @moduledoc """
  Runs the examples that `mix test` does not, plus the fuzzy_search app's own
  tests. Not part of `mix ci`.

      mix defk.examples                      # check-only, everything outside mix test
      mix defk.examples --only lz4_snappy_decode,keccak
      mix defk.examples --list
      mix defk.examples --bench --only geo_nearest   # timed, verdict checked
      mix defk.examples --bench --only geo_nearest --snapshot   # and store that row
      mix defk.examples --stale              # rows whose kernels' C changed since measured

  **Check-only (default).** Every example runs in its own `elixir` process
  with `DEFK_CHECK_ONLY=1`, so `Defk.Bench.report/1` compiles the kernels and
  runs the example's `:check` (defk against Elixir) and does nothing else: no
  timing, no verdict. The answer does not depend on how loaded the machine is.
  Then the fuzzy_search app's tests run
  (`cd examples/fuzzy_search && mix deps.get && mix test`; they need
  `/usr/share/dict/words`, and a missing word list is reported as a failure).

  **`--bench`** is the old `examples/run_all.exs`: examples run one at a time
  with their timings, the measured verdict must be the one each example
  claims, and a scoreboard is printed. Timings under load are meaningless:
  run it on a quiet machine. It measures only what you name: `--only` or
  `--all`. A stored result stands until someone asks for it to be measured
  again (docs/agents/runs.md).

  **`--snapshot`** (with `--bench`) also prints the markdown table and
  stores the run in examples/scoreboard.json: each example's `DEFK_RESULT`
  lines with their stamps (commit, defk version, time, the C's MD5), and the
  run's commit and load before and after. With `--all` it replaces the file;
  with `--only` it replaces those examples' rows and keeps the others, which
  must come from the same machine. That file is the one source of the
  catalog's numbers; `mix defk.examples.tables` rewrites the README tables
  from it. It is written only when every example behaves as claimed.

  **`--stale`** reports the rows of examples/scoreboard.json whose kernels'
  C changed since they were measured: it compiles each example's kernel
  modules in this VM without cc (`DEFK_NO_CC`; no check, no timing, nothing
  written) and compares the MD5 of each module's C with the stamps. A
  report only: it never measures. The C holds the kernels' line numbers, so
  an edit that moves a kernel's lines counts as a change. `--only` narrows
  it to those rows.

  **Result cache.** `--bench` reuses a stored result when nothing the
  measurement depends on changed: the kernel modules' `.beam` files, the C
  build inputs (cflags, `defk_runtime.h`, cc, ERTS, sanitizer mode), the
  script and the files it requires, its `Mix.install` dependencies,
  `Defk.Bench`, the OTP and Elixir versions and the machine. The example
  still runs, and its `:check` still runs (correctness is never cached);
  only the timing is skipped. Only results measured on a quiet machine are
  stored (the 1-minute load average before and after is at most a quarter of
  the logical cores, or `DEFK_BENCH_QUIET_LOAD`), so a loaded run measures
  again next time. The cache is `_build/<env>/defk_bench/`, one file per
  example; `--fresh` measures everything (and stores the quiet results).

  Some compiles are long (argon2 more than 7 minutes, cdcl_sat about 5,
  keccak about 1, hash_chain about 26 s per copy). The task prints a line
  every 30 s of silence; `--timeout` bounds each example.

  Exits non-zero if any example is incorrect, crashes, times out (or, with
  `--bench`, measures another verdict than it claims) or the app's tests fail.

  ## Options

    * `--only a,b` - run just these examples (`fuzzy_search` names the app's
      tests); any example, in `mix test` or not
    * `--all` - also the examples `mix test` covers
    * `--list` - print the selection and stop
    * `--bench` - timed run with the verdict check; needs `--only` or `--all`
    * `--fresh` - with `--bench`, measure every example, reuse nothing
    * `--snapshot` - with `--bench`, also print the markdown table (a
      reused row is marked with the date it was measured) and store the run
      in examples/scoreboard.json: all of it with `--all`, those rows with
      `--only`
    * `--stale` - list the stored rows whose kernels' C changed since they
      were measured; measures nothing
    * `--timeout SECONDS` - kill an example (or the app's tests) that runs longer;
      the default is no limit
  """

  use Mix.Task

  alias Defk.Bench.Cache
  alias Defk.Examples
  alias Defk.Examples.{Scoreboard, Snapshot}

  @switches [
    only: :string,
    all: :boolean,
    list: :boolean,
    bench: :boolean,
    snapshot: :boolean,
    fresh: :boolean,
    stale: :boolean,
    timeout: :integer
  ]

  @impl Mix.Task
  def run(args) do
    {opts, rest} = OptionParser.parse!(args, strict: @switches)
    rest == [] || Mix.raise("unexpected arguments: #{Enum.join(rest, " ")}")

    case validate(opts) do
      :ok -> :ok
      {:error, message} -> Mix.raise(message)
    end

    only = opts[:only] && String.split(opts[:only], ",", trim: true)

    case Examples.select(only, opts[:all] || false) do
      {:ok, selection} -> go(selection, opts)
      {:error, message} -> Mix.raise(message)
    end
  end

  @doc false
  # A timed run is always asked for by name: `--bench` needs `--only` (these
  # examples) or `--all` (the whole catalog), never the default selection.
  # `--snapshot --all` replaces the stored scoreboard; `--snapshot --only`
  # replaces those rows (Snapshot.merge/2).
  def validate(opts) do
    cond do
      opts[:snapshot] && !opts[:bench] ->
        {:error, "--snapshot needs --bench"}

      opts[:fresh] && !opts[:bench] ->
        {:error, "--fresh needs --bench"}

      opts[:bench] && !(opts[:only] || opts[:all]) ->
        {:error,
         "--bench measures only what you name: --only a,b for those examples, " <>
           "--all for the whole catalog"}

      opts[:snapshot] && opts[:only] && opts[:all] ->
        {:error,
         "--snapshot with --all replaces the scoreboard, with --only replaces those rows: pick one"}

      opts[:stale] && (opts[:bench] || opts[:list] || opts[:all]) ->
        {:error, "--stale only reports: it takes --only and nothing else"}

      true ->
        :ok
    end
  end

  defp go({examples, app?}, opts) do
    cond do
      opts[:list] -> list(examples, app?)
      opts[:stale] -> stale(opts[:only] && examples)
      true -> execute(examples, app?, opts)
    end
  end

  # `names` nil: every row of the stored scoreboard
  defp stale(names) do
    snapshot =
      case Snapshot.read() do
        {:ok, snapshot} -> snapshot
        {:error, reason} -> Mix.raise("--stale reads the stored scoreboard: #{reason}")
      end

    rows = Enum.map(snapshot["examples"], & &1["name"])
    names = if names, do: Enum.filter(names, &(&1 in rows)), else: rows

    IO.puts(
      "mix defk.examples --stale: #{length(names)} row(s), their kernels compiled here without cc"
    )

    report = Snapshot.stale(snapshot, Examples.c_digests(names))

    for r <- report, r.status != :current do
      case r do
        %{status: :unstamped} ->
          IO.puts("  #{r.name}  no stamp")

        %{status: :stale} ->
          IO.puts(
            "  #{r.name}  measured #{String.slice(r.measured_at, 0, 10)} at #{r.commit || "?"}; " <>
              "C changed: #{Enum.join(r.changed, ", ")}"
          )
      end
    end

    counts = Enum.frequencies_by(report, & &1.status)

    IO.puts(
      "#{counts[:stale] || 0} stale, #{counts[:current] || 0} current, " <>
        "#{counts[:unstamped] || 0} without a stamp. A report only: a row is measured again " <>
        "when someone asks (mix defk.examples --bench --only <name> --snapshot)."
    )
  end

  defp list(examples, app?) do
    in_test = Examples.in_mix_test()

    for name <- examples do
      IO.puts(if name in in_test, do: "#{name}  (also in mix test)", else: name)
    end

    if app?, do: IO.puts("#{Examples.app_name()}  (app tests)")
  end

  defp execute(examples, app?, opts) do
    mode = if opts[:bench], do: :bench, else: :check
    timeout = opts[:timeout]
    total = length(examples) + if(app?, do: 1, else: 0)
    t0 = System.monotonic_time(:second)
    opts = Keyword.put(opts, :load_before, Cache.load_average())

    IO.puts("mix defk.examples (#{mode}): #{total} to run#{load_note()}")
    if mode == :bench, do: IO.puts(cache_note(opts[:fresh]))

    outcomes =
      examples
      |> Enum.with_index(1)
      |> Enum.map(fn {name, i} ->
        announce(i, total, name)
        name |> Examples.run_example(mode, timeout, opts[:fresh] || false) |> report()
      end)

    app = if app?, do: [run_app(length(examples) + 1, total, timeout)], else: []
    summarize(mode, outcomes, app, opts, System.monotonic_time(:second) - t0)
  end

  defp run_app(i, total, timeout) do
    announce(i, total, Examples.app_name() <> " (app tests)")
    timeout |> Examples.run_app_tests() |> report()
  end

  defp announce(i, total, name), do: IO.puts("[#{i}/#{total}] #{name}")

  defp cache_note(true),
    do: "result cache: --fresh, every report is measured (quiet results are stored)"

  defp cache_note(_) do
    "result cache: ON (#{Path.relative_to_cwd(Examples.bench_cache_dir())}): " <>
      "reports whose inputs did not change are NOT re-measured; --fresh measures everything"
  end

  defp report(o) do
    IO.puts("    #{o.status} (#{o.note}, #{Float.round(o.secs, 1)} s)#{reused_note(o)}")

    unless o.status == :ok do
      IO.puts("--- stdout ---\n#{o.out}\n--- stderr ---\n#{o.err}\n--- end ---")
    end

    o
  end

  # a reused result must be visible where the example's line is read
  defp reused_note(o) do
    case Enum.count(o.results, &(&1["cache"] == "reused")) do
      0 -> ""
      n -> "  CACHED: #{n} of #{length(o.results)} report(s) reused, not measured"
    end
  end

  defp summarize(mode, outcomes, app, opts, wall) do
    all = outcomes ++ app

    if mode == :bench do
      Scoreboard.print_bench(outcomes, opts[:snapshot] || false)
      for o <- app, do: IO.puts("#{o.name}: #{o.status} (#{o.note})")
    else
      Scoreboard.print_check(all)
    end

    failed = Enum.reject(all, &(&1.status == :ok))

    IO.puts(
      "\n#{length(all) - length(failed)}/#{length(all)} passed, wall time #{wall} s#{load_note()}"
    )

    if failed != [] do
      Mix.raise(
        "failed: " <> Enum.map_join(failed, ", ", &"#{&1.name} (#{&1.status}: #{&1.note})")
      )
    end

    if opts[:snapshot], do: store_snapshot(outcomes, opts)
  end

  # every example behaved as claimed (a failure raised above)
  defp store_snapshot(outcomes, opts) do
    selection = if opts[:all], do: "--all", else: "--only #{opts[:only]}"

    command =
      "mix defk.examples --bench #{selection} --snapshot" <>
        if(opts[:fresh], do: " --fresh", else: "")

    loads = {opts[:load_before], Cache.load_average()}
    new = Snapshot.build(outcomes, loads, command)

    snapshot =
      if opts[:all] do
        new
      else
        with {:ok, old} <- Snapshot.read(),
             {:ok, merged} <- Snapshot.merge(old, new) do
          merged
        else
          {:error, reason} ->
            Mix.raise("--snapshot --only replaces rows of the stored scoreboard: #{reason}")
        end
      end

    Snapshot.write(snapshot)

    IO.puts(
      "stored #{length(new["examples"])} row(s) in #{Path.relative_to_cwd(Snapshot.path())}" <>
        if(Cache.quiet?(loads),
          do: "",
          else: " (NOT a quiet machine: the tables will say provisional)"
        ) <>
        "; run mix defk.examples.tables to rewrite the README tables"
    )
  end

  defp load_note do
    with {out, 0} <- System.cmd("uptime", [], stderr_to_stdout: true),
         [_, load] <- Regex.run(~r/load averages?: (.*)$/, String.trim(out)) do
      ", load " <> load
    else
      _ -> ""
    end
  rescue
    _ -> ""
  end
end
