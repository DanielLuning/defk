# fft: radix-2 FFT and direct convolution over audio-sized f64 signals
#
# Why people reach for a NIF here: spectra of audio frames, vibration and
# metrics signals, and FIR filtering are tight float loops; people wrap fftw
# or pull in Nx. On Nerves or in a metrics pipeline a dependency-free,
# yielding kernel is attractive.
# Expected verdict: good
#
#   elixir examples/fft.exs                  # agreement, convolution, report
#   FFT_VARIANTS=1 elixir examples/fft.exs   # also times every Elixir FFT variant
#
# Input: the real part as packed f64 (what a decoder or sensor hands you) and
# an imaginary part of zeros, n a power of two (a non-power-of-two length
# raises ArgumentError; Bluestein is a follow-up). Every Elixir variant starts
# from the same binaries and returns {re_list, im_list}.
#
# Elixir baseline: optimised. Measured (M-series Mac, OTP 29, Elixir 1.20,
# best of 20 runs at n = 4096, best of 3 at n = 2^20):
#
#   variant                                         n = 4096   n = 2^20
#   recursive lists (split evens/odds, combine)      2.8 ms    4420 ms  <- reported at 4096
#   iterative over lists, one pass per stage         3.2 ms    3006 ms
#   iterative, each stage rebuilds one tuple         3.5 ms    2032-2326 ms  <- sweep, large sizes
#   textbook in-place loop on :array                 6.0 ms   21637 ms
#   Nx 0.13.1 Nx.fft, binary backend (*)             7.9 ms    9719 ms
#   defk                                            0.045 ms     32-34 ms
#
# so ~62x at n = 4096 (against the recursive variant, the fastest there) and
# 63-91x at n = 2^20 (against the tuple variant, the fastest there). Runs vary
# with GC: the ranges are two runs.
#
# Realistic size: n = 4096, one audio or metrics frame per call; the verdict
# is measured there (recursive variant vs defk, best of 20). Beside it the
# report sweeps 4096, 16384, 65536, 262144 and 2^20 (fastest Elixir variant
# per size: recursive up to 16384, tuples above; best of 2), giving 50-110x
# at every size, so the crossover is 4096, the smallest size swept. It also
# records the 1 ms-ticker gap on one scheduler for one 2^20-point transform:
# Elixir ~50 ms max, defk ~2 ms (its yield budget; one run each). There is no
# native side: Nx is the only established alternative and is not a
# dependency (see below). Every variant uses the same twiddle table
# and butterflies as the kernel. Not tried yet: separate re/im float lists
# instead of a {re, im} tuple per value, a radix-4 or split-radix FFT (on
# both sides), and EXLA, which should win for large or batched transforms
# (docs/research/nx-boundary.md on branch research/nx-boundary).
#
# (*) Nx is not a dependency of this script: it was measured once with a
# separate Mix.install([{:nx, "~> 0.10"}]) (HEX_OFFLINE=1, from the hex cache),
# end to end from the packed binary: Nx.from_binary |> Nx.fft |> Nx.to_binary.
#
# Agreement: the kernel and all four Elixir variants are bit-exact (===) at
# n = 8, 4096 and 2^20; the check still uses a tolerance (|x - y| <= 1e-9 x
# the largest magnitude), as the ticket asks. Bit-exactness relies on libm
# calls never being fused into a platform sincos.
#
# Convolution (direct, full, out[k] = sum_j a[k - j] * b[j] with j ascending):
# 96,000 samples (2 s at 48 kHz) through a 64-tap FIR filter, bit-exact:
#
#   shift-and-add over lists, one pass per tap     74-101 ms   <- best Elixir
#   per output, elem/2 on tuples                   90-204 ms
#   defk                                           2.6 ms      (28-38x)
#
# FFT-based convolution for long filters and polyphase resampling (both in the
# ticket) are not in this script yet.

Mix.install([{:defk, path: Path.expand("..", __DIR__)}])

