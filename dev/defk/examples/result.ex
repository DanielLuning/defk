defmodule Defk.Examples.Result do
  @moduledoc false
  # One report of an example: what one `DEFK_RESULT` line of
  # `Defk.Bench.report/1` (or its check-only form) says, decoded once. The
  # runner, the scoreboard, the stored scoreboard and the README tables read
  # a report through this record and its questions, never by key. The
  # line's JSON map is kept in `raw`: the stored scoreboard holds the lines
  # as the harness wrote them (Defk.Examples.Snapshot).

  defstruct raw: %{},
            example: nil,
            expected: nil,
            verdict: nil,
            baseline: nil,
            correct: nil,
            reason: nil,
            check_only: false,
            speedup: nil,
            elixir_ms: nil,
            defk_ms: nil,
            native_ms: nil,
            native_label: nil,
            native_speedup: nil,
            realistic_size: nil,
            crossover: :unmeasured,
            gaps: [],
            cache: nil,
            measured_at: nil,
            stamp: nil

  @type t :: %__MODULE__{}

  @fields ~w(example expected verdict baseline correct reason speedup elixir_ms defk_ms
             native_ms native_label native_speedup realistic_size cache measured_at stamp)

  @doc "The record of one decoded `DEFK_RESULT` line (a map with string keys)."
  def decode(%__MODULE__{} = r), do: r

  def decode(map) when is_map(map) do
    fields = for k <- @fields, Map.has_key?(map, k), do: {String.to_existing_atom(k), map[k]}

    struct(
      __MODULE__,
      fields ++
        [
          raw: map,
          check_only: map["check_only"] == true,
          crossover: if(Map.has_key?(map, "crossover"), do: map["crossover"], else: :unmeasured),
          gaps: gaps(map)
        ]
    )
  end

  @doc "The stand-in for an example that crashed before its first line."
  def crashed(name),
    do: %__MODULE__{example: name, expected: "?", verdict: "crashed", correct: false}

  # the tick gaps a report measured, `{side, max, p99}` for each side it has
  defp gaps(map) do
    for {k, side} <- [
          {"elixir_gap_ms", "elixir"},
          {"defk_gap_ms", "defk"},
          {"native_gap_ms", "native"}
        ],
        %{"max" => m, "p99" => p} <- [map[k]],
        do: {side, m, p}
  end

  @doc "The agreement check passed, or the example skipped it with a reason."
  def correct?(%__MODULE__{correct: c}), do: c in [true, "skipped"]

  def skipped?(%__MODULE__{correct: c}), do: c == "skipped"

  @doc "The report's result came from the cache, not from a measurement."
  def reused?(%__MODULE__{cache: c}), do: c == "reused"

  @doc "The report was measured but not stored: the machine was not quiet."
  def unstored?(%__MODULE__{cache: c}), do: c == "not_stored"

  @doc "The report's stamp says the machine was quiet before and after it."
  def quiet?(%__MODULE__{stamp: stamp}) when is_map(stamp),
    do: get_in(stamp, ["quiet", "quiet"]) == true

  def quiet?(%__MODULE__{}), do: false

  @doc "A `good` verdict over a baseline not yet optimised: the claim is provisional."
  def provisional?(%__MODULE__{verdict: "good", baseline: b}), do: b != "optimized"
  def provisional?(%__MODULE__{}), do: false

  @doc "The report ran a size sweep (its crossover may still be none, `nil`)."
  def crossover?(%__MODULE__{crossover: c}), do: c != :unmeasured

  @doc "The day the report was measured, or `?`."
  def measured_on(%__MODULE__{measured_at: at}) when is_binary(at), do: String.slice(at, 0, 10)
  def measured_on(%__MODULE__{}), do: "?"

  @doc "Verdicts in the order the tables list them: `good` first, an unknown one last."
  def rank(%__MODULE__{verdict: v}), do: rank(v)
  def rank("good"), do: 0
  def rank("marginal"), do: 1
  def rank("poor"), do: 2
  def rank("out_of_scope"), do: 3
  def rank(_other), do: 4

  @doc "The verdict's mark in a table."
  def mark(%__MODULE__{verdict: v}), do: mark(v)
  def mark("good"), do: "✅"
  def mark("marginal"), do: "🟡"
  def mark("poor"), do: "❌"
  def mark("out_of_scope"), do: "⛔"
  def mark(other), do: "#{other || "?"}"

  @doc "The verdict in words."
  def label(%__MODULE__{verdict: v}), do: label(v)
  def label("out_of_scope"), do: "out of scope"
  def label(other), do: "#{other || "?"}"
end
