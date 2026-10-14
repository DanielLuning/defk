# image_ops: bilinear resize, RGB to YUV420 and Floyd-Steinberg dithering
# on raw 1080p frames
#
# Why people reach for a NIF here: thumbnails, video preprocessing and
# e-paper/Nerves displays touch every pixel of a 6 MB frame; people wrap
# image/vix (libvips), cvt_color or dither. This script covers three of the
# jobs of ticket defk-52v.11 with from-scratch kernels on raw bytes.
# Expected verdict: good
#
#   elixir examples/image_ops.exs
#
# Three kernels, three DEFK_RESULT lines. mix defk.examples collects only the FIRST
# DEFK_RESULT line of a script, so the resize report is printed first and
# mix defk.examples sees the resize verdict; the YUV and dither verdicts are visible
# when this script is run on its own (and are quoted below).
#
# Skipped: Lanczos-3 resize (a float-weights follow-up of the resize kernel),
# RGB888 to RGB565 (needs bsr/band, defk-w38), and the libvips comparison
# (out of scope here: libvips is SIMD-tuned and expected to win resize on
# speed; on Nerves there is no libvips). Decoding JPEG/PNG is out of scope.
#
# Kernels (all integer-only, so agreement is bit-exact, compared with ==):
#
#   resize_bilinear  RGB/RGBA bytes, 16.16 fixed-point sample positions
#                    (src = dst * (src_size - 1) / (dst_size - 1), corners
#                    aligned), horizontal blend, vertical blend, one rounding
#                    at the end. 1920x1080 RGB -> 480x270.
#   rgb_to_yuv420    BT.601 studio swing, integer coefficients, planar Y then
#                    U then V, chroma from the rounded 2x2 average of RGB.
#                    Even w and h are required (else ArgumentError).
#   dither_fs        Floyd-Steinberg to 0/255, errors truncated with div/2 by
#                    16, a two-row [i64] error buffer allocated in the kernel.
#                    Left-to-right scan on every row (serpentine is not done).
#
# Elixir baselines: optimised (3, 3 and 2 variants). Measured on an M-series
# Mac, OTP 29, Elixir 1.20, best of 3, 1080p RGB frame (6.2 MB); the variants
# are timed with IMAGE_OPS_VARIANTS=1 elixir examples/image_ops.exs, which also
# checks every variant against the kernel (all bit-exact):
#
#   resize 1920x1080 -> 480x270 RGB
#     :binary.at on the whole frame, binary comprehension    42-43 ms
#     binary_part source rows, hoisted per row, iodata rows  17.6-18.4 ms  <- reported
#     horizontal pass per source row into lists, zip         32-33 ms
#     defk                                                    1.4-1.5 ms    (~12x)
#   rgb_to_yuv420, 1080p
#     comprehension for Y, :binary.at for 4-pixel chroma     103-107 ms
#     row pairs walked with binary patterns, Y and UV lists  176 ms
#     comprehension for Y + row-pair binary-pattern chroma   55-70 ms         <- reported
#     defk                                                    4.0-4.3 ms    (~14-18x)
#   dither_fs, 1080p gray
#     rolling error lists (no random access)                  124-149 ms        <- reported
#     error rows as maps (Map.update)                         1650 ms
#     defk                                                    5.9 ms        (~21-26x)
#
# Not tried: Nx (binary backend or EXLA), a two-rows-at-once or
# serpentine dither on both sides, a NIF-free SIMD-ish trick such as
# processing 8 bytes per match. Verdict on all three is `good` against the
# ticket's "good vs pure Elixir" expectation; libvips would beat the resize.
#
# Agreement: bit-exact (==) on the binaries, for all variants. The resize
# check also covers a 37x23 RGBA frame to 10x7 and an upscale.
#
# Kernel notes: no compiler divergence was hit. Nested `for` bodies with
# per-row scalars and array writes compile as written. The dither error
# buffer is written inside loops from alloc/2, as the subset requires.

Mix.install([{:defk, path: Path.expand("..", __DIR__)}])