defmodule FFT.Kernels do
  use Defk

  # Iterative radix-2 decimation-in-time FFT. re and im are packed f64 of the
  # same power-of-two length; returns the transform as two new arrays.
  defk fft(re :: [f64], im :: [f64]) :: {[f64], [f64]} do
    n = length(re)

    # largest power of two <= n, and its log2 (no bitwise operators yet)
    {p, bits} =
      Enum.reduce_while(0..62//1, {1, 0}, fn _, {p, b} ->
        if p * 2 <= n, do: {:cont, {p * 2, b + 1}}, else: {:halt, {p, b}}
      end)

    if p != n or length(im) != n,
      do: raise(ArgumentError, "fft: re and im must have the same power-of-two length")

    ore = alloc(f64, n)
    oim = alloc(f64, n)

    # bit-reversal permutation: j is i with its `bits` bits reversed, kept as
    # a bit-reversed counter (add n/2, carrying downwards)
    _ =
      for i <- 0..(n - 1)//1, reduce: 0 do
        j ->
          ore[j] = re[i]
          oim[j] = im[i]

          {j2, _} =
            Enum.reduce_while(0..bits//1, {j, div(n, 2)}, fn _, {jj, m} ->
              if m >= 1 and jj >= m, do: {:cont, {jj - m, div(m, 2)}}, else: {:halt, {jj + m, m}}
            end)

          j2
      end

    # twiddles w_k = exp(-2 pi i k / n), k < n/2, computed once per call
    h = div(n, 2)
    twr = alloc(f64, h)
    twi = alloc(f64, h)

    # libm calls are never fused, so cos and sin share a loop
    for k <- 0..(h - 1)//1 do
      twr[k] = cos(-2.0 * 3.141592653589793 * k / n)
      twi[k] = sin(-2.0 * 3.141592653589793 * k / n)
    end

    # butterfly stages: block size 2, 4, ..., n; stage twiddle k is w_(k * n / size)
    _ =
      for _s <- 1..bits//1, reduce: 1 do
        half ->
          size = 2 * half
          stride = div(n, size)

          for start <- 0..(n - 1)//size, k <- 0..(half - 1)//1 do
            wr = twr[k * stride]
            wi = twi[k * stride]
            a = start + k
            b = a + half
            xr = ore[b]
            xi = oim[b]
            tr = wr * xr - wi * xi
            ti = wr * xi + wi * xr
            ur = ore[a]
            ui = oim[a]
            ore[a] = ur + tr
            oim[a] = ui + ti
            ore[b] = ur - tr
            oim[b] = ui - ti
          end

          size
      end

    {ore, oim}
  end

  # Direct (full) convolution, length n + m - 1: out[k] = sum_j a[k - j] * b[j],
  # summed with j ascending.
  defk convolve(a :: [f64], b :: [f64]) :: [f64] do
    n = length(a)
    m = length(b)
    out = alloc(f64, n + m - 1)

    for k <- 0..(n + m - 2)//1 do
      lo = max(0, k - n + 1)
      hi = min(k, m - 1)

      out[k] =
        for j <- lo..hi//1, reduce: 0.0 do
          acc -> acc + a[k - j] * b[j]
        end
    end

    out
  end
end

