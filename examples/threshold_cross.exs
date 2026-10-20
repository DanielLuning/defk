# threshold_cross: the first index where a running sum passes a budget, an
# early-exit loop, in Elixir, in a kernel and in Nx defn with EXLA
#
# The job: split a packet stream at a byte budget (rate limiting, chunking
# an upload, batching writes): the index of the first packet whose running
# total passes the budget. Each step depends on the last and the loop stops
# early, the shape docs/research/nx-boundary.md argues from source is a
# kernel's and not Nx's. This example measures it, to find the line, not
# to beat Nx: where EXLA wins, that is the result.
#
#   elixir examples/threshold_cross.exs
#
# Expected verdict (against Elixir): good. EXLA is the native comparison.
#
# Four ways, all integer-exact (i64 sizes, so every side gives the same
# index):
#   E1, E2   Elixir binary matching, one and four packets per clause (E2
#            is the baseline: 1.7-2.1x E1 from 4k packets up).
#   defk     Enum.reduce_while over the packets, halting at the crossing.
#   while    defn with `while` and the stop flag in its condition (Nx has
#            no break), compiled once per shape with Nx.Defn.compile/3 for
#            EXLA, on tensors resident on EXLA.Backend.
#   scan     defn without a loop: Nx.cumulative_sum, then Nx.argmax of the
#            mask (the tensor way: no early exit, all the work).
# Nx has no empty tensors (Nx.from_binary(<<>>) raises), so an Nx caller
# needs a guard for an empty batch; the kernel takes one.
#
# Agreement: every side gives the same index on 80 inputs (1 to 4097
# packets; the budget passed at the first packet, at 1%, 25%, 99%, never),
# including the kernel's Elixir mode (`elixir_mode: true`).
#
# Measured (M-series Mac, OTP 29, Elixir 1.20, Nx and EXLA 0.13.1 on the
# CPU, 2026-10-20; two runs, provisional: the first shared the machine
# with a `mix ci`). Per call, us, the budget passed at 25% (best of 5
# batches):
#
#   n          E2       defk     EXLA while  EXLA scan  scan from a binary
#   16         0.14-0.16 0.05    40-48       37-126     46-134
#   256        0.20-0.26 0.06-0.11 37-41     40         47-49
#   4096       1.03-1.09 0.36-0.42 40-41     50         55-56
#   65536      15.7-17.0 4.4-4.6 62-63       154-168    173-177
#   1M         249       91-92   319-344     1333-1341  1896-2355
#   16M        4336-4467 1473-1478 4272-4359 24780-25650 41807-48137
#
#   The report, 64k packets (realistic size: a few seconds of traffic):
#   Elixir 0.017 ms, defk 0.006 ms (2.8x, good), EXLA while 0.07 ms (defk
#   11.7x). Ticker gap on one scheduler while 16M packets are summed: about
#   2 ms on every side (the floor under load): Elixir is preempted, the
#   kernel yields, EXLA runs on a dirty scheduler.
#
# Crossovers: the kernel is faster than EXLA at every size, from 790x at 16
# packets (EXLA's ~40 us per call: a GenServer lock per device, a
# dirty-scheduler hop) to 2.9x at 16M. Optimised Elixir is faster than
# EXLA's while up to 1M packets and level at 16M. The scan form is slower
# than Elixir at every size: XLA's cumulative sum on the CPU took 1.5 ns a
# packet, the kernel 0.35 ns a packet it reads.
#
# Concurrency, calls per second at 4096 packets (300 ms windows, one run):
#   1 process     E2 0.97M, defk 3.2M, EXLA while 24.5k, scan 19.6k
#   48 processes  E2 7.9M, defk 22.3M, EXLA while 46.8k, scan 32.0k
# EXLA scales 1.6-1.9x from 1 to 48 callers (one host device, one lock);
# the kernel 7x, on the normal schedulers.
#
# Inputs whose length changes per call: 300 calls, 298 distinct lengths
# from 101 to 20000 packets, total ms: E2 0.8-1.0, defk 0.4; EXLA while
# with the jit compiling each new shape 1892-1948 (about 6.4 ms per
# compile), 19-20 once all are compiled; EXLA scan padded to 8
# power-of-two buckets 244-272 cold, 35-36 warm (the bucket workaround: 8
# compiles, then the padding and the larger shapes cost 2x).
#
# Recommendation: for a sequential loop with early exit, a kernel; plain
# Elixir is second and still beats EXLA up to about a million elements.
# EXLA is for whole-tensor work at scale (see cosine_topk.exs and
# matmul.exs), not for a scalar loop, small or variable-length inputs, or
# many concurrent small callers.

Mix.install([
  {:defk, path: Path.expand("..", __DIR__)},
  {:nx, "== 0.13.1"},
  {:exla, "== 0.13.1"}
])

