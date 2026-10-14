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

  **Check-only (default).** Every example runs in its own `elixir` process
  with `DEFK_CHECK_ONLY=1`, so `Defk.Bench.report/1` compiles the kernels and
  runs the example's `:check` (defk against Elixir) and does nothing else: no
  timing, no verdict. The answer does not depend on how loaded the machine is.
  Then the fuzzy_search app's tests run
  (`cd examples/fuzzy_search && mix deps.get && mix test`; they need
  `/usr/share/dict/words`, and a missing word list is reported as a failure).

  **`--bench`** is the old `examples/run_all.exs`: examples run one at a time
  with their timings, the measured verdict must be the one each example
  claims, and a scoreboard is printed (`--snapshot` adds the markdown table
  for docs/verdict.md). Timings under load are meaningless: run it on a quiet
  machine.

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
    * `--bench` - timed run with the verdict check
    * `--fresh` - with `--bench`, measure every example, reuse nothing
    * `--snapshot` - with `--bench`, also print the markdown table (a reused
      row is marked with the date it was measured)
    * `--timeout SECONDS` - kill an example (or the app's tests) that runs longer;
      the default is no limit
  """

  use Mix.Task

  alias Defk.Examples
  alias Defk.Examples.Scoreboard

  @switches [
    only: :string,
    all: :boolean,
    list: :boolean,
    bench: :boolean,
    snapshot: :boolean,
    fresh: :boolean,
    timeout: :integer
  ]

  @impl Mix.Task
  def run(args) do
    {opts, rest} = OptionParser.parse!(args, strict: @switches)
    rest == [] || Mix.raise("unexpected arguments: #{Enum.join(rest, " ")}")
    opts[:snapshot] && !opts[:bench] && Mix.raise("--snapshot needs --bench")
    opts[:fresh] && !opts[:bench] && Mix.raise("--fresh needs --bench")

    only = opts[:only] && String.split(opts[:only], ",", trim: true)

    case Examples.select(only, opts[:all] || false) do
      {:ok, selection} -> go(selection, opts)
      {:error, message} -> Mix.raise(message)
    end
  end

  defp go({examples, app?}, opts) do
    if opts[:list] do
      list(examples, app?)
    else
      execute(examples, app?, opts)
    end
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
