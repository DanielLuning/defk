# Elixir mode at small sizes: could the generated Elixir ever be the fast
# side of a kernel below the crossover? Each kernel is timed three ways at
# 16 B to 1 KiB: the native kernel, its Elixir mode (`__defk_elixir__/2`)
# and the optimised Elixir baseline of its example. Two read-only kernels
# (xxh64 and SipHash-2-4 from examples/hashes.exs: no array writes, the
# best case for Elixir mode) and one that allocates and writes its output
# (ws_mask from examples/ws_masking.exs; a write is a binary copy in Elixir
# mode). docs/performance.md 5.14.
#
#   mix run bench/elixir_mode.exs [rounds]
#
# Each row is the median over the rounds of (ns per call over n calls),
# rounds interleaved; the three sides of a size run in the same round.
# Other processes' CPU is printed before each block (Defk.Bench.other_cpu/0):
# at most one core counts as quiet. Elixir mode's numbers are an
# exploration, never a baseline (Defk.ElixirMode).
rounds = String.to_integer(List.first(System.argv()) || "7")
n = 20_000

defmodule EM.Kernels do
  use Defk, elixir_mode: true

  # ---- xxh64 (examples/hashes.exs) ----------------------------------------
  @xp1 Defk.Bits.wrap64(0x9E3779B185EBCA87)
  @xp2 Defk.Bits.wrap64(0xC2B2AE3D27D4EB4F)
  @xp3 0x165667B19E3779F9
  @xp4 Defk.Bits.wrap64(0x85EBCA77C2B2AE63)
  @xp5 0x27D4EB2F165667C5

  defk(rotl1(x :: i64) :: i64, do: bor(wrap64(bsl(x, 1)), band(bsr(x, 63), 0x1)))
  defk(rotl7(x :: i64) :: i64, do: bor(wrap64(bsl(x, 7)), band(bsr(x, 57), 0x7F)))
  defk(rotl11(x :: i64) :: i64, do: bor(wrap64(bsl(x, 11)), band(bsr(x, 53), 0x7FF)))
  defk(rotl12(x :: i64) :: i64, do: bor(wrap64(bsl(x, 12)), band(bsr(x, 52), 0xFFF)))
  defk(rotl18(x :: i64) :: i64, do: bor(wrap64(bsl(x, 18)), band(bsr(x, 46), 0x3FFFF)))
  defk(rotl23(x :: i64) :: i64, do: bor(wrap64(bsl(x, 23)), band(bsr(x, 41), 0x7FFFFF)))
  defk(rotl27(x :: i64) :: i64, do: bor(wrap64(bsl(x, 27)), band(bsr(x, 37), 0x7FFFFFF)))
  defk(rotl31(x :: i64) :: i64, do: bor(wrap64(bsl(x, 31)), band(bsr(x, 33), 0x7FFFFFFF)))
  defk(rotl13(x :: i64) :: i64, do: bor(wrap64(bsl(x, 13)), band(bsr(x, 51), 0x1FFF)))
  defk(rotl16(x :: i64) :: i64, do: bor(wrap64(bsl(x, 16)), band(bsr(x, 48), 0xFFFF)))
  defk(rotl17(x :: i64) :: i64, do: bor(wrap64(bsl(x, 17)), band(bsr(x, 47), 0x1FFFF)))
  defk(rotl21(x :: i64) :: i64, do: bor(wrap64(bsl(x, 21)), band(bsr(x, 43), 0x1FFFFF)))
  defk(rotl32(x :: i64) :: i64, do: bor(wrap64(bsl(x, 32)), band(bsr(x, 32), 0xFFFFFFFF)))
  defk(shr33(x :: i64) :: i64, do: band(bsr(x, 33), 0x7FFFFFFF))
  defk(shr29(x :: i64) :: i64, do: band(bsr(x, 29), 0x7FFFFFFFF))
  defk(shr32(x :: i64) :: i64, do: band(bsr(x, 32), 0xFFFFFFFF))

  defk(xround(acc :: i64, lane :: i64) :: i64,
    do: wrap64(rotl31(wrap64(acc + lane * @xp2)) * @xp1)
  )

  defk(xmerge(h :: i64, v :: i64) :: i64, do: wrap64(bxor(h, xround(0, v)) * @xp1 + @xp4))

  defk xxh64(b :: [u8], seed :: i64) :: i64 do
    n = length(b)
    stop = n
    body = n - rem(n, 32)

    h =
      if n >= 32 do
        {v1, v2, v3, v4} =
          for i <- 0..(body - 32)//32,
              reduce: {wrap64(seed + @xp1 + @xp2), wrap64(seed + @xp2), seed, wrap64(seed - @xp1)} do
            {v1, v2, v3, v4} ->
              {xround(v1, u64_le(b, i)), xround(v2, u64_le(b, i + 8)),
               xround(v3, u64_le(b, i + 16)), xround(v4, u64_le(b, i + 24))}
          end

        h = wrap64(rotl1(v1) + rotl7(v2) + rotl12(v3) + rotl18(v4))
        xmerge(xmerge(xmerge(xmerge(h, v1), v2), v3), v4)
      else
        wrap64(seed + @xp5)
      end

    h = wrap64(h + n)
    words = stop - rem(stop - body, 8)

    h =
      for i <- body..(words - 8)//8, reduce: h do
        h -> wrap64(rotl27(bxor(h, xround(0, u64_le(b, i)))) * @xp1 + @xp4)
      end

    tail4 = stop - words >= 4

    h =
      if tail4,
        do: wrap64(rotl23(bxor(h, wrap64(u32_le(b, words) * @xp1))) * @xp2 + @xp3),
        else: h

    p = if tail4, do: words + 4, else: words

    h =
      for i <- p..(stop - 1)//1, reduce: h do
        h -> wrap64(rotl11(bxor(h, wrap64(b[i] * @xp5))) * @xp1)
      end

    h = wrap64(bxor(h, shr33(h)) * @xp2)
    h = wrap64(bxor(h, shr29(h)) * @xp3)
    bxor(h, shr32(h))
  end

  # ---- SipHash-2-4 (examples/hashes.exs) ----------------------------------
  defk le_bytes(b :: [u8], from :: i64, to :: i64) :: i64 do
    for i <- (to - 1)..from//-1, reduce: 0 do
      acc -> bor(bsl(acc, 8), b[i])
    end
  end

  defk siphash24(b :: [u8], k0 :: i64, k1 :: i64) :: i64 do
    n = length(b)
    words = n - rem(n, 8)
    last = bor(wrap64(bsl(band(n, 255), 56)), le_bytes(b, words, n))

    {v0, v1, v2, v3} =
      for i <- 0..words//8,
          reduce:
            {bxor(k0, 0x736F6D6570736575), bxor(k1, 0x646F72616E646F6D),
             bxor(k0, 0x6C7967656E657261), bxor(k1, 0x7465646279746573)} do
        {v0, v1, v2, v3} ->
          m = if i < words, do: u64_le(b, i), else: last
          v3 = bxor(v3, m)
          v0 = wrap64(v0 + v1)
          v1 = bxor(rotl13(v1), v0)
          v0 = rotl32(v0)
          v2 = wrap64(v2 + v3)
          v3 = bxor(rotl16(v3), v2)
          v0 = wrap64(v0 + v3)
          v3 = bxor(rotl21(v3), v0)
          v2 = wrap64(v2 + v1)
          v1 = bxor(rotl17(v1), v2)
          v2 = rotl32(v2)
          v0 = wrap64(v0 + v1)
          v1 = bxor(rotl13(v1), v0)
          v0 = rotl32(v0)
          v2 = wrap64(v2 + v3)
          v3 = bxor(rotl16(v3), v2)
          v0 = wrap64(v0 + v3)
          v3 = bxor(rotl21(v3), v0)
          v2 = wrap64(v2 + v1)
          v1 = bxor(rotl17(v1), v2)
          v2 = rotl32(v2)
          {bxor(v0, m), v1, v2, v3}
      end

    {v0, v1, v2, v3} =
      for _ <- 1..4, reduce: {v0, v1, bxor(v2, 0xFF), v3} do
        {v0, v1, v2, v3} ->
          v0 = wrap64(v0 + v1)
          v1 = bxor(rotl13(v1), v0)
          v0 = rotl32(v0)
          v2 = wrap64(v2 + v3)
          v3 = bxor(rotl16(v3), v2)
          v0 = wrap64(v0 + v3)
          v3 = bxor(rotl21(v3), v0)
          v2 = wrap64(v2 + v1)
          v1 = bxor(rotl17(v1), v2)
          {v0, v1, rotl32(v2), v3}
      end

    bxor(bxor(v0, v1), bxor(v2, v3))
  end

  # ---- no loop (bench/call_cost.exs, examples/poor_tiny_calls.exs) -------
  defk add(a :: i64, b :: i64) :: i64 do
    a + b
  end

  defk clamp(x :: f64, lo :: f64, hi :: f64) :: f64 do
    min(max(x, lo), hi)
  end

  # ---- ws_mask (examples/ws_masking.exs): allocates and writes ------------
  defk ws_mask(payload :: [u8], mask :: i64) :: [u8] do
    if mask < 0 or mask > 0xFFFFFFFF do
      raise ArgumentError, "mask must be a 32-bit unsigned integer"
    end

    k0 = band(bsr(mask, 24), 255)
    k1 = band(bsr(mask, 16), 255)
    k2 = band(bsr(mask, 8), 255)
    k3 = band(mask, 255)
    n = length(payload)
    out = alloc(u8, n)

    for i <- 0..(div(n, 4) - 1)//1 do
      j = 4 * i
      out[j] = bxor(payload[j], k0)
      out[j + 1] = bxor(payload[j + 1], k1)
      out[j + 2] = bxor(payload[j + 2], k2)
      out[j + 3] = bxor(payload[j + 3], k3)
    end

    for j <- (n - rem(n, 4))..(n - 1)//1 do
      out[j] = bxor(payload[j], band(bsr(mask, 24 - 8 * rem(j, 4)), 255))
    end

    out
  end