defmodule ImageOps.Kernels do
  use Defk

  defk resize_bilinear(px :: [u8], w :: i64, h :: i64, ch :: i64, out_w :: i64, out_h :: i64) ::
         [u8] do
    if not (w > 1 and h > 1 and out_w > 1 and out_h > 1 and ch > 0 and length(px) == w * h * ch),
      do: raise(ArgumentError, "resize_bilinear: sizes must be > 1 and px w * h * ch bytes")

    out = alloc(u8, out_w * out_h * ch)

    # per output column: first source byte offset of the pixel, and the 16.16 fraction
    xo = alloc(i64, out_w)
    xf = alloc(i64, out_w)

    for x <- 0..(out_w - 1)//1 do
      fx = div(x * (w - 1) * 65536, out_w - 1)
      xo[x] = div(fx, 65536) * ch
      xf[x] = rem(fx, 65536)
    end

    for y <- 0..(out_h - 1)//1 do
      fy = div(y * (h - 1) * 65536, out_h - 1)
      y0 = div(fy, 65536)
      wy = rem(fy, 65536)
      r0 = y0 * w * ch
      r1 = min(y0 + 1, h - 1) * w * ch

      for x <- 0..(out_w - 1)//1, c <- 0..(ch - 1)//1 do
        a = xo[x] + c
        b = min(xo[x] + ch, (w - 1) * ch) + c
        wx = xf[x]
        top = px[r0 + a] * (65536 - wx) + px[r0 + b] * wx
        bot = px[r1 + a] * (65536 - wx) + px[r1 + b] * wx
        v = top * (65536 - wy) + bot * wy
        out[(y * out_w + x) * ch + c] = div(v + 2_147_483_648, 4_294_967_296)
      end
    end

    out
  end

  # BT.601: Y = ((66R + 129G + 25B + 128) >> 8) + 16, U and V likewise (+128),
  # with the negative terms offset so div/2 floors like >>.
  defk rgb_to_yuv420(px :: [u8], w :: i64, h :: i64) :: [u8] do
    if not (w > 0 and h > 0 and rem(w, 2) == 0 and rem(h, 2) == 0 and length(px) == w * h * 3),
      do: raise(ArgumentError, "rgb_to_yuv420: w and h must be even and px w * h * 3 bytes")

    cw = div(w, 2)
    ch = div(h, 2)
    out = alloc(u8, w * h + 2 * cw * ch)

    for p <- 0..(w * h - 1)//1 do
      out[p] =
        div(66 * px[3 * p] + 129 * px[3 * p + 1] + 25 * px[3 * p + 2] + 128, 256) + 16
    end

    for y <- 0..(ch - 1)//1, x <- 0..(cw - 1)//1 do
      p00 = (2 * y * w + 2 * x) * 3
      p01 = p00 + 3
      p10 = p00 + w * 3
      p11 = p10 + 3
      r = div(px[p00] + px[p01] + px[p10] + px[p11] + 2, 4)
      g = div(px[p00 + 1] + px[p01 + 1] + px[p10 + 1] + px[p11 + 1] + 2, 4)
      b = div(px[p00 + 2] + px[p01 + 2] + px[p10 + 2] + px[p11 + 2] + 2, 4)
      out[w * h + y * cw + x] = div(-38 * r - 74 * g + 112 * b + 32768 + 128, 256)
      out[w * h + cw * ch + y * cw + x] = div(112 * r - 94 * g - 18 * b + 32768 + 128, 256)
    end

    out
  end

  # Floyd-Steinberg, left to right on every row. err holds two rows of w + 2
  # entries (one pad each side): row y % 2 is the current row, the other the next.
  defk dither_fs(gray :: [u8], w :: i64, h :: i64) :: [u8] do
    if not (w > 0 and h > 0 and length(gray) == w * h),
      do: raise(ArgumentError, "dither_fs: w and h must be positive and gray w * h bytes")

    out = alloc(u8, w * h)
    err = alloc(i64, 2 * (w + 2))

    for y <- 0..(h - 1)//1 do
      cur = rem(y, 2) * (w + 2) + 1
      nxt = rem(y + 1, 2) * (w + 2) + 1

      for x <- 0..(w - 1)//1 do
        v = gray[y * w + x] + err[cur + x]
        o = if v < 128, do: 0, else: 255
        e = v - o
        out[y * w + x] = o
        err[cur + x + 1] = err[cur + x + 1] + div(e * 7, 16)
        err[nxt + x - 1] = err[nxt + x - 1] + div(e * 3, 16)
        err[nxt + x] = err[nxt + x] + div(e * 5, 16)
        err[nxt + x + 1] = err[nxt + x + 1] + div(e, 16)
      end

      # the current row is done: clear it, it becomes the row after next
      for x <- -1..w//1 do
        err[cur + x] = 0
      end
    end

    out
  end
