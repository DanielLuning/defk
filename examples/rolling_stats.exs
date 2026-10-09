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
# Where the gap comes from (1M samples, M-series Mac): the Elixir arithmetic
# alone takes ~46 ms (defk: ~1.4 ms, ~30x). Most of Elixir's total is building
# the 2M result floats as lists; defk writes one packed binary instead.
#
# Elixir baseline: first pass. Not yet tried: producing the output as one
# packed binary (iodata) instead of two float lists, which is where most of
# Elixir's time goes; batching several windows per recursion step.

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
  # The same sliding-sum algorithm, written the way a careful Elixir developer
  # would: two cursors into the binary (newest sample, sample leaving the
  # window), tail recursion, no window queue.
  def mean_std(bin, w) do
    <<head::binary-size(^w * 8), rest::binary>> = bin

    {s, q} =
      for <<v::float-64-native <- head>>, reduce: {0.0, 0.0}, do: ({s, q} -> {s + v, q + v * v})

    mean = s / w
    walk(rest, bin, w, s, q, [mean], [std(q, w, mean)])
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
    walk(rest, trail, w, s, q, [mean | means], [std(q, w, mean) | stds])
  end

  defp walk(<<>>, _trail, _w, _s, _q, means, stds),
    do: {:lists.reverse(means), :lists.reverse(stds)}

  defp std(q, w, mean), do: :math.sqrt(max(q / w - mean * mean, 0.0))
end

# 1M readings: a slow wave plus deterministic noise
n = 1_000_000
w = 60

input =
  for i <- 1..n,
      into: <<>>,
      do: <<20.0 + 5 * :math.sin(i / 500) + rem(i * 7919, 13) / 10::float-64-native>>

check = fn ->
  {means, stds} = Rolling.Elixir.mean_std(input, w)
  packed = Rolling.Kernels.mean_std(input, w)
  m = n - w + 1
  kmeans = for <<v::float-64-native <- binary_part(packed, 0, m * 8)>>, do: v
  kstds = for <<v::float-64-native <- binary_part(packed, m * 8, m * 8)>>, do: v
  close = fn a, b -> Enum.zip(a, b) |> Enum.all?(fn {x, y} -> abs(x - y) < 1.0e-9 end) end
  length(means) == m and close.(means, kmeans) and close.(stds, kstds)
end

Defk.Bench.report(
  name: "rolling_stats",
  expected: :good,
  baseline: :first_pass,
  elixir: fn -> Rolling.Elixir.mean_std(input, w) end,
  defk: fn -> Rolling.Kernels.mean_std(input, w) end,
  check: check,
  reason: "one pass over packed floats, no allocation per sample"
)