end

# ---- the optimised Elixir baselines (examples/hashes.exs, ws_masking.exs) ---

defmodule EM.XXH64 do
  import Bitwise

  @m 0xFFFFFFFFFFFFFFFF
  @p1 0x9E3779B185EBCA87
  @p2 0xC2B2AE3D27D4EB4F
  @p3 0x165667B19E3779F9
  @p4 0x85EBCA77C2B2AE63
  @p5 0x27D4EB2F165667C5

  @compile {:inline, rotl: 2, round: 2, merge: 2}

  def hash(bin, seed) do
    seed = band(seed, @m)
    n = byte_size(bin)

    {h, rest} =
      if n >= 32 do
        stripes(bin, band(seed + @p1 + @p2, @m), band(seed + @p2, @m), seed, band(seed - @p1, @m))
      else
        {band(seed + @p5, @m), bin}
      end

    h = tail(band(h + n, @m), rest)
    h = band(bxor(h, h >>> 33) * @p2, @m)
    h = band(bxor(h, h >>> 29) * @p3, @m)
    bxor(h, h >>> 32)
  end

  defp stripes(
         <<a::little-64, b::little-64, c::little-64, d::little-64, rest::binary>>,
         v1,
         v2,
         v3,
         v4
       ),
       do: stripes(rest, round(v1, a), round(v2, b), round(v3, c), round(v4, d))

  defp stripes(rest, v1, v2, v3, v4) do
    h = band(rotl(v1, 1) + rotl(v2, 7) + rotl(v3, 12) + rotl(v4, 18), @m)
    {h |> merge(v1) |> merge(v2) |> merge(v3) |> merge(v4), rest}
  end

  defp tail(h, <<k::little-64, rest::binary>>),
    do: tail(band(rotl(bxor(h, round(0, k)), 27) * @p1 + @p4, @m), rest)

  defp tail(h, <<k::little-32, rest::binary>>),
    do: tail(band(rotl(bxor(h, band(k * @p1, @m)), 23) * @p2 + @p3, @m), rest)

  defp tail(h, <<k, rest::binary>>),
    do: tail(band(rotl(bxor(h, band(k * @p5, @m)), 11) * @p1, @m), rest)

  defp tail(h, <<>>), do: h

  defp rotl(x, r), do: bor(band(x <<< r, @m), x >>> (64 - r))
  defp round(acc, lane), do: band(rotl(band(acc + lane * @p2, @m), 31) * @p1, @m)
  defp merge(h, v), do: band(bxor(h, round(0, v)) * @p1 + @p4, @m)