end

defmodule ImageOps.Elixir do
  # ---- resize: shared column table -------------------------------------
  defp cols(w, out_w, ch) do
    for x <- 0..(out_w - 1) do
      fx = div(x * (w - 1) * 65536, out_w - 1)
      {div(fx, 65536) * ch, rem(fx, 65536)}
    end
  end

  @half 2_147_483_648

  # variant 1: :binary.at/2 on the whole frame, binary comprehension
  def resize_at(px, w, h, ch, out_w, out_h) do
    ct = cols(w, out_w, ch) |> List.to_tuple()

    for y <- 0..(out_h - 1), x <- 0..(out_w - 1), c <- 0..(ch - 1), into: <<>> do
      fy = div(y * (h - 1) * 65536, out_h - 1)
      y0 = div(fy, 65536)
      wy = rem(fy, 65536)
      r0 = y0 * w * ch
      r1 = min(y0 + 1, h - 1) * w * ch
      {xo, wx} = elem(ct, x)
      a = xo + c
      b = min(xo + ch, (w - 1) * ch) + c

      top = :binary.at(px, r0 + a) * (65536 - wx) + :binary.at(px, r0 + b) * wx
      bot = :binary.at(px, r1 + a) * (65536 - wx) + :binary.at(px, r1 + b) * wx
      <<div(top * (65536 - wy) + bot * wy + @half, 4_294_967_296)>>
    end
  end

  # variant 2: per output row, the two source rows cut out with binary_part,
  # per-row hoisting, rows collected as iodata
  def resize_rows(px, w, h, ch, out_w, out_h) do
    cl = cols(w, out_w, ch)
    stride = w * ch
    last = (w - 1) * ch

    rows =
      for y <- 0..(out_h - 1) do
        fy = div(y * (h - 1) * 65536, out_h - 1)
        y0 = div(fy, 65536)
        wy = rem(fy, 65536)
        row0 = binary_part(px, y0 * stride, stride)
        row1 = binary_part(px, min(y0 + 1, h - 1) * stride, stride)

        for {xo, wx} <- cl, c <- 0..(ch - 1), into: <<>> do
          a = xo + c
          b = min(xo + ch, last) + c
          top = :binary.at(row0, a) * (65536 - wx) + :binary.at(row0, b) * wx
          bot = :binary.at(row1, a) * (65536 - wx) + :binary.at(row1, b) * wx
          <<div(top * (65536 - wy) + bot * wy + @half, 4_294_967_296)>>
        end
      end

    IO.iodata_to_binary(rows)
  end

  # variant 3: horizontal pass per source row into a list of unrounded blends
  # (cached for the two source rows), then a zip for the vertical blend
  def resize_hpass(px, w, h, ch, out_w, out_h) do
    cl = cols(w, out_w, ch)
    stride = w * ch
    last = (w - 1) * ch

    hpass = fn y ->
      row = binary_part(px, y * stride, stride)

      for {xo, wx} <- cl, c <- 0..(ch - 1) do
        :binary.at(row, xo + c) * (65536 - wx) + :binary.at(row, min(xo + ch, last) + c) * wx
      end
    end

    rows =
      for y <- 0..(out_h - 1) do
        fy = div(y * (h - 1) * 65536, out_h - 1)
        y0 = div(fy, 65536)
        wy = rem(fy, 65536)
        top = hpass.(y0)
        bot = hpass.(min(y0 + 1, h - 1))

        for {t, b} <- Enum.zip(top, bot), into: <<>> do
          <<div(t * (65536 - wy) + b * wy + @half, 4_294_967_296)>>
        end
      end

    IO.iodata_to_binary(rows)
  end

  # ---- YUV420 -------------------------------------------------------------
  defp check_even!(w, h, px) do
    if rem(w, 2) != 0 or rem(h, 2) != 0 or byte_size(px) != w * h * 3,
      do: raise(ArgumentError, "bad size")
  end

  # variant 1: binary comprehension for Y; chroma by :binary.at on 4 pixels
  def yuv_at(px, w, h) do
    check_even!(w, h, px)
    cw = div(w, 2)
    ch = div(h, 2)
    ys = for <<r, g, b <- px>>, into: <<>>, do: <<div(66 * r + 129 * g + 25 * b + 128, 256) + 16>>

    chroma =
      for y <- 0..(ch - 1), x <- 0..(cw - 1) do
        p00 = (2 * y * w + 2 * x) * 3
        p10 = p00 + w * 3
        at = &:binary.at(px, &1)
        r = div(at.(p00) + at.(p00 + 3) + at.(p10) + at.(p10 + 3) + 2, 4)
        g = div(at.(p00 + 1) + at.(p00 + 4) + at.(p10 + 1) + at.(p10 + 4) + 2, 4)
        b = div(at.(p00 + 2) + at.(p00 + 5) + at.(p10 + 2) + at.(p10 + 5) + 2, 4)

        {div(-38 * r - 74 * g + 112 * b + 32768 + 128, 256),
         div(112 * r - 94 * g - 18 * b + 32768 + 128, 256)}
      end

    <<ys::binary, for({u, _} <- chroma, into: <<>>, do: <<u>>)::binary,
      for({_, v} <- chroma, into: <<>>, do: <<v>>)::binary>>
  end

  # variant 2: row pairs; match both rows' bytes pairwise with binary patterns,
  # no random access; Y per row by pattern matching too
  def yuv_rows(px, w, h) do
    check_even!(w, h, px)
    stride = w * 3

    {ys, us, vs} =
      for y2 <- 0..(div(h, 2) - 1), reduce: {[], [], []} do
        {ys, us, vs} ->
          r0 = binary_part(px, 2 * y2 * stride, stride)
          r1 = binary_part(px, (2 * y2 + 1) * stride, stride)
          {y0, y1, u, v} = pairs(r0, r1, [], [], [], [])
          {[y1, y0 | ys], [u | us], [v | vs]}
      end

    IO.iodata_to_binary([Enum.reverse(ys), Enum.reverse(us), Enum.reverse(vs)])
  end

  # variant 3: Y by a binary comprehension (as variant 1), chroma by walking
  # row pairs with binary patterns (no random access, no Y in the walk)
  def yuv_mixed(px, w, h) do
    check_even!(w, h, px)
    stride = w * 3
    ys = for <<r, g, b <- px>>, into: <<>>, do: <<luma(r, g, b)>>

    {us, vs} =
      for y2 <- 0..(div(h, 2) - 1), reduce: {[], []} do
        {us, vs} ->
          {u, v} =
            chroma(
              binary_part(px, 2 * y2 * stride, stride),
              binary_part(px, (2 * y2 + 1) * stride, stride),
              [],
              []
            )

          {[u | us], [v | vs]}
      end

    IO.iodata_to_binary([ys, Enum.reverse(us), Enum.reverse(vs)])
  end

  defp chroma(
         <<ra, ga, ba, rb, gb, bb, t0::binary>>,
         <<rc, gc, bc, rd, gd, bd, t1::binary>>,
         u,
         v
       ) do
    r = div(ra + rb + rc + rd + 2, 4)
    g = div(ga + gb + gc + gd + 2, 4)
    b = div(ba + bb + bc + bd + 2, 4)

    chroma(
      t0,
      t1,
      [div(-38 * r - 74 * g + 112 * b + 32768 + 128, 256) | u],
      [div(112 * r - 94 * g - 18 * b + 32768 + 128, 256) | v]
    )
  end

  defp chroma(<<>>, <<>>, u, v), do: {Enum.reverse(u), Enum.reverse(v)}

  defp luma(r, g, b), do: div(66 * r + 129 * g + 25 * b + 128, 256) + 16

  defp pairs(
         <<ra, ga, ba, rb, gb, bb, t0::binary>>,
         <<rc, gc, bc, rd, gd, bd, t1::binary>>,
         y0,
         y1,
         u,
         v
       ) do
    r = div(ra + rb + rc + rd + 2, 4)
    g = div(ga + gb + gc + gd + 2, 4)
    b = div(ba + bb + bc + bd + 2, 4)

    pairs(
      t0,
      t1,
      [luma(rb, gb, bb), luma(ra, ga, ba) | y0],
      [luma(rd, gd, bd), luma(rc, gc, bc) | y1],
      [div(-38 * r - 74 * g + 112 * b + 32768 + 128, 256) | u],
      [div(112 * r - 94 * g - 18 * b + 32768 + 128, 256) | v]
    )
  end

  defp pairs(<<>>, <<>>, y0, y1, u, v),
    do: {Enum.reverse(y0), Enum.reverse(y1), Enum.reverse(u), Enum.reverse(v)}

  # ---- dither ---------------------------------------------------------------
  # variant 1: rolling error list per row. A row consumes its error list and
  # builds the next row's list; no random access at all.
  def dither_lists(gray, w, h) do
    zero = List.duplicate(0, w)

    {rows, _} =
      for y <- 0..(h - 1), reduce: {[], zero} do
        {acc, errs} ->
          row = binary_part(gray, y * w, w)
          {out, next} = frow(row, errs, 0, 0, 0, [], [])
          {[out | acc], next}
      end

    rows |> Enum.reverse() |> IO.iodata_to_binary()
  end

  # carry: error pushed right; last: previous pixel's error; partial: next[x-1]
  # so far (everything but the 3/16 of this pixel's error). `next` starts with a
  # dummy element for x = -1, dropped at the end.
  defp frow(<<g, grest::binary>>, [e0 | erest], carry, last, partial, out, next) do
    v = g + e0 + carry
    o = if v < 128, do: 0, else: 255
    e = v - o

    frow(
      grest,
      erest,
      div(e * 7, 16),
      e,
      div(last, 16) + div(e * 5, 16),
      [o | out],
      [partial + div(e * 3, 16) | next]
    )
  end

  defp frow(<<>>, [], _carry, _last, partial, out, next),
    do: {Enum.reverse(out), tl(Enum.reverse([partial | next]))}

  # variant 2: the error rows as maps keyed by x (random access, Map.update)
  def dither_maps(gray, w, h) do
    {rows, _} =
      for y <- 0..(h - 1), reduce: {[], %{}} do
        {acc, cur} ->
          row = binary_part(gray, y * w, w)

          {out, _, next} =
            for x <- 0..(w - 1), reduce: {[], cur, %{}} do
              {out, cur, next} ->
                v = :binary.at(row, x) + Map.get(cur, x, 0)
                o = if v < 128, do: 0, else: 255
                e = v - o

                {[o | out], Map.update(cur, x + 1, div(e * 7, 16), &(&1 + div(e * 7, 16))),
                 next
                 |> Map.update(x - 1, div(e * 3, 16), &(&1 + div(e * 3, 16)))
                 |> Map.update(x, div(e * 5, 16), &(&1 + div(e * 5, 16)))
                 |> Map.update(x + 1, div(e, 16), &(&1 + div(e, 16)))}
            end

          {[Enum.reverse(out) | acc], next}
      end

    rows |> Enum.reverse() |> IO.iodata_to_binary()
  end
