# ws_masking: WebSocket frame masking (RFC 6455 5.3), as Bandit does it, against
# bandit_native's Rust NIF
#
# The job: every frame a browser sends to a WebSocket server is XORed with a
# fresh 32-bit key, and the server undoes it (masking is an involution) before
# it looks at the payload. Bandit 1.12.5 does it in
# Bandit.PrimitiveOps.WebSocket.ws_mask/2, 32 bits at a time with a binary
# append, and lets you swap the implementation: `websocket_options:
# [primitive_ops_module: Mod]`, where Mod implements that module's one
# callback, ws_mask/2 (read in the dep source: Bandit.WebSocket.Handler takes
# the option, Bandit.WebSocket.Frame calls `primitive_ops_module.ws_mask/2` on
# every client frame). The defk kernel here is that callback, `Ws.Defk`.
#
# The NIF column: bandit_native 0.1.2 (January 2023, MIT, Rust via rustler,
# precompiled for aarch64-apple-darwin and downloaded by rustler_precompiled, so
# it built and loaded here with no Rust toolchain involved). Design, read in
# native/bandit_native/src/lib.rs: Bandit.Native.mask/2 copies the payload into
# an owned binary and XORs it one byte at a time with `mask_bytes[i % 4]`, on a
# normal scheduler (no dirty flag, no yielding), so a big frame blocks its
# scheduler for the whole call. The package is two years older than Bandit
# 1.12.5 and is not used by current Bandit (its default is the Elixir above;
# the package also wraps simdutf8, see utf8_valid.exs). `Ws.Nif` is the obvious
# adapter that makes it a primitive_ops_module.
#
# Why people reach for a NIF here: masking touches every byte of every
# incoming frame, and the BEAM binary loop is far from memory speed.
# Expected verdict: marginal at the realistic size, good at large frames (see
# the results).
#
#   elixir examples/ws_masking.exs                # agreement + reports
#   WS_VARIANTS=1 elixir examples/ws_masking.exs  # also every Elixir variant
#
# Realistic size (declared before any numbers): 125-byte frames. That is the
# largest payload with the 7-bit length field (126 and 127 mean an extended
# length): chat messages, ticks, presence and control traffic. The timed job
# is 10,000 frames of 125 B, each its own sub-binary of one receive buffer
# with its own mask, one ws_mask/2 call each. The other size is 1 MiB frames
# (8 per run; file chunks, binary blobs). The sweep goes 125 B, 1 KiB, 8 KiB,
# 64 KiB, 1 MiB, 16 MiB, each timed over ~8 MiB of frames (at most 10,000
# frames), and reports the crossover. Responsiveness is one 16 MiB frame per
# side on one scheduler.
#
# DEFK_RESULT lines (mix defk.examples reads the first; the script checks both):
#   1. ws_masking        125 B frames, the workload verdict, with the NIF as
#                        `native`, the sweep and responsiveness
#   2. ws_masking_1mib   1 MiB frames
#
# The kernel: allocate the output, fill it four bytes per iteration from the
# four key bytes (no per-byte index arithmetic), so clang vectorises it; the
# 0..3 trailing bytes take their key byte by position. It checks the mask
# range like Bandit's guard. 32-36 GB/s from 64 KiB up, which is memory
# bandwidth, not the loop (the cost at 125 B is the call, ~0.13 us, which the
# NIF pays too).
#
# Agreement, checked on every run (a mismatch raises): the anchor, every
# Elixir variant, the kernel, the kernel's Elixir mode (`elixir_mode: true`)
# and the NIF are byte-identical to an independent byte-at-a-time reference on
# 2,187 payloads (every length 0..70, 125-128, 255, 256, 1000, 65535, 65536
# and 65541, as sub-binaries at three offsets, eight edge masks including 0,
# 0x80000000 and 0xFFFFFFFF, plus a random one); masking twice returns the
# payload; a mask outside 0..0xFFFFFFFF or a non-integer raises on the anchor,
# the kernel, its Elixir mode and the NIF (different exception types: the
# anchor fails its guard with FunctionClauseError, the others raise
# ArgumentError); and Bandit's own Frame.deserialize/2 returns equal frames
# with Bandit's module, Ws.Defk and Ws.Nif as primitive_ops_module, for 7-,
# 16- and 64-bit length frames of text, binary, ping and close. The timed
# frames of every size are checked against each other too. Not done: a live
# Bandit server with a WebSocket client (the deserializer above is the code
# path the option feeds).
#
# Elixir baseline: optimised. The anchor, Bandit's own ws_mask/2, is the
# first baseline; it was tried against the following (ns per frame, best of 7
# interleaved rounds, WS_VARIANTS=1, under load):
#
#                                     125 B   1 KiB   8 KiB   64 KiB    1 MiB
#   Bandit ws_mask/2 (the anchor)      184     991    6,906   55,406  926,375
#   same loop, no inner <<>> wrapper   204   1,063    7,313   57,648 1,005,875
#   64-bit words, mask repeated to     335   1,888   13,741  108,969 1,920,625
#     word width, appended
#   binary comprehension over 64-bit   373   1,775   13,202  106,992 1,844,625
#     words
#   64-bit words as a list, joined     449   3,042   25,698  221,203 3,767,000
#   whole payload and key as two       299   1,135    7,431   58,422   (minutes)
#     integers, one bxor
#   :crypto.exor/2, key from           374   1,664   12,063   95,211 1,530,000
#     :binary.copy/2
#   :crypto.exor/2, key doubled        318     720    4,195   32,313   532,125
#   hybrid: the anchor under 512 B,    184     720    4,195   32,313   532,125  <- baseline
#     :crypto.exor/2 with the doubled
#     key from there
#
# The BEAM's JIT already compiles the anchor's 32-bit append loop well (about
# 1 GB/s); 64-bit words are slower, not faster (the bigger append and the
# word-wide integers in the comprehension cost more than the halved
# iteration count). The only Elixir that beats it is :crypto.exor/2, C XOR of
# two equal-size binaries, with a key built by doubling it with memcpys
# (building the key with :binary.copy/2's 4-byte repeat costs half of the
# time): 1.4x at 1 KiB, 1.7x from 8 KiB. exor2 loses to the loop below
# ~600 B (the call and the key), so the baseline is the hybrid, with the
# threshold at 512 B (anchor 532 ns vs 575 ns at 512 B, 798 vs 662 at 768 B).
# The whole-integer variant is the anchor's speed up to 64 KiB and then
# quadratic (building a 1 MiB integer back into a binary did not finish in
# two minutes). Not tried: splitting a big frame across processes (it scales
# every side alike for frames of this kind, and kernel tasks stay on 2-3
# schedulers, defk-8qs).
#
# Results (PROVISIONAL: taken while other benchmark agents loaded the
# machine, load average ~15; the quiet-machine run is defk-sgw.4). M-series
# Mac, OTP 29, Elixir 1.20. Verdict at the realistic size, 125 B frames,
# 10,000 per run: hybrid 1.6 ms (~158 ns per frame), defk 1.3 ms (~134 ns),
# NIF 1.4 ms (~141 ns): defk 1.18x (marginal; 1.18-1.31x over four runs, sweep and
# variants table included), 1.06x over the NIF. The kernel's work at 125 B is a few ns;
# the rest is the call (~0.12 us for a kernel, about the same for a NIF), which
# the Elixir loop does not pay. Use Bandit's own loop at this size.
# The other size, 1 MiB frames, 8 per run: hybrid 4.1 ms (513 us per frame,
# 2 GB/s), defk 0.22 ms (27 us, 38 GB/s), NIF 4.4 ms (548 us, byte at a
# time): defk 18.8x over the best Elixir, 20x over the NIF (good).
# Sweep (defk over the hybrid): 125 B 1.25x, 1 KiB 4.8x, 8 KiB 9.3x, 64 KiB
# 14.3x, 1 MiB 19x, 16 MiB 22.9x; crossover at 1 KiB (the first sweep size
# where defk is at least 2x; sizes between 125 B and 1 KiB were not swept).
# Responsiveness (one scheduler, one 16 MiB frame, 1 ms ticker): Elixir max
# 2.0 ms (the ticker's floor under load), defk 0.44 ms (the whole call takes
# less than a tick, so this says the kernel is not worse, not that it
# yields), NIF 9.0 ms max and p99: the 16 MiB mask runs as one uninterrupted
# NIF call on a normal scheduler.
#
# Recommendation: for typical WebSocket traffic (frames under ~1 KiB) keep
# Bandit's default, which the BEAM already makes fast; the kernel is 1.2x
# there. For large binary frames a kernel as primitive_ops_module is 5-20x
# over the best Elixir (:crypto.exor/2 in the hybrid) and over bandit_native,
# which is byte-at-a-time and blocks its scheduler. Whether that is worth
# native code depends on how much of an app's WebSocket traffic is in large
# frames.