defmodule Cross.Kernels do
  use Defk, elixir_mode: true

  # The index of the first packet whose running total of bytes passes the
  # budget, or -1.
  defk first_cross(x :: [i64], budget :: i64) :: i64 do
    n = length(x)

    {_s, idx} =
      Enum.reduce_while(0..(n - 1)//1, {0, -1}, fn i, {s, _idx} ->
        s1 = s + x[i]
        if s1 > budget, do: {:halt, {s1, i}}, else: {:cont, {s1, -1}}
      end)

    idx
  end
end

defmodule Cross.Elixir do
  # E1: one packet per clause
  def first_cross(bin, budget), do: go(bin, budget, 0, 0)

  defp go(<<x::signed-native-64, rest::binary>>, b, s, i) do
    s = s + x
    if s > b, do: i, else: go(rest, b, s, i + 1)
  end

  defp go(<<>>, _b, _s, _i), do: -1

  # E2: four packets per clause, then one at a time
  def first_cross4(bin, budget), do: go4(bin, budget, 0, 0)

  defp go4(
         <<a::signed-native-64, b::signed-native-64, c::signed-native-64, d::signed-native-64,
           rest::binary>>,
         t,
         s,
         i
       ) do
    s4 = s + a + b + c + d

    if s4 > t,
      do:
        go(
          <<a::signed-native-64, b::signed-native-64, c::signed-native-64, d::signed-native-64>>,
          t,
          s,
          i
        ),
      else: go4(rest, t, s4, i + 4)
  end

  defp go4(rest, t, s, i), do: go(rest, t, s, i)
end

defmodule Cross.Nx do
  import Nx.Defn

  # The early-exit form: a while loop whose condition folds in the stop flag
  defn first_cross_while(x, budget) do
    n = Nx.size(x)
    zero = Nx.tensor(0, type: :s64)

    {_i, _s, found, _x, _b} =
      while {i = zero, s = zero, found = zero - 1, x, budget}, i < n and found < 0 do
        s = s + x[i]
        found = Nx.select(s > budget, i, found)
        {i + 1, s, found, x, budget}
      end

    found
  end

  # The tensor form: the whole prefix sum, then the first index over budget
  defn first_cross_scan(x, budget) do
    hit = Nx.cumulative_sum(x) > budget
    idx = Nx.argmax(hit, tie_break: :low)
    Nx.select(hit[idx], idx, -1)
  end
end

defmodule Cross.Data do
  # Packet sizes 40..1500 bytes; the budget is passed at about `at` of the
  # way through (the mean packet is 770 bytes).
  def packets(n, seed \\ 1) do
    :rand.seed(:exsss, {seed, 9, 11})
    for _ <- 1..n//1, into: <<>>, do: <<39 + :rand.uniform(1461)::signed-native-64>>
  end

  def budget(n, at), do: trunc(n * at * 770)
end

alias Cross.{Data, Kernels}

# ---- the EXLA sides: tensors resident on EXLA.Backend, as an Nx app keeps
# them; one Nx.Defn.compile/3 per shape (the jit cache lookup skipped), and
# the jit for the variable-length runs ----

compiled = fn fun, n ->
  Nx.Defn.compile(fun, [Nx.template({n}, :s64), Nx.template({}, :s64)], compiler: EXLA)
end

to_dev = fn bin -> Nx.from_binary(bin, :s64, backend: EXLA.Backend) end
scalar = fn v -> Nx.tensor(v, type: :s64, backend: EXLA.Backend) end

while_jit = Nx.Defn.jit(&Cross.Nx.first_cross_while/2, compiler: EXLA)
scan_jit = Nx.Defn.jit(&Cross.Nx.first_cross_scan/2, compiler: EXLA)
exla = fn f, bin, b -> Nx.to_number(f.(to_dev.(bin), scalar.(b))) end

# ---- agreement ----

oracle = fn bin, b -> Kernels.__defk_elixir__(:first_cross, [bin, b]) end

cases =
  for n <- [1, 2, 3, 5, 16, 99, 1000, 4097], at <- [0.0, 0.01, 0.25, 0.99, 2.0], seed <- [1, 2] do
    {Data.packets(n, seed + n), Data.budget(n, at)}
  end

agree =
  Enum.all?(cases, fn {bin, b} ->
    e = Cross.Elixir.first_cross(bin, b)

    Enum.all?(
      [
        Cross.Elixir.first_cross4(bin, b),
        Kernels.first_cross(bin, b),
        oracle.(bin, b),
        exla.(while_jit, bin, b),
        exla.(scan_jit, bin, b)
      ],
      &(&1 == e)
    )
  end)

