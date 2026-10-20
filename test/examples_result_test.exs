defmodule Defk.ExamplesResultTest do
  # One report of an example as the runner reads it (Defk.Examples.Result):
  # decoded once from its DEFK_RESULT line, then asked, never indexed by key.
  use ExUnit.Case, async: true

  alias Defk.Examples.Result

  @line %{
    "example" => "crc16",
    "expected" => "good",
    "verdict" => "good",
    "baseline" => "first_pass",
    "correct" => true,
    "speedup" => 12.5,
    "elixir_ms" => 10.0,
    "defk_ms" => 0.8,
    "cache" => "reused",
    "measured_at" => "2026-10-19T20:00:00Z",
    "stamp" => %{"quiet" => %{"quiet" => true}},
    "defk_gap_ms" => %{"max" => 1.5, "p99" => 0.2}
  }

  test "decode keeps the line and answers its questions" do
    r = Result.decode(@line)
    assert r.raw == @line
    assert r.example == "crc16" and r.speedup == 12.5
    assert Result.correct?(r)
    refute Result.skipped?(r)
    assert Result.reused?(r)
    refute Result.unstored?(r)
    assert Result.quiet?(r)
    assert Result.provisional?(r)
    assert Result.measured_on(r) == "2026-10-19"
    assert r.gaps == [{"defk", 1.5, 0.2}]
    assert Result.decode(r) == r
  end

  test "a crossover is unmeasured, none, or a size" do
    refute Result.crossover?(Result.decode(@line))
    assert %{crossover: nil} = r = Result.decode(Map.put(@line, "crossover", nil))
    assert Result.crossover?(r)
    assert Result.decode(Map.put(@line, "crossover", 4096)).crossover == 4096
  end

  test "a skipped check is correct; a failed one is not; an unquiet or unstamped report is not quiet" do
    assert Result.skipped?(Result.decode(%{"correct" => "skipped"}))
    assert Result.correct?(Result.decode(%{"correct" => "skipped"}))
    refute Result.correct?(Result.decode(%{"correct" => false}))
    refute Result.quiet?(Result.decode(%{"stamp" => %{"quiet" => %{"quiet" => false}}}))
    refute Result.quiet?(Result.decode(%{}))
    refute Result.provisional?(Result.decode(%{"verdict" => "good", "baseline" => "optimized"}))
    refute Result.provisional?(Result.decode(%{"verdict" => "poor"}))
  end

  test "the verdicts rank good first and have a mark and a label" do
    verdicts = ~w(good marginal poor out_of_scope crashed)
    assert Enum.map(verdicts, &Result.rank/1) == [0, 1, 2, 3, 4]
    assert Enum.map(verdicts, &Result.mark/1) == ["✅", "🟡", "❌", "⛔", "crashed"]
    assert Result.label("out_of_scope") == "out of scope"
    assert Result.label(nil) == "?"
    assert Result.rank(Result.crashed("x")) == 4
    refute Result.correct?(Result.crashed("x"))
  end
end
