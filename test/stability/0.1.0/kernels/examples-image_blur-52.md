<!-- examples/image_blur.exs line 52 of v0.1.0. A frozen file is never edited. -->

<!-- defk-example compiles: a catalog kernel module -->
```elixir
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
```
