# byte_histogram: count the bytes of a binary (a 256-bin histogram), and the
# Shannon entropy of every 4 KiB window
#
# The job: a byte histogram tells you whether data is text, compressed or
# encrypted (file-type sniffing, "is this block worth compressing?"), and the
# entropy of fixed windows is what binwalk -E plots for a firmware image and
# what ransomware detectors compute over written blocks. Both are one pass
# over the bytes with a 256-entry table of counts: an indexed increment per
# byte, which Elixir has no cheap spelling for (no mutable array; a map or a
# tuple copies, :counters/:atomics are a BIF call per byte). OTP has no BIF
# for it (:binary has no histogram, :binary.matches/2 per byte value is 256
# scans). This is the cold-test job of docs/cold-tests/hexdocs-entropy.md.
#
# Realistic size (declared before the numbers): a 16 MB binary (a firmware
# image or an upload, half random bytes and half text), whole-binary
# histogram, and the entropy of 4,096 windows of 4 KiB. The histogram sweep
# runs one process against one call from 4 KB to 16 MB.
#
# Expected verdict: good for both, parallel against parallel (both sides
# split over System.schedulers_online() chunks, one Task.async per chunk).
#
#   elixir examples/byte_histogram.exs                   # agreement + reports
#   HIST_VARIANTS=1 elixir examples/byte_histogram.exs   # also every variant
#
# Two DEFK_RESULT lines: byte_histogram, then windowed_entropy; mix defk.examples reads
# the first and the script checks the second itself.
#
# Both sides return the same bytes: the histogram as 256 native-endian i64
# counts (exact), the entropies as one f64 per whole window, bit for bit.
# Both sides compute -p * log2(p) (the kernel's log2/1 builtin, defk-ngj,
# calls the same libm function as :math.log2/1), in the same order (bins 0 to
# 255, empty bins skipped), and kernels never fuse or reassociate floats, so
# the floats agree exactly (no tolerance). The cold test, before log2 landed,
# wrote log(p) / log(2.0) in the kernel and was ~1 ulp from :math.log2.
#
# ALL NUMBERS BELOW ARE PROVISIONAL, MEASURED UNDER LOAD (other agents'
# builds and benchmarks on the machine, load average 12-31 on 12 cores;
# M4 Pro, 12 schedulers, OTP 29, Elixir 1.20). Every variant returns the
# kernel's bytes exactly; the script checks each one before timing it.
#
# Elixir baseline: optimised. Histogram variants (HIST_VARIANTS=1, two runs
# of the script), ms; E1-E4 best of 3 at 1 MB (x16 for 16 MB), the rest best
# of 5 at 16 MB in two interleaved rounds (the second in reverse order):
#
#   E1 :binary.bin_to_list |> Enum.frequencies (cold-test first pass) 136-169
#   E2 for <<b <- bin>>, reduce: %{} with Map.update                 202-209
#   E3 a 256-tuple of counts, setelement per byte                      62-80
#   E4 :binary.matches(bin, <<b>>) for each of the 256 values      24.7-26.4
#      (C scans, but a list of 16M match tuples at 16 MB: ~400 ms)
#   E5 :counters, 1 byte per binary-pattern step                     112-115
#   E6 :counters, 8 bytes per step (the cold test's optimised one)   101-103
#   E7 :counters from a binary comprehension                         116-123
#   E8 :atomics, 1 byte per step                                       91-92
#   E9 :atomics, 8 bytes per step                                      75-77
#   E10 16-bit pairs into a 65,536-slot :atomics, 8 pairs per step,
#       folded to 256 bins once (half the BIF calls)               43.0-43.9
#   E11 E6 in 12 chunks (one per scheduler), histograms summed     15.9-17.7
#   E12 E6 in 12 chunks into one shared :counters (write_concurrency) 23-26
#   E13 E9 in 12 chunks                                            12.1-13.3
#   E14 one/1 in 12 chunks                          <- baseline     8.7-9.9
#
# E10's fold of 65,536 slots costs ~0.35 ms, so below ~512 KB E9 wins
# (E9 / E10 ms: 4 KB 0.023 / 0.38, 64 KB 0.30 / 0.95-0.98, 256 KB 1.16-1.21
# / 1.57-1.62, 512 KB 2.31 / 2.24-2.34, 1 MB 4.7 / 3.6-3.8). Hist.Elixir.one/1
# is E10 from 512 KB and E9 below: the one-process baseline, and what each
# chunk of E14 runs (16 MB / 12 = 1.4 MB per chunk). :atomics beats
# :counters by 1.3x, eight bytes per step beat one by 1.1-1.2x, and a shared
# write_concurrency :counters loses to per-chunk tables summed at the end.
#
# Windowed entropy variants, w = 4096 (one window's counts must be read and
# reset every 4 KiB, so E10's 65,536-slot fold does not pay); N1-N2 at 1 MB;
# one run with log2 (an earlier run with log(p) / log(2.0) was within load
# noise of it):
#
#   N1 Enum.frequencies per window, sorted (first pass)                  121
#   N2 a 256-tuple per window, setelement per byte                        65
#   N3 :counters, 8 bytes per step, get + put 0 per bin              121-123
#   N4 :atomics, 8 bytes per step, :atomics.exchange(a, i, 0) per bin  90-91
#   N5 N4 with a tuple of the per-count terms (-p log2 p for count c,
#      built once per call: the same floats, no log per bin)       83.5-84.3
#   N6 N3 in 12 chunks of whole windows                            17.6-19.0
#   N7 N4 in 12 chunks                                             14.9-15.3
#   N8 N5 in 12 chunks                               <- baseline   13.4-14.4
#
# defk: Hist.Kernels.histogram counts into four interleaved 256-bin tables
# (bytes i, i+1, i+2, i+3 go to different tables, so consecutive increments
# of the same bin do not wait on each other) and sums them; entropy does the
# same per window, then the same term table as N5. Both read the input with
# no bounds check (the fast-path report proves the ranges: the window loop
# runs over lo..hi - 4//4 with lo = max(k * w, 0), hi = min(lo + w,
# len(data))). The parallel side splits exactly as the Elixir side and
# starts one Task.async per chunk (examples/README.md, measuring rule 7).
# Kernel variants (HIST_VARIANTS=1), ms at 16 MB:
#
#   D1 histogram, one table, one call                              5.8-6.0
#   D2 histogram, four tables, one call            <- the kernel   3.6-3.7
#   D1 / D2 in 12 chunks                             2.0-2.35 / 1.47-1.56
#   D3 entropy, one table, a log2 per bin, one call                    7.6
#   D4 entropy, four tables, a log2 per bin                        5.8-5.9
#   D5 entropy, four tables, term table            <- the kernel   4.7-4.8
#   D3 / D5 in 12 chunks                             2.27-2.36 / 1.66-1.68
#
# (Before the window bounds were written as max/min the window loop kept a
# bounds check per byte: D5 was 7.0 ms and D4 8.5, with log(p) / log(2.0).)
#
# Result (seven runs of the script, load 12-31, provisional):
#
#   byte_histogram, parallel vs parallel (the verdict): Elixir 8.7-10.9 ms vs
#   defk 1.40-1.71 ms = 5.5-6.6x, good. One process vs one call: 42.6-46.9
#   vs 3.58-3.77 ms = 11.4-12.7x (0.39 vs 4.6 GB/s). Sweep, one process vs
#   one call: 4 KB 24-28x (0.025 vs 0.001 ms), 64 KB 19-23x, 1 MB 17.7-19.4x,
#   16 MB 11.4-12.5x; the kernel is at least 2x from the smallest size
#   measured.
#
#   windowed_entropy, parallel vs parallel (the verdict): Elixir 12.5-18.6
#   ms vs defk 1.83-2.0 ms = 6.7-10.2x, good. One process vs one call:
#   82-89 vs 4.73-5.21 ms = 17.0-17.9x.
#
# The cold test (docs/cold-tests/hexdocs-entropy.md, a loaded machine, not
# this script) had :counters with 8-byte steps at 138 MB/s against a kernel
# at ~2250 MB/s (16x, one process vs one call); here E6 is 163 MB/s, the
# best one-process Elixir (E10) 390 MB/s and the kernel 4.6 GB/s.
#
# Not tried: a NIF or a library (no Hex package does a byte histogram that
# we know of); splitting a window's count over processes; 32-bit or 24-bit
# keys in Elixir (a 16M-slot table).

