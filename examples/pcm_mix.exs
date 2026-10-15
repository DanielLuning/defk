# pcm_mix: mix N PCM streams into one with clip prevention, as Membrane's
# ClipPreventingAdder does, against its C twin NativeAdder
#
# The job: an audio mixer element (membrane_audio_mix_plugin's AudioMixer,
# a conference or podcast mix) sums N streams sample by sample. Where a sum
# overflows the sample format, ClipPreventingAdder does not hard-clip: it
# holds the samples back until the next zero crossing, then scales that
# whole half-wave down so its peak lands on the format's limit. The plugin
# ships the same algorithm in C as NativeAdder (Unifex NIF, mixer state in a
# resource) because the Elixir one is slow; that is the NIF column here.
# (The plugin's hard-clipping Adder has no native twin and is not compared.)
#
# Why people reach for a NIF here: a per-sample sum over N binaries plus a
# sequential sign scan, with state carried across calls, every 10 ms.
# Expected verdict: good.
#
#   elixir examples/pcm_mix.exs
#   PCM_REPORT=1 elixir examples/pcm_mix.exs   # also Defk.Report of the kernels
#   PCM_GAPS=1 elixir examples/pcm_mix.exs     # raw tick gaps per side, then stop
#
# Realistic size (declared before any numbers): N = 4 streams of 48 kHz
# stereo s16le in 10 ms chunks (1920 bytes per stream per call), the buffer
# size of an RTC or live mix; the timed job is 1 s of audio, 100 mix calls
# plus flush. The other size is 1 s chunks (one call). The sweep varies the
# chunk from 1 ms to 1 s over the same 1 s of audio.
#
# DEFK_RESULT lines (mix defk.examples reads the first; the script checks both):
#   1. pcm_mix     10 ms chunks, the workload verdict, with NativeAdder as
#                  `native`, the chunk-size sweep, and responsiveness
#   2. pcm_mix_1s  1 s chunks
#
# What is reproduced, read from the plugin's source (0.16.5,
# clip_preventing_adder.ex and c_src/.../mixer.c):
#   - interleaved samples are scanned as one sequence, channels included;
#   - a zero belongs to the open half-wave whichever its sign; the first
#     half-wave takes values >= 0 (NativeAdder's is_wave_positive = false
#     means the same thing);
#   - a closed half-wave (held-back queue plus this chunk's values) is
#     scaled by limit / peak in doubles and truncated (trunc / (int64_t));
#   - flush emits the open half-wave the same way.
# Buffers must be the same length, as the Mixer behaviour asks: on unequal
# buffers ClipPreventingAdder zips to the longest and NativeAdder cuts to
# the shortest, so they disagree with each other there.
# Formats: s16le and s32le, byte-identical across all three. ClipPreventingAdder
# also mixes f32le (as floats), but NativeAdder reads f32 bits as integers,
# so there is no native twin to agree with; s24le needs a 24-bit element
# type defk does not have; u8/s8 and the big-endian formats were not added.
#
# The split: one kernel call per chunk does the sum over the N
# streams, every sum clamped into an [i16] (check-free, vectorised at width
# 8), and the sign scan that rescales each overflowing half-wave. The open
# half-wave's i64 sums (a binary) and its sign stay in Elixir and are passed
# back in on the next call; the kernel returns the whole output and sums
# arrays plus a count, and Elixir cuts them with binary_part (no copy). The
# s16le and s32le kernels come from one quoted source through a macro.
# Kernel notes (Defk.Report):
#   - the sum loop keeps two bounds checks, so it runs scalar: a block
#     offset bufs[j * m + i] with m = div(length(bufs), n) cannot be proven.
#     It is ~70% of the kernel at 1 s chunks (0.2-0.29 ms of
#     0.3-0.37 ms for 4 x 48k stereo frames, timed phase by phase);
#   - out = alloc(t, total) with total = length(held) + m: out[i] is proven
#     only with the loop bound min(length(all), length(out));
#   - the rescale loop inside the scan makes the scan take a safepoint per
#     iteration; it runs on 0.5% of half-waves at the realistic input.
# The macro quotes with `location: :keep`, so Defk.Report puts each note of
# the generated kernels on its line in the macro (without it, every note
# would be on the macro call line).
#
# Agreement, checked on every run (a mismatch raises): the concatenated
# mix + flush output of ClipPreventingAdder, every Elixir variant, the defk
# kernels and NativeAdder is byte-identical on 144 cases: s16le and s32le,
# N = 1, 2, 4, 8, chunks of 1, 10 and 250 ms, and six signals (realistic,
# loud with 40% of half-waves scaled, quiet with none, a DC offset with
# long held-back queues, silence, full-scale noise with a sign change on
# most samples). Each kernel also agrees with its Elixir mode
# (`elixir_mode: true`) on 80 small random cases, held-back queues and n = 0
# (ArithmeticError in both) included.
#
# Elixir baseline: optimised. ClipPreventingAdder is the first baseline.
# Per 1 s of audio, N = 4, under load (ms, 10 ms chunks / 1 s chunks):
#
#   ClipPreventingAdder (the plugin)                      19-20  / 29-30
#   lists: decode each stream, add lists (recursion),      6.0   / 5.8-6.0
#     scan keeping each half-wave as a list
#   same, :lists.zipwith/3 for the sums                    6.3-6.6 / 6.3-6.4
#   same, Enum.zip_with + Enum.sum/1 per sample            7.0   / 13-14.5
#   same, streams after the first added from their         4.6-4.8 / 4.4
#     binaries (no list per stream)
#   PCM.Elixir: the first two streams summed from their    2.6-2.7 / 2.5
#     binaries, the last added inside the scan, each sum
#     appended to the output binary as it is scanned; an
#     overflowing half-wave is cut off the end and
#     written again scaled
#   PCM.Elixir without the half-wave list until it         3.2   / 5.8-15
#     overflows (decoded from the appended bytes then)
#
# plus a 32 MB min_heap_size for the mixer process (see the measurement
# section), which every side gets. PCM.Elixir is ~7x (10 ms chunks) to
# ~12x (1 s) faster than the plugin; the biggest single steps are not
# building a list per stream and not keeping each half-wave as a list. Not tried: Nx (the
# scan is sequential and stateful; Nx's binary backend is itself Elixir),
# splitting one chunk's sum across processes (10 us of work per call).
#
# Results (PROVISIONAL: taken while two other benchmarks loaded the
# machine; a quiet-machine run was recorded separately). M-series Mac, OTP 29,
# Elixir 1.20:
#   10 ms chunks (verdict): Elixir 2.6-2.7 ms, defk 0.41-0.49 ms: 5.4-6.6x,
#     good. NativeAdder 0.73-0.75 ms: defk 1.5-1.8x faster.
#   1 s chunks: Elixir 2.4-2.6 ms, defk 0.31-0.37 ms: 6.6-8.5x; NativeAdder
#     0.68-0.75 ms: defk 1.9-2.5x faster.
#   Sweep (chunk 1, 4, 16, 64, 250, 1000 ms): 2.8-3.0x at 1 ms (the call
#     cost: 48 frames per call), 5.4-5.6x at 4 ms, 6-8x from 16 ms up;
#     crossover (first size >= 2x) at 1 ms, the smallest size.
#   N = 2, 4, 8, 16 at 10 ms: 5.2-5.6x, 6.8-7.4x, 9.3-9.5x, 7.8-10.4x; defk
#     1.5-2.1x faster than NativeAdder throughout. s16le and s32le alike
#     (s32le N = 4: Elixir 3.4-3.5, defk 0.45, NativeAdder 1.0 ms). Loud input
#     (40% of half-waves scaled): Elixir 4.1, defk 0.42-0.46, NativeAdder
#     0.74-0.75 ms.
#   NativeAdder's per-sample path is generic: each sample is read through
#     raw_audio_format_sample_to_value (a byte loop with format branches)
#     and written through value_to_sample (read from the source, not
#     profiled), against the kernel's typed [i16] loads.
#
# Responsiveness (1 ms ticker, one scheduler, 60 s of audio in 1 s chunks;
# under load the ticker's own floor is ~2 ms): Elixir max 3.2-5.6 ms (p99
# 3.2-3.4), defk max 2.2-2.3 ms (it yields), NativeAdder 41-43 ms: each
# NativeAdder call blocks ~0.7 ms, and its 60 back-to-back calls are never
# preempted because the NIF does not report its time slice
# (enif_consume_timeslice), so the loop holds the scheduler throughout. A
# Membrane element calling it once per buffer from its mailbox can do the
# same when buffers queue up.
#
# NativeAdder: built locally by bundlex/unifex inside Mix.install on macOS
# arm64 with the system clang, no extra setup (a first install compiles
# the C; later runs hit the Mix.install cache).