# A kernel takes an empty array; Nx has no empty tensors
empty = Kernels.first_cross(<<>>, 0) == -1 and Cross.Elixir.first_cross(<<>>, 0) == -1

nx_empty =
  try do
    to_dev.(<<>>)
    "built"
  rescue
    e -> "raises #{inspect(e.__struct__)}"
  end

IO.puts("""
agreement: Elixir (2), the kernel, its Elixir mode and EXLA (while, scan) on #{length(cases)} inputs \
(budget passed at the first packet, 1%, 25%, 99%, never) #{agree}; empty input #{empty}, \
Nx.from_binary(<<>>) #{nx_empty}
""")

# ---- per call, by size: best of 5 batches, each long enough to time ----

per_call = fn f, n ->
  reps = min(20_000, max(1, div(2_000_000, n)))
  f.()

  us =
    for _ <- 1..5 do
      {t, _} = :timer.tc(fn -> for _ <- 1..reps, do: f.() end)
      t / reps
    end

  Enum.min(us)
end

sizes = [16, 256, 4096, 65_536, 1_048_576, 16_777_216]

IO.puts(
  "per call, us (budget passed at 25%; EXLA on resident tensors, one Nx.Defn.compile per shape):"
)

IO.puts(
  "  #{String.pad_trailing("n", 10)} #{Enum.map_join(~w(E1 E2 defk while scan from_bin), " ", &String.pad_leading(&1, 10))}"
)

for n <- sizes do
  bin = Data.packets(n, 3)
  b = Data.budget(n, 0.25)
  xt = to_dev.(bin)
  bt = scalar.(b)
  cw = compiled.(&Cross.Nx.first_cross_while/2, n)
  cs = compiled.(&Cross.Nx.first_cross_scan/2, n)
  true = Nx.to_number(cw.(xt, bt)) == Kernels.first_cross(bin, b)

  row = [
    per_call.(fn -> Cross.Elixir.first_cross(bin, b) end, n),
    per_call.(fn -> Cross.Elixir.first_cross4(bin, b) end, n),
    per_call.(fn -> Kernels.first_cross(bin, b) end, n),
    per_call.(fn -> Nx.to_number(cw.(xt, bt)) end, n),
    per_call.(fn -> Nx.to_number(cs.(xt, bt)) end, n),
    per_call.(fn -> Nx.to_number(cs.(to_dev.(bin), bt)) end, n)
  ]

  IO.puts(
    "  #{String.pad_trailing(Integer.to_string(n), 10)} #{Enum.map_join(row, " ", &String.pad_leading(:erlang.float_to_binary(&1 * 1.0, decimals: 2), 10))}"
  )
end

# ---- concurrency: 1 process, then P processes, calling for 300 ms each at
# n = 4096 (a fixed count of calls was too short for the CPU sides: the
# Task setup was what got timed) ----

p = 4 * System.schedulers_online()
cbin = Data.packets(4096, 5)
cb = Data.budget(4096, 0.25)
cxt = to_dev.(cbin)
cbt = scalar.(cb)
ccw = compiled.(&Cross.Nx.first_cross_while/2, 4096)
ccs = compiled.(&Cross.Nx.first_cross_scan/2, 4096)

loop_until = fn f, deadline, count ->
  if System.monotonic_time(:millisecond) >= deadline do
    count
  else
    f.()
    f.()
    f.()
    f.()
    {:cont, count + 4}
  end
end

calls_per_s = fn f, procs ->
  f.()

  for _ <- 1..3 do
    deadline = System.monotonic_time(:millisecond) + 300

    count =
      1..procs
      |> Task.async_stream(
        fn _ ->
          Stream.iterate(0, & &1)
          |> Enum.reduce_while(0, fn _, c ->
            case loop_until.(f, deadline, c) do
              {:cont, c} -> {:cont, c}
              c -> {:halt, c}
            end
          end)
        end,
        max_concurrency: procs,
        timeout: :infinity
      )
      |> Enum.reduce(0, fn {:ok, c}, acc -> acc + c end)

    count / 0.3
  end
  |> Enum.max()
end

IO.puts("concurrency at n = 4096, calls per second (best of 3 windows of 300 ms):")

IO.puts(
  "  #{String.pad_trailing("", 12)} #{String.pad_leading("1 process", 12)} #{String.pad_leading("#{p} processes", 14)}"
)

for {label, f} <- [
      {"E2", fn -> Cross.Elixir.first_cross4(cbin, cb) end},
      {"defk", fn -> Kernels.first_cross(cbin, cb) end},
      {"EXLA while", fn -> Nx.to_number(ccw.(cxt, cbt)) end},
      {"EXLA scan", fn -> Nx.to_number(ccs.(cxt, cbt)) end}
    ] do
  one = round(calls_per_s.(f, 1))
  many = round(calls_per_s.(f, p))

  IO.puts(
    "  #{String.pad_trailing(label, 12)} #{String.pad_leading(Integer.to_string(one), 12)} #{String.pad_leading(Integer.to_string(many), 14)}"
  )