Mix.install([{:defk, path: Path.expand("..", __DIR__)}])

defmodule Hist.Kernels do
  use Defk, elixir_mode: true

  # Four interleaved tables; the 4-byte loop reads bytes[i..i+3] with i
  # stepping by 4 below len - 3, the tail one byte at a time.
  defk histogram(bytes :: [u8]) :: [i64] do
    n = len(bytes)
    h = alloc(i64, 1024)

    for i <- 0..(n - 4)//4 do
      a = bytes[i]
      b = bytes[i + 1]
      c = bytes[i + 2]
      d = bytes[i + 3]
      h[a] = h[a] + 1
      h[256 + b] = h[256 + b] + 1
      h[512 + c] = h[512 + c] + 1
      h[768 + d] = h[768 + d] + 1
    end

    for i <- max(n - rem(n, 4), 0)..(n - 1)//1 do
      b = bytes[i]
      h[b] = h[b] + 1
    end

    out = alloc(i64, 256)

    for j <- 0..255//1 do
      out[j] = h[j] + h[256 + j] + h[512 + j] + h[768 + j]
    end

    out
  end

  # One table (variant D1).
  defk histogram1(bytes :: [u8]) :: [i64] do
    h = alloc(i64, 256)

    for b <- bytes do
      h[b] = h[b] + 1
    end

    h
  end

  # Entropy in bits per byte of each whole window of w bytes (a trailing
  # partial window is ignored). t[c] is the term for a bin with count c,
  # 0.0 - p * log2(p) with p = c / w, built once per call.
  defk entropy(data :: [u8], w :: i64) :: [f64] do
    n = div(len(data), w)
    out = alloc(f64, n)
    h = alloc(i64, 1024)
    t = alloc(f64, w + 1)

    for c <- 1..w//1 do
      p = c / w
      t[c] = 0.0 - p * log2(p)
    end

    for k <- 0..(n - 1)//1 do
      for i <- 0..1023//1 do
        h[i] = 0
      end

      lo = max(k * w, 0)
      hi = min(lo + w, len(data))

      for i <- lo..(hi - 4)//4 do
        a = data[i]
        b = data[i + 1]
        c = data[i + 2]
        d = data[i + 3]
        h[a] = h[a] + 1
        h[256 + b] = h[256 + b] + 1
        h[512 + c] = h[512 + c] + 1
        h[768 + d] = h[768 + d] + 1
      end

      for i <- max(hi - rem(hi - lo, 4), 0)..(hi - 1)//1 do
        b = data[i]
        h[b] = h[b] + 1
      end

      out[k] =
        for j <- 0..255//1, reduce: 0.0 do
          acc ->
            c = h[j] + h[256 + j] + h[512 + j] + h[768 + j]
            if c > 0, do: acc + t[c], else: acc
        end
    end

    out
  end

  # One table, a log per bin (variant D3).
  defk entropy1(data :: [u8], w :: i64) :: [f64] do
    n = div(len(data), w)
    out = alloc(f64, n)
    h = alloc(i64, 256)

    for k <- 0..(n - 1)//1 do
      for i <- 0..255//1 do
        h[i] = 0
      end

      lo = max(k * w, 0)
      hi = min(lo + w, len(data))

      for i <- lo..(hi - 1)//1 do
        b = data[i]
        h[b] = h[b] + 1
      end

      out[k] =
        for c <- h, c > 0, reduce: 0.0 do
          acc ->
            p = c / w
            acc - p * log2(p)
        end
    end

    out
  end

  # Four tables, a log per bin (variant D4).
  defk entropy4(data :: [u8], w :: i64) :: [f64] do
    n = div(len(data), w)
    out = alloc(f64, n)
    h = alloc(i64, 1024)

    for k <- 0..(n - 1)//1 do
      for i <- 0..1023//1 do
        h[i] = 0
      end

      lo = max(k * w, 0)
      hi = min(lo + w, len(data))

      for i <- lo..(hi - 4)//4 do
        a = data[i]
        b = data[i + 1]
        c = data[i + 2]
        d = data[i + 3]
        h[a] = h[a] + 1
        h[256 + b] = h[256 + b] + 1
        h[512 + c] = h[512 + c] + 1
        h[768 + d] = h[768 + d] + 1
      end

      for i <- max(hi - rem(hi - lo, 4), 0)..(hi - 1)//1 do
        b = data[i]
        h[b] = h[b] + 1
      end

      out[k] =
        for j <- 0..255//1, reduce: 0.0 do
          acc ->
            c = h[j] + h[256 + j] + h[512 + j] + h[768 + j]

            if c > 0 do
              p = c / w
              acc - p * log2(p)
            else
              acc
            end
        end
    end

    out
  end
