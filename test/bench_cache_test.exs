defmodule Defk.BenchCacheTest do
  # The --bench result cache (Defk.Bench.Cache), in-process:
  # each "run" is a fresh process, like one example script under
  # mix defk.examples, with the runner's environment variables set by hand.
  # Examples.Kernels (test/support) is a loaded kernel module, so the key's
  # kernel part is not empty. A changed defk_runtime.h is the key's build
  # part (Defk.Build.cache_key/1, tested in build_test.exs); here a changed
  # stored part stands in for it.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO
  import Defk.TestKit, only: [restore_env_on_exit: 1]

  alias Defk.Bench.Cache

  @vars ~w(DEFK_BENCH_CACHE_DIR DEFK_BENCH_SCRIPT DEFK_BENCH_FRESH DEFK_BENCH_QUIET_LOAD DEFK_CHECK_ONLY)

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    restore_env_on_exit(@vars)
    Enum.each(@vars, &System.delete_env/1)

    script = Path.join(dir, "ex.exs")
    File.write!(script, "# baseline v1\n")
    System.put_env("DEFK_BENCH_CACHE_DIR", Path.join(dir, "cache"))
    System.put_env("DEFK_BENCH_SCRIPT", script)
    # quiet whatever the machine's load; the loaded case sets its own
    System.put_env("DEFK_BENCH_QUIET_LOAD", "1.0e9")
    %{script: script, cache: Path.join(dir, "cache/ex.term")}
  end

  # One example process: its reports, what it printed, and how many times
  # the Elixir side ran (zero means nothing was measured).
  defp run(opts_list) do
    timed = :counters.new(1, [])

    elixir = fn -> :counters.add(timed, 1, 1) end
    reports = fn -> Enum.map(opts_list, &Defk.Bench.report(Keyword.put(&1, :elixir, elixir))) end

    out =
      capture_io(fn ->
        send(self(), {:results, reports |> Task.async() |> Task.await(:infinity)})
      end)

    assert_received {:results, results}
    json = for [_, j] <- Regex.scan(~r/^DEFK_RESULT (.*)$/m, out), do: JSON.decode!(j)
    %{results: results, json: json, out: out, timed: :counters.get(timed, 1)}
  end

  defp opts(check \\ fn -> true end),
    do: [name: "t", expected: :poor, defk: fn -> :ok end, check: check, runs: 1]

  test "nothing changed: reused, not measured, and it says so; the check still runs" do
    first = run([opts()])
    assert first.timed > 0
    assert [%{"cache" => "stored"}] = first.json
    assert first.out =~ "cache      measured; stored"

    checks = :counters.new(1, [])
    again = run([opts(fn -> :counters.add(checks, 1, 1) == :ok end)])
    assert again.timed == 0
    assert :counters.get(checks, 1) == 1
    assert [%{"cache" => "reused", "measured_at" => at, "correct" => true}] = again.json
    assert {:ok, _, _} = DateTime.from_iso8601(at)
    assert again.out =~ "REUSED, NOT MEASURED"

    # the returned map is the stored one (atoms, not JSON strings)
    [r] = again.results
    assert r.verdict == hd(first.results).verdict
    assert r.cache == "reused"
  end

  test "a measured result carries its stamp, and a reused one keeps it" do
    restore_env_on_exit(["DEFK_BENCH_COMMIT"])
    System.put_env("DEFK_BENCH_COMMIT", "abc1234")
    first = run([opts()])
    assert [%{"stamp" => stamp}] = first.json
    assert %{"commit" => "abc1234", "defk" => vsn, "measured_at" => at, "c" => c} = stamp
    assert vsn == to_string(Application.spec(:defk, :vsn))
    assert {:ok, _, _} = DateTime.from_iso8601(at)

    assert c["Examples.Kernels"] ==
             Base.encode16(:erlang.md5(Examples.Kernels.__defk_c_source__()), case: :lower)

    System.put_env("DEFK_BENCH_COMMIT", "def5678")
    again = run([opts()])
    assert [%{"cache" => "reused", "stamp" => ^stamp}] = again.json
  end

  test "a reused result whose check now fails is reported as incorrect" do
    run([opts()])
    again = run([opts(fn -> false end)])
    assert [%{"cache" => "reused", "correct" => false}] = again.json
  end

  test "a changed script (the Elixir baseline) is measured again", %{script: script} do
    run([opts()])
    File.write!(script, "# baseline v2\n")
    again = run([opts()])
    assert again.timed > 0
    assert [%{"cache" => "stored"}] = again.json
    assert again.out =~ "changed: sources"
  end

  test "any other changed key part (the build inputs) is measured again", %{cache: cache} do
    run([opts()])

    entries =
      Cache.read(cache)
      |> Map.update!("t", fn e -> %{e | key: "old", parts: %{e.parts | build: "old"}} end)

    File.write!(cache, :erlang.term_to_binary(%{version: 2, entries: entries}))
    again = run([opts()])
    assert again.timed > 0
    assert again.out =~ "changed: build"
  end

  test "a loaded run is not stored, so the next one measures again", %{cache: cache} do
    System.put_env("DEFK_BENCH_QUIET_LOAD", "-1")
    first = run([opts()])
    assert [%{"cache" => "not_stored"}] = first.json
    assert first.out =~ "not stored: not a quiet machine"
    refute File.exists?(cache)

    System.put_env("DEFK_BENCH_QUIET_LOAD", "1.0e9")
    assert run([opts()]).timed > 0
  end

  test "--fresh measures a stored report and stores it again" do
    run([opts()])
    System.put_env("DEFK_BENCH_FRESH", "1")
    again = run([opts()])
    assert again.timed > 0
    assert [%{"cache" => "stored"}] = again.json
  end

  test "two reports of one name in a script are cached apart", %{cache: cache} do
    run([opts(), opts()])
    assert cache |> Cache.read() |> Map.keys() |> Enum.sort() == ["t", "t#2"]
    assert run([opts(), opts()]).timed == 0
  end

  test "off without the runner's variables: always measured, no cache field" do
    System.delete_env("DEFK_BENCH_CACHE_DIR")
    run([opts()])
    again = run([opts()])
    assert again.timed > 0
    refute Map.has_key?(hd(again.json), "cache")
  end

  test "the key covers the loaded kernel modules" do
    # loaded by an earlier test in most orders only
    Code.ensure_loaded!(Examples.Kernels)
    parts = Cache.key_parts("t", "t", __ENV__.file)
    assert Map.has_key?(parts.kernels, Examples.Kernels)
    assert parts.build == Defk.Build.cache_key("")
  end

  test "an unreadable cache file is empty", %{cache: cache} do
    File.mkdir_p!(Path.dirname(cache))
    File.write!(cache, "not a term")
    assert Cache.read(cache) == %{}
  end
end
