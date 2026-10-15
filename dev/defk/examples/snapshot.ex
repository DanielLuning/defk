defmodule Defk.Examples.Snapshot do
  @moduledoc false
  # The stored scoreboard: `mix defk.examples --bench --all --snapshot`
  # writes every example's DEFK_RESULT lines and the run's conditions to
  # examples/scoreboard.json, the one source of the catalog's numbers.
  # `Defk.Examples.Tables` renders the README tables from it. The file is
  # generated: never edit it by hand, measure again.

  alias Defk.Bench.Cache

  @version 1

  @doc "Where the stored scoreboard lives."
  def path, do: Path.join(Defk.Examples.root(), "examples/scoreboard.json")

  @doc """
  The snapshot map for a finished bench run: `outcomes` as the examples
  runner returns them, `loads` the 1-minute load average before and after
  the run, `command` the command line that made it.
  """
  def build(outcomes, loads, command) do
    {before, after_} = loads

    %{
      "version" => @version,
      "measured_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "commit" => commit(),
      "command" => command,
      "machine" => Cache.cpu_model(),
      "logical_cores" => :erlang.system_info(:logical_processors),
      "otp" => otp_version(),
      "elixir" => System.version(),
      "load_before" => before,
      "load_after" => after_,
      "quiet" => Cache.quiet?(loads),
      "examples" =>
        for(
          o <- outcomes,
          do: %{"name" => o.name, "status" => to_string(o.status), "results" => o.results}
        )
    }
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

  # the commit measured, with "-dirty" when the tree had changes
  defp commit do
    root = Defk.Examples.root()

    with {sha, 0} <-
           System.cmd("git", ["rev-parse", "--short", "HEAD"], cd: root, stderr_to_stdout: true),
         {status, 0} <-
           System.cmd("git", ["status", "--porcelain"], cd: root, stderr_to_stdout: true) do
      String.trim(sha) <> if(String.trim(status) == "", do: "", else: "-dirty")
    else
      _ -> "unknown"
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