end

defmodule Hist.Elixir do
  import Bitwise

  # ---------------------------------------------------------- histogram --

  # The baseline: E14, one chunk per scheduler, each counted by one/1.
  def histogram(bin, chunks \\ System.schedulers_online()),
    do: split(bin, chunks, 8, &one/1) |> sum_histograms()

  # One process: E10 (16-bit pairs) from 512 KB, where its 65,536-slot fold
  # pays for itself; E9 (bytes, 8 per step) below.
  def one(bin) when byte_size(bin) >= 524_288, do: pairs(bin)
  def one(bin), do: atomics8(bin)

  # E10: one :atomics increment per two bytes into 65,536 slots, then one
  # fold of the pair counts into the 256 bins.
  def pairs(bin) do
    a = :atomics.new(65_536, signed: false)
    tail = p16(bin, a)
    acc = :atomics.new(256, signed: false)
    fold(a, acc, 0)
    for <<b <- tail>>, do: :atomics.add(acc, b + 1, 1)
    from_atomics(acc)
  end

  defp p16(<<a::16, b::16, c::16, d::16, e::16, f::16, g::16, h::16, rest::binary>>, x) do
    :atomics.add(x, a + 1, 1)
    :atomics.add(x, b + 1, 1)
    :atomics.add(x, c + 1, 1)
    :atomics.add(x, d + 1, 1)
    :atomics.add(x, e + 1, 1)
    :atomics.add(x, f + 1, 1)
    :atomics.add(x, g + 1, 1)
    :atomics.add(x, h + 1, 1)
    p16(rest, x)
  end

  defp p16(<<a::16, rest::binary>>, x),
    do:
      (
        :atomics.add(x, a + 1, 1)
        p16(rest, x)
      )

  defp p16(tail, _x), do: tail

  defp fold(_a, _acc, 65_536), do: :ok

  defp fold(a, acc, i) do
    case :atomics.get(a, i + 1) do
      0 ->
        :ok

      v ->
        :atomics.add(acc, (i >>> 8) + 1, v)
        :atomics.add(acc, (i &&& 255) + 1, v)
    end

    fold(a, acc, i + 1)
  end

  # E9: :atomics, 8 bytes per step (also N4's and N5's counting loop).
  def atomics8(bin) do
    a = :atomics.new(256, signed: false)
    a8(bin, a)
    from_atomics(a)
  end

  def a8(<<a, b, c, d, e, f, g, h, rest::binary>>, x) do
    :atomics.add(x, a + 1, 1)
    :atomics.add(x, b + 1, 1)
    :atomics.add(x, c + 1, 1)
    :atomics.add(x, d + 1, 1)
    :atomics.add(x, e + 1, 1)
    :atomics.add(x, f + 1, 1)
    :atomics.add(x, g + 1, 1)
    :atomics.add(x, h + 1, 1)
    a8(rest, x)
  end

  def a8(<<b, rest::binary>>, x),
    do:
      (
        :atomics.add(x, b + 1, 1)
        a8(rest, x)
      )

  def a8(<<>>, _x), do: :ok

  def pack(counts), do: for(c <- counts, into: <<>>, do: <<c::signed-64-native>>)

  def from_atomics(a), do: pack(for i <- 1..256, do: :atomics.get(a, i))

  def sum_histograms(parts) do
    parts
    |> Enum.map(fn p -> for <<c::signed-64-native <- p>>, do: c end)
    |> Enum.zip_with(&Enum.sum/1)
    |> pack()
  end

  # Chunks of `align`-byte multiples, one Task.async each (the same split
  # on the defk side).
  def split(bin, chunks, align, fun) do
    size = byte_size(bin)
    per = div(div(size + chunks - 1, chunks) + align - 1, align) * align

    for(
      c <- 0..(chunks - 1),
      c * per < size,
      do: binary_part(bin, c * per, min(per, size - c * per))
    )
    |> Enum.map(fn part -> Task.async(fn -> fun.(part) end) end)
    |> Task.await_many(:infinity)
  end

  # ------------------------------------------------------------ entropy --

  # The baseline: N5 in chunks of whole windows, one per scheduler (N8).
  def entropy(bin, w, chunks \\ System.schedulers_online()) do
    whole = binary_part(bin, 0, div(byte_size(bin), w) * w)
    split(whole, chunks, w, &entropy_table(&1, w)) |> IO.iodata_to_binary()
  end

  # N5: count each window into :atomics (8 bytes per step), then read and
  # reset every bin with one exchange and add the bin's term from a tuple.
  def entropy_table(bin, w) do
    a = :atomics.new(256, signed: false)
    terms = terms(w)
    et(bin, w, a, terms, <<>>)
  end

  def terms(w) do
    List.to_tuple([
      0.0
      | for(
          c <- 1..w,
          do:
            (
              p = c / w
              0.0 - p * :math.log2(p)
            )
        )
    ])
  end

  defp et(bin, w, a, terms, acc) do
    case bin do
      <<win::binary-size(^w), rest::binary>> ->
        a8(win, a)
        h = tsum(a, 1, terms, 0.0)
        et(rest, w, a, terms, <<acc::binary, h::float-64-native>>)

      _ ->
        acc
    end
  end

  defp tsum(_a, 257, _terms, h), do: h

  defp tsum(a, i, terms, h) do
    case :atomics.exchange(a, i, 0) do
      0 -> tsum(a, i + 1, terms, h)
      c -> tsum(a, i + 1, terms, h + elem(terms, c))
    end
  end
