# Per-call state copy cost at catalog sizes: what "state
# travels as binaries" (ADR-0001) costs against the kernel's own work.
#
#   mix run bench/state_copy_cost.exs            # timings + GC run
#   mix run bench/state_copy_cost.exs timings    # timings only
#   mix run bench/state_copy_cost.exs gc         # GC run only
#   ROUNDS=9 mix run bench/state_copy_cost.exs   # more rounds (default 7)
#
# For each state size three kernels take the same state binary, and each
# timed loop chains the state through the calls (s = f(s)), as a caller
# that keeps a sketch between batches does:
#
#   full   the workload: HLL register update, Bloom insert, window append
#   touch  the memcpy-equivalent: the state copied (the kernel's one
#          defk_copy_u8: enif_alloc_binary + memcpy), one byte written,
#          returned as a new binary; nothing else
#   nop    the same call with the same argument returning length(state): the
#          call and loop overhead, no copy
#
# copy = touch - nop, share = copy / full. An input binary is read in place
# (zero copy in), so the copy is the output allocation plus the copy of the
# untouched bytes; touch measures exactly that. The variants run
# interleaved in every round, so load hits them alike, and the share is a
# ratio of two numbers taken back to back. Each cell is the best of ROUNDS.
#
# Context rows (not part of the share): Elixir's own copy of the same size
# (:binary.copy/1), and an :atomics Bloom filter in plain Elixir, the
# in-place structure Elixir already has.

defmodule StateCopy.Kernels do
  use Defk

  @mask64 0xFFFFFFFFFFFFFFFF

  # HLL, as examples/hll_update_many.exs: a 4-byte header and 2^p one-byte
  # registers; the state is copied once, before the loop, and written in
  # place.
  defk hll_update(state :: [u8], hashes :: [u64], p :: i64) :: [u8] do
    bits = 64 - p

    for h <- hashes do
      j = 4 + bsr(h, bits)
      r = min(clz(band(bsl(h, p), @mask64)), bits) + 1
      state[j] = max(state[j], r)
    end

    state
  end

  # Bloom filter over length(bits) * 8 bits (a power of two), k probes per key
  # by double hashing (Kirsch-Mitzenmacher: h1 + i * h2) on one 64-bit hash:
  # real bit ops (bsl/bor/band) on byte-granular storage.
  defk bloom_add(bits :: [u8], hashes :: [u64], k :: i64) :: [u8] do
    mask = length(bits) * 8 - 1

    for h <- hashes do
      h1 = band(h, 0xFFFFFFFF)
      h2 = bor(band(bsr(h, 32), 0xFFFFFFFF), 1)

      for i <- 0..(k - 1)//1 do
        b = band(h1 + i * h2, mask)
        j = bsr(b, 3)
        bits[j] = bor(bits[j], bsl(1, band(b, 7)))
      end
    end

    bits
  end

  # The no-copy twins: the same probes, reading instead of writing, so no
  # copy and no output binary: a direct measure of the in-place work (a
  # Bloom membership query; an HLL "would this batch raise a register").
  defk hll_probe(state :: [u8], hashes :: [u64], p :: i64) :: i64 do
    bits = 64 - p

    for h <- hashes, reduce: 0 do
      acc ->
        j = 4 + bsr(h, bits)
        r = min(clz(band(bsl(h, p), @mask64)), bits) + 1
        acc + max(state[j], r)
    end
  end

  defk bloom_probe(bits :: [u8], hashes :: [u64], k :: i64) :: i64 do
    mask = length(bits) * 8 - 1

    for h <- hashes, reduce: 0 do
      acc ->
        h1 = band(h, 0xFFFFFFFF)
        h2 = bor(band(bsr(h, 32), 0xFFFFFFFF), 1)

        for i <- 0..(k - 1)//1, reduce: acc do
          acc ->
            b = band(h1 + i * h2, mask)
            acc + bor(bits[bsr(b, 3)], bsl(1, band(b, 7)))
        end
    end
  end

  # The streaming shape: one block appended into a window at an offset (as
  # a zstd/xxh3 streaming state does), the window returned.
  defk window_append(win :: [u8], chunk :: [u8], off :: i64) :: [u8] do
    for i <- 0..(length(chunk) - 1)//1 do
      win[off + i] = chunk[i]
    end

    win
  end

  # The memcpy-equivalent: copy, one byte touched, return.
  defk touch(state :: [u8]) :: [u8] do
    state[0] = bxor(state[0], 1)
    state
  end

  # The same call without a copy.
  defk nop(state :: [u8]) :: i64 do
    length(state)
  end
