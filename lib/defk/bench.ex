defmodule Defk.Bench do
  @moduledoc """
  Uniform measurement and reporting for `examples/*.exs`.

  Every example calls `report/1` once. It checks that the Elixir and defk
  implementations agree, times both, prints a short table, and ends with one
  machine-readable line that `examples/run_all.exs` collects:

      DEFK_RESULT {"example":"rolling_stats","expected":"good","verdict":"good",...}

  The verdict comes from the measurement, not from the example's author:

    * `good`         - defk is at least #{2}x faster end to end
    * `marginal`     - between 1x and 2x
    * `poor`         - defk is slower
    * `out_of_scope` - defk cannot express the use case at all

  An example also states the verdict it `expected`; the runner flags any
  example whose measured verdict differs from its claim.
  """

  @good 2.0

  @doc """
  Options:

    * `:name` (required) - example name, e.g. `"rolling_stats"`
    * `:expected` (required) - `:good`, `:marginal`, `:poor` or `:out_of_scope`
    * `:elixir` (required) - zero-arity fun running the pure Elixir version
    * `:defk` - zero-arity fun running the defk version, end to end
      (include any conversion the caller would really pay for)
    * `:check` - zero-arity fun returning true when both versions agree
    * `:reason` - one sentence explaining the outcome (required for `:out_of_scope`)
    * `:runs` - timed repetitions per side, best one wins (default 5)
  """
  def report(opts) do
    name = Keyword.fetch!(opts, :name)
    expected = Keyword.fetch!(opts, :expected)
    runs = Keyword.get(opts, :runs, 5)
    elixir_us = best(Keyword.fetch!(opts, :elixir), runs)

    result =
      case Keyword.fetch(opts, :defk) do
        {:ok, defk} ->
          correct = Keyword.get(opts, :check, fn -> true end).()
          defk_us = best(defk, runs)
          speedup = elixir_us / max(defk_us, 1)

          %{
            correct: correct,
            elixir_ms: ms(elixir_us),
            defk_ms: ms(defk_us),
            speedup: Float.round(speedup, 2),
            verdict: verdict(speedup)
          }

        :error ->
          %{correct: true, elixir_ms: ms(elixir_us), defk_ms: nil, speedup: nil, verdict: :out_of_scope}
      end

    result = Map.merge(result, %{example: name, expected: expected, reason: Keyword.get(opts, :reason)})
    print(result)
    result
  end

  defp verdict(s) when s >= @good, do: :good
  defp verdict(s) when s >= 1.0, do: :marginal
  defp verdict(_), do: :poor

  defp best(fun, runs) do
    fun.()
    Enum.map(1..runs, fn _ -> elem(:timer.tc(fun), 0) end) |> Enum.min()
  end

  defp ms(us), do: Float.round(us / 1000, 3)

  defp print(r) do
    IO.puts("")
    IO.puts("  elixir     #{r.elixir_ms} ms")
    if r.defk_ms, do: IO.puts("  defk       #{r.defk_ms} ms   (#{r.speedup}x)")
    IO.puts("  correct    #{r.correct}")
    IO.puts("  verdict    #{r.verdict}#{if r.verdict != r.expected, do: "   (expected #{r.expected}!)", else: ""}")
    if r.reason, do: IO.puts("  why        #{r.reason}")
    IO.puts("\nDEFK_RESULT " <> JSON.encode!(r))
  end
end
