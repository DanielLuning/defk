# rolling_stats: moving average and standard deviation over sensor readings
#
# Why people reach for a NIF here: metrics/IoT pipelines smooth millions of
# samples per batch; a per-sample loop with a window queue is slow in Elixir.
# Expected verdict: good
#
#   elixir examples/rolling_stats.exs
#
# Readings arrive as a packed binary of f64 (file, device, or a previous
# step), so both versions start from the same bytes.
#
# Both sides return the same thing: one packed binary of the n - w + 1 means
# followed by the n - w + 1 standard deviations (f64, native endian).
#
# Elixir baseline: optimised. Best of 7 runs after a warm-up, 1M samples,
# w = 60, 12 schedulers, shared machine (provisional: other benchmarks were
# running; the first-pass list version measured 100-110 ms in these runs and
# 308 ms inside Defk.Bench, GC and load dependent). Every variant returns the
# same bytes (the parallel ones agree to ~1e-12: each chunk re-seeds its sums):
#
#   first pass: two float lists (cons per result, reverse)         ~100-110 ms
#   same, then packed with iodata of <<x::float-64>>               ~335-370 ms (3x worse)
#   two binary accumulators, <<acc::binary, x::float-64-native>>
#     (the binary append is optimised in place)                    ~62-68 ms
#   + 4 windows per recursion step (one 32-byte match, 8 appends)  ~53-60 ms
#   + parallel: Task.async_stream over 12 chunks of the output,
#     each with a w - 1 overlap, merged with iolist_to_binary
#     (batching helps inside chunks)                               ~9.6 ms  <- baseline
#   parallel with the unbatched binary walk                        ~10.5 ms
#   parallel over 4 chunks                                         ~16-20 ms
#
# The arithmetic (two float ops per sample) is cheap; what a single process
# pays for is boxing each float result. Binary accumulation avoids the boxes
# and the 2M cons cells; chunks across schedulers give the rest.
#
# defk, parallel vs parallel (the verdict): the same 12 chunks with a w - 1
# overlap, one kernel call per chunk started with Task.async + Task.await_many
# (README rule 7), same merge: 1.5-2.3 ms. One process / one call beside it:
# Elixir with one chunk ~65 ms (batched binary walk), defk one call ~1.9 ms
# (~34x); the one-call kernel is bit-exact with the one-chunk Elixir.
#
# Result: first pass 172x; optimised Elixir (parallel) 10.8-11.7 ms vs defk
# parallel 1.5-2.3 ms = 5.0-7.8x over three runs. Still good (above 2x). The
# one-process comparison is ~34x. Most of the 12 chunk tasks' time is the
# 1M-sample binary walk itself; Elixir's 16 MB output is the other cost. A
# supporting example: it does not count towards the verdict. Provisional,
# measured under load.

Mix.install([{:defk, path: Path.expand("..", __DIR__)}])

defmodule Rolling.Kernels do
  use Defk

  # Sliding sums: O(n) regardless of window size. Returns means then stddevs,
  # n - w + 1 values each, packed into one array.
  defk mean_std(x :: [f64], w :: i64) :: [f64] do
    n = len(x)
    m = n - w + 1
    out = alloc(f64, 2 * m)

    _ =
      for i <- 0..(n - 1)//1, reduce: {0.0, 0.0} do
        {s, q} ->
          v = x[i]
          # the sample leaving the window (0.0 while the window fills)
          old = if i >= w, do: x[i - w], else: 0.0
          s2 = s + v - old
          q2 = q + v * v - old * old

          if i >= w - 1 do
            mean = s2 / w
            out[i - w + 1] = mean
            out[m + i - w + 1] = sqrt(max(q2 / w - mean * mean, 0.0))
          end

          {s2, q2}
      end

    out
  end
end

