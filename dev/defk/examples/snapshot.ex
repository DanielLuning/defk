defmodule Defk.Examples.Snapshot do
  @moduledoc false
  # The stored scoreboard: examples/scoreboard.json, the one source of the
  # catalog's numbers. `mix defk.examples --bench --all --snapshot` writes
  # every example; `--bench --only a,b --snapshot` replaces the rows of a and
  # b and keeps the others. Each row keeps the conditions of the run that
  # measured it (`run`), and each report its stamp (Defk.Bench): a row
  # stands until someone asks for it to be measured again. A row is `quiet`
  # when every report in it passed the quiet test (its stamp's `quiet`).
  # `Defk.Examples.Tables` renders the README tables from it. The file is
  # generated: never edit it by hand, measure again.

  alias Defk.Bench.Cache

  # 3: quiet is per row, from the reports' stamps; the run keeps the limit,
  # not the load average
  @version 3

  @doc "Where the stored scoreboard lives."
  def path, do: Path.join(Defk.Examples.root(), "examples/scoreboard.json")

  @doc """
  The snapshot map for a finished bench run: `outcomes` as the examples
  runner returns them, `command` the command line that made it.
  """
  def build(outcomes, command) do
    run = %{
      "measured_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "commit" => Defk.Examples.commit(),
      "command" => command,
      "otp" => otp_version(),
      "elixir" => System.version(),
      "quiet_limit" => Defk.Bench.quiet_limit()
    }

    %{
      "version" => @version,
      "machine" => Cache.cpu_model(),
      "logical_cores" => :erlang.system_info(:logical_processors),
      "examples" =>
        for(
          o <- outcomes,
          do: %{
            "name" => o.name,
            "status" => to_string(o.status),
            "results" => o.results,
            "quiet" => quiet?(o.results),
            "run" => run
          }
        )
    }
  end

  @doc "Whether every report of a row passed the quiet test."
  def quiet?(results), do: Enum.all?(results, &(get_in(&1, ["stamp", "quiet", "quiet"]) == true))

  @doc """
  `{:ok, snapshot}`: `old` with the rows of `new` in place of its rows of
  the same name, rows sorted by name; `{:error, reason}` when the two were
  measured on different machines (one scoreboard is one machine).
  """
  def merge(old, new) do
    same =
      Map.take(old, ["machine", "logical_cores"]) == Map.take(new, ["machine", "logical_cores"])

    if same do
      rows =
        Map.merge(by_name(old), by_name(new))
        |> Enum.sort_by(&elem(&1, 0))
        |> Enum.map(&elem(&1, 1))

      {:ok, %{old | "examples" => rows}}
    else
      {:error,
       "the stored scoreboard was measured on #{old["machine"]} (#{old["logical_cores"]} logical cores), " <>
         "this run on #{new["machine"]} (#{new["logical_cores"]}): measure every example here (--all) " <>
         "to replace it"}
    end
  end

  defp by_name(snapshot), do: Map.new(snapshot["examples"], &{&1["name"], &1})

  @doc """
  Each row of `snapshot` that `digests` names (`Defk.Examples.c_digests/1`)
  against its reports' stamps, in row order: `%{name:, status: :current |
  :stale | :unstamped}`, and for a stamped row the kernel modules whose C
  differs (`changed`, sorted; a module only one side has counts) and the
  newest stamp's `measured_at` and `commit`. A report only: a stale row
  stands until someone asks for it to be measured again.
  """
  def stale(snapshot, digests) do
    for %{"name" => name, "results" => results} <- snapshot["examples"],
        Map.has_key?(digests, name) do
      stamps = Enum.map(results, & &1["stamp"])

      if stamps == [] or nil in stamps do
        %{name: name, status: :unstamped}
      else
        stamped = stamps |> Enum.map(& &1["c"]) |> Enum.reduce(%{}, &Map.merge(&2, &1))
        now = digests[name]

        changed =
          for mod <- Enum.uniq(Map.keys(stamped) ++ Map.keys(now)),
              stamped[mod] != now[mod],
              do: mod

        newest = Enum.max_by(stamps, & &1["measured_at"])

        %{
          name: name,
          status: if(changed == [], do: :current, else: :stale),
          changed: Enum.sort(changed),
          measured_at: newest["measured_at"],
          commit: newest["commit"]
        }
      end
    end
  end

  @doc "Writes the snapshot, one example per line so a diff shows which rows moved."
  def write(snapshot, file \\ path()) do
    {examples, meta} = Map.pop(snapshot, "examples")

    head =
      meta |> Enum.sort() |> Enum.map(fn {k, v} -> "  #{JSON.encode!(k)}: #{JSON.encode!(v)}" end)

    rows = Enum.map(examples, &("    " <> JSON.encode!(&1)))

    File.write!(
      file,
      "{\n" <>
        Enum.join(head, ",\n") <>
        ",\n  \"examples\": [\n" <> Enum.join(rows, ",\n") <> "\n  ]\n}\n"
    )
  end

  @doc "The stored snapshot, `{:ok, map}` or `{:error, reason}`."
  def read(file \\ path()) do
    with {:ok, bin} <- File.read(file),
         {:ok, %{"version" => @version} = snapshot} <- JSON.decode(bin) do
      {:ok, snapshot}
    else
      {:ok, %{"version" => v}} -> {:error, "#{file}: version #{inspect(v)}, expected #{@version}"}
      {:ok, _} -> {:error, "#{file}: not a scoreboard snapshot"}
      {:error, reason} -> {:error, "#{file}: #{inspect(reason)}"}
    end
  end

  defp otp_version do
    file = Path.join([:code.root_dir(), "releases", System.otp_release(), "OTP_VERSION"])

    case File.read(file) do
      {:ok, v} -> String.trim(v)
      _ -> System.otp_release()
    end
  end
end