end

defmodule Hist.DefkParallel do
  # The same split as Hist.Elixir, one kernel call per chunk.
  def histogram(bin, chunks \\ System.schedulers_online()),
    do:
      Hist.Elixir.split(bin, chunks, 8, &Hist.Kernels.histogram/1) |> Hist.Elixir.sum_histograms()

  def entropy(bin, w, chunks \\ System.schedulers_online()) do
    whole = binary_part(bin, 0, div(byte_size(bin), w) * w)
    Hist.Elixir.split(whole, chunks, w, &Hist.Kernels.entropy(&1, w)) |> IO.iodata_to_binary()
  end
end

defmodule Hist.Variants do
  # The variants the header lists that are not the baseline.
  alias Hist.Elixir, as: E

  def freq(bin) do
    f = bin |> :binary.bin_to_list() |> Enum.frequencies()
    E.pack(for b <- 0..255, do: Map.get(f, b, 0))
  end

  def map_update(bin) do
    f = for <<b <- bin>>, reduce: %{}, do: (m -> Map.update(m, b, 1, &(&1 + 1)))
    E.pack(for b <- 0..255, do: Map.get(f, b, 0))
  end

  def tuple(bin), do: bin |> t1(:erlang.make_tuple(256, 0)) |> Tuple.to_list() |> E.pack()

  defp t1(<<b, rest::binary>>, t), do: t1(rest, :erlang.setelement(b + 1, t, elem(t, b) + 1))
  defp t1(<<>>, t), do: t

  def matches(bin), do: E.pack(for b <- 0..255, do: length(:binary.matches(bin, <<b>>)))

  def counters1(bin) do
    c = :counters.new(256, [])
    c1(bin, c)
    from_counters(c)
  end

  defp c1(<<b, rest::binary>>, c),
    do:
      (
        :counters.add(c, b + 1, 1)
        c1(rest, c)
      )

  defp c1(<<>>, _), do: :ok

  def counters8(bin) do
    c = :counters.new(256, [])
    c8(bin, c)
    from_counters(c)
  end

  def c8(<<a, b, d, e, f, g, h, i, rest::binary>>, c) do
    :counters.add(c, a + 1, 1)
    :counters.add(c, b + 1, 1)
    :counters.add(c, d + 1, 1)
    :counters.add(c, e + 1, 1)
    :counters.add(c, f + 1, 1)
    :counters.add(c, g + 1, 1)
    :counters.add(c, h + 1, 1)
    :counters.add(c, i + 1, 1)
    c8(rest, c)
  end

  def c8(<<b, rest::binary>>, c),
    do:
      (
        :counters.add(c, b + 1, 1)
        c8(rest, c)
      )

  def c8(<<>>, _), do: :ok

  def comprehension(bin) do
    c = :counters.new(256, [])
    for <<b <- bin>>, do: :counters.add(c, b + 1, 1)
    from_counters(c)
  end

  def atomics1(bin) do
    a = :atomics.new(256, signed: false)
    a1(bin, a)
    E.from_atomics(a)
  end

  defp a1(<<b, rest::binary>>, x),
    do:
      (
        :atomics.add(x, b + 1, 1)
        a1(rest, x)
      )

  defp a1(<<>>, _), do: :ok

  def shared_counters(bin, chunks \\ System.schedulers_online()) do
    c = :counters.new(256, [:write_concurrency])
    E.split(bin, chunks, 8, &c8(&1, c))
    from_counters(c)
  end

  def from_counters(c), do: E.pack(for i <- 1..256, do: :counters.get(c, i))

  def par(fun),
    do: fn bin -> E.split(bin, System.schedulers_online(), 8, fun) |> E.sum_histograms() end

  # -- entropy
  def ent_freq(bin, w) do
    for <<win::binary-size(^w) <- bin>>, into: <<>> do
      h =
        win
        |> :binary.bin_to_list()
        |> Enum.frequencies()
        |> Enum.sort()
        |> Enum.reduce(0.0, fn {_, c}, h ->
          p = c / w
          h - p * :math.log2(p)
        end)

      <<h::float-64-native>>
    end
  end

  def ent_tuple(bin, w) do
    for <<win::binary-size(^w) <- bin>>, into: <<>> do
      h =
        win
        |> t1(:erlang.make_tuple(256, 0))
        |> Tuple.to_list()
        |> Enum.reduce(0.0, fn
          0, h ->
            h

          c, h ->
            p = c / w
            h - p * :math.log2(p)
        end)

      <<h::float-64-native>>
    end
  end

  def ent_counters(bin, w) do
    c = :counters.new(256, [])
    ec(bin, w, c, <<>>)
  end

  defp ec(bin, w, c, acc) do
    case bin do
      <<win::binary-size(^w), rest::binary>> ->
        c8(win, c)
        ec(rest, w, c, <<acc::binary, csum(c, 1, w, 0.0)::float-64-native>>)

      _ ->
        acc
    end
  end

  defp csum(_c, 257, _w, h), do: h

  defp csum(c, i, w, h) do
    case :counters.get(c, i) do
      0 ->
        csum(c, i + 1, w, h)

      v ->
        :counters.put(c, i, 0)
        p = v / w
        csum(c, i + 1, w, h - p * :math.log2(p))
    end
  end

  def ent_atomics(bin, w) do
    a = :atomics.new(256, signed: false)
    ea(bin, w, a, <<>>)
  end

  defp ea(bin, w, a, acc) do
    case bin do
      <<win::binary-size(^w), rest::binary>> ->
        E.a8(win, a)
        ea(rest, w, a, <<acc::binary, asum(a, 1, w, 0.0)::float-64-native>>)

      _ ->
        acc
    end
  end

  defp asum(_a, 257, _w, h), do: h

  defp asum(a, i, w, h) do
    case :atomics.exchange(a, i, 0) do
      0 ->
        asum(a, i + 1, w, h)

      v ->
        p = v / w
        asum(a, i + 1, w, h - p * :math.log2(p))
    end
  end

  def ent_par(fun, w),
    do: fn bin ->
      E.split(bin, System.schedulers_online(), w, &fun.(&1, w)) |> IO.iodata_to_binary()
    end