Mix.install([
  {:defk, path: Path.expand("..", __DIR__)},
  {:membrane_audio_mix_plugin, "0.16.5"}
])

defmodule PCM.Gen do
  # One mix kernel and one flush kernel per sample format, from the same
  # source: `t` is the element type, `lo..hi` its sample range.
  defmacro mixer(mix, flush, t, lo, hi) do
    quote location: :keep do
      # One mix call: n equal-length chunks concatenated in bufs, the
      # held-back sums of the open half-wave in held, its sign in pos (true:
      # it takes values >= 0). Returns {out, all, emitted, pos}: out[0,
      # emitted) are the finished samples, all[emitted, length(all)) the new
      # held-back sums.
      defk unquote(mix)(bufs :: [unquote(t)], n :: i64, held :: [i64], pos :: bool) ::
             {[unquote(t)], [i64], i64, bool} do
        hl = length(held)
        m = div(length(bufs), n)
        total = hl + m
        all = alloc(i64, total)

        for i <- 0..(min(length(held), length(all)) - 1)//1 do
          all[i] = held[i]
        end

        for j <- 0..(n - 1)//1 do
          base = j * m

          for i <- 0..(m - 1)//1 do
            all[hl + i] = all[hl + i] + bufs[base + i]
          end
        end

        # every sum as a sample, then rescale the half-waves that overflow
        out = alloc(unquote(t), total)

        for i <- 0..(min(length(all), length(out)) - 1)//1 do
          out[i] = max(min(all[i], unquote(hi)), unquote(lo))
        end

        {_n, start, pos, _peak} =
          for v <- all, reduce: {0, 0, pos, 0} do
            {i, start, pos, peak} ->
              cond do
                pos and v >= 0 ->
                  {i + 1, start, pos, max(peak, v)}

                not pos and v <= 0 ->
                  {i + 1, start, pos, min(peak, v)}

                true ->
                  if peak > unquote(hi) or peak < unquote(lo) do
                    q = if peak > unquote(hi), do: unquote(hi) / peak, else: unquote(lo) / peak

                    for k <- start..(i - 1)//1 do
                      out[k] = max(min(trunc(all[k] * q), unquote(hi)), unquote(lo))
                    end
                  end

                  {i + 1, i, not pos, v}
              end
          end

        {out, all, start, pos}
      end

      # flush: the held-back half-wave, scaled if it overflows
      defk unquote(flush)(held :: [i64]) :: [unquote(t)] do
        {lo, hi} =
          for v <- held, reduce: {0, 0} do
            {lo, hi} -> {min(lo, v), max(hi, v)}
          end

        q =
          cond do
            lo < unquote(lo) -> unquote(lo) / lo
            hi > unquote(hi) -> unquote(hi) / hi
            true -> 1.0
          end

        out = alloc(unquote(t), length(held))

        if q == 1.0 do
          for k <- 0..(length(held) - 1)//1 do
            out[k] = max(min(held[k], unquote(hi)), unquote(lo))
          end
        else
          for k <- 0..(length(held) - 1)//1 do
            out[k] = max(min(trunc(held[k] * q), unquote(hi)), unquote(lo))
          end
        end

        out
      end
    end
  end
