# Cost per call of the candidate "is my run queue crowded?" checks (defk-04y),
# idle and with every other scheduler busy: `mix run bench/run_queue_check_cost.exs [rounds]`
# The NIF API (erl_nif.h) exposes no run-queue length, so every check is a BIF
# called from Elixir before the kernel.
rounds = String.to_integer(List.first(System.argv()) || "7")
n = 200_000

checks = [
  {"system_info(:scheduler_id)", fn -> :erlang.system_info(:scheduler_id) end},
  {"statistics(:run_queue)", fn -> :erlang.statistics(:run_queue) end},
  {"statistics(:total_run_queue_lengths)", fn -> :erlang.statistics(:total_run_queue_lengths) end},
  {"statistics(:run_queue_lengths)", fn -> :erlang.statistics(:run_queue_lengths) end},
  {"run_queue_lengths + nth(scheduler_id)",
   fn -> :lists.nth(:erlang.system_info(:scheduler_id), :erlang.statistics(:run_queue_lengths)) end},
  # a tiny yielding kernel call (count_primes(10)): its NIF with no hint,
  # the default function (total_run_queue_lengths hint), and the own-queue hint
  {"tiny kernel call, no hint", fn -> Examples.Kernels.__defk_native_count_primes__(10, 0) end},
  {"tiny call + total_run_queue_lengths", fn -> Examples.Kernels.count_primes(10) end},
  {"tiny call + own run queue",
   fn ->
     Examples.Kernels.__defk_native_count_primes__(
       10,
       :lists.nth(:erlang.system_info(:scheduler_id), :erlang.statistics(:run_queue_lengths))
     )
   end},
  {"empty loop", fn -> :ok end}
]

defmodule CheckCost do
  def loop(_f, 0), do: :ok

  def loop(f, k) do
    f.()
    loop(f, k - 1)
  end

  def ns(f, n) do
    {us, _} = :timer.tc(fn -> loop(f, n) end)
    us * 1000 / n
  end

  def spin(stop), do: if(:atomics.get(stop, 1) == 0, do: spin(stop), else: :ok)
end

med = fn l -> Enum.at(Enum.sort(l), div(length(l), 2)) end

measure = fn label ->
  # interleaved: each round runs every check once
  res =
    for _ <- 1..rounds do
      for {name, f} <- checks, do: {name, CheckCost.ns(f, n)}
    end
    |> List.flatten()
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

  empty = med.(res["empty loop"])

  for {name, _} <- checks, name != "empty loop" do
    IO.puts("#{label}  #{String.pad_trailing(name, 42)} #{Float.round(med.(res[name]) - empty, 1)} ns/call")
  end
end

IO.puts("load: #{:os.cmd(~c"uptime") |> to_string() |> String.trim()}")
measure.("idle")

stop = :atomics.new(1, [])
spinners = for _ <- 2..System.schedulers_online(), do: spawn(fn -> CheckCost.spin(stop) end)
Process.sleep(50)
measure.("busy")
:atomics.put(stop, 1, 1)
Enum.each(spinners, &Process.exit(&1, :kill))
