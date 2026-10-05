defmodule Defk.Bench do
  @moduledoc """
  Uniform measurement and reporting for `examples/*.exs`.

  The point of the examples is not to show that defk beats Elixir. It is to
  find the use cases where defk helps Elixir, and to say plainly where it
  doesn't. Elixir is the default: when an Elixir solution is as good or as
  fast, it is the right choice.

  Every example calls `report/1` once. It checks that the Elixir and defk
  implementations agree, times both, prints a short table, and ends with one
  machine-readable line that `examples/run_all.exs` collects:

      DEFK_RESULT {"example":"rolling_stats","expected":"good","verdict":"good",...}

  The verdict comes from the measurement, not from the example's author, and
  it is a recommendation:

    * `good`         - defk is at least #{2}x faster than the best Elixir
                       version we found: defk helps here
    * `marginal`     - between 1x and 2x: use Elixir, the gain does not pay
                       for native code
    * `poor`         - defk is slower: use Elixir
    * `out_of_scope` - defk cannot express the use case at all: use Elixir

  A `good` verdict only counts once the Elixir side is `baseline: :optimized`.
  Until then the runner shows it as provisional.

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
    * `:baseline` - `:first_pass` (default) or `:optimized`. Use `:optimized`
      only after a real attempt to make the Elixir version as fast as it can
      be (stdlib, Erlang BIFs, established libraries, better data layout);
      say what was tried in the example's header.
    * `:runs` - timed repetitions per side, best one wins (default 5)
  """
  def report(opts) do
    name = Keyword.fetch!(opts, :name)
    expected = Keyword.fetch!(opts, :expected)
    baseline = Keyword.get(opts, :baseline, :first_pass)
    baseline in [:first_pass, :optimized] || raise ArgumentError, "baseline must be :first_pass or :optimized"
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

    result =
      Map.merge(result, %{
        example: name,
        expected: expected,
        baseline: baseline,
        reason: Keyword.get(opts, :reason)
      })
    print(result)
    result
  end

  defp verdict(s) when s >= @good, do: :good
  defp verdict(s) when s >= 1.0, do: :marginal
  defp verdict(_), do: :poor

  # A full GC before each run, so garbage left by the previous run is not
  # billed to the next one. Large inputs shared across requests should live
  # where a real app keeps them (:persistent_term, ETS), not on this process's
  # heap: a major GC copying them lands on whichever side is being timed.
  defp best(fun, runs) do
    fun.()

    Enum.map(1..runs, fn _ ->
      :erlang.garbage_collect()
      elem(:timer.tc(fun), 0)
    end)
    |> Enum.min()
  end

  defp ms(us), do: Float.round(us / 1000, 3)

  defp print(r) do
    IO.puts("")
    IO.puts("  elixir     #{r.elixir_ms} ms")
    if r.defk_ms, do: IO.puts("  defk       #{r.defk_ms} ms   (#{r.speedup}x)")
    IO.puts("  correct    #{r.correct}")
    IO.puts("  baseline   #{r.baseline}#{if r.verdict == :good and r.baseline != :optimized, do: "   (claim is provisional until the Elixir side is optimised)", else: ""}")
    IO.puts("  verdict    #{r.verdict}#{if r.verdict != r.expected, do: "   (expected #{r.expected}!)", else: ""}")
    if r.reason, do: IO.puts("  why        #{r.reason}")
    IO.puts("\nDEFK_RESULT " <> JSON.encode!(r))
  end
end