Mix.install([
  {:defk, path: Path.expand("..", __DIR__)},
  {:bandit, "== 1.12.5"},
  {:bandit_native, "== 0.1.2"}
])

# The plug-in point, as Bandit 1.12.5 defines it: `websocket_options:
# [primitive_ops_module: Mod]`, where Mod implements the
# Bandit.PrimitiveOps.WebSocket behaviour (one callback, ws_mask/2). Bandit's
# Frame.to_frame/7 calls `primitive_ops_module.ws_mask(payload, mask)` on
# every client frame. The kernel is that callback.
defmodule Ws.Defk do
  use Defk, elixir_mode: true

  @behaviour Bandit.PrimitiveOps.WebSocket

  # RFC 6455 5.3: payload byte i is XORed with byte (i mod 4) of the 32-bit
  # masking key, most significant byte first. The output is a fresh array of
  # the payload's size (the input is a sub-binary of the socket buffer and is
  # never written), filled four bytes per iteration with no per-byte index
  # arithmetic, so clang turns the loop into vector loads, XORs and stores;
  # the 0..3 trailing bytes take their key byte by position. The mask range
  # check mirrors Bandit's guard (`mask >= 0 and mask <= 0xFFFFFFFF`).
  @impl true
  defk ws_mask(payload :: [u8], mask :: i64) :: [u8] do
    if mask < 0 or mask > 0xFFFFFFFF do
      raise ArgumentError, "mask must be a 32-bit unsigned integer"
    end

    k0 = band(bsr(mask, 24), 255)
    k1 = band(bsr(mask, 16), 255)
    k2 = band(bsr(mask, 8), 255)
    k3 = band(mask, 255)
    n = len(payload)
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