end

# ---- variable length: 300 calls, lengths 101..20000, data arriving as
# binaries; EXLA's jit compiles once per new shape (cold pass), then
# reuses (warm pass); buckets pad to the next power of two with zero bytes,
# which never pass a budget ----

:rand.seed(:exsss, {21, 22, 23})
lens = for _ <- 1..300, do: 100 + :rand.uniform(19_900)
calls = for {n, k} <- Enum.with_index(lens), do: {Data.packets(n, 100 + k), Data.budget(n, 0.25)}

pad = fn bin ->
  n = div(byte_size(bin), 8)
  m = max(128, 2 ** ceil(:math.log2(n)))
  bin <> :binary.copy(<<0::signed-native-64>>, m - n)
end

total_ms = fn f -> elem(:timer.tc(fn -> for {bin, b} <- calls, do: f.(bin, b) end), 0) / 1000 end
fresh_jit = fn fun -> Nx.Defn.jit(fun, compiler: EXLA) end

wj = fresh_jit.(&Cross.Nx.first_cross_while/2)
bj = fresh_jit.(&Cross.Nx.first_cross_scan/2)
buckets = calls |> Enum.map(fn {bin, _} -> byte_size(pad.(bin)) end) |> Enum.uniq() |> length()

IO.puts(
  "variable length: 300 calls, #{length(Enum.uniq(lens))} distinct lengths, #{buckets} buckets; total ms:"
)

for {label, f} <- [
      {"E2", fn bin, b -> Cross.Elixir.first_cross4(bin, b) end},
      {"defk", fn bin, b -> Kernels.first_cross(bin, b) end}
    ] do
  IO.puts("  #{String.pad_trailing(label, 26)} #{Float.round(total_ms.(f), 1)}")
end

for {label, j, prep} <- [
      {"EXLA while, jit per shape", wj, & &1},
      {"EXLA scan, jit, buckets", bj, pad}
    ] do
  f = fn bin, b -> Nx.to_number(j.(to_dev.(prep.(bin)), scalar.(b))) end
  cold = total_ms.(f)
  warm = total_ms.(f)

  IO.puts(
    "  #{String.pad_trailing(label, 26)} cold #{Float.round(cold, 1)}, warm #{Float.round(warm, 1)}"
  )
end

# ---- the verdict: the kernel against the best Elixir at 64k packets,
# EXLA's while form (its faster form here) beside them; the tick gap while
# 16M packets are summed with a budget never passed ----

rbin = Data.packets(65_536, 7)
rb = Data.budget(65_536, 0.25)
rxt = to_dev.(rbin)
rbt = scalar.(rb)
rcw = compiled.(&Cross.Nx.first_cross_while/2, 65_536)

big = Data.packets(16_777_216, 8)
bigb = Data.budget(16_777_216, 2.0)
bigt = to_dev.(big)
bigbt = scalar.(bigb)
bigw = compiled.(&Cross.Nx.first_cross_while/2, 16_777_216)

Defk.Bench.report(
  name: "threshold_cross",
  expected: :good,
  baseline: :optimized,
  runs: 15,
  realistic_size: "64k packets, the budget passed at 25%",
  elixir: fn -> Cross.Elixir.first_cross4(rbin, rb) end,
  defk: fn -> Kernels.first_cross(rbin, rb) end,
  native: {fn -> Nx.to_number(rcw.(rxt, rbt)) end, "Nx 0.13.1 + EXLA 0.13.1, while"},
  check: fn ->
    agree and empty and Kernels.first_cross(rbin, rb) == Cross.Elixir.first_cross(rbin, rb) and
      Nx.to_number(rcw.(rxt, rbt)) == Cross.Elixir.first_cross(rbin, rb)
  end,
  sweep:
    {[16_384, 65_536, 1_048_576],
     fn n ->
       bin = Data.packets(n, 9)
       b = Data.budget(n, 0.25)
       {fn -> Cross.Elixir.first_cross4(bin, b) end, fn -> Kernels.first_cross(bin, b) end}
     end},
  sweep_runs: 5,
  responsiveness: [
    elixir: fn -> Cross.Elixir.first_cross4(big, bigb) end,
    defk: fn -> Kernels.first_cross(big, bigb) end,
    native: fn -> Nx.to_number(bigw.(bigt, bigbt)) end
  ],
  reason:
    "a sequential loop that stops early: the kernel runs it at C speed with a call cost of tens of ns; EXLA pays about 40 us per call and its while loop is several times slower per step"
)
