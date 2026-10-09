# Worst 1ms-ticker gap on ONE scheduler while a busy process runs:
# `mix run bench/tick_gap.exs [runs]`
alias Examples.Kernels, as: K

defmodule TickGap do
  def ex_prime?(x), do: Enum.reduce(2..trunc(:math.sqrt(x))//1, true, &(&2 and rem(x, &1) != 0))
  def ex_count_primes(n), do: Enum.count(2..n//1, &ex_prime?/1)
end

runs = String.to_integer(List.first(System.argv()) || "5")

cases = [
  {"idle", fn -> Process.sleep(500) end},
  {"plain Elixir", fn -> TickGap.ex_count_primes(400_000) end},
  {"yielding kernel", fn -> K.count_primes(2_000_000) end},
  # early exit (Enum.all? halts at the first divisor), n scaled to a similar runtime
  {"early-exit kernel", fn -> K.count_primes_early(6_000_000) end}
]

f = fn us -> :erlang.float_to_binary(us / 1000, decimals: 2) end

IO.puts(
  String.pad_trailing("case", 18) <>
    "runtime ms (min)  yields/run  p99 gap ms  worst gap ms per run"
)

Defk.Bench.TickGap.with_one_scheduler(fn ->
  for {name, fun} <- cases do
    res =
      for _ <- 1..runs do
        y0 = K.__defk_stats__().yields
        {us, gaps} = Defk.Bench.TickGap.measure(fun)
        {us, gaps, K.__defk_stats__().yields - y0}
      end

    worst = Enum.map(res, fn {_, g, _} -> Enum.max(g) end)
    all = Enum.flat_map(res, fn {_, g, _} -> g end)
    {us, _, y} = Enum.min_by(res, &elem(&1, 0))

    IO.puts(
      String.pad_trailing(name, 18) <>
        String.pad_trailing(f.(us), 18) <>
        String.pad_trailing("#{y}", 12) <>
        String.pad_trailing(f.(Defk.Bench.TickGap.percentile(all, 0.99)), 12) <>
        Enum.map_join(worst, " ", f)
    )
  end
end)