# bandit_native as Bandit would use it: Bandit.Native.mask/2 behind the same
# behaviour (the package does not ship such a module; this is the obvious
# adapter, and what its README suggests setting as primitive_ops_module).
defmodule Ws.Nif do
  @behaviour Bandit.PrimitiveOps.WebSocket
  @impl true
  def ws_mask(payload, mask), do: Bandit.Native.mask(payload, mask)
end

defmodule Ws.Elixir do
  import Bitwise

  # The anchor: Bandit's own implementation, 32 bits at a time.
  def bandit(p, m), do: Bandit.PrimitiveOps.WebSocket.ws_mask(p, m)

  # Bandit's loop without the inner <<>> wrapper.
  def b32(p, m), do: b32(p, m, <<>>)
  defp b32(<<h::32, r::binary>>, m, acc), do: b32(r, m, <<acc::binary, bxor(h, m)::32>>)
  defp b32(<<>>, _, acc), do: acc
  defp b32(rest, m, acc), do: <<acc::binary, tail(rest, m)::bitstring>>

  # 64-bit chunks against the mask repeated to word width, the 4..7 byte
  # tail by 32-bit and then smaller steps.
  def b64(p, m), do: b64(p, m <<< 32 ||| m, m, <<>>)

  defp b64(<<h::64, r::binary>>, m64, m, acc),
    do: b64(r, m64, m, <<acc::binary, bxor(h, m64)::64>>)

  defp b64(<<h::32, r::binary>>, m64, m, acc),
    do: b64(r, m64, m, <<acc::binary, bxor(h, m)::32>>)

  defp b64(<<>>, _, _, acc), do: acc
  defp b64(rest, _, m, acc), do: <<acc::binary, tail(rest, m)::bitstring>>

  # the last 1..3 bytes: the first bits of the key
  defp tail(rest, m) do
    s = bit_size(rest)
    <<h::size(^s)>> = rest
    <<mm::size(^s), _::bitstring>> = <<m::32>>
    <<bxor(h, mm)::size(s)>>
  end

  # a binary comprehension over 64-bit words
  def comp(p, m) do
    m64 = m <<< 32 ||| m
    n8 = div(byte_size(p), 8) * 8
    <<head::binary-size(^n8), rest::binary>> = p
    for(<<w::64 <- head>>, into: <<>>, do: <<bxor(w, m64)::64>>) <> rest_mask(rest, m)
  end

  # the same, as a list of words joined at the end
  def iol(p, m) do
    m64 = m <<< 32 ||| m
    n8 = div(byte_size(p), 8) * 8
    <<head::binary-size(^n8), rest::binary>> = p
    words = for <<w::64 <- head>>, do: <<bxor(w, m64)::64>>
    IO.iodata_to_binary([words, rest_mask(rest, m)])
  end

  # after 64-bit words, the key restarts at byte 0 (8 is a multiple of 4)
  defp rest_mask(<<>>, _), do: <<>>

  defp rest_mask(rest, m) do
    s = bit_size(rest)
    <<h::size(^s)>> = rest
    <<mm::size(^s), _::bitstring>> = <<m::32, m::32>>
    <<bxor(h, mm)::size(s)>>
  end

  # the whole payload as one integer XORed with the whole key as another
  def big(p, m) do
    n = byte_size(p)
    <<bxor(:binary.decode_unsigned(p), :binary.decode_unsigned(key(<<m::32>>, n)))::size(n * 8)>>
  end

  # :crypto.exor/2 (C, XOR of two equal-size binaries) with the
  # key built by :binary.copy/2 ...
  def exor(p, m) do
    n = byte_size(p)
    :crypto.exor(p, binary_part(:binary.copy(<<m::32>>, div(n, 4) + 1), 0, n))
  end

  # ... or by doubling it (a few memcpys instead of a 4-byte repeat)
  def exor2(p, m), do: :crypto.exor(p, key(<<m::32>>, byte_size(p)))

  defp key(k, n) when byte_size(k) >= n, do: binary_part(k, 0, n)
  defp key(k, n), do: key(<<k::binary, k::binary>>, n)

  # The baseline: Bandit's loop for small frames, :crypto.exor/2 from the
  # threshold up.
  @threshold 512
  def hybrid(p, m) when byte_size(p) < @threshold, do: bandit(p, m)
  def hybrid(p, m), do: exor2(p, m)
  def threshold, do: @threshold