end

defmodule PCM.Kernels do
  use Defk, elixir_mode: true, report: :full
  require PCM.Gen

  PCM.Gen.mixer(:mix_s16, :flush_s16, i16, -32_768, 32_767)
  PCM.Gen.mixer(:mix_s32, :flush_s32, i32, -2_147_483_648, 2_147_483_647)
end

if System.get_env("PCM_REPORT"), do: Defk.Report.print(PCM.Kernels)

defmodule PCM.Fmt do
  # The sample formats all three implementations support byte for byte.
  def info(:s16le), do: %{bits: 16, lo: -32_768, hi: 32_767}
  def info(:s32le), do: %{bits: 32, lo: -2_147_483_648, hi: 2_147_483_647}

  def raw_audio(format),
    do: struct!(Membrane.RawAudio, channels: 2, sample_rate: 48_000, sample_format: format)
end

defmodule PCM.Elixir do
  # The optimised Elixir version of ClipPreventingAdder: same job, same
  # bytes. N-1 streams are summed into a list (the first two straight from
  # their binaries), the last is added inside the scan, and each sum is
  # appended to the output binary as it is scanned. A half-wave that ends
  # without overflow needs no more work; one that overflows is cut off the
  # end (a sub-binary, no copy) and written again scaled. State: the open
  # half-wave's sign (pos: values >= 0), its sums newest first (seg), its
  # peak (max of a positive wave, min of a negative one: only that end can
  # overflow) and its bytes as already appended (held).
  def init(format), do: {true, [], 0, <<>>, PCM.Fmt.info(format)}

  def mix(buffers, {pos, seg, peak, held, f}) do
    {first, [last]} = Enum.split(buffers, -1)
    vs = partial_sum(first, last, f.bits)
    {pos, seg, peak, pieces, acc, s0} = scan(vs, last, pos, seg, peak, [], 0, held, f)
    done = binary_part(acc, 0, s0)
    out = if pieces == [], do: done, else: IO.iodata_to_binary(:lists.reverse(pieces, [done]))
    {out, {pos, seg, peak, binary_part(acc, s0, byte_size(acc) - s0), f}}
  end

  def flush({pos, seg, peak, _held, f}),
    do: {IO.iodata_to_binary(emit(seg, peak, f)), {not pos, [], 0, <<>>, f}}

  defp partial_sum([], last, bits), do: :lists.duplicate(div(byte_size(last) * 8, bits), 0)
  defp partial_sum([b], _last, bits), do: decode(b, bits)

  defp partial_sum([b1, b2 | bs], _last, bits),
    do: Enum.reduce(bs, sum2(b1, b2, bits), &addb(&2, &1, bits))

  def decode(b, 16), do: for(<<x::16-signed-little <- b>>, do: x)
  def decode(b, 32), do: for(<<x::32-signed-little <- b>>, do: x)

  # equal-length buffers, as the Mixer contract asks
  for bits <- [16, 32] do
    def sum2(
          <<a::unquote(bits)-signed-little, r1::binary>>,
          <<b::unquote(bits)-signed-little, r2::binary>>,
          unquote(bits)
        ),
        do: [a + b | sum2(r1, r2, unquote(bits))]

    def addb([a | as], <<b::unquote(bits)-signed-little, r::binary>>, unquote(bits)),
      do: [a + b | addb(as, r, unquote(bits))]

    defp scan(
           [a | as],
           <<b::unquote(bits)-signed-little, r::binary>>,
           pos,
           seg,
           peak,
           pieces,
           s0,
           acc,
           %{bits: unquote(bits)} = f
         ) do
      v = a + b

      cond do
        pos and v >= 0 ->
          scan(
            as,
            r,
            pos,
            [v | seg],
            max(peak, v),
            pieces,
            s0,
            <<acc::binary, v::unquote(bits)-signed-little>>,
            f
          )

        not pos and v <= 0 ->
          scan(
            as,
            r,
            pos,
            [v | seg],
            min(peak, v),
            pieces,
            s0,
            <<acc::binary, v::unquote(bits)-signed-little>>,
            f
          )

        peak > f.hi or peak < f.lo ->
          pieces = [emit(seg, peak, f), binary_part(acc, 0, s0) | pieces]
          scan(as, r, not pos, [v], v, pieces, 0, <<v::unquote(bits)-signed-little>>, f)

        true ->
          scan(
            as,
            r,
            not pos,
            [v],
            v,
            pieces,
            byte_size(acc),
            <<acc::binary, v::unquote(bits)-signed-little>>,
            f
          )
      end
    end
  end

  def sum2(<<>>, <<>>, _), do: []
  def addb([], <<>>, _), do: []
  defp scan([], <<>>, pos, seg, peak, pieces, s0, acc, _f), do: {pos, seg, peak, pieces, acc, s0}

  # a finished half-wave (newest first) as samples, scaled if it overflows
  def emit(seg, peak, %{bits: bits, lo: lo, hi: hi}) do
    vs = :lists.reverse(seg)

    cond do
      peak < lo -> scaled(vs, lo / peak, bits)
      peak > hi -> scaled(vs, hi / peak, bits)
      true -> for v <- vs, into: <<>>, do: <<v::size(bits)-signed-little>>
    end
  end

  defp scaled(vs, q, bits),
    do: for(v <- vs, into: <<>>, do: <<trunc(v * q)::size(bits)-signed-little>>)
