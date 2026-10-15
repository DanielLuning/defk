<!-- examples/rolling_stats.exs line 51 of v0.1.0. A frozen file is never edited. -->

<!-- defk-example compiles: a catalog kernel module -->
```elixir
defmodule Rolling.Kernels do
  use Defk

  # Sliding sums: O(n) regardless of window size. Returns means then stddevs,
  # n - w + 1 values each, packed into one array.
  defk mean_std(x :: [f64], w :: i64) :: [f64] do
    n = length(x)
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
```