end

{w, h} = {1920, 1080}
{ow, oh} = {480, 270}
# synthetic 1080p RGB frame: gradients plus a checkerboard, so there are edges
rgb =
  for y <- 0..(h - 1), x <- 0..(w - 1), into: <<>> do
    c = if rem(div(x, 40) + div(y, 40), 2) == 0, do: 200, else: 30
    <<rem(x, 256), rem(y, 256), c>>
  end

# the same frame as gray, what a dithering caller would hold
gray = for <<r, g, b <- rgb>>, into: <<>>, do: <<div(77 * r + 150 * g + 29 * b, 256)>>

IO.puts("frame #{byte_size(rgb)} bytes, gray #{byte_size(gray)} bytes")

if System.get_env("IMAGE_OPS_VARIANTS") do
  time = fn label, f ->
    best =
      Enum.min(
        for _ <- 1..3,
            do:
              (
                :erlang.garbage_collect()
                elem(:timer.tc(f), 0)
              )
      )

    IO.puts("  #{String.pad_trailing(label, 22)} #{Float.round(best / 1000, 1)} ms")
  end

  time.("resize at", fn -> ImageOps.Elixir.resize_at(rgb, w, h, 3, ow, oh) end)
  time.("resize rows", fn -> ImageOps.Elixir.resize_rows(rgb, w, h, 3, ow, oh) end)
  time.("resize hpass", fn -> ImageOps.Elixir.resize_hpass(rgb, w, h, 3, ow, oh) end)
  time.("resize defk", fn -> ImageOps.Kernels.resize_bilinear(rgb, w, h, 3, ow, oh) end)
  time.("yuv at", fn -> ImageOps.Elixir.yuv_at(rgb, w, h) end)
  time.("yuv rows", fn -> ImageOps.Elixir.yuv_rows(rgb, w, h) end)
  time.("yuv mixed", fn -> ImageOps.Elixir.yuv_mixed(rgb, w, h) end)
  time.("yuv defk", fn -> ImageOps.Kernels.rgb_to_yuv420(rgb, w, h) end)
  time.("dither lists", fn -> ImageOps.Elixir.dither_lists(gray, w, h) end)
  time.("dither maps", fn -> ImageOps.Elixir.dither_maps(gray, w, h) end)
  time.("dither defk", fn -> ImageOps.Kernels.dither_fs(gray, w, h) end)

  IO.inspect(
    {ImageOps.Elixir.resize_at(rgb, w, h, 3, ow, oh) ==
       ImageOps.Kernels.resize_bilinear(rgb, w, h, 3, ow, oh),
     ImageOps.Elixir.resize_rows(rgb, w, h, 3, ow, oh) ==
       ImageOps.Kernels.resize_bilinear(rgb, w, h, 3, ow, oh),
     ImageOps.Elixir.resize_hpass(rgb, w, h, 3, ow, oh) ==
       ImageOps.Kernels.resize_bilinear(rgb, w, h, 3, ow, oh),
     ImageOps.Elixir.yuv_at(rgb, w, h) == ImageOps.Kernels.rgb_to_yuv420(rgb, w, h),
     ImageOps.Elixir.yuv_rows(rgb, w, h) == ImageOps.Kernels.rgb_to_yuv420(rgb, w, h),
     ImageOps.Elixir.yuv_mixed(rgb, w, h) == ImageOps.Kernels.rgb_to_yuv420(rgb, w, h),
     ImageOps.Elixir.dither_lists(gray, w, h) == ImageOps.Kernels.dither_fs(gray, w, h),
     ImageOps.Elixir.dither_maps(gray, w, h) == ImageOps.Kernels.dither_fs(gray, w, h)}
  )