end

defmodule PCM.Defk do
  # The kernel does the sum and scale loops; the held-back half-wave and its
  # sign stay in Elixir, passed back in on each call.
  def init(format), do: {<<>>, true, format}

  def mix(buffers, {held, pos, format}) do
    n = length(buffers)
    bufs = IO.iodata_to_binary(buffers)
    {out, all, e, pos} = kernel_mix(format, bufs, n, held, pos)
    w = div(PCM.Fmt.info(format).bits, 8)
    rest = byte_size(all) - 8 * e
    {binary_part(out, 0, w * e), {binary_part(all, 8 * e, rest), pos, format}}
  end

  def flush({held, pos, format}), do: {kernel_flush(format, held), {<<>>, not pos, format}}

  defp kernel_mix(:s16le, b, n, h, p), do: PCM.Kernels.mix_s16(b, n, h, p)
  defp kernel_mix(:s32le, b, n, h, p), do: PCM.Kernels.mix_s32(b, n, h, p)
  defp kernel_flush(:s16le, h), do: PCM.Kernels.flush_s16(h)
  defp kernel_flush(:s32le, h), do: PCM.Kernels.flush_s32(h)
end

defmodule PCM.Run do
  # A whole stream: init, one mix call per chunk, flush. Each chunk is the
  # list of N buffers (one per input stream) a mixer receives. Returns the
  # output buffers as iodata, as the mixer would send them on.
  def run({init, mix, flush}, format, chunks) do
    {outs, st} = Enum.map_reduce(chunks, init.(format), mix)
    {last, _} = flush.(st)
    [outs, last]
  end

  def sides do
    %{
      membrane:
        {&Membrane.AudioMixer.ClipPreventingAdder.init(PCM.Fmt.raw_audio(&1)),
         &Membrane.AudioMixer.ClipPreventingAdder.mix/2,
         &Membrane.AudioMixer.ClipPreventingAdder.flush/1},
      elixir: {&PCM.Elixir.init/1, &PCM.Elixir.mix/2, &PCM.Elixir.flush/1},
      defk: {&PCM.Defk.init/1, &PCM.Defk.mix/2, &PCM.Defk.flush/1},
      native:
        {&Membrane.AudioMixer.NativeAdder.init(PCM.Fmt.raw_audio(&1)),
         &Membrane.AudioMixer.NativeAdder.mix/2, &Membrane.AudioMixer.NativeAdder.flush/1}
    }
  end
end