end

# --- agreement -------------------------------------------------------------

:rand.seed(:exsss, {12, 34, 56})

ref_bin = fn p, m ->
  # an independent reference: the key byte by byte, no shared code with any
  # side
  key = <<m::32>>

  for {b, i} <- Enum.with_index(:binary.bin_to_list(p)), into: <<>> do
    <<Bitwise.bxor(b, :binary.at(key, rem(i, 4)))>>
  end
end

sides = [
  {"Bandit (anchor)", &Ws.Elixir.bandit/2},
  {"b32", &Ws.Elixir.b32/2},
  {"b64", &Ws.Elixir.b64/2},
  {"comp", &Ws.Elixir.comp/2},
  {"iol", &Ws.Elixir.iol/2},
  {"exor", &Ws.Elixir.exor/2},
  {"exor2", &Ws.Elixir.exor2/2},
  {"hybrid", &Ws.Elixir.hybrid/2},
  {"defk", &Ws.Defk.ws_mask/2},
  {"defk (Elixir mode)", &Ws.Defk.__defk_elixir__(:ws_mask, [&1, &2])},
  {"Bandit.Native.mask (NIF)", &Ws.Nif.ws_mask/2}
]

# `big` is quadratic in the payload size (a 1 MiB payload took minutes), so
# it is checked on small payloads only
small_sides = sides ++ [{"big", &Ws.Elixir.big/2}]

edge_masks = [0, 1, 0xFF, 0x100, 0x01020304, 0x80000000, 0xA1B2C3D4, 0xFFFFFFFF]

# every length 0..70, plus the frame-size boundaries, with every edge mask;
# the payload is cut from the middle of a larger binary, at offsets 0..3, as
# a Bandit payload is a sub-binary of the receive buffer
cases =
  for len <- Enum.to_list(0..70) ++ [125, 126, 127, 128, 255, 256, 1000, 65_535, 65_536, 65_541],
      off <- [0, 1, 3],
      m <- edge_masks ++ [:rand.uniform(0x100000000) - 1] do
    buf = :rand.bytes(off + len + 5)
    {binary_part(buf, off, len), m}
  end

mismatches =
  for {p, m} <- cases,
      want = ref_bin.(p, m),
      {label, f} <- if(byte_size(p) <= 1000, do: small_sides, else: sides),
      f.(p, m) != want,
      do: {label, byte_size(p), m}

unless mismatches == [] do
  raise "agreement failed (#{length(mismatches)}), first: #{inspect(Enum.take(mismatches, 5))}"
end

# masking is its own inverse
for {p, m} <- Enum.take_every(cases, 37) do
  true = Ws.Defk.ws_mask(Ws.Defk.ws_mask(p, m), m) == p
end

# a bad mask or payload raises on every side (the exception types differ:
# Bandit's guard fails the clause, the kernel and the NIF raise their own)
bad_inputs = [{"abc", -1}, {"abc", 0x100000000}, {"abc", 1.0}, {"abc", "x"}, {:x, 1}, {[1, 2], 1}]

