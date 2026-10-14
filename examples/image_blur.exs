# image_blur: grayscale + 3x3 box blur on a raw RGB frame
#
# Why people reach for a NIF here: thumbnailing, preview generation and
# vision preprocessing touch every pixel several times; a 1080p frame is
# 2M pixels x 9 neighbour reads.
# Expected verdict: good
#
#   elixir examples/image_blur.exs
#
# Starts from raw RGB bytes (what a decoder hands you). Decoding JPEG/PNG is
# out of scope: use an existing library (Vix/libvips) for codecs.
#
# Elixir baseline: optimised (3 variants). Measured on a shared M-series Mac
# under load (other benchmark agents running: **provisional**), OTP 29,
# Elixir 1.20, best of 3, 1080p frame (6.2 MB in, 2 MB out); the variants are
# timed with BLUR_VARIANTS=1 elixir examples/image_blur.exs and every one is
# byte-identical to the kernel:
#
#   first pass: 9 :binary.at/2 reads per pixel, comprehension output  ~780-830 ms
#   three-row walk, one process: gray by a binary comprehension (8 ms),
#     then the three gray rows (y-1, y, y+1) matched in step, a sliding
#     column sum, one output row per binary                           ~140 ms
#   same walk on 12 bands of rows, one Task each (halo row per band)   10.3-11.5 ms  <- baseline
#
# Also tried while writing it (not kept): a separable blur, horizontal 3-sums
# as 16-bit rows then vertical, ~180 ms with a recursive gray pass and ~124 ms
# with the comprehension gray (slower than the sliding three-row walk, ~111 ms
# for the walk alone); gray by list accumulation + list_to_binary (23-59 ms,
# against 8 ms for the comprehension); output as an iodata list of rows or a
# list of bytes (no faster than appending to a binary, 113 vs 111 ms).
# Separable and sliding sums keep the result exact: all sums are integers, and
# the clamped 9-neighbour sum is the same number either way.
#
# Fairness: the kernel switched to the same separable algorithm (horizontal
# 3-sums into an i64 buffer, then vertical), and is chunked the same way as
# the Elixir baseline: 12 row bands with halo rows, one kernel call per band,
# started together with Task.async + Task.await_many (Task.async_stream would
# keep short kernel tasks on 2-4 schedulers, README "Measuring correctly" 7).
# Parallel against parallel, default VM, 3 runs:
#
#   Elixir, 12 bands            9.1-9.9 ms
#   defk, 12 bands              2.3-2.5 ms   -> 3.8-4.2x, good  <- verdict
#   defk, 4 / 24 bands          3.5-3.9 / 1.7-2.1 ms
#   defk, 12 bands, +swt very_low  1.7 ms    (5.6x against Elixir 9.4 ms)
#
# One process against one call: Elixir 141-160 ms, defk 5.4-5.8 ms (about
# 26-29x); the old 9-reads-per-pixel kernel was 15.3 ms in one call.
# Numbers are provisional (shared machine under load).

Mix.install([{:defk, path: Path.expand("..", __DIR__)}])