end

small = for i <- 0..(37 * 23 * 4 - 1), into: <<>>, do: <<rem(i * 31 + div(i, 7), 256)>>

resize_ok = fn ->
  ImageOps.Elixir.resize_rows(rgb, w, h, 3, ow, oh) ==
    ImageOps.Kernels.resize_bilinear(rgb, w, h, 3, ow, oh) and
    ImageOps.Elixir.resize_at(small, 37, 23, 4, 10, 7) ==
      ImageOps.Kernels.resize_bilinear(small, 37, 23, 4, 10, 7) and
    ImageOps.Elixir.resize_rows(small, 37, 23, 4, 80, 50) ==
      ImageOps.Kernels.resize_bilinear(small, 37, 23, 4, 80, 50)
end

# mix defk.examples takes the first DEFK_RESULT line, so resize is reported first
Defk.Bench.report(
  name: "image_resize",
  expected: :good,
  baseline: :optimized,
  runs: 3,
  elixir: fn -> ImageOps.Elixir.resize_rows(rgb, w, h, 3, ow, oh) end,
  defk: fn -> ImageOps.Kernels.resize_bilinear(rgb, w, h, 3, ow, oh) end,
  check: resize_ok,
  reason:
    "fixed-point bilinear over raw bytes; Elixir pays per-sample binary reads and tuple/list work (libvips not measured)"
)

Defk.Bench.report(
  name: "image_yuv420",
  expected: :good,
  baseline: :optimized,
  runs: 3,
  elixir: fn -> ImageOps.Elixir.yuv_mixed(rgb, w, h) end,
  defk: fn -> ImageOps.Kernels.rgb_to_yuv420(rgb, w, h) end,
  check: fn ->
    ImageOps.Elixir.yuv_mixed(rgb, w, h) == ImageOps.Kernels.rgb_to_yuv420(rgb, w, h)
  end,
  reason: "per-pixel integer maths on packed bytes, planar output in one allocation"
)

Defk.Bench.report(
  name: "image_dither",
  expected: :good,
  baseline: :optimized,
  runs: 3,
  elixir: fn -> ImageOps.Elixir.dither_lists(gray, w, h) end,
  defk: fn -> ImageOps.Kernels.dither_fs(gray, w, h) end,
  check: fn ->
    ImageOps.Elixir.dither_lists(gray, w, h) == ImageOps.Kernels.dither_fs(gray, w, h)
  end,
  reason: "serial error diffusion with an i64 error row; Elixir threads the error through lists"
)