defmodule Rolling.Elixir do
  # The same sliding-sum algorithm: two cursors into the binary (newest
  # sample, sample leaving the window), tail recursion, no window queue.
  # Output is appended to two binaries (no float boxing, no cons cells), four
  # windows per step, and the output range is split in chunks over all
  # schedulers (each chunk starts from its own window sums).
  def mean_std(bin, w, chunks \\ System.schedulers_online()) do
    m = div(byte_size(bin), 8) - w + 1
    per = div(m + chunks - 1, chunks)

    parts =
      0..(chunks - 1)
      |> Enum.map(fn c -> {c * per, min(per, m - c * per)} end)
      |> Enum.filter(fn {_, k} -> k > 0 end)
      |> Task.async_stream(
        fn {start, k} ->
          chunk = binary_part(bin, start * 8, (k + w - 1) * 8)
          <<means::binary-size(^k * 8), stds::binary>> = run(chunk, w)
          {means, stds}
        end,
        max_concurrency: chunks,
        timeout: :infinity
      )
      |> Enum.map(fn {:ok, part} -> part end)

    :erlang.iolist_to_binary([Enum.map(parts, &elem(&1, 0)), Enum.map(parts, &elem(&1, 1))])
  end

  # One chunk: means then stddevs, packed.
  defp run(bin, w) do
    <<head::binary-size(^w * 8), rest::binary>> = bin

    {s, q} =
      for <<v::float-64-native <- head>>, reduce: {0.0, 0.0}, do: ({s, q} -> {s + v, q + v * v})

    mean = s / w
    walk(rest, bin, w, s, q, <<mean::float-64-native>>, <<std(q, w, mean)::float-64-native>>)
  end

  defp walk(
         <<v1::float-64-native, v2::float-64-native, v3::float-64-native, v4::float-64-native,
           rest::binary>>,
         <<o1::float-64-native, o2::float-64-native, o3::float-64-native, o4::float-64-native,
           trail::binary>>,
         w,
         s,
         q,
         means,
         stds
       ) do
    s1 = s + v1 - o1
    q1 = q + v1 * v1 - o1 * o1
    s2 = s1 + v2 - o2
    q2 = q1 + v2 * v2 - o2 * o2
    s3 = s2 + v3 - o3
    q3 = q2 + v3 * v3 - o3 * o3
    s4 = s3 + v4 - o4
    q4 = q3 + v4 * v4 - o4 * o4
    m1 = s1 / w
    m2 = s2 / w
    m3 = s3 / w
    m4 = s4 / w

    walk(
      rest,
      trail,
      w,
      s4,
      q4,
      <<means::binary, m1::float-64-native, m2::float-64-native, m3::float-64-native,
        m4::float-64-native>>,
      <<stds::binary, std(q1, w, m1)::float-64-native, std(q2, w, m2)::float-64-native,
        std(q3, w, m3)::float-64-native, std(q4, w, m4)::float-64-native>>
    )
  end

  defp walk(
         <<v::float-64-native, rest::binary>>,
         <<old::float-64-native, trail::binary>>,
         w,
         s,
         q,
         means,
         stds
       ) do
    s = s + v - old
    q = q + v * v - old * old
    mean = s / w

    walk(
      rest,
      trail,
      w,
      s,
      q,
      <<means::binary, mean::float-64-native>>,
      <<stds::binary, std(q, w, mean)::float-64-native>>
    )
  end

  defp walk(<<>>, _trail, _w, _s, _q, means, stds), do: <<means::binary, stds::binary>>

  defp std(q, w, mean), do: :math.sqrt(max(q / w - mean * mean, 0.0))
end

defmodule Rolling.DefkParallel do
  # The same split as Rolling.Elixir: output range in chunks, each with a
  # w - 1 overlap, one kernel call per chunk started at once with Task.async +
  # Task.await_many (examples/README.md, measuring rule 7), merged the same way.
  def mean_std(bin, w, chunks \\ System.schedulers_online()) do
    m = div(byte_size(bin), 8) - w + 1
    per = div(m + chunks - 1, chunks)

    parts =
      0..(chunks - 1)
      |> Enum.map(fn c -> {c * per, min(per, m - c * per)} end)
      |> Enum.filter(fn {_, k} -> k > 0 end)
      |> Enum.map(fn {start, k} ->
        Task.async(fn ->
          chunk = binary_part(bin, start * 8, (k + w - 1) * 8)
          <<means::binary-size(^k * 8), stds::binary>> = Rolling.Kernels.mean_std(chunk, w)
          {means, stds}
        end)
      end)
      |> Task.await_many(:infinity)

    :erlang.iolist_to_binary([Enum.map(parts, &elem(&1, 0)), Enum.map(parts, &elem(&1, 1))])
  end
end

# 1M readings: a slow wave plus deterministic noise
n = 1_000_000
w = 60

input =
  for i <- 1..n,
      into: <<>>,
      do: <<20.0 + 5 * :math.sin(i / 500) + rem(i * 7919, 13) / 10::float-64-native>>

check = fn ->
  expected = Rolling.Elixir.mean_std(input, w)
  packed = Rolling.DefkParallel.mean_std(input, w)

  # the one-call kernel and the one-chunk Elixir agree on every byte
  true = Rolling.Kernels.mean_std(input, w) == Rolling.Elixir.mean_std(input, w, 1)
  m = n - w + 1
  floats = fn bin -> for <<v::float-64-native <- bin>>, do: v end

  # same layout and length; values within 1e-9 (chunks re-seed their sums)
  byte_size(packed) == 16 * m and byte_size(expected) == 16 * m and
    Enum.zip(floats.(expected), floats.(packed))
    |> Enum.all?(fn {x, y} -> abs(x - y) < 1.0e-9 end)
end

best = fn f ->
  f.()
  for(_ <- 1..7, do: (:erlang.garbage_collect(); elem(:timer.tc(f), 0))) |> Enum.min() |> Kernel./(1000)
end

IO.puts("one process / one call (same output):")
IO.puts("  elixir 1 chunk  #{Float.round(best.(fn -> Rolling.Elixir.mean_std(input, w, 1) end), 2)} ms")
IO.puts("  defk 1 call     #{Float.round(best.(fn -> Rolling.Kernels.mean_std(input, w) end), 2)} ms")

Defk.Bench.report(
  name: "rolling_stats",
  expected: :good,
  baseline: :optimized,
  elixir: fn -> Rolling.Elixir.mean_std(input, w) end,
  defk: fn -> Rolling.DefkParallel.mean_std(input, w) end,
  check: check,
  reason: "one pass over packed floats, no allocation per sample"
)