defmodule Blur.Kernels do
  use Defk

  defk gray_blur(rgb :: [u8], w :: i64, h :: i64) :: [u8] do
    gray = alloc(u8, w * h)

    # integer luma: (77 R + 150 G + 29 B) / 256
    for p <- 0..(w * h - 1)//1 do
      gray[p] = div(77 * rgb[3 * p] + 150 * rgb[3 * p + 1] + 29 * rgb[3 * p + 2], 256)
    end

    # separable: horizontal 3-sums (<= 765) into an i64 buffer, then vertical
    hs = alloc(i64, w * h)

    for y <- 0..(h - 1)//1, x <- 0..(w - 1)//1 do
      l = gray[y * w + max(x - 1, 0)]
      r = gray[y * w + min(x + 1, w - 1)]
      hs[y * w + x] = l + gray[y * w + x] + r
    end

    out = alloc(u8, w * h)

    for y <- 0..(h - 1)//1, x <- 0..(w - 1)//1 do
      up = hs[max(y - 1, 0) * w + x]
      dn = hs[min(y + 1, h - 1) * w + x]
      out[y * w + x] = div(up + hs[y * w + x] + dn, 9)
    end

    out
  end
  # One band of the frame: output rows y0..y1-1 of the same blur. Gray and
  # horizontal sums are computed only for the band plus its halo rows.
  defk gray_blur_band(rgb :: [u8], w :: i64, h :: i64, y0 :: i64, y1 :: i64) :: [u8] do
    lo = max(y0 - 1, 0)
    hi = min(y1, h - 1)
    n = (hi - lo + 1) * w
    gray = alloc(u8, n)

    for p <- 0..(n - 1)//1 do
      q = lo * w + p
      gray[p] = div(77 * rgb[3 * q] + 150 * rgb[3 * q + 1] + 29 * rgb[3 * q + 2], 256)
    end

    hs = alloc(i64, n)

    for y <- 0..(hi - lo)//1, x <- 0..(w - 1)//1 do
      l = gray[y * w + max(x - 1, 0)]
      r = gray[y * w + min(x + 1, w - 1)]
      hs[y * w + x] = l + gray[y * w + x] + r
    end

    out = alloc(u8, (y1 - y0) * w)

    for y <- y0..(y1 - 1)//1, x <- 0..(w - 1)//1 do
      up = hs[(max(y - 1, 0) - lo) * w + x]
      dn = hs[(min(y + 1, h - 1) - lo) * w + x]
      out[(y - y0) * w + x] = div(up + hs[(y - lo) * w + x] + dn, 9)
    end

    out
  end
end

defmodule Blur.Elixir do
  # First-pass baseline (kept for the variants run): 9 :binary.at/2 reads per pixel.
  def first_pass(rgb, w, h) do
    gray = for <<r, g, b <- rgb>>, into: <<>>, do: <<div(77 * r + 150 * g + 29 * b, 256)>>

    for y <- 0..(h - 1), x <- 0..(w - 1), into: <<>> do
      s =
        for dy <- -1..1, dx <- -1..1, reduce: 0 do
          acc ->
            yy = min(max(y + dy, 0), h - 1)
            xx = min(max(x + dx, 0), w - 1)
            acc + :binary.at(gray, yy * w + xx)
        end

      <<div(s, 9)>>
    end
  end

  # Optimised, one process: gray by a binary comprehension (8 ms), then output
  # row by row, walking the three gray rows (y-1, y, y+1, clamped) in step with
  # binary matching. A column sum a+b+c slides over x, so each pixel costs one
  # new 3-byte read and the sum of three column sums (exactly the 9-neighbour
  # sum, so the bytes match the kernel).
  def gray_blur(rgb, w, h) do
    gray = gray(rgb)
    rows = for y <- 0..(h - 1), do: out_row(gray, y, w, y, h)
    :erlang.iolist_to_binary(rows)
  end

  # Optimised, all schedulers: the same code on horizontal bands of rows (each
  # band's gray rows include a one-row halo), one Task per band.
  def gray_blur_par(rgb, w, h, n \\ System.schedulers_online()) do
    band = div(h + n - 1, n)

    0..(n - 1)
    |> Task.async_stream(
      fn i ->
        y0 = i * band
        y1 = min(h, y0 + band) - 1
        lo = max(y0 - 1, 0)
        hi = min(y1 + 1, h - 1)

        if y0 > y1 do
          <<>>
        else
          gray = gray(:binary.part(rgb, lo * w * 3, (hi - lo + 1) * w * 3))
          rows = for y <- y0..y1, do: out_row(gray, y - lo, w, y, h)
          :erlang.iolist_to_binary(rows)
        end
      end,
      max_concurrency: n,
      ordered: true,
      timeout: :infinity
    )
    |> Enum.map(fn {:ok, b} -> b end)
    |> :erlang.iolist_to_binary()
  end

  defp gray(rgb), do: for(<<r, g, b <- rgb>>, into: <<>>, do: <<div(77 * r + 150 * g + 29 * b, 256)>>)

  # y: row index inside `gray`; gy/h: global row and frame height, so only the
  # true frame edges clamp.
  defp out_row(gray, y, w, gy, h) do
    up = if gy == 0, do: y, else: y - 1
    dn = if gy == h - 1, do: y, else: y + 1
    <<a0, ra::binary>> = :binary.part(gray, up * w, w)
    <<b0, rb::binary>> = :binary.part(gray, y * w, w)
    <<c0, rc::binary>> = :binary.part(gray, dn * w, w)
    col0 = a0 + b0 + c0
    walk(ra, rb, rc, col0, col0, <<>>)
  end

  defp walk(<<a, ra::binary>>, <<b, rb::binary>>, <<c, rc::binary>>, p, cu, acc) do
    nx = a + b + c
    walk(ra, rb, rc, cu, nx, <<acc::binary, div(p + cu + nx, 9)>>)
  end

  defp walk(<<>>, <<>>, <<>>, p, cu, acc), do: <<acc::binary, div(p + cu + cu, 9)>>