end

# ------------------------------------------------------------- inputs --

w = 4096
size = 16 * 1024 * 1024
:rand.seed(:exsss, {28, 6, 9})
line = "the quick brown fox jumps over the lazy dog; 0123456789 GET /index.html\n"
text = :binary.copy(line, div(size, 2 * byte_size(line)) + 1)
input = :rand.bytes(div(size, 2)) <> binary_part(text, 0, size - div(size, 2))

fail = fn what -> raise "disagreement: #{what}" end

# ----------------------------------------------------------- agreement --

# Native against Elixir mode on edge cases, odd lengths and windows.
small_cases =
  [<<>>, <<0>>, <<255, 255, 1>>, <<1, 2, 3, 4, 5>>, :binary.copy(<<7>>, 4099)] ++
    for n <- [1, 3, 4, 7, 63, 1000, 70_001], do: :rand.bytes(n)

for bin <- small_cases do
  for k <- [:histogram, :histogram1] do
    if apply(Hist.Kernels, k, [bin]) != Hist.Kernels.__defk_elixir__(k, [bin]),
      do: fail.("#{k} native vs Elixir mode, #{byte_size(bin)} bytes")
  end

  if Hist.Kernels.histogram(bin) != Hist.Elixir.pairs(bin) or
       Hist.Kernels.histogram(bin) != Hist.Elixir.atomics8(bin),
     do: fail.("histogram vs Elixir, #{byte_size(bin)} bytes")

  for ww <- if(byte_size(bin) > 5000, do: [7, 64, 4096], else: [1, 3, 4, 7, 64, 4096]),
      k <- [:entropy, :entropy1, :entropy4] do
    native = apply(Hist.Kernels, k, [bin, ww])

    if native != Hist.Kernels.__defk_elixir__(k, [bin, ww]),
      do: fail.("#{k} native vs Elixir mode, #{byte_size(bin)} bytes, w = #{ww}")

    if native != Hist.Elixir.entropy_table(binary_part(bin, 0, div(byte_size(bin), ww) * ww), ww),
      do: fail.("#{k} vs Elixir entropy, #{byte_size(bin)} bytes, w = #{ww}")
  end