end

defmodule StateCopy.ElixirBloom do
  # The in-place Elixir answer to a Bloom filter: an :atomics array of
  # 64-bit words, bits set with a compare-free bor per probe (one writer).
  import Bitwise

  def new(bytes), do: :atomics.new(div(bytes, 8), signed: false)

  def add(a, bytes, hashes, k) do
    mask = bytes * 8 - 1
    fold(a, mask, hashes, k)
  end

  defp fold(_a, _mask, <<>>, _k), do: :ok

  defp fold(a, mask, <<h::unsigned-64-native, rest::binary>>, k) do
    h1 = h &&& 0xFFFFFFFF
    h2 = (h >>> 32 &&& 0xFFFFFFFF) ||| 1
    probe(a, mask, h1, h2, 0, k)
    fold(a, mask, rest, k)
  end

  defp probe(_a, _mask, _h1, _h2, k, k), do: :ok

  defp probe(a, mask, h1, h2, i, k) do
    b = h1 + i * h2 &&& mask
    w = (b >>> 6) + 1
    bit = 1 <<< (b &&& 63)
    old = :atomics.get(a, w)
    if (old &&& bit) == 0, do: :atomics.put(a, w, old ||| bit)
    probe(a, mask, h1, h2, i + 1, k)
  end
end

