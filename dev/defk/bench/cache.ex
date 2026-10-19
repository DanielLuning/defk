defmodule Defk.Bench.Cache do
  @moduledoc false
  # The benchmark result cache of `mix defk.examples --bench`: the runner's
  # adapter to `Defk.Bench`, not part of the library (ADR-0011). It lives
  # in dev/, is never packaged, and the runner loads it into each example's
  # process with `elixir -r` before the script's `Mix.install` brings defk
  # (hence no warnings about defk's modules below). `Defk.Bench.report/1`
  # asks it only when it is loaded; absent, every report measures.
  #
  # When nothing a measurement depends on changed, `Defk.Bench.report/1`
  # reuses the stored result instead of timing again. It still runs the
  # example's `:check`: correctness is never cached.
  #
  # Off unless the runner turns it on, so `elixir examples/x.exs` always
  # measures. The runner sets, per example process:
  #
  #   DEFK_BENCH_CACHE_DIR  where the result files go (one per example script)
  #   DEFK_BENCH_SCRIPT     the example script, whose contents are in the key
  #   DEFK_BENCH_FRESH=1    measure every report, but still store the quiet ones
  #
  # The key of one report (all of it must match to reuse a result):
  #
  #   * kernels: every loaded defk kernel module's `.beam` MD5. That covers
  #     the C source (compiled in as `__defk_c_source__/0`) and the generated
  #     Elixir wrappers, which are part of the timing.
  #   * build: `Defk.Build.cache_key("")`, the library inputs other than the C
  #     source (cflags, defk_runtime.h, cc and its version, ERTS, sanitizer).
  #   * sources: the MD5 of the script and of every file it required
  #     (`Code.required_files/0`; cdcl_sat_per_call.exs requires cdcl_sat.exs):
  #     the Elixir baseline and the inputs.
  #   * deps: the MD5 of the `Mix.install` project's mix.lock (the competing
  #     library's version).
  #   * bench: this module's, `Defk.Bench`'s and `Defk.Bench.TickGap`'s MD5;
  #     the OTP and Elixir versions.
  #   * machine: architecture, CPU model, logical cores, schedulers online.
  #   * report: the report's name, and how many reports of that name the
  #     process made before it (a script may reuse a name).
  #
  # Only quiet-machine results are stored: the CPU that other processes use
  # (`Defk.Bench.other_cpu/0`) before and after the measurement must be at
  # most `Defk.Bench.quiet_limit/0`. A loaded run is never stored, so the
  # next run measures again. Not the load average: it counts the bench's
  # own work (the example's cc compile, the report before, the measured
  # threads) and lags it by a minute or more, so a sequential run could
  # never be quiet.

  @compile {:no_warn_undefined, [Defk.Bench, Defk.Build]}

  # 3: the stamp records the quiet test (Defk.Bench); an older file is read
  # as empty
  @version 3

  @type slot :: %{
          file: String.t(),
          id: String.t(),
          parts: map(),
          key: binary(),
          fresh?: boolean()
        }

  @doc """
  Looks up a report. `:off` when the runner did not turn the cache on;
  `{:hit, result, entry}` with the stored result map and its entry; else
  `{:miss, slot, changed}`, where `changed` names the key parts that differ
  from the stored entry (`[]` when there is none, or for `--fresh`).
  """
  @spec lookup(String.t()) :: :off | {:hit, map(), map()} | {:miss, slot(), [atom()]}
  def lookup(name) do
    case {System.get_env("DEFK_BENCH_CACHE_DIR"), System.get_env("DEFK_BENCH_SCRIPT")} do
      {dir, script} when dir in [nil, ""] or script in [nil, ""] ->
        :off

      {dir, script} ->
        id = report_id(name)
        parts = key_parts(name, id, script)
        slot = %{file: file(dir, script), id: id, parts: parts, key: key(parts), fresh?: fresh?()}
        find(slot)
    end
  end

  defp find(%{fresh?: true} = slot), do: {:miss, slot, []}

  defp find(slot) do
    case Map.fetch(read(slot.file), slot.id) do
      {:ok, %{key: key, result: result} = entry} when key == slot.key -> {:hit, result, entry}
      {:ok, %{parts: old}} -> {:miss, slot, changed(old, slot.parts)}
      _ -> {:miss, slot, []}
    end
  end

  defp changed(old, new), do: for({k, v} <- new, Map.get(old, k) != v, do: k)

  @doc """
  Stores `result` under `slot` when `cpus`, the other processes' CPU
  `{before, after}` the measurement, passes `Defk.Bench.quiet?/1`. Returns
  `:stored` or `:not_stored`.
  """
  @spec store(slot(), map(), {float() | nil, float() | nil}) :: :stored | :not_stored
  def store(slot, result, cpus) do
    if Defk.Bench.quiet?(cpus) do
      entry = %{
        key: slot.key,
        parts: slot.parts,
        result: result,
        measured_at: DateTime.utc_now() |> DateTime.truncate(:second),
        cpus: cpus
      }

      File.mkdir_p!(Path.dirname(slot.file))
      entries = Map.put(read(slot.file), slot.id, entry)
      bin = :erlang.term_to_binary(%{version: @version, entries: entries})
      # write then rename, so an interrupted run never leaves half a file
      tmp = slot.file <> ".tmp"
      File.write!(tmp, bin)
      File.rename!(tmp, slot.file)
      :stored
    else
      :not_stored
    end
  end

  @doc false
  # The parsed cache file's entries; a missing, unreadable or other-version
  # file is empty (its results are measured again and the file replaced).
  def read(file) do
    with {:ok, bin} <- File.read(file),
         %{version: @version, entries: entries} <- safe_decode(bin) do
      entries
    else
      _ -> %{}
    end
  end

  defp safe_decode(bin) do
    :erlang.binary_to_term(bin, [:safe])
  rescue
    ArgumentError -> nil
  end

  defp file(dir, script), do: Path.join(dir, Path.basename(script, ".exs") <> ".term")

  defp fresh?, do: System.get_env("DEFK_BENCH_FRESH") in ["1", "true"]

  # "name" for the first report of that name in this process, "name#2" for
  # the second, and so on
  defp report_id(name) do
    n = Process.get({__MODULE__, name}, 0) + 1
    Process.put({__MODULE__, name}, n)
    if n == 1, do: name, else: "#{name}##{n}"
  end

  defp key(parts), do: :erlang.md5(:erlang.term_to_binary(parts, [:deterministic]))

  @doc false
  def key_parts(name, id, script) do
    %{
      kernels: kernels(),
      build: Defk.Build.cache_key(""),
      sources: sources(script),
      deps: deps(),
      bench: {md5(Defk.Bench), md5(Defk.Bench.TickGap), md5(__MODULE__)},
      versions: {otp_version(), System.version()},
      machine: machine(),
      report: {name, id}
    }
  end

  defp kernels do
    for {mod, _} <- :code.all_loaded(),
        function_exported?(mod, :__defk_c_source__, 0),
        do: {mod, md5(mod)},
        into: %{}
  end

  defp md5(mod), do: Base.encode16(mod.module_info(:md5), case: :lower)

  defp sources(script) do
    for path <- Enum.uniq([Path.expand(script) | Code.required_files()]),
        into: %{},
        do: {Path.basename(path), file_md5(path)}
  end

  defp file_md5(path) do
    case File.read(path) do
      {:ok, bin} -> Base.encode16(:erlang.md5(bin), case: :lower)
      {:error, reason} -> {:error, reason}
    end
  end

  defp deps do
    if Mix.installed?() do
      file_md5(Path.join(Mix.install_project_dir(), "mix.lock"))
    else
      :none
    end
  end

  defp otp_version do
    path =
      Path.join([:code.root_dir(), "releases", :erlang.system_info(:otp_release), "OTP_VERSION"])

    case File.read(path) do
      {:ok, v} -> String.trim(v)
      _ -> to_string(:erlang.system_info(:otp_release))
    end
  end

  defp machine do
    {to_string(:erlang.system_info(:system_architecture)), cpu_model(),
     :erlang.system_info(:logical_processors), :erlang.system_info(:schedulers_online)}
  end

  @doc false
  # also names the machine in the examples' stored scoreboard
  def cpu_model do
    case :os.type() do
      {:unix, :darwin} ->
        case System.cmd("sysctl", ["-n", "machdep.cpu.brand_string"], stderr_to_stdout: true) do
          {out, 0} -> String.trim(out)
          _ -> "unknown"
        end

      _ ->
        with {:ok, info} <- File.read("/proc/cpuinfo"),
             [_, model] <- Regex.run(~r/^(?:model name|Model|CPU part)\s*:\s*(.+)$/m, info) do
          String.trim(model)
        else
          _ -> "unknown"
        end
    end
  rescue
    _ -> "unknown"
  end
end
