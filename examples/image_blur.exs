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
# Elixir baseline: first pass. Not yet tried: a separable blur (horizontal
# then vertical pass), walking three rows at a time with binary matching
# instead of 9 :binary.at/2 reads per pixel, and building output as iodata.

Mix.install([{:defk, path: Path.expand("..", __DIR__)}])

defmodule Blur.Kernels do
  use Defk

  defk gray_blur(rgb :: [u8], w :: i64, h :: i64) :: [u8] do
    gray = alloc(u8, w * h)

    # integer luma: (77 R + 150 G + 29 B) / 256
    for p <- 0..(w * h - 1)//1 do
      gray[p] = div(77 * rgb[3 * p] + 150 * rgb[3 * p + 1] + 29 * rgb[3 * p + 2], 256)
    end

    out = alloc(u8, w * h)

    for y <- 0..(h - 1)//1, x <- 0..(w - 1)//1 do
      s =
        for dy <- -1..1//1, dx <- -1..1//1, reduce: 0 do
          acc ->
            yy = min(max(y + dy, 0), h - 1)
            xx = min(max(x + dx, 0), w - 1)
            acc + gray[yy * w + xx]
        end

      out[y * w + x] = div(s, 9)
    end

    out
  end
end

defmodule Blur.Elixir do
  # Same algorithm; :binary.at/2 gives O(1) reads into the gray frame.
  def gray_blur(rgb, w, h) do
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
end

{w, h} = {1920, 1080}
# synthetic frame: gradients plus a checkerboard so the blur has edges to soften
rgb =
  for y <- 0..(h - 1), x <- 0..(w - 1), into: <<>> do
    c = if rem(div(x, 40) + div(y, 40), 2) == 0, do: 200, else: 30
    <<rem(x, 256), rem(y, 256), c>>
  end

Defk.Bench.report(
  name: "image_blur",
  expected: :good,
  baseline: :first_pass,
  runs: 3,
  elixir: fn -> Blur.Elixir.gray_blur(rgb, w, h) end,
  defk: fn -> Blur.Kernels.gray_blur(rgb, w, h) end,
  check: fn -> Blur.Elixir.gray_blur(rgb, w, h) == Blur.Kernels.gray_blur(rgb, w, h) end,
  reason: "byte-level neighbourhood loops; output is one packed binary"
)
