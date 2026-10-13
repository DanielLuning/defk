defmodule Defk.Examples do
  @moduledoc false
  # What `mix defk.examples` does (defk-30c.3): choose the examples, run each
  # in its own OS process, and judge the outcome. Dev tooling, compiled only
  # in :dev and :test (see `elixirc_paths/1` in mix.exs and the layout note in
  # `Mix.Tasks.Defk.Examples`), never part of the package.
  #
  # Two modes. :check runs every example with DEFK_CHECK_ONLY=1, where
  # `Defk.Bench.report/1` runs the example's `:check` and nothing else: no
  # timing, no verdict, so the result is reliable on a loaded machine. :bench
  # is the old `examples/run_all.exs`: timed, and the measured verdict must be
  # the one the example claims.

  @app "fuzzy_search"
  @dict "/usr/share/dict/words"
  @heartbeat_ms 30_000

  @type outcome :: %{
          name: String.t(),
          status: :ok | :incorrect | :unexpected_verdict | :crashed | :timeout,
          secs: float(),
          results: [map()],
          out: String.t(),
          err: String.t(),
          note: String.t()
        }

  @doc "The name `--only` uses for the fuzzy_search app's own tests."
  def app_name, do: @app

  def root, do: Path.dirname(Mix.Project.project_file())

  @doc "Every example script's name (the `_`-prefixed template is not one), sorted."
  def all do
    root()
    |> Path.join("examples/*.exs")
    |> Path.wildcard()
    |> Enum.map(&Path.basename(&1, ".exs"))
    |> Enum.reject(&String.starts_with?(&1, "_"))
    |> Enum.sort()
  end

  @doc "The examples `mix test` already compiles (`Defk.Catalog`)."
  def in_mix_test, do: Enum.map(Defk.Catalog.scripts(), &Atom.to_string/1)

  @doc """
  The selection: `{:ok, {examples, app?}}`. By default every example not in
  `mix test` plus the app's tests; `all?` adds the `mix test` ones; `only`
  (a list of names, `"fuzzy_search"` for the app) replaces the default.
  """
  def select(only, all?)

  def select(nil, all?) do
    examples = if all?, do: all(), else: all() -- in_mix_test()
    {:ok, {examples, true}}
  end

  def select(only, _all?) do
    case only -- [@app | all()] do
      [] -> {:ok, {Enum.filter(all(), &(&1 in only)), @app in only}}
      unknown -> {:error, "unknown example(s): #{Enum.join(unknown, ", ")} (see --list --all)"}
    end
  end

  @doc """
  Where `--bench` keeps its result cache (`Defk.Bench.Cache`, defk-30c.5):
  outside git, one file per example script.
  """
  def bench_cache_dir, do: Path.join(Mix.Project.build_path(), "defk_bench")

  @doc """
  Runs one example in its own `elixir` process. `mode` is `:check` or `:bench`;
  `timeout_s` is `nil` for none. Prints a heartbeat every 30 s of silence.
  With `:bench`, the example's reports reuse cached results unless `fresh?`.
  """
  @spec run_example(String.t(), :check | :bench, pos_integer() | nil, boolean()) :: outcome()
  def run_example(name, mode, timeout_s, fresh? \\ false) do
    file = Path.join(root(), "examples/#{name}.exs")

    err_file =
      Path.join(System.tmp_dir!(), "defk_examples_#{System.unique_integer([:positive])}.err")

    env = [{~c"ERL_CRASH_DUMP", ~c"/dev/null"} | mode_env(mode, file, fresh?)]

    # stdout and stderr stay apart: a stderr write (a Logger line, a VM
    # warning) must not land inside a DEFK_RESULT line
    {secs, ran} =
      timed(fn ->
        shell(~s(exec elixir "$0" 2>"$1"), [file, err_file], env, root(), name, timeout_s)
      end)

    err = read_and_rm(err_file)
    judge(name, mode, ran, secs, err)
  end

  # `false` unsets a variable the task's own environment may carry
  defp mode_env(:check, _file, _fresh?) do
    [
      {~c"DEFK_CHECK_ONLY", ~c"1"},
      {~c"DEFK_BENCH_CACHE_DIR", false},
      {~c"DEFK_BENCH_SCRIPT", false},
      {~c"DEFK_BENCH_FRESH", false}
    ]
  end

  defp mode_env(:bench, file, fresh?) do
    [
      {~c"DEFK_CHECK_ONLY", false},
      {~c"DEFK_BENCH_CACHE_DIR", String.to_charlist(bench_cache_dir())},
      {~c"DEFK_BENCH_SCRIPT", String.to_charlist(file)},
      {~c"DEFK_BENCH_FRESH", if(fresh?, do: ~c"1", else: false)}
    ]
  end

  @doc "Runs the fuzzy_search app's own tests (`mix deps.get && mix test` in its directory)."
  @spec run_app_tests(pos_integer() | nil) :: outcome()
  def run_app_tests(timeout_s) do
    name = @app <> " (app tests)"

    if File.exists?(@dict) do
      dir = Path.join(root(), "examples/#{@app}")
      script = ~s({ mix deps.get && mix test; } 2>&1)
      # the app has its own _build and its own env
      env = [{~c"MIX_ENV", false}, {~c"DEFK_CHECK_ONLY", false}]
      {secs, ran} = timed(fn -> shell(script, [], env, dir, name, timeout_s) end)
      judge_app(name, ran, secs)
    else
      %{
        name: name,
        status: :crashed,
        secs: 0.0,
        results: [],
        out: "",
        err: "",
        note: "#{@dict} is missing: the app's tests need a word list (install `words`)"
      }
    end
  end

  # ---- judging --------------------------------------------------------

  defp judge(name, mode, ran, secs, err) do
    base = %{name: name, secs: secs, err: err, results: [], out: ""}

    case ran do
      {:timeout, out} ->
        %{base | out: out} |> Map.merge(%{status: :timeout, note: "timed out"})

      {:exit, status, out} ->
        results = parse_results(out)
        base = %{base | out: out, results: results}
        Map.merge(base, verdict_of(mode, status, results))
    end
  end

  defp verdict_of(_mode, status, _results) when status != 0,
    do: %{status: :crashed, note: "exit #{status}"}

  defp verdict_of(_mode, _status, []), do: %{status: :crashed, note: "no DEFK_RESULT line"}

  defp verdict_of(mode, _status, [first | _] = results) do
    cond do
      Enum.any?(results, &(&1["correct"] not in [true, "skipped"])) ->
        %{status: :incorrect, note: "an agreement check returned #{inspect(wrong(results))}"}

      mode == :bench and first["verdict"] != first["expected"] ->
        %{
          status: :unexpected_verdict,
          note: "measured #{first["verdict"]}, expected #{first["expected"]}"
        }

      true ->
        %{status: :ok, note: "#{length(results)} #{noun(mode, length(results))}"}
    end
  end

  defp noun(:check, 1), do: "check"
  defp noun(:check, _), do: "checks"
  defp noun(:bench, 1), do: "report"
  defp noun(:bench, _), do: "reports"

  defp wrong(results),
    do: Enum.find(results, &(&1["correct"] not in [true, "skipped"]))["correct"]

  defp judge_app(name, ran, secs) do
    base = %{name: name, secs: secs, err: "", results: []}

    case ran do
      {:timeout, out} ->
        Map.merge(base, %{out: out, status: :timeout, note: "timed out"})

      {:exit, 0, out} ->
        Map.merge(base, %{out: out, status: :ok, note: test_counts(out)})

      {:exit, status, out} ->
        Map.merge(base, %{out: out, status: :crashed, note: "exit #{status}: #{test_counts(out)}"})
    end
  end

  defp test_counts(out) do
    case Regex.run(~r/(\d+ tests?, \d+ failures?)|Result: (.+)/, out) do
      [_, counts] -> counts
      [_, "", result] -> result
      _ -> "no ExUnit summary"
    end
  end

  @doc "Every `DEFK_RESULT` line of an example's stdout, decoded, in order."
  def parse_results(out) do
    for [_, json] <- Regex.scan(~r/^DEFK_RESULT (.*)$/m, out),
        {:ok, r} <- [JSON.decode(json)],
        do: r
  end

  # ---- running a process ----------------------------------------------

  defp timed(fun) do
    t0 = System.monotonic_time(:millisecond)
    result = fun.()
    {(System.monotonic_time(:millisecond) - t0) / 1000, result}
  end

  defp read_and_rm(file) do
    err =
      case File.read(file) do
        {:ok, e} -> e
        _ -> ""
      end

    File.rm(file)
    err
  end

  defp shell(script, argv, env, dir, label, timeout_s) do
    port =
      Port.open({:spawn_executable, System.find_executable("sh")}, [
        :binary,
        :exit_status,
        :hide,
        args: ["-c", script | argv],
        env: env,
        cd: dir
      ])

    {:os_pid, os_pid} = Port.info(port, :os_pid)
    now = System.monotonic_time(:millisecond)
    deadline = timeout_s && now + timeout_s * 1000

    collect(port, os_pid, "", %{
      label: label,
      started: now,
      deadline: deadline,
      beat: now + @heartbeat_ms
    })
  end

  defp collect(port, os_pid, acc, st) do
    now = System.monotonic_time(:millisecond)
    wait = max(0, min(st.beat, st.deadline || st.beat) - now)

    receive do
      {^port, {:data, d}} -> collect(port, os_pid, acc <> d, st)
      {^port, {:exit_status, s}} -> {:exit, s, acc}
    after
      wait ->
        cond do
          st.deadline && now >= st.deadline ->
            kill(port, os_pid)
            {:timeout, acc}

          now >= st.beat ->
            IO.puts("    ... #{st.label} still running (#{div(now - st.started, 1000)} s)")
            collect(port, os_pid, acc, %{st | beat: now + @heartbeat_ms})

          true ->
            collect(port, os_pid, acc, st)
        end
    end
  end

  # best effort: the shell's children first, then the shell
  defp kill(port, os_pid) do
    pid = Integer.to_string(os_pid)
    System.cmd("pkill", ["-KILL", "-P", pid], stderr_to_stdout: true)
    System.cmd("kill", ["-KILL", pid], stderr_to_stdout: true)

    try do
      Port.close(port)
    rescue
      ArgumentError -> :ok
    end

    flush(port)
  end

  defp flush(port) do
    receive do
      {^port, _} -> flush(port)
    after
      0 -> :ok
    end
  end
end
