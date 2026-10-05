# Worst 1ms-ticker gap on ONE scheduler while a busy process runs:
# `mix run bench/tick_gap.exs [runs]`
alias Examples.Kernels, as: K

defmodule TickGap do
  # max gap between 1ms ticks while `fun` runs in another process
  def measure(fun) do
    parent = self()
    ticker = spawn(fn -> tick(System.monotonic_time(:microsecond), [], parent) end)
    {us, _} = :timer.tc(fn -> Task.await(Task.async(fun), :infinity) end)
    send(ticker, :stop)
    receive do: ({:gaps, g} -> {us, g})
  end

  defp tick(last, gaps, parent) do
    receive do
      :stop -> send(parent, {:gaps, gaps})
    after
      1 ->
        now = System.monotonic_time(:microsecond)
        tick(now, [now - last | gaps], parent)
    end
  end

  def ex_prime?(x), do: Enum.reduce(2..trunc(:math.sqrt(x))//1, true, &(&2 and rem(x, &1) != 0))
  def ex_count_primes(n), do: Enum.count(2..n//1, &ex_prime?/1)
end

runs = String.to_integer(List.first(System.argv()) || "5")
:erlang.system_flag(:schedulers_online, 1)

cases = [
  {"idle", fn -> Process.sleep(500) end},
  {"plain Elixir", fn -> TickGap.ex_count_primes(400_000) end},
  {"yielding kernel", fn -> K.count_primes(2_000_000) end}
]

pct = fn l, p -> Enum.at(Enum.sort(l), min(length(l) - 1, trunc(p * length(l)))) end
f = fn us -> :erlang.float_to_binary(us / 1000, decimals: 2) end

IO.puts(String.pad_trailing("case", 18) <> "runtime ms (min)  yields/run  p99 gap ms  worst gap ms per run")

for {name, fun} <- cases do
  res =
    for _ <- 1..runs do
      y0 = K.__defk_stats__().yields
      {us, gaps} = TickGap.measure(fun)
      {us, gaps, K.__defk_stats__().yields - y0}
    end

  worst = Enum.map(res, fn {_, g, _} -> Enum.max(g) end)
  all = Enum.flat_map(res, fn {_, g, _} -> g end)
  {us, _, y} = Enum.min_by(res, &elem(&1, 0))

  IO.puts(
    String.pad_trailing(name, 18) <>
      String.pad_trailing(f.(us), 18) <>
      String.pad_trailing("#{y}", 12) <> String.pad_trailing(f.(pct.(all, 0.99)), 12) <> Enum.map_join(worst, " ", f)
  )
end
