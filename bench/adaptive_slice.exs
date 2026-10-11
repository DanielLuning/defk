# defk-04y: a short yield slice only when the run queue is crowded.
# Treatments, interleaved in one VM (medians):
#   today     no hint: 250 us slices (what `adaptive_slice: false` compiles)
#   adaptive  hint = the caller's own run queue
#             (statistics(:run_queue_lengths), nth scheduler_id)
#   total     the default kernel function: hint = statistics(:total_run_queue_lengths);
#             crowded (hint > 0) -> 50 us slices for the call's first 1 ms
# The fixed50 (50 us for the whole call) and gap (switch to 50 us after a
# resume that waited) columns in docs/performance.md 4.9 were measured with
# the experimental API of commit c552fb1 (`git show c552fb1:bench/adaptive_slice.exs`).
# Run `ERL_FLAGS_LABEL="+swt very_low" elixir --erl "+swt very_low" -S mix run bench/adaptive_slice.exs spread`
# for the +swt very_low column.
#
#   mix run bench/adaptive_slice.exs single [rounds]   one-call cost vs yield: false
#   mix run bench/adaptive_slice.exs tick [runs]       tick gap on one scheduler
#   mix run bench/adaptive_slice.exs spread [rounds]   spread + wall time of fan-outs
alias Examples.Kernels, as: K