for {label, f} <-
      [
        {"Bandit", &Ws.Elixir.bandit/2},
        {"defk", &Ws.Defk.ws_mask/2},
        {"defk (Elixir mode)", &Ws.Defk.__defk_elixir__(:ws_mask, [&1, &2])},
        {"NIF", &Ws.Nif.ws_mask/2}
      ],
    {p, m} <- bad_inputs do
  try do
    r = f.(p, m)
    raise "#{label} accepted #{inspect({p, m})} and returned #{inspect(r)}"
  rescue
    e in [FunctionClauseError, ArgumentError] -> e
  end
end

# the plug-in point end to end: Bandit's own frame deserializer, with each
# module as primitive_ops_module, on masked client frames of every length
# class (7-bit, 16-bit and 64-bit lengths) and opcode
frame = fn opcode, payload, mask ->
  len = byte_size(payload)

  len_field =
    cond do
      len <= 125 -> <<len::7>>
      len <= 0xFFFF -> <<126::7, len::16>>
      true -> <<127::7, len::64>>
    end

  <<1::1, 0::1, 0::2, opcode::4, 1::1, len_field::bitstring, mask::32,
    ref_bin.(payload, mask)::binary>>
end

frames =
  for {op, len} <- [{1, 0}, {1, 5}, {2, 125}, {2, 126}, {9, 20}, {8, 2}, {2, 70_000}] do
    payload = :rand.bytes(len)
    {payload, frame.(op, payload, :rand.uniform(0x100000000) - 1)}
  end

for {payload, bytes} <- frames do
  {:ok, want} = Bandit.WebSocket.Frame.deserialize(bytes, Bandit.PrimitiveOps.WebSocket)

  # a close frame's data is split into code and reason by its struct; the
  # others keep the payload as is
  if is_struct(want, Bandit.WebSocket.Frame.Text) or
       is_struct(want, Bandit.WebSocket.Frame.Binary) do
    true = IO.iodata_to_binary(want.data) == payload
  end

  for mod <- [Ws.Defk, Ws.Nif] do
    {:ok, ^want} = Bandit.WebSocket.Frame.deserialize(bytes, mod)
  end
end

IO.puts(
  "agreement: #{length(cases)} payloads (lengths 0..70 and 125 B to 65541 B, sub-binaries at 3 offsets, 8 edge masks + random) on #{length(sides)} sides, the independent reference, round trip, bad inputs, and #{length(frames) * 3} Bandit frame deserializations: ok"
)

# --- data ------------------------------------------------------------------

# Frames arrive as sub-binaries of the receive buffer, each with its own
# mask. A job masks every frame of one size once; `count` frames of `size`
# bytes keeps a run at a few ms for the small sizes.
sizes = [125, 1024, 8192, 65_536, 1_048_576, 16_777_216]
count_for = fn size -> size |> then(&div(8_388_608, &1)) |> max(1) |> min(10_000) end

for size <- sizes do
  n = count_for.(size)
  buf = :rand.bytes(size * n)

  :persistent_term.put(
    {:ws_frames, size},
    for i <- 0..(n - 1) do
      {binary_part(buf, i * size, size), :rand.uniform(0x100000000) - 1}
    end
  )
end

# Keep only the last result: thousands of results held to the end would make
# every GC during the run walk them.
job = fn f, size ->
  fn ->
    Enum.reduce(:persistent_term.get({:ws_frames, size}), nil, fn {p, m}, _ -> f.(p, m) end)
  end
end

check_size = fn size ->
  frames = :persistent_term.get({:ws_frames, size})
  check = Enum.take(frames, 20)

  Enum.all?(check, fn {p, m} ->
    want = Ws.Elixir.exor2(p, m)

    Ws.Defk.ws_mask(p, m) == want and Ws.Nif.ws_mask(p, m) == want and
      Ws.Elixir.bandit(p, m) == want
  end)
end

unless Enum.all?(sizes, check_size) do
  raise "agreement failed on the timed frames"
end