end

# w = 0 raises on both sides of the kernel
for mode <- [:native, :elixir] do
  try do
    if mode == :native,
      do: Hist.Kernels.entropy(<<1, 2>>, 0),
      else: Hist.Kernels.__defk_elixir__(:entropy, [<<1, 2>>, 0])

    fail.("entropy w = 0 did not raise (#{mode})")
  rescue
    ArithmeticError -> :ok
  end
end

# Forced yields: every resume path of the long loops, on 1 MB.
mb = binary_part(input, 0, 1_048_576)
plain = {Hist.Kernels.histogram(mb), Hist.Kernels.entropy(mb, w)}
Hist.Kernels.__defk_force_yields__(true)

forced =
  try do
    {Hist.Kernels.histogram(mb), Hist.Kernels.entropy(mb, w)}
  after
    Hist.Kernels.__defk_force_yields__(false)
  end

if forced != plain or
     plain !=
       {Hist.Kernels.__defk_elixir__(:histogram, [mb]),
        Hist.Kernels.__defk_elixir__(:entropy, [mb, w])},
   do: fail.("forced yields")

# The full input: every side the same bytes.
hist_ref = Hist.Kernels.histogram(input)
ent_ref = Hist.Kernels.entropy(input, w)

check_hist = fn ->
  Hist.Elixir.histogram(input) == hist_ref and Hist.DefkParallel.histogram(input) == hist_ref and
    Hist.Elixir.pairs(input) == hist_ref