defmodule Slice do
  alias Examples.Kernels, as: K

  def crowded?,
    do: :lists.nth(:erlang.system_info(:scheduler_id), :erlang.statistics(:run_queue_lengths)) > 0

  def call(:today, n), do: K.__defk_native_count_primes__(n, 0)
  def call(:noyield, n), do: K.count_primes_noyield(n)

  def call(:adaptive, n),
    do: K.__defk_native_count_primes__(n, if(crowded?(), do: 1, else: 0))

  def call(:total, n), do: K.count_primes(n)

  def call(:elixir, n), do: ex_count_primes(n)

  def ex_prime?(x), do: Enum.reduce(2..trunc(:math.sqrt(x))//1, true, &(&2 and rem(x, &1) != 0))
  def ex_count_primes(n), do: Enum.count(2..n//1, &ex_prime?/1)

  def med(l), do: Enum.at(Enum.sort(l), div(length(l), 2))

  def us(f), do: elem(:timer.tc(f), 0)

  # n whose lone call takes about `target_us` (median of 31)
  def calibrate(t, target_us, lo \\ 1000, hi \\ 4_000_000) do
    if hi - lo < max(div(lo, 200), 1) do
      lo
    else
      mid = div(lo + hi, 2)
      took = med(for _ <- 1..31, do: us(fn -> call(t, mid) end))
      if took < target_us, do: calibrate(t, target_us, mid, hi), else: calibrate(t, target_us, lo, mid)
    end
  end

  def load, do: :os.cmd(~c"uptime") |> to_string() |> String.trim()
end

[mode | rest] = System.argv() ++ ["spread"]
reps = String.to_integer(List.first(rest) || "0")
IO.puts("# #{mode}  #{System.get_env("ERL_FLAGS_LABEL", "default VM")}  #{Slice.load()}")

# fixed n (calibrated once, quiet-ish: Slice.calibrate(:today, us)) so runs compare
{n_short, n_055, n_5ms} = {19_500, 17_500, 78_000}

IO.puts(
  "# lone today calls, median us: #{inspect(for(n <- [n_short, n_055, n_5ms], do: Slice.med(for _ <- 1..31, do: Slice.us(fn -> Slice.call(:today, n) end))), charlists: :as_lists)}"
)

case mode do
  "single" ->
    # lone calls in one process, on 12 schedulers and on one; each round runs
    # every treatment back to back (order rotated per round); median of the
    # per-round ratio to `today` and to yield: false
    rounds = if reps > 0, do: reps, else: 15
    ts = [:noyield, :today, :adaptive, :total]

    for online <- [12, 1], {label, n, k} <- [{"0.65 ms", n_short, 200}, {"2M", 2_000_000, 1}] do
      :erlang.system_flag(:schedulers_online, online)

      res =
        for r <- 1..rounds do
          {a, b} = Enum.split(ts, rem(r, length(ts)))

          for t <- b ++ a,
              into: %{},
              do: {t, Slice.us(fn -> for _ <- 1..k, do: Slice.call(t, n) end) / k}
        end

      pct = fn t, ref -> Float.round(100 * (Slice.med(Enum.map(res, &(&1[t] / &1[ref]))) - 1), 2) end

      line =
        Enum.map_join(ts, "  ", fn t ->
          "#{t} #{Float.round(Slice.med(Enum.map(res, & &1[t])), 1)} us (#{pct.(t, :today)}% vs today, #{pct.(t, :noyield)}% vs noyield)"
        end)

      IO.puts("#{online} schedulers, #{label}: #{line}")
    end

    :erlang.system_flag(:schedulers_online, 12)

  "tick" ->
    runs = if reps > 0, do: reps, else: 5
    n_tick = 2_000_000
    ts = [:today, :adaptive, :total]

    Defk.Bench.TickGap.with_one_scheduler(fn ->
      # lone kernel vs ticker; then the kernel with 3 other kernel calls queued
      for {label, extra} <- [{"lone", 0}, {"crowded(+3)", 3}] do
        res =
          for _ <- 1..runs, t <- ts do
            {us, gaps} =
              Defk.Bench.TickGap.measure(fn ->
                others = for _ <- 1..extra//1, do: Task.async(fn -> Slice.call(t, n_tick) end)
                Slice.call(t, n_tick)
                Task.await_many(others, :infinity)
              end)

            {t, us, gaps}
          end

        for t <- ts do
          rs = for {^t, us, g} <- res, do: {us, g}
          all = Enum.flat_map(rs, &elem(&1, 1))
          worst = Enum.map(rs, fn {_, g} -> Enum.max(g) / 1000 end)

          IO.puts(
            "#{label} #{t}: runtime #{Float.round(Slice.med(Enum.map(rs, &elem(&1, 0))) / 1000, 1)} ms  " <>
              "p99 #{Float.round(Defk.Bench.TickGap.percentile(all, 0.99) / 1000, 2)} ms  worst #{inspect(worst)}"
          )
        end
      end
    end)

  "spread" ->
    rounds = if reps > 0, do: reps, else: 9
    ts = [:today, :adaptive, :total, :elixir]
    n_ex = Slice.calibrate(:elixir, 650, 1000, 400_000)
    n_ex55 = Slice.calibrate(:elixir, 550, 1000, 400_000)
    n_ex5 = Slice.calibrate(:elixir, 5000, 1000, 2_000_000)

    task = fn t, n ->
      s0 = :erlang.system_info(:scheduler_id)
      c = Slice.crowded?()
      Slice.call(t, n)
      {s0, :erlang.system_info(:scheduler_id), c}
    end

    ns = fn t, nk, ne -> if t == :elixir, do: ne, else: nk end

    harnesses = [
      {"48 x 0.65 ms async_stream",
       fn t ->
         1..48
         |> Task.async_stream(fn _ -> task.(t, ns.(t, n_short, n_ex)) end,
           max_concurrency: 12,
           timeout: :infinity
         )
         |> Enum.map(fn {:ok, r} -> r end)
       end},
      {"48 x 0.65 ms async+await_many",
       fn t ->
         n = ns.(t, n_short, n_ex)
         1..48 |> Enum.map(fn _ -> Task.async(fn -> task.(t, n) end) end) |> Task.await_many(:infinity)
       end},
      {"12 x 0.55 ms async_stream",
       fn t ->
         1..12
         |> Task.async_stream(fn _ -> task.(t, ns.(t, n_055, n_ex55)) end,
           max_concurrency: 12,
           timeout: :infinity
         )
         |> Enum.map(fn {:ok, r} -> r end)
       end},
      {"48 x 5 ms async_stream",
       fn t ->
         1..48
         |> Task.async_stream(fn _ -> task.(t, ns.(t, n_5ms, n_ex5)) end,
           max_concurrency: 12,
           timeout: :infinity
         )
         |> Enum.map(fn {:ok, r} -> r end)
       end}
    ]

    for {label, h} <- harnesses do
      res =
        for _ <- 1..rounds, t <- ts do
          {us, rs} = :timer.tc(fn -> h.(t) end)
          scheds = rs |> Enum.flat_map(fn {a, b, _} -> [a, b] end) |> Enum.uniq() |> length()
          crowded = Enum.count(rs, &elem(&1, 2))
          {t, us, scheds, crowded}
        end

      for t <- ts do
        rs = for {^t, us, s, c} <- res, do: {us, s, c}

        IO.puts(
          "#{String.pad_trailing(label, 30)} #{String.pad_trailing(to_string(t), 9)} " <>
            "wall #{Float.round(Slice.med(Enum.map(rs, &elem(&1, 0))) / 1000, 2)} ms  " <>
            "schedulers #{Slice.med(Enum.map(rs, &elem(&1, 1)))} (#{rs |> Enum.map(&elem(&1, 1)) |> Enum.min_max() |> inspect()})  " <>
            "crowded at start #{Slice.med(Enum.map(rs, &elem(&1, 2)))}/#{if String.starts_with?(label, "12"), do: 12, else: 48}"
        )
      end
    end
end

IO.puts("# end  #{Slice.load()}")
_ = K