defmodule PCM.Signal do
  # n streams of `ms` milliseconds of 48 kHz stereo: each stream two sines
  # (110-880 Hz) plus a little noise, right channel 0.8x the left (same
  # sign, as a panned mono source), peak `amp` of full scale. Sums of 4 at
  # amp 0.3 overflow on some half-waves, which is the job.
  def streams(format, n, ms, amp \\ 0.3, seed \\ 1) do
    :rand.seed(:exsss, {seed, 2, 3})
    %{bits: bits, hi: hi} = PCM.Fmt.info(format)
    frames = div(48_000 * ms, 1000)

    for k <- 0..(n - 1) do
      f1 = 110.0 * (1 + rem(k * 3, 7))
      f2 = f1 * 1.5 + 13.0 * k
      ph = k * 0.7

      for t <- 0..(frames - 1), into: <<>> do
        x = t / 48_000

        s =
          0.6 * :math.sin(2 * :math.pi() * f1 * x + ph) +
            0.35 * :math.sin(2 * :math.pi() * f2 * x)

        l = trunc(amp * hi * (s + 0.05 * (:rand.uniform() - 0.5)))
        r = trunc(0.8 * l)
        <<l::size(bits)-signed-little, r::size(bits)-signed-little>>
      end
    end
  end

  # cut each stream into chunks of `chunk_ms`: a list of [buf_1, ..., buf_n]
  def chunks(streams, format, chunk_ms) do
    bytes = div(48_000 * chunk_ms, 1000) * 2 * div(PCM.Fmt.info(format).bits, 8)
    total = byte_size(hd(streams))
    for off <- 0..(total - bytes)//bytes, do: Enum.map(streams, &binary_part(&1, off, bytes))
  end
end

defmodule PCM.Variants do
  # Elixir variants measured on the way to PCM.Elixir (PCM_VARIANTS=1 prints
  # them). All but the last share one shape: sum the streams into a list,
  # then scan it, keeping each half-wave as a list and encoding it when it
  # ends (iodata of one binary per half-wave). They differ in the sum.
  alias PCM.Elixir, as: E

  defp lists(sum) do
    init = fn format -> {true, [], 0, PCM.Fmt.info(format)} end

    mix = fn buffers, {pos, seg, peak, f} ->
      {pos, seg, peak, out} = scan(sum.(buffers, f.bits), pos, seg, peak, f, [])
      {IO.iodata_to_binary(:lists.reverse(out)), {pos, seg, peak, f}}
    end

    flush = fn {pos, seg, peak, f} ->
      {if(seg == [], do: <<>>, else: E.emit(seg, peak, f)), {not pos, [], 0, f}}
    end

    {init, mix, flush}
  end

  defp scan([v | r], true, seg, peak, f, out) when v >= 0,
    do: scan(r, true, [v | seg], max(peak, v), f, out)

  defp scan([v | r], false, seg, peak, f, out) when v <= 0,
    do: scan(r, false, [v | seg], min(peak, v), f, out)

  defp scan([_ | _] = l, pos, [], _peak, f, out), do: scan(l, not pos, [], 0, f, out)

  defp scan([_ | _] = l, pos, seg, peak, f, out),
    do: scan(l, not pos, [], 0, f, [E.emit(seg, peak, f) | out])

  defp scan([], pos, seg, peak, _f, out), do: {pos, seg, peak, out}

  def add([a | as], [b | bs]), do: [a + b | add(as, bs)]
  def add([], []), do: []

  # lazy: PCM.Elixir without the per-sample cons. Until the open half-wave
  # overflows, its appended bytes hold its values exactly, so seg stays nil;
  # at the first overflow they are decoded into the list, which then grows.
  def lazy do
    init = fn format -> {true, nil, 0, <<>>, PCM.Fmt.info(format)} end

    mix = fn buffers, {pos, seg, peak, held, f} ->
      {first, [last]} = Enum.split(buffers, -1)

      vs =
        case first do
          [] -> :lists.duplicate(div(byte_size(last) * 8, f.bits), 0)
          [b] -> E.decode(b, f.bits)
          [b1, b2 | bs] -> Enum.reduce(bs, E.sum2(b1, b2, f.bits), &E.addb(&2, &1, f.bits))
        end

      {pos, seg, peak, pieces, acc, s0} = lscan(vs, last, pos, seg, peak, [], 0, held, f)
      done = binary_part(acc, 0, s0)
      out = if pieces == [], do: done, else: IO.iodata_to_binary(:lists.reverse(pieces, [done]))
      {out, {pos, seg, peak, binary_part(acc, s0, byte_size(acc) - s0), f}}
    end

    flush = fn {pos, seg, peak, held, f} ->
      {E.emit(seg || :lists.reverse(E.decode(held, f.bits)), peak, f), {not pos, nil, 0, <<>>, f}}
    end

    {init, mix, flush}
  end

  for bits <- [16, 32] do
    defp lscan(
           [a | as],
           <<b::unquote(bits)-signed-little, r::binary>>,
           pos,
           seg,
           peak,
           pieces,
           s0,
           acc,
           %{bits: unquote(bits)} = f
         ) do
      v = a + b

      cond do
        seg == nil and ((pos and v >= 0 and v <= f.hi) or (not pos and v <= 0 and v >= f.lo)) ->
          lscan(
            as,
            r,
            pos,
            nil,
            if(pos, do: max(peak, v), else: min(peak, v)),
            pieces,
            s0,
            <<acc::binary, v::unquote(bits)-signed-little>>,
            f
          )

        (pos and v >= 0) or (not pos and v <= 0) ->
          seg =
            seg ||
              :lists.reverse(E.decode(binary_part(acc, s0, byte_size(acc) - s0), unquote(bits)))

          lscan(
            as,
            r,
            pos,
            [v | seg],
            if(pos, do: max(peak, v), else: min(peak, v)),
            pieces,
            s0,
            <<acc::binary, v::unquote(bits)-signed-little>>,
            f
          )

        seg != nil ->
          pieces = [E.emit(seg, peak, f), binary_part(acc, 0, s0) | pieces]

          lscan(
            [a | as],
            <<b::unquote(bits)-signed-little, r::binary>>,
            not pos,
            nil,
            0,
            pieces,
            0,
            <<>>,
            f
          )

        true ->
          lscan(
            [a | as],
            <<b::unquote(bits)-signed-little, r::binary>>,
            not pos,
            nil,
            0,
            pieces,
            byte_size(acc),
            acc,
            f
          )
      end
    end
  end

  defp lscan([], <<>>, pos, seg, peak, pieces, s0, acc, _f), do: {pos, seg, peak, pieces, acc, s0}

  def all do
    decode_all = fn buffers, bits -> Enum.map(buffers, &E.decode(&1, bits)) end

    [
      {"lists: decode each, add (body recursion)",
       lists(fn bs, bits -> bs |> decode_all.(bits) |> Enum.reduce(&add(&2, &1)) end)},
      {"lists: decode each, :lists.zipwith/3",
       lists(fn bs, bits ->
         bs |> decode_all.(bits) |> Enum.reduce(&:lists.zipwith(fn x, y -> x + y end, &1, &2))
       end)},
      {"lists: Enum.zip_with + Enum.sum/1",
       lists(fn bs, bits -> bs |> decode_all.(bits) |> Enum.zip_with(&Enum.sum/1) end)},
      {"lists: add from binaries",
       lists(fn [b | bs], bits -> Enum.reduce(bs, E.decode(b, bits), &E.addb(&2, &1, bits)) end)},
      {"fused, no half-wave list until it overflows", lazy()}
    ]
  end