end

check_ent = fn ->
  Hist.Elixir.entropy(input, w) == ent_ref and Hist.DefkParallel.entropy(input, w) == ent_ref and
    Hist.Elixir.entropy_table(input, w) == ent_ref and byte_size(ent_ref) == 8 * div(size, w)
end

if not (check_hist.() and check_ent.()), do: fail.("16 MB input")

entropies = for <<e::float-64-native <- ent_ref>>, do: e
{lo_e, hi_e} = Enum.min_max(entropies)

IO.puts(
  "agreement: histogram exact and entropy bit for bit (kernel, Elixir mode, Elixir, parallel, forced yields); " <>
    "entropy #{Float.round(lo_e, 3)}..#{Float.round(hi_e, 3)} bits/byte"
)

# ------------------------------------------------------------ variants --

best = fn fun, runs ->
  fun.()

  1..runs
  |> Enum.map(fn _ ->
    :erlang.garbage_collect()
    elem(:timer.tc(fun), 0)
  end)
  |> Enum.min()
  |> Kernel./(1000)
  |> Float.round(3)
end

# Two rounds over every variant, the second in reverse order (interleaved).
rounds = fn vars, bin ->
  r1 = for {name, f} <- vars, do: {name, best.(fn -> f.(bin) end, 5)}
  r2 = for {name, f} <- Enum.reverse(vars), into: %{}, do: {name, best.(fn -> f.(bin) end, 5)}
  for {name, t} <- r1, do: IO.puts("  #{String.pad_trailing(name, 52)} #{t}  #{r2[name]}")
end

if System.get_env("HIST_VARIANTS") do
  alias Hist.Variants, as: V
  slow_in = mb
  slow_ref = Hist.Kernels.histogram(slow_in)

  IO.puts("\nhistogram variants (best of 3 at 1 MB, ms; x16 for 16 MB):")

  for {name, f} <- [
        {"E1 bin_to_list |> Enum.frequencies", &V.freq/1},
        {"E2 comprehension, Map.update", &V.map_update/1},
        {"E3 256-tuple, setelement per byte", &V.tuple/1},
        {"E4 :binary.matches per byte value", &V.matches/1}
      ] do
    if f.(slow_in) != slow_ref, do: fail.(name)
    IO.puts("  #{String.pad_trailing(name, 52)} #{best.(fn -> f.(slow_in) end, 3)}")
  end

  par = System.schedulers_online()

  hvars = [
    {"E5 :counters, 1 byte per step", &V.counters1/1},
    {"E6 :counters, 8 bytes per step", &V.counters8/1},
    {"E7 :counters, comprehension", &V.comprehension/1},
    {"E8 :atomics, 1 byte per step", &V.atomics1/1},
    {"E9 :atomics, 8 bytes per step", &Hist.Elixir.atomics8/1},
    {"E10 16-bit pairs into :atomics, one process", &Hist.Elixir.pairs/1},
    {"E11 E6 in #{par} chunks", V.par(&V.counters8/1)},
    {"E12 E6 in #{par} chunks, one shared :counters", &V.shared_counters/1},
    {"E13 E9 in #{par} chunks", V.par(&Hist.Elixir.atomics8/1)},
    {"E14 E10 in #{par} chunks (baseline)", &Hist.Elixir.histogram/1},
    {"D1 kernel, one table, one call", &Hist.Kernels.histogram1/1},
    {"D2 kernel, four tables, one call", &Hist.Kernels.histogram/1},
    {"D1 in #{par} chunks", V.par(&Hist.Kernels.histogram1/1)},
    {"D2 in #{par} chunks (defk side)", &Hist.DefkParallel.histogram/1}
  ]

  for {name, f} <- hvars, f.(input) != hist_ref, do: fail.(name)

  IO.puts("\nhistogram variants at 16 MB (best of 5, ms; round 1, round 2 reversed):")
  rounds.(hvars, input)

  IO.puts("\none process, E9 (:atomics, 8 bytes) against E10 (pairs) by size (best of 5, ms):")

  for n <- [4096, 16_384, 65_536, 131_072, 262_144, 524_288, 1_048_576] do
    part = binary_part(input, 0, n)
    a = best.(fn -> Hist.Elixir.atomics8(part) end, 5)
    b = best.(fn -> Hist.Elixir.pairs(part) end, 5)
    IO.puts("  #{String.pad_trailing(to_string(n), 9)} E9 #{a}  E10 #{b}")
  end

  IO.puts("\nentropy variants (w = #{w}):")
  slow_e = Hist.Kernels.entropy(slow_in, w)

  for {name, f} <- [
        {"N1 Enum.frequencies per window (1 MB)", &V.ent_freq(&1, w)},
        {"N2 256-tuple per window (1 MB)", &V.ent_tuple(&1, w)}
      ] do
    if f.(slow_in) != slow_e, do: fail.(name)
    IO.puts("  #{String.pad_trailing(name, 52)} #{best.(fn -> f.(slow_in) end, 3)}")
  end

  evars = [
    {"N3 :counters 8 bytes/step, get + put", &V.ent_counters(&1, w)},
    {"N4 :atomics 8 bytes/step, exchange", &V.ent_atomics(&1, w)},
    {"N5 N4 + term table, one process", &Hist.Elixir.entropy_table(&1, w)},
    {"N6 N3 in #{par} chunks", V.ent_par(&V.ent_counters/2, w)},
    {"N7 N4 in #{par} chunks", V.ent_par(&V.ent_atomics/2, w)},
    {"N8 N5 in #{par} chunks (baseline)", &Hist.Elixir.entropy(&1, w)},
    {"D3 kernel, one table, log per bin", &Hist.Kernels.entropy1(&1, w)},
    {"D4 kernel, four tables, log per bin", &Hist.Kernels.entropy4(&1, w)},
    {"D5 kernel, four tables, term table", &Hist.Kernels.entropy(&1, w)},
    {"D3 in #{par} chunks", V.ent_par(&Hist.Kernels.entropy1/2, w)},
    {"D5 in #{par} chunks (defk side)", &Hist.DefkParallel.entropy(&1, w)}
  ]

  for {name, f} <- evars, f.(input) != ent_ref, do: fail.(name)

  IO.puts("entropy variants at 16 MB (best of 5, ms; round 1, round 2 reversed):")
  rounds.(evars, input)