end

defmodule EM.SipHash do
  import Bitwise

  @m 0xFFFFFFFFFFFFFFFF

  @compile {:inline, rotl: 2, sipround: 4}

  def hash(k0, k1, bin) do
    blocks(
      bin,
      byte_size(bin),
      bxor(k0, 0x736F6D6570736575),
      bxor(k1, 0x646F72616E646F6D),
      bxor(k0, 0x6C7967656E657261),
      bxor(k1, 0x7465646279746573)
    )
  end

  defp blocks(<<m::little-64, rest::binary>>, n, v0, v1, v2, v3) do
    {v0, v1, v2, v3} = sipround(v0, v1, v2, bxor(v3, m))
    {v0, v1, v2, v3} = sipround(v0, v1, v2, v3)
    blocks(rest, n, bxor(v0, m), v1, v2, v3)
  end

  defp blocks(tail, n, v0, v1, v2, v3) do
    m = bor(band(n, 255) <<< 56, :binary.decode_unsigned(tail, :little))
    {v0, v1, v2, v3} = sipround(v0, v1, v2, bxor(v3, m))
    {v0, v1, v2, v3} = sipround(v0, v1, v2, v3)
    {v0, v1, v2, v3} = sipround(bxor(v0, m), v1, bxor(v2, 0xFF), v3)
    {v0, v1, v2, v3} = sipround(v0, v1, v2, v3)
    {v0, v1, v2, v3} = sipround(v0, v1, v2, v3)
    {v0, v1, v2, v3} = sipround(v0, v1, v2, v3)
    bxor(bxor(v0, v1), bxor(v2, v3))
  end

  defp sipround(v0, v1, v2, v3) do
    v0 = band(v0 + v1, @m)
    v1 = bxor(rotl(v1, 13), v0)
    v0 = rotl(v0, 32)
    v2 = band(v2 + v3, @m)
    v3 = bxor(rotl(v3, 16), v2)
    v0 = band(v0 + v3, @m)
    v3 = bxor(rotl(v3, 21), v0)
    v2 = band(v2 + v1, @m)
    v1 = bxor(rotl(v1, 17), v2)
    {v0, v1, rotl(v2, 32), v3}
  end

  defp rotl(x, r), do: bor(band(x <<< r, @m), x >>> (64 - r))