if System.get_env("WS_VARIANTS") do
  # interleaved: each round runs every side once; best of 7 rounds, per frame
  IO.puts("\nper frame, ns (best of 7 interleaved rounds):")

  variant_sides =
    [
      {"Bandit (anchor)", &Ws.Elixir.bandit/2},
      {"b32", &Ws.Elixir.b32/2},
      {"b64", &Ws.Elixir.b64/2},
      {"comp", &Ws.Elixir.comp/2},
      {"iol", &Ws.Elixir.iol/2},
      {"big", &Ws.Elixir.big/2},
      {"exor", &Ws.Elixir.exor/2},
      {"exor2", &Ws.Elixir.exor2/2},
      {"defk", &Ws.Defk.ws_mask/2},
      {"NIF", &Ws.Nif.ws_mask/2}
    ]

  for size <- sizes do
    n = length(:persistent_term.get({:ws_frames, size}))
    IO.puts("  #{size} B (#{n} frames per round)")

    ss =
      Enum.reject(variant_sides, fn {l, _} ->
        (l == "big" and size > 65_536) or (l == "iol" and size > 1_048_576)
      end)

    t =
      for _ <- 1..7, {l, f} <- ss do
        :erlang.garbage_collect()
        {l, elem(:timer.tc(job.(f, size)), 0)}
      end

    for {l, _} <- ss do
      us = t |> Enum.filter(&(elem(&1, 0) == l)) |> Enum.map(&elem(&1, 1)) |> Enum.min()
      IO.puts("    #{String.pad_trailing(l, 18)} #{round(us * 1000 / n)}")
    end
  end

  # where the hybrid's threshold belongs
  IO.puts("  Bandit loop vs :crypto.exor/2 (key doubled), ns per frame:")

  for size <- [64, 125, 192, 256, 384, 512, 768, 1024] do
    buf = :rand.bytes(size * 2000)
    fr = for i <- 0..1999, do: {binary_part(buf, i * size, size), 0xA1B2C3D4 + i}

    ts =
      for {l, f} <- [{"bandit", &Ws.Elixir.bandit/2}, {"exor2", &Ws.Elixir.exor2/2}] do
        us =
          Enum.min(
            for _ <- 1..9 do
              :erlang.garbage_collect()
              elem(:timer.tc(fn -> Enum.reduce(fr, nil, fn {p, m}, _ -> f.(p, m) end) end), 0)
            end
          )

        "#{l} #{round(us * 1000 / 2000)}"
      end

    IO.puts("    #{size} B: #{Enum.join(ts, "  ")}")
  end
end

elixir_f = &Ws.Elixir.hybrid/2
defk_f = &Ws.Defk.ws_mask/2
nif_f = &Ws.Nif.ws_mask/2
nif_label = "bandit_native 0.1.2 Bandit.Native.mask/2 (Rust, byte at a time, normal scheduler)"

# 125 B x 10,000 frames, and 1 MiB x 8 frames, per run
realistic = 125
other = 1_048_576

IO.puts("")

r125 =
  Defk.Bench.report(
    name: "ws_masking",
    expected: :marginal,
    baseline: :optimized,
    runs: 15,
    realistic_size: "125 B frames (the largest 7-bit length), 10,000 frames per timed run",
    elixir: job.(elixir_f, realistic),
    defk: job.(defk_f, realistic),
    native: {job.(nif_f, realistic), nif_label},
    check: fn -> check_size.(realistic) end,
    sweep:
      {Enum.map(sizes, &"#{&1} B"),
       fn size ->
         n = size |> String.trim_trailing(" B") |> String.to_integer()
         {job.(elixir_f, n), job.(defk_f, n)}
       end},
    sweep_runs: 5,
    responsiveness: [
      elixir: job.(elixir_f, 16_777_216),
      defk: job.(defk_f, 16_777_216),
      native: job.(nif_f, 16_777_216)
    ],
    reason:
      "a 125 B frame is ~0.13 us of kernel call against the BEAM's already-compiled 32-bit loop; use Bandit's own ws_mask/2 for small frames"
  )

r1m =
  Defk.Bench.report(
    name: "ws_masking_1mib",
    expected: :good,
    baseline: :optimized,
    runs: 15,
    realistic_size: "1 MiB frames, 8 per timed run",
    elixir: job.(elixir_f, other),
    defk: job.(defk_f, other),
    native: {job.(nif_f, other), nif_label},
    check: fn -> check_size.(other) end,
    reason:
      "the vectorised kernel runs at memory bandwidth (~38 GB/s) while the best Elixir (:crypto.exor/2) and bandit_native's byte-at-a-time loop run at 2 GB/s"
  )

for r <- [r125, r1m], not r.correct or r.verdict != r.expected do
  IO.puts("#{r.example}: verdict #{r.verdict}, expected #{r.expected}, correct #{r.correct}")
  System.halt(1)
end