defmodule StateCopy do
  import Bitwise
  alias StateCopy.Kernels, as: K

  # Each timed loop runs in a fresh process with default heap settings, as
  # a state-owning GenServer would: the script process holds every state
  # (128 MiB of binaries), so its binary virtual heap is large, it collects
  # rarely, and each new output lands in memory not yet reused (see the
  # "vheap" rows of the GC run).
  def in_proc(fun, opts \\ []) do
    parent = self()

    {pid, ref} =
      :erlang.spawn_opt(fn -> send(parent, {:res, self(), fun.()}) end, [:monitor | opts])

    receive do
      {:res, ^pid, r} ->
        receive do
          {:DOWN, ^ref, _, _, _} -> r
        end
    end
  end

  # n chained calls; returns ns per call
  def chain(f, s0, n, opts \\ []) do
    in_proc(
      fn ->
        {us, _} = :timer.tc(fn -> loop(f, s0, n) end)
        us * 1000 / n
      end,
      opts
    )
  end

  # us per call and GCs per call of n chained touches, in this process
  def timed_gcs(fun, n) do
    {g0, _, _} = :erlang.statistics(:garbage_collection)
    {us, _} = :timer.tc(fun)
    {g1, _, _} = :erlang.statistics(:garbage_collection)
    {us / n, (g1 - g0) / n}
  end

  def chain_here(s0, n), do: loop(&K.touch/1, s0, n)

  defp loop(_f, s, 0), do: s
  defp loop(f, s, n), do: loop(f, f.(s), n - 1)

  # n calls on the same state, result dropped (nop, :binary.copy, :atomics)
  def repeat(f, n) do
    in_proc(fn ->
      {us, _} = :timer.tc(fn -> rep(f, n) end)
      us * 1000 / n
    end)
  end

  defp rep(_f, 0), do: :ok

  defp rep(f, n) do
    f.()
    rep(f, n - 1)
  end

  def hashes(n), do: for(_ <- 1..n, into: <<>>, do: <<:rand.uniform(1 <<< 64) - 1::64-native>>)

  def workloads do
    p = 14
    hll0 = <<1, p, 0, 0>> <> :binary.copy(<<0>>, 1 <<< p)
    hll0 = K.hll_update(hll0, hashes(50_000), p)

    hll =
      for n <- [100, 1_000, 10_000] do
        hs = hashes(n)

        {"HLL p=14 (16 KiB)", "#{n} hashes", hll0, fn s -> K.hll_update(s, hs, p) end, nil,
         fn -> K.hll_probe(hll0, hs, p) end}
      end

    bloom =
      for bytes <- [1 <<< 20, 16 <<< 20], n <- [1, 100, 10_000] do
        b0 = K.bloom_add(:binary.copy(<<0>>, bytes), hashes(div(bytes, 16)), 7)
        hs = hashes(n)
        mib = div(bytes, 1 <<< 20)
        a = StateCopy.ElixirBloom.new(bytes)

        {"Bloom #{mib} MiB, k=7", "#{n} inserts", b0, fn s -> K.bloom_add(s, hs, 7) end,
         fn -> StateCopy.ElixirBloom.add(a, bytes, hs, 7) end, fn -> K.bloom_probe(b0, hs, 7) end}
      end

    win_bytes = 128 <<< 20
    win0 = :binary.copy(<<7>>, win_bytes)
    chunk = :crypto.strong_rand_bytes(128 <<< 10)

    stream = [
      {"Window 128 MiB", "1 byte", win0, fn s -> K.touch(s) end, nil, nil},
      {"Window 128 MiB", "128 KiB block", win0, fn s -> K.window_append(s, chunk, 4096) end, nil,
       nil}
    ]

    hll ++ bloom ++ stream
  end

  # calls per timed loop: ~20-40 ms of work for the biggest variant
  def iters(state) do
    cond do
      byte_size(state) >= 100 <<< 20 -> 4
      byte_size(state) >= 16 <<< 20 -> 20
      byte_size(state) >= 1 <<< 20 -> 1_000
      true -> 20_000
    end
  end

  def timings(rounds) do
    ws = workloads()

    # warm every variant once (first-touch pages, code)
    for {_, _, s0, full, _, _} <- ws do
      full.(s0)
      K.touch(s0)
    end

    results =
      for _r <- 1..rounds, reduce: %{} do
        acc ->
          for {{wl, batch, s0, full, ex, twin}, idx} <- Enum.with_index(ws), reduce: acc do
            acc ->
              n = iters(s0)
              # interleave: the order rotates every round
              order = Enum.shuffle([:full, :touch, :nop, :bincopy, :atomics, :twin])

              Enum.reduce(order, acc, fn
                :full, acc ->
                  put_min(acc, {idx, :full}, chain(full, s0, n))

                :touch, acc ->
                  put_min(acc, {idx, :touch}, chain(&K.touch/1, s0, n))

                :nop, acc ->
                  put_min(acc, {idx, :nop}, repeat(fn -> K.nop(s0) end, n))

                :bincopy, acc ->
                  put_min(acc, {idx, :bincopy}, repeat(fn -> :binary.copy(s0) end, n))

                :atomics, acc when ex != nil ->
                  put_min(acc, {idx, :atomics}, repeat(ex, n))

                :atomics, acc ->
                  acc

                :twin, acc when twin != nil ->
                  put_min(acc, {idx, :twin}, repeat(twin, n))

                :twin, acc ->
                  acc
              end)
              |> Map.put({idx, :label}, {wl, batch, byte_size(s0)})
          end
      end

    IO.puts(
      "\n" <>
        Enum.join(
          [
            pad("workload", 20),
            pad("batch", 14),
            lpad("full us", 10),
            lpad("touch us", 10),
            lpad("nop us", 8),
            lpad("copy us", 10),
            lpad("GB/s", 6),
            lpad("share", 7),
            lpad("in-place us", 12),
            lpad(":binary.copy us", 16),
            lpad("no-copy twin us", 16),
            lpad(":atomics us", 12)
          ],
          ""
        )
    )

    for idx <- 0..(length(ws) - 1) do
      {wl, batch, bytes} = results[{idx, :label}]
      full = results[{idx, :full}] / 1000
      touch = results[{idx, :touch}] / 1000
      nop = results[{idx, :nop}] / 1000
      copy = max(touch - nop, 0.0)
      share = copy / full
      gbs = bytes / (copy * 1000)
      at = results[{idx, :atomics}]
      tw = results[{idx, :twin}]

      IO.puts(
        Enum.join(
          [
            pad(wl, 20),
            pad(batch, 14),
            lpad(f(full), 10),
            lpad(f(touch), 10),
            lpad(f(nop), 8),
            lpad(f(copy), 10),
            lpad(f1(gbs), 6),
            lpad("#{round(100 * share)}%", 7),
            lpad(f(max(full - copy, 0.0)), 12),
            lpad(f(results[{idx, :bincopy}] / 1000), 16),
            lpad(if(tw, do: f(tw / 1000), else: "-"), 16),
            lpad(if(at, do: f(at / 1000), else: "-"), 12)
          ],
          ""
        )
      )
    end
  end

  defp put_min(acc, k, v), do: Map.update(acc, k, v, &min(&1, v))

  defp f(x) when x >= 100, do: :erlang.float_to_binary(x * 1.0, decimals: 0)
  defp f(x) when x >= 1, do: :erlang.float_to_binary(x * 1.0, decimals: 2)
  defp f(x), do: :erlang.float_to_binary(x * 1.0, decimals: 3)
  defp f1(x), do: :erlang.float_to_binary(x * 1.0, decimals: 1)
  defp pad(s, n), do: String.pad_trailing(s, n)
  defp lpad(s, n), do: String.pad_leading(s, n)

  # ------------------------------------------------------------------ GC --
  # One process chains a state through `call` for `secs` seconds at up to
  # `rate` calls/s (paced per millisecond; :max = as fast as it goes), while
  # a sampler reads :erlang.memory(:binary) every 5 ms. Reports the calls/s
  # reached, the binary memory peak and mean, the caller's GC count, and the
  # binary memory once the caller has exited.
  def gc_run(label, s0, call, rate, secs) do
    base = :erlang.memory(:binary)
    parent = self()
    sampler = spawn_link(fn -> sample(parent, []) end)

    {pid, ref} =
      spawn_monitor(fn ->
        :erlang.garbage_collect()
        {gcs0, _, _} = :erlang.statistics(:garbage_collection)
        {:garbage_collection, info0} = Process.info(self(), :garbage_collection)
        t0 = System.monotonic_time(:microsecond)
        n = drive(call, s0, rate, t0, t0 + secs * 1_000_000, 0)
        t1 = System.monotonic_time(:microsecond)
        {gcs1, _, _} = :erlang.statistics(:garbage_collection)
        {:garbage_collection, info1} = Process.info(self(), :garbage_collection)
        send(parent, {:done, n, t1 - t0, gcs1 - gcs0, info0, info1})
      end)

    {n, us, gcs, _info0, _info1} =
      receive do
        {:done, n, us, gcs, i0, i1} -> {n, us, gcs, i0, i1}
      end

    receive do
      {:DOWN, ^ref, :process, ^pid, _} -> :ok
    end

    send(sampler, :stop)

    samples =
      receive do
        {:samples, s} -> s
      end

    after_exit = :erlang.memory(:binary)
    peak = Enum.max(samples)
    mean = Enum.sum(samples) / length(samples)
    mib = fn b -> Float.round((b - base) / (1 <<< 20), 1) end

    IO.puts(
      "#{pad(label, 34)} #{lpad("#{round(n * 1_000_000 / us)}", 7)} calls/s  " <>
        "#{lpad(f1(n * byte_size(s0) / us / 1000), 5)} GB/s out  " <>
        "binary above base: peak #{lpad("#{mib.(peak)}", 7)} MiB, mean #{lpad("#{mib.(mean)}", 7)} MiB, " <>
        "after exit #{mib.(after_exit)} MiB  GCs per call #{f(gcs / max(n, 1))}"
    )
  end

  defp drive(call, s, rate, t0, stop, n) do
    now = System.monotonic_time(:microsecond)

    cond do
      now >= stop ->
        n

      rate != :max and n >= div((now - t0) * rate, 1_000_000) ->
        # ahead of the pace: wait for the next millisecond
        receive do
        after
          1 -> :ok
        end

        drive(call, s, rate, t0, stop, n)

      true ->
        drive(call, call.(s), rate, t0, stop, n + 1)
    end
  end

  defp sample(parent, acc) do
    receive do
      :stop -> send(parent, {:samples, [:erlang.memory(:binary) | acc]})
    after
      5 -> sample(parent, [:erlang.memory(:binary) | acc])
    end
  end

  def gc do
    # The same chained touch (copy only) in a fresh process, and in one that
    # also holds 256 MiB of other live binaries (four 64 MiB refc binaries):
    # its binary virtual heap grows to fit them, so it collects every few
    # hundred MiB of new output instead of after every call, and the dead
    # outputs pile up before they are freed.
    IO.puts("\nvheap: chained touch (copy only), us per call, best of 5")
    held = for i <- 1..4, do: :binary.copy(<<i>>, 64 <<< 20)

    for {label, bytes, n} <- [
          {"16 KiB", 16 <<< 10, 20_000},
          {"1 MiB", 1 <<< 20, 1_000},
          {"16 MiB", 16 <<< 20, 40}
        ] do
      s0 = :binary.copy(<<0>>, bytes)

      {d, b, gd, gb} =
        Enum.reduce(1..5, {nil, nil, 0, 0}, fn _, {d, b, _, _} ->
          {d1, gd} = in_proc(fn -> timed_gcs(fn -> chain_here(s0, n) end, n) end)

          {b1, gb} =
            in_proc(fn ->
              r = timed_gcs(fn -> chain_here(s0, n) end, n)
              _ = Enum.map(held, &byte_size/1)
              r
            end)

          {min(d1, d || d1), min(b1, b || b1), gd, gb}
        end)

      IO.puts(
        "  #{pad(label, 8)} fresh process #{lpad(f(d), 8)} us (GCs per call #{f(gd)})   " <>
          "holding 256 MiB #{lpad(f(b), 8)} us (GCs per call #{f(gb)})   #{f1(b / d)}x"
      )
    end

    # drop the held binaries before the GC rows measure :erlang.memory(:binary)
    :erlang.garbage_collect()
    hs1 = hashes(1)
    b16 = :binary.copy(<<0>>, 16 <<< 20)
    b1 = :binary.copy(<<0>>, 1 <<< 20)
    bloom = fn s -> K.bloom_add(s, hs1, 7) end

    IO.puts("\nGC: one process, state chained through the kernel, 3 s per row")
    gc_run("16 MiB Bloom, 1 insert, max rate", b16, bloom, :max, 3)
    gc_run("16 MiB Bloom, 1 insert, 10k/s", b16, bloom, 10_000, 3)
    gc_run("16 MiB Bloom, 1 insert, 1k/s", b16, bloom, 1_000, 3)
    gc_run("1 MiB Bloom, 1 insert, 10k/s", b1, bloom, 10_000, 3)
    gc_run("1 MiB Bloom, 1 insert, max rate", b1, bloom, :max, 3)

    # 10k calls/s of 16 MiB spread over 12 processes (the rate one process
    # cannot reach): each drives ~833 calls/s
    procs = System.schedulers_online()
    base = :erlang.memory(:binary)
    parent = self()
    sampler = spawn_link(fn -> sample(parent, []) end)
    t0 = System.monotonic_time(:microsecond)

    tasks =
      for _ <- 1..procs do
        Task.async(fn ->
          t = System.monotonic_time(:microsecond)
          drive(bloom, b16, div(10_000, procs), t, t + 3_000_000, 0)
        end)
      end

    n = tasks |> Task.await_many(:infinity) |> Enum.sum()
    us = System.monotonic_time(:microsecond) - t0
    send(sampler, :stop)

    samples =
      receive do
        {:samples, s} -> s
      end

    IO.puts(
      "#{pad("16 MiB Bloom, 10k/s over #{procs} procs", 34)} #{lpad("#{round(n * 1_000_000 / us)}", 7)} calls/s  " <>
        "#{lpad(f1(n * byte_size(b16) / us / 1000), 5)} GB/s out  binary above base: peak " <>
        "#{Float.round((Enum.max(samples) - base) / (1 <<< 20), 1)} MiB, mean " <>
        "#{Float.round((Enum.sum(samples) / length(samples) - base) / (1 <<< 20), 1)} MiB"
    )
  end
end

:rand.seed(:exsss, {7, 7, 7})
mode = List.first(System.argv()) || "all"
rounds = String.to_integer(System.get_env("ROUNDS") || "7")
{load, 0} = System.cmd("uptime", [])
IO.puts("uptime at start: " <> String.trim(load))

copies =
  StateCopy.Kernels.__defk_report__()
  |> Enum.filter(fn {_k, _line, {topic, _, _}} -> topic == :copy end)
  |> Enum.map(fn {{name, arity}, _line, {_, _, text}} -> "#{name}/#{arity}: #{text}" end)

IO.puts("copies the compiler inserted (Defk.Report):\n  " <> Enum.join(copies, "\n  "))

if mode in ["all", "timings"] do
  IO.puts("\nper call, best of #{rounds} interleaved rounds (chained: s = f(s)):")
  StateCopy.timings(rounds)
end

if mode in ["all", "gc"], do: StateCopy.gc()

{load, 0} = System.cmd("uptime", [])
IO.puts("\nuptime at end: " <> String.trim(load))
