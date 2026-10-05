# Throughput cost of yielding: yielding vs yield: false kernel on one
# scheduler, interleaved so machine noise hits both alike.
# `mix run bench/yield_cost.exs [rounds]`
alias Examples.Kernels, as: K
:erlang.system_flag(:schedulers_online, 1)
rounds = String.to_integer(List.first(System.argv()) || "15")
t = fn f -> elem(:timer.tc(fn -> Task.await(Task.async(f), :infinity) end), 0) end
y0 = K.__defk_stats__().yields

pairs =
  for _ <- 1..rounds do
    {t.(fn -> K.count_primes(2_000_000) end), t.(fn -> K.count_primes_noyield(2_000_000) end)}
  end

y = div(K.__defk_stats__().yields - y0, rounds)
med = fn l -> Enum.at(Enum.sort(l), div(length(l), 2)) end
ratio = med.(Enum.map(pairs, fn {a, b} -> a / b end))
tn = med.(Enum.map(pairs, &elem(&1, 1)))
IO.puts("yields/run #{y}  noyield median #{div(tn, 1000)} ms  yielding/noyield median #{Float.round(100 * (ratio - 1), 2)}%  => #{Float.round((ratio - 1) * tn / max(y, 1), 2)} us/yield")