end

defmodule EM.Ws do
  import Bitwise

  # ws_masking's baseline: the 32-bit loop (Bandit's shape) below 512 B,
  # :crypto.exor/2 with a doubled key from there
  @threshold 512
  def hybrid(p, m) when byte_size(p) < @threshold, do: b32(p, m, <<>>)
  def hybrid(p, m), do: :crypto.exor(p, key(<<m::32>>, byte_size(p)))

  defp b32(<<h::32, r::binary>>, m, acc), do: b32(r, m, <<acc::binary, bxor(h, m)::32>>)
  defp b32(<<>>, _, acc), do: acc
  defp b32(rest, m, acc), do: <<acc::binary, tail(rest, m)::bitstring>>

  defp tail(rest, m) do
    s = bit_size(rest)
    <<h::size(^s)>> = rest
    <<mm::size(^s), _::bitstring>> = <<m::32>>
    <<bxor(h, mm)::size(s)>>
  end

  defp key(k, n) when byte_size(k) >= n, do: binary_part(k, 0, n)
  defp key(k, n), do: key(<<k::binary, k::binary>>, n)
end

# ---- the measurement ---------------------------------------------------------

defmodule EM.Time do
  def loop(_f, 0), do: :ok

  def loop(f, k) do
    f.()
    loop(f, k - 1)
  end

  def ns(f, n) do
    {us, _} = :timer.tc(fn -> loop(f, n) end)
    us * 1000 / n
  end

  def median(l), do: Enum.at(Enum.sort(l), div(length(l), 2))

  def fmt(ns) when ns < 10_000, do: :erlang.float_to_binary(ns * 1.0, decimals: 0) <> " ns"
  def fmt(ns), do: :erlang.float_to_binary(ns / 1000, decimals: 1) <> " us"

  # interleaved: each round runs every row of every size once
  def block(title, sizes, rows, n, rounds) do
    IO.puts("\n#{title}  (other CPU: #{Float.round(Defk.Bench.other_cpu() * 1.0, 2)} cores)")

    IO.puts(
      "  #{String.pad_trailing("size", 8)}#{Enum.map_join(rows, fn {name, _} -> String.pad_leading(name, 16) end)}   mode/kernel  mode/Elixir"
    )

    res =
      for _ <- 1..rounds, {size, input} <- sizes, {name, f} <- rows, reduce: %{} do
        acc ->
          Map.update(
            acc,
            {size, name},
            [ns(fn -> f.(input) end, n)],
            &[ns(fn -> f.(input) end, n) | &1]
          )
      end

    for {size, _} <- sizes do
      meds = for {name, _} <- rows, do: median(res[{size, name}])
      [kernel, mode, elixir] = meds

      IO.puts(
        "  #{String.pad_trailing(if(is_integer(size), do: "#{size} B", else: size), 8)}#{Enum.map_join(meds, &String.pad_leading(fmt(&1), 16))}   #{String.pad_leading(:erlang.float_to_binary(mode / kernel, decimals: 1) <> "x", 11)}  #{String.pad_leading(:erlang.float_to_binary(mode / elixir, decimals: 1) <> "x", 11)}"
      )
    end
  end
