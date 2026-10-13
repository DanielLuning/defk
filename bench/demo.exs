# defk demo: `mix run bench/demo.exs` (from the repo root)
# Answers: does defk get native speed, what does the boundary cost, and does it
# keep the BEAM promises (preemption, isolation, cleanup)?

alias Examples.Kernels, as: K

defmodule Bench do
  def pack(list), do: for(x <- list, into: <<>>, do: <<x::float-64-native>>)
  def unpack(bin), do: for(<<x::float-64-native <- bin>>, do: x)

  def best(n \\ 3, fun) do
    Enum.map(1..n, fn _ -> elem(:timer.tc(fun), 0) end) |> Enum.min()
  end

  # reference implementations in plain Elixir
  def ex_sum_list(l), do: Enum.reduce(l, 0.0, &(&1 + &2))
  def ex_sum_bin(b), do: for(<<x::float-64-native <- b>>, reduce: 0.0, do: (acc -> acc + x))
  def ex_dot_list(a, b), do: Enum.zip_reduce(a, b, 0.0, fn x, y, acc -> acc + x * y end)

  # same algorithm as the kernel and the C baseline: no early exit
  def ex_prime?(x), do: Enum.reduce(2..trunc(:math.sqrt(x))//1, true, &(&2 and rem(x, &1) != 0))
  def ex_count_primes(n), do: Enum.count(2..n//1, &ex_prime?/1)

  # count_primes_early: stop at the first divisor. Enum.all? is the kernel's
  # code; tail recursion with guards was the fastest Elixir tried (Enum.all?
  # 1.7x, Enum.reduce_while 3x slower; d * d > x instead of sqrt: the same)
  def ex_prime_early?(x), do: Enum.all?(2..trunc(:math.sqrt(x))//1, &(rem(x, &1) != 0))
  def ex_count_primes_early(n), do: Enum.count(2..n//1, &ex_prime_early?/1)
  def ex_prime_rec?(x), do: no_divisor?(x, 2, trunc(:math.sqrt(x)))
  defp no_divisor?(_x, d, limit) when d > limit, do: true
  defp no_divisor?(x, d, _limit) when rem(x, d) == 0, do: false
  defp no_divisor?(x, d, limit), do: no_divisor?(x, d + 1, limit)
  def ex_count_primes_rec(n), do: Enum.count(2..n//1, &ex_prime_rec?/1)

  # boundary micro-benchmark: compiled loops, remote calls
  def eadd(a, b), do: a + b
  def loop_elixir(0, acc), do: acc
  def loop_elixir(n, acc), do: loop_elixir(n - 1, Bench.eadd(acc, 1))
  def loop_nif(0, acc), do: acc
  def loop_nif(n, acc), do: loop_nif(n - 1, K.add(acc, 1))

  # max gap between 1ms ticks while `fun` runs in another process
  def max_tick_gap(fun) do
    parent = self()
    ticker = spawn(fn -> tick(System.monotonic_time(:microsecond), 0, parent) end)
    {us, res} = :timer.tc(fun)
    send(ticker, :stop)
    receive do: ({:gap, g} -> {us, res, g})
  end

  defp tick(last, max, parent) do
    receive do
      :stop -> send(parent, {:gap, max})
    after
      1 ->
        now = System.monotonic_time(:microsecond)
        tick(now, max(max, now - last), parent)
    end
  end
end

h = fn title -> IO.puts("\n\e[1m== #{title}\e[0m") end
row = fn label, value -> IO.puts("  #{String.pad_trailing(label, 44)} #{value}") end
check = fn label, ok -> row.(label, if(ok, do: "ok", else: "\e[31mMISMATCH\e[0m")) end
close? = fn a, b -> abs(a - b) <= 1.0e-9 * max(1.0, abs(b)) end

IO.puts("defk demo  (OTP #{System.otp_release()}, #{System.schedulers_online()} schedulers)")
IO.puts("generated C: #{K.__defk_lib__() |> String.replace_suffix(".so", ".c")}")

# ---------------------------------------------------------------------------
h.("1. correctness vs plain Elixir")
xs = for i <- 1..10_001, do: :math.sin(i) * 100
ys = for i <- 1..10_001, do: :math.cos(i)
{bx, by} = {Bench.pack(xs), Bench.pack(ys)}

check.("sum", close?.(K.sum(bx), Bench.ex_sum_list(xs)))
check.("dot", close?.(K.dot(bx, by), Bench.ex_dot_list(xs, ys)))
mean = Enum.sum(xs) / length(xs)
var = Enum.sum(Enum.map(xs, &((&1 - mean) ** 2))) / length(xs)
{m, v} = K.mean_var(bx)
check.("mean_var (tuple accumulator + return)", close?.(m, mean) and close?.(v, var))
check.("scale (alloc + write + return array)", Bench.unpack(K.scale(bx, 2.5)) == Enum.map(xs, &(&1 * 2.5)))
bytes = :crypto.strong_rand_bytes(100_000)
<<_::binary>> = hist = K.histogram(bytes)
counts = for <<c::64-signed-native <- hist>>, do: c
ref = bytes |> :binary.bin_to_list() |> Enum.frequencies()
check.("histogram ([u8] in, [i64] out)", counts == Enum.map(0..255, &Map.get(ref, &1, 0)))
check.("count_primes(20_000)", K.count_primes(20_000) == Bench.ex_count_primes(20_000))
check.("count_primes_early(20_000) (Enum.all? exits early)",
      K.count_primes_early(20_000) == Bench.ex_count_primes_early(20_000) and
        K.count_primes_early(20_000) == Bench.ex_count_primes_rec(20_000))
<<_::8, unaligned::binary>> = <<0>> <> bx
check.("unaligned sub-binary input (copied once)", K.sum(unaligned) == K.sum(bx))

# ---------------------------------------------------------------------------
h.("2. throughput: Elixir vs defk vs plain C (5M f64)")
n = 5_000_000
list = for i <- 1..n, do: rem(i, 1000) / 1000
bin = Bench.pack(list)
pn = 1_000_000

native = Path.join(System.tmp_dir!(), "defk_native_bench")
{_, 0} = System.cmd("cc", ["-O3", "-o", native, "bench/native.c", "-lm"])
{out, 0} = System.cmd(native, ["#{n}", "#{pn}"], stderr_to_stdout: false)
[c_sum, c_dot, c_primes, c_primes_early] = out |> String.split() |> Enum.map(&String.to_float/1)

ns = fn us -> us * 1000 / n end
fmt = fn x -> :erlang.float_to_binary(x * 1.0, decimals: 2) end
t_list = ns.(Bench.best(fn -> Bench.ex_sum_list(list) end))
t_bin = ns.(Bench.best(fn -> Bench.ex_sum_bin(bin) end))
t_sum = ns.(Bench.best(5, fn -> K.sum(bin) end))
t_dot = ns.(Bench.best(5, fn -> K.dot(bin, bin) end))
t_dotl = ns.(Bench.best(fn -> Bench.ex_dot_list(list, list) end))

row.("sum  Elixir list        ns/elem", fmt.(t_list))
row.("sum  Elixir binary comp ns/elem", fmt.(t_bin))
row.("sum  defk               ns/elem", fmt.(t_sum))
row.("sum  plain C            ns/elem", fmt.(c_sum))
row.("dot  Elixir list        ns/elem", fmt.(t_dotl))
row.("dot  defk (a[i], checks elided) ns/elem", fmt.(t_dot))
row.("dot  plain C            ns/elem", fmt.(c_dot))
row.("defk sum vs C", "#{fmt.(t_sum / c_sum)}x   (Elixir list: #{fmt.(t_list / c_sum)}x)")
row.("defk dot vs C", "#{fmt.(t_dot / c_dot)}x")

t_p = Bench.best(3, fn -> K.count_primes(pn) end) / 1000
t_pn = Bench.best(3, fn -> K.count_primes_noyield(pn) end) / 1000
t_pe = Bench.best(1, fn -> Bench.ex_count_primes(pn) end) / 1000
row.("count_primes(1M)  Elixir              ms", fmt.(t_pe))
row.("count_primes(1M)  defk, yielding      ms", fmt.(t_p))
row.("count_primes(1M)  defk, yield: false  ms", fmt.(t_pn))
row.("count_primes(1M)  plain C             ms", fmt.(c_primes))
row.("safepoint overhead (yielding vs not)", "#{fmt.((t_p / t_pn - 1) * 100)}%")

t_q = Bench.best(3, fn -> K.count_primes_early(pn) end) / 1000
t_qn = Bench.best(3, fn -> K.count_primes_early_noyield(pn) end) / 1000
t_qe = Bench.best(3, fn -> Bench.ex_count_primes_early(pn) end) / 1000
t_qr = Bench.best(3, fn -> Bench.ex_count_primes_rec(pn) end) / 1000
row.("count_primes_early(1M)  Elixir Enum.all?   ms", fmt.(t_qe))
row.("count_primes_early(1M)  Elixir recursion   ms", fmt.(t_qr))
row.("count_primes_early(1M)  defk, yielding     ms", fmt.(t_q))
row.("count_primes_early(1M)  defk, yield: false ms", fmt.(t_qn))
row.("count_primes_early(1M)  plain C            ms", fmt.(c_primes_early))

# ---------------------------------------------------------------------------
h.("3. boundary cost per call (1M calls, compiled loop)")
calls = 1_000_000
t_e = Bench.best(fn -> Bench.loop_elixir(calls, 0) end) * 1000 / calls
t_n = Bench.best(fn -> Bench.loop_nif(calls, 0) end) * 1000 / calls
row.("Elixir remote call add/2      ns/call", fmt.(t_e))
row.("defk add/2 (NIF + decode + checked add)", fmt.(t_n) <> " ns/call")
row.("boundary overhead vs Elixir call", fmt.(t_n - t_e) <> " ns")
big = Bench.pack(List.duplicate(1.0, 1_000_000))
t_big = Bench.best(5, fn -> K.sum(<<1.0::float-64-native>>) end)
t_big1m = Bench.best(5, fn -> K.sum(big) end)
row.("sum of 1 elem vs 1M elems (us)", "#{t_big} vs #{t_big1m}  (input is never copied)")

# ---------------------------------------------------------------------------
h.("4. preemption on ONE scheduler (ticker wants to run every 1ms)")
:erlang.system_flag(:schedulers_online, 1)
pn2 = 2_000_000
run = fn fun -> fn -> Task.await(Task.async(fun), :infinity) end end
{_, _, gap0} = Bench.max_tick_gap(fn -> Process.sleep(500) end)
row.("idle (reference): worst tick gap", "#{fmt.(gap0 / 1000)} ms")
{us0, _, gapE} = Bench.max_tick_gap(run.(fn -> Bench.ex_count_primes(400_000) end))
row.("plain Elixir busy process: runtime / worst gap", "#{div(us0, 1000)} ms / #{fmt.(gapE / 1000)} ms")
{us, r1, gap1} = Bench.max_tick_gap(run.(fn -> K.count_primes(pn2) end))
row.("yielding kernel: runtime / worst tick gap", "#{div(us, 1000)} ms / #{fmt.(gap1 / 1000)} ms")
{us2, r2, gap2} = Bench.max_tick_gap(run.(fn -> K.count_primes_noyield(pn2) end))
row.("yield: false   : runtime / worst tick gap", "#{div(us2, 1000)} ms / #{fmt.(gap2 / 1000)} ms")
{us3, r3, gap3} = Bench.max_tick_gap(run.(fn -> K.count_primes_via_call(pn2) end))
row.("loops in callees (count_primes_via_call)", "#{div(us3, 1000)} ms / #{fmt.(gap3 / 1000)} ms")
# early exit: n scaled so the halting loops run about as long as count_primes(2M)
{us4, _, gap4} = Bench.max_tick_gap(run.(fn -> K.count_primes_early(6_000_000) end))
row.("early exit (count_primes_early, 6M)", "#{div(us4, 1000)} ms / #{fmt.(gap4 / 1000)} ms")
check.("same answer (#{r1})", r1 == r2 and r1 == r3)
row.("frame promotions / yields so far", inspect(Map.take(K.__defk_stats__(), [:promotions, :yields])))
:erlang.system_flag(:schedulers_online, System.schedulers())

# ---------------------------------------------------------------------------
h.("5. failure isolation: errors are exceptions in the caller, VM survives")

for {label, fun} <- [
      {"a[len(a)]", fn -> K.oob(bx) end},
      {"i64 overflow", fn -> K.overflow(4_000_000_000) end},
      {"wrong binary size", fn -> K.sum("abc") end},
      {"float where i64 expected", fn -> K.add(1, 2.0) end},
      {"mean_var of empty array", fn -> K.mean_var(<<>>) end}
    ] do
  try do
    fun.()
    row.(label, "\e[31mno error?\e[0m")
  rescue
    e -> row.(label, "#{inspect(e.__struct__)}: #{Exception.message(e)}")
  end
end

pid = spawn(fn -> K.count_primes(50_000_000) end)
Process.sleep(100)
live = K.__defk_stats__().frames_live
Process.exit(pid, :kill)
Process.sleep(50)
row.("suspended frames: while running / after kill", "#{live} / #{K.__defk_stats__().frames_live}")

IO.puts("\ndone.")
