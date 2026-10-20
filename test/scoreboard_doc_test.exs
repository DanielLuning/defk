defmodule Defk.ScoreboardDocTest do
  # The catalog's result tables (examples/README.md's scoreboard, README.md's
  # summary) are rendered from examples/scoreboard.json and the text in
  # examples/_tables.exs by `mix defk.docs`, whose `--check` fails on a table
  # that differs from the stored scoreboard. The renderer's rules are tested
  # on a small made-up scoreboard.
  use ExUnit.Case, async: true

  alias Defk.Examples.{Snapshot, Tables}

  describe "the README tables" do
    test "every placeholder names a report or an example that exists" do
      scripts = Path.wildcard("examples/*.exs") -- ["examples/_tables.exs"]
      examples = Enum.map(scripts, &Path.basename(&1, ".exs"))

      reports =
        for s <- scripts,
            [_, n] <- Regex.scan(~r/^\s*name: "([a-z0-9_]+)"/m, File.read!(s)),
            do: n

      text = Tables.text()

      texts =
        Enum.flat_map(Map.values(text.examples), &Map.values/1) ++
          Enum.map(text.summary, & &1.text)

      named = for t <- texts, [_, n] <- Regex.scan(~r/\{[a-z_]+:([a-z0-9_]+)\}/, t), do: n
      assert Enum.uniq(named) -- (reports ++ examples) == []
      assert Map.keys(text.examples) -- examples == []

      grouped = for %{examples: names} <- text.summary, n <- names, do: n
      assert grouped -- examples == []
    end
  end

  describe "rendering" do
    defp report(name, verdict, speedup, extra \\ %{}) do
      Map.merge(%{"example" => name, "verdict" => verdict, "speedup" => speedup}, extra)
    end

    @run %{
      "measured_at" => "2026-10-20T08:00:00Z",
      "commit" => "abc1234",
      "command" => "mix defk.examples --bench --all --snapshot --fresh",
      "otp" => "29.0.3",
      "elixir" => "1.20.2",
      "quiet_limit" => 1.0
    }

    # `quiet` is every row's; a `{name, results, own}` row has its own run
    # fields, and its own quiet when `own` has "quiet"
    defp snapshot(examples, quiet \\ true) do
      %{
        "version" => 3,
        "machine" => "Test CPU",
        "logical_cores" => 12,
        "examples" =>
          for e <- examples do
            {name, results, own} =
              case e do
                {name, results} -> {name, results, %{}}
                {_, _, _} -> e
              end

            %{
              "name" => name,
              "results" => results,
              "quiet" => Map.get(own, "quiet", quiet),
              "run" => Map.merge(@run, Map.delete(own, "quiet"))
            }
          end
      }
    end

    @text %{
      examples: %{
        "fast" => %{
          job: "a fast job",
          native: "{native} the NIF",
          line: "also {speedup:fast_big} big"
        },
        "slow" => %{job: "a slow job", line: "crossover {crossover}"},
        "meh" => %{job: "a so-so job", line: "use Elixir"}
      },
      apps: [%{name: "app", verdict: "good", job: "an app", value: "its own", line: "see it"}],
      summary: [
        %{text: "fast and meh", examples: ["meh"]},
        %{text: "the fast one, {native:fast} the NIF", examples: ["fast"]},
        %{text: "the app", app: "app", value: "its own"}
      ]
    }

    defp good do
      [
        report("fast", "good", 209.4, %{"native_speedup" => 3.14}),
        report("fast_big", "good", 7.26)
      ]
    end

    test "the scoreboard: verdict then speedup order, apps after their verdict, formats" do
      s =
        snapshot([
          {"meh", [report("meh", "marginal", 1.04)]},
          {"slow", [report("slow", "poor", 0.084, %{"crossover" => nil})]},
          {"fast", good()}
        ])

      assert {:ok, %{"scoreboard" => board}} = Tables.render(s, @text)

      assert board ==
               """
               Measured on 2026-10-20 at commit `abc1234` on Test CPU (12 logical cores), OTP 29.0.3, Elixir 1.20.2: `mix defk.examples --bench --all --snapshot --fresh`. A quiet measurement: other processes used at most 1.0 cores before and after it.

               | | Example | The job | defk vs best Elixir | vs the package's NIF | In one line |
               |---|---|---|---|---|---|
               | ✅ | [`fast`](fast.exs) | a fast job | **209×** | 3.1× the NIF | also 7.3× big |
               | ✅ | [`app/`](app) | an app | its own | – | see it |
               | 🟡 | [`meh`](meh.exs) | a so-so job | 1.0× | – | use Elixir |
               | ❌ | [`slow`](slow.exs) | a slow job | 0.08× | – | crossover none |
               """
    end

    test "the summary: groups in their order, a range over a group, placeholders" do
      s =
        snapshot([
          {"meh", [report("meh", "marginal", 1.04)]},
          {"slow", [report("slow", "poor", 0.5, %{"crossover" => "1 KiB"})]},
          {"fast", good()}
        ])

      text = Map.update!(@text, :summary, &[%{text: "two", examples: ["meh", "meh"]} | &1])
      assert {:ok, %{"summary" => summary}} = Tables.render(s, text)
      assert summary =~ "measured end to end on Test CPU on 2026-10-20"

      assert summary =~
               "| 🟡 | two | 1.0× |\n| 🟡 | fast and meh | 1.0× |\n| ✅ | the fast one, 3.1× the NIF | 209× |\n| ✅ | the app | its own |\n"
    end

    test "a range spans the group's first reports" do
      s =
        snapshot([
          {"meh", [report("meh", "good", 8.6)]},
          {"slow", [report("slow", "good", 11.2, %{"crossover" => nil})]},
          {"fast", good()}
        ])

      text = %{@text | summary: [%{text: "all", examples: ["meh", "slow", "fast"]}]}
      assert {:ok, %{"summary" => summary}} = Tables.render(s, text)
      assert summary =~ "| ✅ | all | 8.6–209× |"
    end

    test "rows not measured quietly are provisional, and a reused row says when it was measured" do
      reused =
        report("meh", "marginal", 1.04, %{
          "cache" => "reused",
          "measured_at" => "2026-10-01T00:00:00Z"
        })

      s =
        snapshot(
          [
            {"meh", [reused]},
            {"slow", [report("slow", "poor", 0.5, %{"crossover" => nil})]},
            {"fast", good()}
          ],
          false
        )

      assert {:ok, %{"scoreboard" => board}} = Tables.render(s, @text)
      assert board =~ "**No row was measured quietly: every number is provisional.**"
      assert board =~ "[`meh`](meh.exs) (measured 2026-10-01) |"
      assert board =~ "[`slow`](slow.exs) |"
    end

    test "rows from several runs: the span, the newest run, and each older row's stamp" do
      older = %{
        "measured_at" => "2026-10-02T09:00:00Z",
        "commit" => "0ld0001",
        "quiet" => false
      }

      stamped =
        report("meh", "marginal", 1.04, %{
          "stamp" => %{"measured_at" => "2026-10-02T08:59:00Z", "commit" => "0ld0001"}
        })

      reused =
        report("slow", "poor", 0.5, %{
          "crossover" => nil,
          "cache" => "reused",
          "measured_at" => "2026-10-05T00:00:00Z",
          "stamp" => %{"measured_at" => "2026-10-05T00:00:00Z", "commit" => "c0ffee1"}
        })

      s = snapshot([{"meh", [stamped], older}, {"slow", [reused]}, {"fast", good()}])
      assert {:ok, %{"scoreboard" => board, "summary" => summary}} = Tables.render(s, @text)

      assert board =~
               "Measured on Test CPU (12 logical cores) in 2 runs, from 2026-10-02 to 2026-10-20. " <>
                 "The newest at commit `abc1234`, OTP 29.0.3"

      assert board =~ "**A row not measured quietly says provisional.**"
      assert board =~ "[`meh`](meh.exs) (measured 2026-10-02 at `0ld0001`, provisional) |"
      assert board =~ "[`slow`](slow.exs) (measured 2026-10-05 at `c0ffee1`) |"
      assert board =~ "[`fast`](fast.exs) |"
      assert summary =~ "on Test CPU from 2026-10-02 to 2026-10-20 (one machine"
    end

    test "every problem is listed, not just the first" do
      s =
        snapshot([
          {"meh", [report("meh", "marginal", 1.04)]},
          {"slow", [report("slow", "poor", 0.5)]},
          {"fast", [report("fast", "good", 209.4)]},
          {"extra", [report("extra", "good", 3.0)]}
        ])

      text = %{
        @text
        | summary: [
            %{text: "mixed", examples: ["meh", "fast"]},
            %{text: "gone", examples: ["nope"]}
          ]
      }

      assert {:error, problems} = Tables.render(s, text)

      assert Enum.sort(problems) ==
               Enum.sort([
                 "extra: measured, but examples/_tables.exs has no text for it",
                 ~s("{native} the NIF": {native} but report fast recorded no native_speedup),
                 ~s("also {speedup:fast_big} big": {speedup:fast_big} names no report),
                 ~s("crossover {crossover}": {crossover} but report slow has no sweep),
                 "summary: meh, fast have different verdicts (marginal, good)",
                 "summary: nope is not in the scoreboard"
               ])
    end

    test "a region's put and get replace only the block between the markers" do
      doc = "intro\n<!-- t:start -->\nold\n<!-- t:end -->\nafter\n"
      assert {:ok, new} = Defk.Docs.put(doc, "t", "new\n")
      assert new == "intro\n<!-- t:start -->\nnew\n<!-- t:end -->\nafter\n"
      assert Defk.Docs.get(new, "t") == {:ok, "new\n"}
      assert {:error, _} = Defk.Docs.put("no markers", "t", "x")
      assert Defk.Docs.put("whole", :file, "new") == {:ok, "new"}
    end
  end

  describe "the stored file" do
    @tag :tmp_dir
    test "round-trips, one example per line", %{tmp_dir: dir} do
      outcome = %{name: "fast", status: :ok, results: [%{"example" => "fast", "speedup" => 2.5}]}
      s = Snapshot.build([outcome], "mix defk.examples --bench --all --snapshot")
      file = Path.join(dir, "scoreboard.json")
      Snapshot.write(s, file)

      assert {:ok, ^s} = Snapshot.read(file)

      assert File.read!(file) =~
               ~s(\n    {"name":"fast","quiet":false,"results":[{"example":"fast","speedup":2.5}],"run":{)

      assert [%{"run" => run}] = s["examples"]
      assert run["quiet_limit"] == Defk.Bench.quiet_limit()
      assert run["commit"] == Defk.Examples.commit()
    end

    test "a row is quiet when every report passed the quiet test" do
      quiet = fn q -> %{"stamp" => %{"quiet" => %{"quiet" => q}}} end
      assert Snapshot.quiet?([quiet.(true), quiet.(true)])
      refute Snapshot.quiet?([quiet.(true), quiet.(false)])
      # measured directly, without the runner's quiet test
      refute Snapshot.quiet?([%{"stamp" => %{"quiet" => nil}}])
    end

    test "stale compares each row's stamps with the current C" do
      stamp = fn at, c -> %{"stamp" => %{"measured_at" => at, "commit" => "abc", "c" => c}} end

      s = %{
        "examples" => [
          %{"name" => "same", "results" => [stamp.("2026-10-01T00:00:00Z", %{"S.K" => "1"})]},
          %{
            "name" => "moved",
            "results" => [
              stamp.("2026-10-01T00:00:00Z", %{"M.K" => "1", "M.Gone" => "2"}),
              stamp.("2026-10-03T00:00:00Z", %{"M.K" => "1"})
            ]
          },
          %{"name" => "old", "results" => [%{"speedup" => 1.0}]},
          %{"name" => "not_asked", "results" => [stamp.("2026-10-01T00:00:00Z", %{})]}
        ]
      }

      digests = %{
        "same" => %{"S.K" => "1"},
        "moved" => %{"M.K" => "9", "M.New" => "3"},
        "old" => %{}
      }

      assert Snapshot.stale(s, digests) == [
               %{
                 name: "same",
                 status: :current,
                 changed: [],
                 measured_at: "2026-10-01T00:00:00Z",
                 commit: "abc"
               },
               %{
                 name: "moved",
                 status: :stale,
                 changed: ["M.Gone", "M.K", "M.New"],
                 measured_at: "2026-10-03T00:00:00Z",
                 commit: "abc"
               },
               %{name: "old", status: :unstamped}
             ]
    end

    test "merge replaces the measured rows and keeps the others" do
      row = fn name, speedup, at ->
        %{
          "name" => name,
          "results" => [%{"speedup" => speedup}],
          "run" => %{"measured_at" => at}
        }
      end

      file = fn rows ->
        %{"version" => 3, "machine" => "M", "logical_cores" => 12, "examples" => rows}
      end

      old = file.([row.("a", 1.0, "old"), row.("b", 2.0, "old")])
      new = file.([row.("b", 3.0, "new"), row.("c", 4.0, "new")])

      assert {:ok, merged} = Snapshot.merge(old, new)

      assert merged["examples"] == [
               row.("a", 1.0, "old"),
               row.("b", 3.0, "new"),
               row.("c", 4.0, "new")
             ]

      assert {:error, reason} = Snapshot.merge(old, %{new | "machine" => "Other"})
      assert reason =~ "measured on M (12 logical cores), this run on Other"
    end
  end

  describe "mix defk.examples options" do
    alias Mix.Tasks.Defk.Examples, as: Task

    test "a timed run names what it measures; --snapshot stores all or those rows" do
      assert Task.validate([]) == :ok
      assert Task.validate(bench: true, only: "fft") == :ok
      assert Task.validate(bench: true, all: true, snapshot: true) == :ok
      assert Task.validate(bench: true, only: "fft", snapshot: true) == :ok
      assert {:error, "--bench measures only what you name" <> _} = Task.validate(bench: true)
      assert {:error, "--snapshot needs --bench"} = Task.validate(snapshot: true, all: true)
      assert {:error, "--fresh needs --bench"} = Task.validate(fresh: true)
      assert Task.validate(stale: true, only: "fft") == :ok

      assert {:error, "--stale only reports" <> _} =
               Task.validate(stale: true, bench: true, all: true)

      assert {:error, "--snapshot with --all replaces" <> _} =
               Task.validate(bench: true, all: true, only: "fft", snapshot: true)
    end
  end
end