end

:rand.seed(:exsss, {7, 8, 9})
sizes = for s <- [1, 8, 16, 64, 256, 1024], do: {s, :crypto.strong_rand_bytes(s)}
seed = 0x1234_5678
k0 = 0x0706050403020100
k1 = 0x0F0E0D0C0B0A0908
mask = 0x37FA213D

# agreement first: the three sides give the same answer on every input
for {_, b} <- sizes do
  u = &Bitwise.band(&1, 0xFFFFFFFFFFFFFFFF)
  x = EM.Kernels.xxh64(b, seed)
  ^x = EM.Kernels.__defk_elixir__(:xxh64, [b, seed])
  true = u.(x) == EM.XXH64.hash(b, seed)
  s = EM.Kernels.siphash24(b, k0, k1)
  ^s = EM.Kernels.__defk_elixir__(:siphash24, [b, k0, k1])
  true = u.(s) == EM.SipHash.hash(k0, k1, b)
  w = EM.Kernels.ws_mask(b, mask)
  ^w = EM.Kernels.__defk_elixir__(:ws_mask, [b, mask])
  ^w = EM.Ws.hybrid(b, mask)
end

IO.puts("#{rounds} rounds x #{n} calls per cell, median; mode = the kernel's Elixir mode")

EM.Time.block(
  "xxh64 (read-only)",
  sizes,
  [
    {"kernel", &EM.Kernels.xxh64(&1, seed)},
    {"Elixir mode", &EM.Kernels.__defk_elixir__(:xxh64, [&1, seed])},
    {"Elixir (opt.)", &EM.XXH64.hash(&1, seed)}
  ],
  n,
  rounds
)

EM.Time.block(
  "siphash24 (read-only)",
  sizes,
  [
    {"kernel", &EM.Kernels.siphash24(&1, k0, k1)},
    {"Elixir mode", &EM.Kernels.__defk_elixir__(:siphash24, [&1, k0, k1])},
    {"Elixir (opt.)", &EM.SipHash.hash(k0, k1, &1)}
  ],
  n,
  rounds
)

EM.Time.block(
  "ws_mask (alloc + writes)",
  sizes,
  [
    {"kernel", &EM.Kernels.ws_mask(&1, mask)},
    {"Elixir mode", &EM.Kernels.__defk_elixir__(:ws_mask, [&1, mask])},
    {"Elixir (opt.)", &EM.Ws.hybrid(&1, mask)}
  ],
  n,
  rounds
)

# kernels without a loop: the call is the cost (docs/performance.md 5.13),
# so this is where Elixir mode would have its best chance against the kernel
defmodule EM.Scalar do
  def add(a, b), do: a + b
  def clamp(x, lo, hi), do: min(max(x, lo), hi)
end

7 = EM.Kernels.add(3, 4)
7 = EM.Kernels.__defk_elixir__(:add, [3, 4])
2.5 = EM.Kernels.clamp(2.5, 1.0, 3.0)
2.5 = EM.Kernels.__defk_elixir__(:clamp, [2.5, 1.0, 3.0])

EM.Time.block(
  "no loop (scalars in, scalar out)",
  [{"add", {3, 4}}, {"clamp", {2.5, 1.0, 3.0}}],
  [
    {"kernel",
     fn
       {a, b} -> EM.Kernels.add(a, b)
       {x, lo, hi} -> EM.Kernels.clamp(x, lo, hi)
     end},
    {"Elixir mode",
     fn
       {a, b} -> EM.Kernels.__defk_elixir__(:add, [a, b])
       {x, lo, hi} -> EM.Kernels.__defk_elixir__(:clamp, [x, lo, hi])
     end},
    {"Elixir (opt.)",
     fn
       {a, b} -> EM.Scalar.add(a, b)
       {x, lo, hi} -> EM.Scalar.clamp(x, lo, hi)
     end}
  ],
  n * 10,
  rounds
)