defmodule FFT.Elixir do
  # Every variant starts from the same packed f64 binaries the kernel gets,
  # computes the same twiddles the same way (index k * n / size into one
  # table for n) and does the same butterflies, so results can agree bit for
  # bit. They return {re_list, im_list}: a list of floats is what Elixir code
  # would consume next, and packing to a binary would only add to their time.

  @two_pi_neg -2.0 * :math.pi()

  def floats(bin), do: for(<<x::float-64-native <- bin>>, do: x)

  defp check!(n) do
    p =
      Enum.reduce_while(0..62, 1, fn _, p ->
        if p * 2 <= n, do: {:cont, p * 2}, else: {:halt, p}
      end)

    p == n || raise ArgumentError, "fft: length #{n} is not a power of two"
  end

  defp twiddles(n), do: for(k <- 0..(div(n, 2) - 1)//1, do: twiddle(k, n))

  defp twiddle(k, n) do
    a = @two_pi_neg * k / n
    {:math.cos(a), :math.sin(a)}
  end

  defp pairs(re, im), do: :lists.zip(floats(re), floats(im))

  # --- variant A: recursive list FFT (split evens/odds, recurse, combine)

  def recursive(re, im) do
    xs = pairs(re, im)
    n = length(xs)
    check!(n)
    tw = List.to_tuple(twiddles(n))
    :lists.unzip(rec(xs, 1, tw))
  end

  defp rec([x], _stride, _tw), do: [x]

  defp rec(xs, stride, tw) do
    {ev, od} = split(xs, [], [])
    e = rec(ev, stride * 2, tw)
    o = rec(od, stride * 2, tw)
    combine(e, o, 0, stride, tw, [], [])
  end

  defp split([a, b | rest], ev, od), do: split(rest, [a | ev], [b | od])
  defp split([], ev, od), do: {:lists.reverse(ev), :lists.reverse(od)}

  defp combine([{ur, ui} | e], [{xr, xi} | o], k, stride, tw, top, bot) do
    {wr, wi} = elem(tw, k * stride)
    tr = wr * xr - wi * xi
    ti = wr * xi + wi * xr
    combine(e, o, k + 1, stride, tw, [{ur + tr, ui + ti} | top], [{ur - tr, ui - ti} | bot])
  end

  defp combine([], [], _k, _stride, _tw, top, bot), do: :lists.reverse(top, :lists.reverse(bot))

  # --- variant B: iterative over lists, one pass per stage

  def stages(re, im) do
    xs = pairs(re, im)
    n = length(xs)
    check!(n)
    tw = List.to_tuple(twiddles(n))
    :lists.unzip(stage_loop(bitrev(xs), 1, n, tw))
  end

  # even/odd splitting all the way down puts a list in bit-reversed order
  defp bitrev([x]), do: [x]

  defp bitrev(xs) do
    {ev, od} = split(xs, [], [])
    bitrev(ev) ++ bitrev(od)
  end

  defp stage_loop(xs, half, n, _tw) when half >= n, do: xs

  defp stage_loop(xs, half, n, tw) do
    stride = div(n, 2 * half)
    tws = for k <- 0..(half - 1)//1, do: elem(tw, k * stride)
    stage_loop(blocks(xs, half, tws), half * 2, n, tw)
  end

  defp blocks([], _half, _tws), do: []

  defp blocks(xs, half, tws) do
    {a, rest} = :lists.split(half, xs)
    {b, rest} = :lists.split(half, rest)
    bfly(a, b, tws, [], [], blocks(rest, half, tws))
  end

  defp bfly([{ur, ui} | a], [{xr, xi} | b], [{wr, wi} | tws], top, bot, tail) do
    tr = wr * xr - wi * xi
    ti = wr * xi + wi * xr
    bfly(a, b, tws, [{ur + tr, ui + ti} | top], [{ur - tr, ui - ti} | bot], tail)
  end

  defp bfly([], [], [], top, bot, tail), do: :lists.reverse(top, :lists.reverse(bot, tail))

  # --- variant C: the textbook in-place loop on :array

  def array(re, im) do
    xs = pairs(re, im)
    n = length(xs)
    check!(n)
    tw = List.to_tuple(twiddles(n))
    arr = :array.from_list(bitrev(xs))

    arr =
      Enum.reduce(Stream.iterate(1, &(&1 * 2)) |> Enum.take_while(&(&1 < n)), arr, fn half, arr ->
        size = 2 * half
        stride = div(n, size)

        Enum.reduce(0..(n - 1)//size, arr, fn start, arr ->
          Enum.reduce(0..(half - 1)//1, arr, fn k, arr ->
            {wr, wi} = elem(tw, k * stride)
            a = start + k
            b = a + half
            {xr, xi} = :array.get(b, arr)
            {ur, ui} = :array.get(a, arr)
            tr = wr * xr - wi * xi
            ti = wr * xi + wi * xr
            arr = :array.set(a, {ur + tr, ui + ti}, arr)
            :array.set(b, {ur - tr, ui - ti}, arr)
          end)
        end)
      end)

    :lists.unzip(:array.to_list(arr))
  end

  # --- variant D: iterative on tuples, each stage rebuilds one tuple

  def tuples(re, im) do
    xs = pairs(re, im)
    n = length(xs)
    check!(n)
    tw = List.to_tuple(twiddles(n))
    t = List.to_tuple(bitrev(xs))
    :lists.unzip(Tuple.to_list(tuple_stages(t, 1, n, tw)))
  end

  defp tuple_stages(t, half, n, _tw) when half >= n, do: t

  defp tuple_stages(t, half, n, tw) do
    size = 2 * half
    stride = div(n, size)

    out =
      for start <- (n - size)..0//-size, reduce: [] do
        acc ->
          {top, bot} =
            for k <- (half - 1)..0//-1, reduce: {[], []} do
              {top, bot} ->
                {wr, wi} = elem(tw, k * stride)
                {ur, ui} = elem(t, start + k)
                {xr, xi} = elem(t, start + k + half)
                tr = wr * xr - wi * xi
                ti = wr * xi + wi * xr
                {[{ur + tr, ui + ti} | top], [{ur - tr, ui - ti} | bot]}
            end

          top ++ bot ++ acc
      end

    tuple_stages(List.to_tuple(out), size, n, tw)
  end

  # --- direct convolution

  # shift-and-add: one pass over the signal per tap, so each output sums its
  # terms with j ascending, as the kernel does (padding adds exact zeros)
  def convolve(a, b) do
    as = floats(a)
    bs = floats(b)
    n = length(as)
    m = length(bs)
    zeros = List.duplicate(0.0, n + m - 1)

    {out, _} =
      Enum.reduce(bs, {zeros, 0}, fn bj, {acc, j} ->
        {add_scaled(acc, j, as, bj), j + 1}
      end)

    out
  end

  # acc[j + i] += bj * a[i]
  defp add_scaled(acc, 0, as, bj), do: add_tail(acc, as, bj)
  defp add_scaled([x | acc], j, as, bj), do: [x | add_scaled(acc, j - 1, as, bj)]

  defp add_tail([x | acc], [y | as], bj), do: [x + y * bj | add_tail(acc, as, bj)]
  defp add_tail(acc, [], _bj), do: acc

  # per output: tuples, out[k] = sum over the overlap, j ascending
  def convolve_tuples(a, b) do
    at = List.to_tuple(floats(a))
    bt = List.to_tuple(floats(b))
    n = tuple_size(at)
    m = tuple_size(bt)

    for k <- 0..(n + m - 2)//1 do
      for j <- max(0, k - n + 1)..min(k, m - 1)//1, reduce: 0.0 do
        acc -> acc + elem(at, k - j) * elem(bt, j)
      end
    end
  end
end

defmodule FFT.Check do
  # |x - y| <= tol * scale, scale = the largest magnitude in the reference,
  # so near-zero bins (cancellation) are judged against the signal's size.
  def close?(xs, ys, tol \\ 1.0e-9) do
    scale = Enum.reduce(xs, 1.0e-300, &max(abs(&1), &2))

    length(xs) == length(ys) and
      Enum.all?(:lists.zip(xs, ys), fn {x, y} -> abs(x - y) <= tol * scale end)
  end

  def exact?(xs, ys), do: xs === ys

  def time_ms(fun, runs) do
    fun.()

    Enum.map(1..runs, fn _ ->
      :erlang.garbage_collect()
      elem(:timer.tc(fun), 0)
    end)
    |> Enum.min()
    |> Kernel./(1000)
    |> Float.round(3)
  end
end

pack = fn xs -> for x <- xs, into: <<>>, do: <<x::float-64-native>> end

# A deterministic "audio" signal: three tones plus a little pseudo-random noise.
signal = fn n ->
  re =
    for i <- 0..(n - 1) do
      :math.sin(i * 0.031) + 0.5 * :math.sin(i * 0.47 + 1.0) + 0.25 * :math.cos(i * 1.9) +
        rem(i * 7919, 101) / 1000
    end

  {pack.(re), pack.(List.duplicate(0.0, n))}
end

variants = [
  recursive: &FFT.Elixir.recursive/2,
  stages: &FFT.Elixir.stages/2,
  tuples: &FFT.Elixir.tuples/2,
  array: &FFT.Elixir.array/2
]

agree = fn {re, im}, {kre, kim}, variants ->
  krel = FFT.Elixir.floats(kre)
  kiml = FFT.Elixir.floats(kim)

  for {name, f} <- variants do
    {r, i} = f.(re, im)

    {name, FFT.Check.close?(r, krel) and FFT.Check.close?(i, kiml),
     FFT.Check.exact?(r, krel) and FFT.Check.exact?(i, kiml)}
  end
end

measure? = System.get_env("FFT_VARIANTS") == "1"

for n <- [8, 4096] do
  {re, im} = signal.(n)

  IO.puts(
    "n = #{n}: agreement (close, bit-exact) #{inspect(agree.({re, im}, FFT.Kernels.fft(re, im), variants))}"
  )

  if measure? do
    for {name, f} <- variants,
        do: IO.puts("  #{name}: #{FFT.Check.time_ms(fn -> f.(re, im) end, 20)} ms")

    IO.puts("  defk: #{FFT.Check.time_ms(fn -> FFT.Kernels.fft(re, im) end, 20)} ms")
  end
end

# a non-power-of-two length raises ArgumentError
{bad, _} = signal.(1000)

true =
  match?(
    {:error, %ArgumentError{message: "fft: re and im must have the same power-of-two length"}},
    try do
      {:ok, FFT.Kernels.fft(bad, bad)}
    rescue
      e -> {:error, e}
    end
  )

# convolution: 2 s of 48 kHz audio through a 64-tap FIR filter
{ca, _} = signal.(96_000)
cb = pack.(for j <- 0..63, do: :math.sin(j * 0.1) / 32)
kconv = FFT.Elixir.floats(FFT.Kernels.convolve(ca, cb))

for {name, f} <- [shift_add: &FFT.Elixir.convolve/2, tuples: &FFT.Elixir.convolve_tuples/2] do
  out = f.(ca, cb)

  IO.puts(
    "convolve #{name}: close #{FFT.Check.close?(out, kconv)}, bit-exact #{FFT.Check.exact?(out, kconv)}, #{FFT.Check.time_ms(fn -> f.(ca, cb) end, 5)} ms"
  )
end

IO.puts("convolve defk: #{FFT.Check.time_ms(fn -> FFT.Kernels.convolve(ca, cb) end, 5)} ms")

# The reported measurement is at the realistic size, one 4096-point frame
# (what an audio or metrics pipeline transforms per call). Beside it: a
# geometric sweep up to 2^20 (the fastest Elixir variant per size) and the
# 1 ms-ticker gap of each side on one 2^20-point transform.
n = 1_048_576
{re, im} = signal.(n)

if measure? do
  for {name, f} <- variants,
      do: IO.puts("  n = #{n} #{name}: #{FFT.Check.time_ms(fn -> f.(re, im) end, 3)} ms")
end

{kre, kim} = FFT.Kernels.fft(re, im)

IO.puts(
  "n = #{n}: agreement (close, bit-exact) #{inspect(agree.({re, im}, {kre, kim}, Keyword.take(variants, [:tuples, :stages])))}"
)

{sre, sim} = signal.(4096)
{skre, skim} = FFT.Kernels.fft(sre, sim)

# fastest Elixir variant at each size: recursive up to 16384, tuples above
elixir_for = fn size ->
  if size <= 16_384, do: &FFT.Elixir.recursive/2, else: &FFT.Elixir.tuples/2
end

sweep_fun = fn size ->
  {re, im} = signal.(size)
  f = elixir_for.(size)
  {fn -> f.(re, im) end, fn -> FFT.Kernels.fft(re, im) end}
end

Defk.Bench.report(
  name: "fft",
  expected: :good,
  baseline: :optimized,
  runs: 20,
  realistic_size: "n = 4096",
  elixir: fn -> FFT.Elixir.recursive(sre, sim) end,
  defk: fn -> FFT.Kernels.fft(sre, sim) end,
  check: fn ->
    {r, i} = FFT.Elixir.recursive(sre, sim)
    FFT.Check.close?(r, FFT.Elixir.floats(skre)) and FFT.Check.close?(i, FFT.Elixir.floats(skim))
  end,
  sweep: {[4096, 16_384, 65_536, 262_144, 1_048_576], sweep_fun},
  sweep_runs: 2,
  responsiveness: [
    elixir: fn -> FFT.Elixir.tuples(re, im) end,
    defk: fn -> FFT.Kernels.fft(re, im) end
  ],
  reason:
    "butterflies over packed floats in place, where Elixir allocates a tuple or cons cell per value and rebuilds the signal every stage"
)