end

defmodule PCM.Check do
  # Byte-identical concatenated mix + flush output from every side.
  def outputs(sides, format, chunks) do
    for {k, s} <- sides, into: %{}, do: {k, IO.iodata_to_binary(PCM.Run.run(s, format, chunks))}
  end

  def agree?(outs), do: outs |> Map.values() |> Enum.uniq() |> length() == 1

  # Half-waves in the summed signal, and how many of them the clip
  # prevention scales down (from PCM.Elixir's own scan rule).
  def half_waves(streams, format) do
    %{lo: lo, hi: hi} = PCM.Fmt.info(format)
    bits = PCM.Fmt.info(format).bits
    sums = streams |> Enum.map(&PCM.Elixir.decode(&1, bits)) |> Enum.zip_with(&Enum.sum/1)

    sums
    |> Enum.chunk_while(
      {true, 0},
      fn v, {pos, peak} ->
        if (pos and v >= 0) or (not pos and v <= 0),
          do: {:cont, {pos, if(pos, do: max(peak, v), else: min(peak, v))}},
          else: {:cont, peak, {not pos, v}}
      end,
      fn {_, peak} -> {:cont, peak, nil} end
    )
    |> then(&{length(&1), Enum.count(&1, fn p -> p > hi or p < lo end)})
  end
end

sides = PCM.Run.sides()
n_real = 4

# --- Agreement -------------------------------------------------------------
# Every format x stream count x chunk size x signal: the concatenated mix +
# flush output of ClipPreventingAdder, PCM.Elixir, the defk kernels and
# NativeAdder must be byte-identical. Signals: realistic (amp 0.3), loud
# (0.9: most half-waves scaled), quiet (0.05: none), DC (a 0.2 offset, so
# long stretches with no zero crossing and a growing held-back queue),
# silence, and full-scale noise (a sign change on most samples).
noise = fn format, n, ms ->
  :rand.seed(:exsss, {7, 7, 7})
  %{bits: bits, lo: lo, hi: hi} = PCM.Fmt.info(format)
  frames = div(48_000 * ms, 1000) * 2

  for _ <- 1..n,
      do:
        for(
          _ <- 1..frames,
          into: <<>>,
          do: <<lo + :rand.uniform(hi - lo + 1) - 1::size(bits)-signed-little>>
        )
end

dc = fn format, n, ms ->
  %{bits: bits, hi: hi} = PCM.Fmt.info(format)

  for s <- PCM.Signal.streams(format, n, ms, 0.25, 3) do
    for <<x::size(^bits)-signed-little <- s>>,
      into: <<>>,
      do: <<x + trunc(0.2 * hi)::size(bits)-signed-little>>
  end
end

signals = [
  {"realistic", &PCM.Signal.streams(&1, &2, &3)},
  {"loud", &PCM.Signal.streams(&1, &2, &3, 0.9, 2)},
  {"quiet", &PCM.Signal.streams(&1, &2, &3, 0.05, 4)},
  {"dc", dc},
  {"silence",
   fn f, n, ms ->
     List.duplicate(
       :binary.copy(<<0>>, div(48_000 * ms, 1000) * 2 * div(PCM.Fmt.info(f).bits, 8)),
       n
     )
   end},
  {"noise", noise}
]