end

# Chunked defk: the same row bands, one kernel call per band, all started at
# once (Task.async + await_many; Task.async_stream keeps short kernel tasks on
# 2-4 schedulers, README "Measuring correctly" item 7).
defmodule Blur.Chunked do
  def run(rgb, w, h, n \\ System.schedulers_online()) do
    band = div(h + n - 1, n)

    for i <- 0..(n - 1), i * band < h do
      y0 = i * band
      y1 = min(h, y0 + band)
      Task.async(fn -> Blur.Kernels.gray_blur_band(rgb, w, h, y0, y1) end)
    end
    |> Task.await_many(:infinity)
    |> :erlang.iolist_to_binary()
  end
end

{w, h} = {1920, 1080}
# synthetic frame: gradients plus a checkerboard so the blur has edges to soften
rgb =
  for y <- 0..(h - 1), x <- 0..(w - 1), into: <<>> do
    c = if rem(div(x, 40) + div(y, 40), 2) == 0, do: 200, else: 30
    <<rem(x, 256), rem(y, 256), c>>
  end

if System.get_env("BLUR_VARIANTS") do
  time = fn f ->
    f.()
    for(_ <- 1..3, do: (t = System.monotonic_time(:microsecond); f.(); (System.monotonic_time(:microsecond) - t) / 1000))
    |> Enum.min()
    |> Float.round(1)
  end

  want = Blur.Kernels.gray_blur(rgb, w, h)

  for {name, f} <- [
        {"first pass (9 :binary.at/2 per pixel)", fn -> Blur.Elixir.first_pass(rgb, w, h) end},
        {"three-row walk, one process", fn -> Blur.Elixir.gray_blur(rgb, w, h) end},
        {"three-row walk, bands on all schedulers", fn -> Blur.Elixir.gray_blur_par(rgb, w, h) end},
        {"defk one call", fn -> Blur.Kernels.gray_blur(rgb, w, h) end},
        {"defk 12 bands", fn -> Blur.Chunked.run(rgb, w, h) end},
        {"defk 4 bands", fn -> Blur.Chunked.run(rgb, w, h, 4) end},
        {"defk 24 bands", fn -> Blur.Chunked.run(rgb, w, h, 24) end}
      ] do
    IO.puts("  #{String.pad_trailing(name, 44)} #{time.(f)} ms  exact=#{f.() == want}")
  end
end

Defk.Bench.report(
  name: "image_blur",
  expected: :good,
  baseline: :optimized,
  runs: 3,
  elixir: fn -> Blur.Elixir.gray_blur_par(rgb, w, h) end,
  defk: fn -> Blur.Chunked.run(rgb, w, h) end,
  check: fn ->
    want = Blur.Kernels.gray_blur(rgb, w, h)
    Blur.Elixir.gray_blur(rgb, w, h) == want and Blur.Elixir.gray_blur_par(rgb, w, h) == want and
      Blur.Chunked.run(rgb, w, h) == want and Blur.Chunked.run(rgb, w, h, 5) == want
  end,
  reason: "12 row bands on both sides (sliding three-row walk vs separable kernel, one Task.async per band); one process: 141-160 vs 5.5 ms"
)
