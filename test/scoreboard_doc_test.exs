defmodule Defk.ScoreboardDocTest do
  # The catalog's result tables (examples/README.md's scoreboard, README.md's
  # summary) are rendered from examples/scoreboard.json and the text in
  # examples/_tables.exs by `mix defk.examples.tables`; a table that differs
  # from the stored scoreboard fails here. The renderer's rules are tested on
  # a small made-up scoreboard.
  use ExUnit.Case, async: true

  alias Defk.Examples.{Snapshot, Tables}

  describe "the README tables" do
    test "match the stored scoreboard, or neither exists yet" do
      case Snapshot.read() do
        {:ok, snapshot} ->
          {:ok, blocks} = Tables.render(snapshot, Tables.text())

          for {file, marker} <- Tables.targets() do
            assert {:ok, block} = Tables.get(File.read!(file), marker),
                   "#{file} has no #{marker} markers"

            assert block == blocks[marker],
                   "#{file}'s #{marker} table is out of date: run mix defk.examples.tables"
          end

        {:error, _} ->
          # before the first stored run the tables are hand-written; a marker
          # without a scoreboard would be a table nothing can check
          for {file, marker} <- Tables.targets() do
            assert Tables.get(File.read!(file), marker) == :error,
                   "#{file} has #{marker} markers but #{Snapshot.path()} is missing"
          end
      end
    end

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

    defp snapshot(examples, extra \\ %{}) do
      Map.merge(
        %{
          "measured_at" => "2026-10-20T08:00:00Z",
          "commit" => "abc1234",
          "command" => "mix defk.examples --bench --all --snapshot --fresh",
          "machine" => "Test CPU",
          "logical_cores" => 12,
          "otp" => "29.0.3",
          "elixir" => "1.20.2",
          "load_before" => 1.5,
          "load_after" => 2.0,
          "quiet" => true,
          "examples" =>
            for({name, results} <- examples, do: %{"name" => name, "results" => results})
        },
        extra
      )
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
               Measured on 2026-10-20 at commit `abc1234` on Test CPU (12 logical cores), OTP 29.0.3, Elixir 1.20.2: `mix defk.examples --bench --all --snapshot --fresh`; 1-minute load average 1.5 before the run and 2.0 after.

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

    test "a loaded run says its numbers are provisional, and a reused row says when it was measured" do
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
          %{"quiet" => false}
        )

      assert {:ok, %{"scoreboard" => board}} = Tables.render(s, @text)
      assert board =~ "**Not a quiet machine: every number is provisional.**"
      assert board =~ "[`meh`](meh.exs) (reused, measured 2026-10-01)"
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

    test "put and get replace only the block between the markers" do
      doc = "intro\n<!-- t:start -->\nold\n<!-- t:end -->\nafter\n"
      assert {:ok, new} = Tables.put(doc, "t", "new\n")
      assert new == "intro\n<!-- t:start -->\nnew\n<!-- t:end -->\nafter\n"
      assert Tables.get(new, "t") == {:ok, "new\n"}
      assert {:error, _} = Tables.put("no markers", "t", "x")
    end
  end

  describe "the stored file" do
    @tag :tmp_dir
    test "round-trips, one example per line", %{tmp_dir: dir} do
      outcome = %{name: "fast", status: :ok, results: [%{"example" => "fast", "speedup" => 2.5}]}
      s = Snapshot.build([outcome], {1.0, 1.5}, "mix defk.examples --bench --all --snapshot")
      file = Path.join(dir, "scoreboard.json")
      Snapshot.write(s, file)

      assert {:ok, ^s} = Snapshot.read(file)

      assert File.read!(file) =~
               ~s(\n    {"name":"fast","results":[{"example":"fast","speedup":2.5}],"status":"ok"}\n)

      assert s["quiet"] == 1.5 <= Defk.Bench.Cache.quiet_limit()
    end
  end
end
