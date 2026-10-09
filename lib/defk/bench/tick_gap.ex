defmodule Defk.Bench.TickGap do
  @moduledoc """
  Responsiveness measurement shared by `Defk.Bench.report/1` and
  `bench/tick_gap.exs`.

  A ticker process wakes every 1 ms and records the time since its previous
  tick. While a function runs once in another process, on ONE scheduler,
  the gaps show how long the scheduler was held away from the ticker: a plain
  Elixir loop is preempted by reductions, a yielding kernel by its yield
  budget, a native call that does not yield blocks the ticker for its whole
  run.
  """

  @doc """
  Runs `fun` once in another process while a 1 ms ticker runs. Returns
  `{runtime_us, gaps_us}`. The caller is responsible for the scheduler count
  (see `with_one_scheduler/1`).
  """
  def measure(fun) do
    parent = self()
    ticker = spawn(fn -> tick(System.monotonic_time(:microsecond), [], parent) end)
    {us, _} = :timer.tc(fn -> Task.await(Task.async(fun), :infinity) end)
    send(ticker, :stop)

    receive do
      {:gaps, gaps} -> {us, gaps}
    end
  end

  defp tick(last, gaps, parent) do
    receive do
      :stop ->
        send(parent, {:gaps, [System.monotonic_time(:microsecond) - last | gaps]})
    after
      1 ->
        now = System.monotonic_time(:microsecond)
        tick(now, [now - last | gaps], parent)
    end
  end

  @doc "Runs `fun` with `:schedulers_online` set to 1 and restores the old value."
  def with_one_scheduler(fun) do
    online = :erlang.system_info(:schedulers_online)
    :erlang.system_flag(:schedulers_online, 1)

    try do
      fun.()
    after
      :erlang.system_flag(:schedulers_online, online)
    end
  end

  @doc """
  Max and p99 tick gap in ms over `runs` runs of `fun` (default 1), on one
  scheduler: `%{max: ms, p99: ms, runtime_ms: ms}` (runtime of the fastest run).
  """
  def run(fun, runs \\ 1) do
    with_one_scheduler(fn ->
      res = for _ <- 1..runs, do: measure(fun)
      gaps = Enum.flat_map(res, &elem(&1, 1))
      us = res |> Enum.map(&elem(&1, 0)) |> Enum.min()
      summary(gaps) |> Map.put(:runtime_ms, to_ms(us))
    end)
  end

  @doc "`%{max: ms, p99: ms}` of a list of gaps in microseconds."
  def summary([]), do: %{max: 0.0, p99: 0.0}
  def summary(gaps), do: %{max: to_ms(Enum.max(gaps)), p99: to_ms(percentile(gaps, 0.99))}

  @doc "The `p` quantile (0..1) of a non-empty list, by rank."
  def percentile(list, p) do
    n = length(list)
    list |> Enum.sort() |> Enum.drop(min(n - 1, trunc(p * n))) |> hd()
  end

  defp to_ms(us), do: Float.round(us / 1000, 3)
end