end

# Beside the verdicts: one process against one call.
IO.puts("\none process / one call, 16 MB (best of 7, ms):")
eh = best.(fn -> Hist.Elixir.one(input) end, 7)
dh = best.(fn -> Hist.Kernels.histogram(input) end, 7)
IO.puts("  histogram  Elixir #{eh}  defk #{dh}  (#{Float.round(eh / dh, 1)}x)")
ee = best.(fn -> Hist.Elixir.entropy_table(input, w) end, 7)
de = best.(fn -> Hist.Kernels.entropy(input, w) end, 7)
IO.puts("  entropy    Elixir #{ee}  defk #{de}  (#{Float.round(ee / de, 1)}x)")

# -------------------------------------------------------------- report --

sweep_fun = fn n ->
  part = binary_part(input, 0, n)
  {fn -> Hist.Elixir.one(part) end, fn -> Hist.Kernels.histogram(part) end}
end

Defk.Bench.report(
  name: "byte_histogram",
  expected: :good,
  baseline: :optimized,
  runs: 9,
  realistic_size: "16 MB, #{System.schedulers_online()} chunks each side",
  elixir: fn -> Hist.Elixir.histogram(input) end,
  defk: fn -> Hist.DefkParallel.histogram(input) end,
  check: check_hist,
  sweep: {[4096, 65_536, 1_048_576, size], sweep_fun},
  sweep_runs: 5,
  reason:
    "an indexed increment per byte: Elixir's best is a BIF call per two bytes (:atomics over 16-bit pairs), the kernel a plain store into four tables"
)

r_ent =
  Defk.Bench.report(
    name: "windowed_entropy",
    expected: :good,
    baseline: :optimized,
    runs: 9,
    realistic_size: "16 MB in 4 KiB windows, #{System.schedulers_online()} chunks each side",
    elixir: fn -> Hist.Elixir.entropy(input, w) end,
    defk: fn -> Hist.DefkParallel.entropy(input, w) end,
    check: check_ent,
    reason:
      "a histogram per window plus 256 table lookups: Elixir pays a BIF call per byte and per bin, the kernel neither"
  )

# mix defk.examples reads the first DEFK_RESULT line; the second is checked here.
if not r_ent.correct or r_ent.verdict != r_ent.expected do
  IO.puts(
    "windowed_entropy: verdict #{r_ent.verdict}, expected #{r_ent.expected}, correct #{r_ent.correct}"
  )

  System.halt(1)
end