all_sides = Map.merge(sides, Map.new(PCM.Variants.all()))

agreement =
  for format <- [:s16le, :s32le],
      n <- [1, 2, 4, 8],
      {sig, gen} <- signals,
      chunk_ms <- [1, 10, 250] do
    streams = gen.(format, n, 500)
    outs = PCM.Check.outputs(all_sides, format, PCM.Signal.chunks(streams, format, chunk_ms))
    {{format, n, sig, chunk_ms}, PCM.Check.agree?(outs)}
  end

bad = for {case_, false} <- agreement, do: case_

IO.puts(
  "agreement: #{length(agreement) - length(bad)}/#{length(agreement)} cases byte-identical across ClipPreventingAdder, PCM.Elixir (and the variants), defk and NativeAdder (s16le, s32le; N 1-8; 1/10/250 ms chunks; 6 signals)"
)

if bad != [], do: raise("PCM outputs differ: #{inspect(bad)}")

# Elixir mode: each kernel against its Elixir-mode twin on small inputs,
# including a held-back queue, both signs, overflow both ways, and n = 0.
outcome = fn f ->
  try do
    {:ok, f.()}
  rescue
    e -> {:raise, e.__struct__}
  end
end

em_cases =
  for {mix, flush, w} <- [{:mix_s16, :flush_s16, 16}, {:mix_s32, :flush_s32, 32}],
      seed <- 1..40 do
    :rand.seed(:exsss, {seed, 5, 9})
    hi = Bitwise.bsl(1, w - 1)
    n = :rand.uniform(4)
    m = :rand.uniform(12) - 1

    bufs =
      for _ <- 1..(n * m)//1,
          into: <<>>,
          do: <<:rand.uniform(2 * hi) - hi - 1::size(w)-signed-native>>

    held =
      for _ <- 1..:rand.uniform(4), into: <<>>, do: <<:rand.uniform(3 * hi)::signed-64-native>>

    pos = rem(seed, 2) == 0
    args = [bufs, n, if(pos, do: held, else: <<>>), pos]

    outcome.(fn -> apply(PCM.Kernels, mix, args) end) ==
      outcome.(fn -> PCM.Kernels.__defk_elixir__(mix, args) end) and
      outcome.(fn -> apply(PCM.Kernels, flush, [held]) end) ==
        outcome.(fn -> PCM.Kernels.__defk_elixir__(flush, [held]) end) and
      outcome.(fn -> apply(PCM.Kernels, mix, [bufs, 0, <<>>, true]) end) ==
        outcome.(fn -> PCM.Kernels.__defk_elixir__(mix, [bufs, 0, <<>>, true]) end)
  end

IO.puts("Elixir mode: #{Enum.count(em_cases, & &1)}/#{length(em_cases)} kernel cases agree")
if not Enum.all?(em_cases), do: raise("kernel and Elixir mode differ")

# --- Measurement -------------------------------------------------------------
# A mixer process can be spawned with a heap that fits a chunk's lists
# (spawn_opt min_heap_size, here 32 MB). Without it the Elixir side pays for
# regrowing its heap after each forced GC: 3.4 instead of 2.7 ms at 10 ms
# chunks, and 4-10 ms instead of 2.5 at 1 s chunks, varying run to run. It
# applies to every side (ClipPreventingAdder 40-70 ms without it, ~20 with).
Process.flag(:min_heap_size, 4_000_000)

fmt = :s16le
one_s = PCM.Signal.streams(fmt, n_real, 1000)
{waves, scaled} = PCM.Check.half_waves(one_s, fmt)

IO.puts(
  "realistic input: #{n_real} streams x 1 s, #{waves} half-waves in the sum, #{scaled} scaled down (#{Float.round(100 * scaled / waves, 1)}%)"
)

best = fn f, runs ->
  for(
    _ <- 1..runs,
    do:
      (
        :erlang.garbage_collect()
        elem(:timer.tc(f), 0)
      )
  )
  |> Enum.min()
  |> Kernel./(1000)
end

# The chunks live in :persistent_term, as a mixer's input arrives from
# outside its heap: kept on the benchmark process's heap, every sweep size's
# chunks stay live at once and the GC they cost lands on the Elixir side
# (1 s chunks measured 10 ms instead of 4).
job = fn side, streams, chunk_ms ->
  key = {:pcm_chunks, :erlang.phash2(streams), chunk_ms}

  if :persistent_term.get(key, nil) == nil,
    do: :persistent_term.put(key, PCM.Signal.chunks(streams, fmt, chunk_ms))

  s = sides[side] || side
  fn -> PCM.Run.run(s, fmt, :persistent_term.get(key)) end
end

IO.puts("\nElixir versions, 1 s of audio, N = #{n_real} (ms, best of 5):")

