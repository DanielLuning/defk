# Cost of yielding: `search/4` vs its `yield: false` twin, interleaved query by
# query so machine noise hits both alike: `NO_SERVER=1 mix run bench/yield_cost.exs [rounds] [schedulers]`
alias FuzzySearch.{Catalog, Kernels}

[rounds, scheds] =
  case System.argv() do
    [r, s] -> [String.to_integer(r), String.to_integer(s)]
    [r] -> [String.to_integer(r), System.schedulers_online()]
    [] -> [5, System.schedulers_online()]
  end

:erlang.system_flag(:schedulers_online, scheds)
%{blob: blob, offsets: offs} = Catalog.get()
:rand.seed(:exsss, {1, 2, 3})
words = Catalog.get().words
qs = for _ <- 1..20, do: elem(words, :rand.uniform(tuple_size(words)) - 1) <> "x"
t = fn f -> elem(:timer.tc(fn -> Task.await(Task.async(f), :infinity) end), 0) end
y0 = Kernels.__defk_stats__().yields

pairs =
  for _ <- 1..rounds, q <- qs do
    {t.(fn -> Kernels.search(q, blob, offs, 10) end), t.(fn -> Kernels.search_blocking(q, blob, offs, 10) end)}
  end

y = (Kernels.__defk_stats__().yields - y0) / length(pairs)
med = fn l -> Enum.at(Enum.sort(l), div(length(l), 2)) end
ratio = med.(Enum.map(pairs, fn {a, b} -> a / b end))
tb = med.(Enum.map(pairs, &elem(&1, 1)))
ty = med.(Enum.map(pairs, &elem(&1, 0)))

IO.puts("#{scheds} sched: yielding #{Float.round(ty / 1000, 2)} ms  blocking #{Float.round(tb / 1000, 2)} ms  yields/query #{Float.round(y, 1)}  median ratio +#{Float.round(100 * (ratio - 1), 2)}%")
