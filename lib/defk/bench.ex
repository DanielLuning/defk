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

  Target workloads report four more things beside the verdict, none of which
  changes it (see the `:native`, `:responsiveness`, `:realistic_size` and
  `:sweep` options of `report/1`).
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
    * `:native` - the anchor package's NIF, as `{fun, label}` or
      `[fun: fun, label: label]` (e.g. `"picosat_elixir 0.2.3"`). Timed like
      the other sides; the JSON gets `native_ms`, `native_label` and
      `native_speedup` (defk against the NIF; above 1 means defk is faster).
      The verdict stays defk against Elixir.
    * `:responsiveness` - `true` to measure, per side, the max and p99 gap of
      a 1 ms ticker on one scheduler while that side runs once
      (`Defk.Bench.TickGap`). The sides' own funs are used; pass
      `[elixir: fun, defk: fun, native: fun]` to run other funs instead (e.g.
      the same job at a larger size). The JSON gets `elixir_gap_ms`,
      `defk_gap_ms` and `native_gap_ms` (when present), each `{"max": ms,
      "p99": ms}`. `schedulers_online` is restored afterwards.
    * `:realistic_size` - a label or number: the size the anchor package is
      really called with, which the verdict is measured at. Printed and
      recorded as `realistic_size`.
    * `:sweep` - a list of `{size_label, elixir_fun, defk_fun}`, or
      `{sizes, fun}` where `fun.(size)` returns `{elixir_fun, defk_fun}`. Each
      pair is timed best-of `:sweep_runs` (default 3). The JSON gets `sweep`
      (per size: `size`, `elixir_ms`, `defk_ms`, `speedup`) and `crossover`:
      the first size where defk is at least #{2}x faster, or `nil`. Never
      changes the verdict.
  """
  def report(opts) do
    name = Keyword.fetch!(opts, :name)
    expected = Keyword.fetch!(opts, :expected)
    baseline = Keyword.get(opts, :baseline, :first_pass)

    baseline in [:first_pass, :optimized] ||
      raise ArgumentError, "baseline must be :first_pass or :optimized"

    runs = Keyword.get(opts, :runs, 5)
    elixir_us = best(Keyword.fetch!(opts, :elixir), runs)

    result =
      case Keyword.fetch(opts, :defk) do
        {:ok, defk} ->
          correct = Keyword.get(opts, :check, fn -> true end).()
          defk_us = best(defk, runs)
          Map.put(compare(elixir_us, defk_us), :correct, correct)

        :error ->
          %{
            correct: true,
            elixir_ms: ms(elixir_us),
            defk_ms: nil,
            speedup: nil,
            verdict: :out_of_scope
          }
      end

    result =
      Map.merge(result, %{
        example: name,
        expected: expected,
        baseline: baseline,
        reason: Keyword.get(opts, :reason)
      })

    result =
      result
      |> add_native(Keyword.get(opts, :native), runs)
      |> add_realistic_size(Keyword.get(opts, :realistic_size))
      |> add_sweep(Keyword.get(opts, :sweep), Keyword.get(opts, :sweep_runs, 3))
      |> add_responsiveness(Keyword.get(opts, :responsiveness), opts)

    print(result)
    result
  end

  @doc """
  The pure arithmetic behind a report, over measured times in microseconds:
  `%{elixir_ms, defk_ms, speedup, verdict}`. The verdict uses the unrounded
  speedup.
  """
  def compare(elixir_us, defk_us) do
    speedup = elixir_us / max(defk_us, 1)

    %{
      elixir_ms: ms(elixir_us),
      defk_ms: ms(defk_us),
      speedup: Float.round(speedup, 2),
      verdict: verdict(speedup)
    }
  end

  @doc "Defk's speedup over the native side, from times in ms (above 1: defk is faster)."
  def native_speedup(native_ms, defk_ms), do: Float.round(native_ms / max(defk_ms, 0.001), 2)

  @doc "One sweep row from times in ms."
  def sweep_row(size, elixir_ms, defk_ms) do
    %{
      size: size,
      elixir_ms: elixir_ms,
      defk_ms: defk_ms,
      speedup: native_speedup(elixir_ms, defk_ms)
    }
  end

  @doc "The verdict for a speedup of defk over the Elixir baseline."
  def verdict(s) when s >= @good, do: :good
  def verdict(s) when s >= 1.0, do: :marginal
  def verdict(_), do: :poor

  @doc """
  The first size label in `rows` (maps with `:size` and `:speedup`, in sweep
  order) where defk is at least #{2}x faster, or `nil`.
  """
  def crossover(rows) do
    Enum.find_value(rows, fn %{size: size, speedup: s} -> if s >= @good, do: size end)
  end

  defp add_native(result, nil, _runs), do: result

  defp add_native(result, native, runs) do
    {fun, label} = native_parts(native)
    native_us = best(fun, runs)
    native_ms = ms(native_us)

    native_speedup = if result.defk_ms, do: native_speedup(native_ms, result.defk_ms)

    Map.merge(result, %{
      native_ms: native_ms,
      native_label: label,
      native_speedup: native_speedup
    })
  end

  defp native_parts({fun, label}) when is_function(fun, 0), do: {fun, to_string(label)}

  defp native_parts(opts) when is_list(opts),
    do: {Keyword.fetch!(opts, :fun), to_string(Keyword.fetch!(opts, :label))}

  defp add_realistic_size(result, nil), do: result
  defp add_realistic_size(result, size), do: Map.put(result, :realistic_size, size)

  defp add_sweep(result, nil, _runs), do: result

  defp add_sweep(result, sweep, runs) do
    rows =
      sweep
      |> sweep_pairs()
      |> Enum.map(fn {size, elixir, defk} ->
        e = ms(best(elixir, runs))
        d = ms(best(defk, runs))
        sweep_row(size, e, d)
      end)

    Map.merge(result, %{sweep: rows, crossover: crossover(rows)})
  end

  defp sweep_pairs({sizes, fun}) when is_function(fun, 1) do
    for size <- sizes do
      {e, d} = fun.(size)
      {size, e, d}
    end
  end

  defp sweep_pairs(list) when is_list(list), do: list

  defp add_responsiveness(result, falsy, _opts) when falsy in [nil, false], do: result

  defp add_responsiveness(result, spec, opts) do
    over = if is_list(spec), do: spec, else: []

    fun = fn side ->
      Keyword.get(over, side) ||
        case side do
          :native -> opts |> Keyword.get(:native) |> then(&(&1 && elem_fun(&1)))
          _ -> Keyword.get(opts, side)
        end
    end

    gaps =
      for side <- [:elixir, :defk, :native], f = fun.(side), into: %{} do
        g = Defk.Bench.TickGap.run(f)
        {:"#{side}_gap_ms", %{max: g.max, p99: g.p99}}
      end

    Map.merge(result, gaps)
  end

  defp elem_fun(native), do: native |> native_parts() |> elem(0)

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
    if r[:native_ms], do: IO.puts(native_line(r))
    IO.puts("  correct    #{r.correct}")
    if r[:realistic_size], do: IO.puts("  realistic  #{r.realistic_size}")

    IO.puts(
      "  baseline   #{r.baseline}#{if r.verdict == :good and r.baseline != :optimized, do: "   (claim is provisional until the Elixir side is optimised)", else: ""}"
    )

    IO.puts(
      "  verdict    #{r.verdict}#{if r.verdict != r.expected, do: "   (expected #{r.expected}!)", else: ""}"
    )

    if r.reason, do: IO.puts("  why        #{r.reason}")
    print_gaps(r)
    print_sweep(r)
    IO.puts("\nDEFK_RESULT " <> JSON.encode!(r))
  end

  defp native_line(r) do
    vs = if r.native_speedup, do: "   (defk #{r.native_speedup}x vs native)", else: ""
    "  native     #{r.native_ms} ms   [#{r.native_label}]#{vs}"
  end

  defp print_gaps(r) do
    for side <- [:elixir, :defk, :native], g = r[:"#{side}_gap_ms"] do
      IO.puts("  gap #{String.pad_trailing(to_string(side), 7)}max #{g.max} ms, p99 #{g.p99} ms")
    end
  end

  defp print_sweep(%{sweep: rows} = r) do
    IO.puts("  sweep      size        elixir ms   defk ms   speedup")

    for row <- rows do
      IO.puts(
        "             #{String.pad_trailing(to_string(row.size), 11)} " <>
          "#{String.pad_trailing(to_string(row.elixir_ms), 11)} " <>
          "#{String.pad_trailing(to_string(row.defk_ms), 9)} #{row.speedup}x"
      )
    end

    IO.puts("  crossover  #{r.crossover || "none"}")
  end

  defp print_sweep(_), do: :ok
end