for {label, s} <-
      [{"ClipPreventingAdder (membrane_audio_mix_plugin 0.16.5)", sides.membrane}] ++
        PCM.Variants.all() ++ [{"PCM.Elixir (fused scan, appended output)", sides.elixir}] do
  t = for c <- [10, 1000], do: best.(job.(s, one_s, c), 5)

  IO.puts(
    "  #{String.pad_trailing(label, 56)} 10 ms chunks #{Enum.at(t, 0)}   1 s chunks #{Enum.at(t, 1)}"
  )
end

IO.puts("\nStream count, 10 ms chunks, 1 s of audio (ms, best of 5):")

for n <- [2, 4, 8, 16] do
  st = PCM.Signal.streams(fmt, n, 1000)
  [e, d, nat] = for k <- [:elixir, :defk, :native], do: best.(job.(k, st, 10), 5)

  IO.puts(
    "  N = #{String.pad_trailing(to_string(n), 3)} elixir #{e}   defk #{d}   NativeAdder #{nat}   defk/elixir #{Float.round(e / d, 1)}x   defk vs NativeAdder #{Float.round(nat / d, 2)}x"
  )
end

st32 = PCM.Signal.streams(:s32le, n_real, 1000)
:persistent_term.put(:pcm_chunks32, PCM.Signal.chunks(st32, :s32le, 10))

job32 = fn side ->
  fn -> PCM.Run.run(sides[side], :s32le, :persistent_term.get(:pcm_chunks32)) end
end

[e32, d32, n32] = for k <- [:elixir, :defk, :native], do: best.(job32.(k), 5)
IO.puts("\ns32le, N = #{n_real}, 10 ms chunks: elixir #{e32}   defk #{d32}   NativeAdder #{n32}")

loud = PCM.Signal.streams(fmt, n_real, 1000, 0.9, 2)
{lw, ls} = PCM.Check.half_waves(loud, fmt)
[el, dl, nl] = for k <- [:elixir, :defk, :native], do: best.(job.(k, loud, 10), 5)

IO.puts(
  "loud input (amp 0.9, #{ls} of #{lw} half-waves scaled), N = #{n_real}, 10 ms chunks: elixir #{el}   defk #{dl}   NativeAdder #{nl}\n"
)

# responsiveness input: 60 s of audio (10 s generated, tiled 6x), in 1 s chunks
sixty_s = fmt |> PCM.Signal.streams(n_real, 10_000) |> Enum.map(&:binary.copy(&1, 6))

if System.get_env("PCM_GAPS") do
  for side <- [:elixir, :defk, :native], _ <- 1..3 do
    {us, gaps} =
      Defk.Bench.TickGap.with_one_scheduler(fn ->
        Defk.Bench.TickGap.measure(job.(side, sixty_s, 1000))
      end)

    IO.puts(
      "#{side} run #{us / 1000} ms, #{length(gaps)} ticks, top gaps us #{inspect(gaps |> Enum.sort(:desc) |> Enum.take(6))}"
    )
  end

  System.halt(0)
end

sweep_sizes = [1, 4, 16, 64, 250, 1000]

r10 =
  Defk.Bench.report(
    name: "pcm_mix",
    expected: :good,
    baseline: :optimized,
    runs: 7,
    realistic_size:
      "N = 4 streams, 48 kHz stereo s16le, 10 ms chunks (1 s of audio: 100 mix calls + flush)",
    elixir: job.(:elixir, one_s, 10),
    defk: job.(:defk, one_s, 10),
    native: {job.(:native, one_s, 10), "membrane_audio_mix_plugin 0.16.5 NativeAdder"},
    check: fn -> bad == [] and Enum.all?(em_cases) end,
    sweep:
      {Enum.map(sweep_sizes, &"#{&1} ms"),
       fn size ->
         c = size |> String.trim_trailing(" ms") |> String.to_integer()
         {job.(:elixir, one_s, c), job.(:defk, one_s, c)}
       end},
    sweep_runs: 5,
    responsiveness: [
      elixir: job.(:elixir, sixty_s, 1000),
      defk: job.(:defk, sixty_s, 1000),
      native: job.(:native, sixty_s, 1000)
    ],
    reason:
      "the sum and half-wave scan run as one kernel per chunk with the held-back queue passed back in; pure Elixir pays per sample for list cells and binary appends"
  )

r1s =
  Defk.Bench.report(
    name: "pcm_mix_1s",
    expected: :good,
    baseline: :optimized,
    runs: 7,
    realistic_size: "N = 4 streams, 48 kHz stereo s16le, 1 s chunks (1 mix call + flush)",
    elixir: job.(:elixir, one_s, 1000),
    defk: job.(:defk, one_s, 1000),
    native: {job.(:native, one_s, 1000), "membrane_audio_mix_plugin 0.16.5 NativeAdder"},
    check: fn -> bad == [] end,
    reason: "the same job in 1 s chunks"
  )

for r <- [r10, r1s], not r.correct or r.verdict != r.expected do
  IO.puts("#{r.example}: verdict #{r.verdict}, expected #{r.expected}, correct #{r.correct}")
  System.halt(1)
end
