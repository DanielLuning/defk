# hll_update_many: fold a batch of pre-hashed u64s into a HyperLogLog
# sketch (p = 14), against ex_data_sketch 0.10.3 (Pure Elixir and Rust NIF
# backends)
#
# The job: count distinct users, sessions or keys in a stream. Each event's
# key is hashed to a u64, and a batch of hashes is folded into the sketch's
# 2^p one-byte registers: the top p bits pick a register, which keeps the
# largest rank (1 + leading zeros of the other 64 - p bits) it has seen.
# ex_data_sketch is the Hex answer; its Rust backend exists because its
# Pure backend is slow. Compared at the backend layer, from the list of
# hashes a caller has: Backend.Pure.hll_update_many(state, hashes, p: 14)
# is the anchor, Backend.Rust.hll_update_many(state, hashes, p: 14) the NIF
# (it packs the list to a binary in Elixir with Enum.map + IO.iodata_to_binary,
# copies the state once in and once out per call, as the kernel does, and
# runs on a dirty CPU scheduler above 10k hashes). The public HLL.update_many
# (10k chunks, raw-item hashing) is out of scope.
#
# Realistic size (declared before the numbers): a batch of 100k hashes into
# a p = 14 sketch (16 KB of registers) that already holds 50k hashes, e.g.
# one ingest window of event ids. The other size is a 100-hash batch (one
# small request or Broadway batch). The sweep has 10k, the chunk the public
# API hands the backend.
#
# Expected verdict: good.
#
#   elixir examples/hll_update_many.exs                 # agreement + report
#   HLL_VARIANTS=1 elixir examples/hll_update_many.exs  # also every variant
#
# All numbers below are PROVISIONAL, MEASURED UNDER LOAD (two other
# benchmark runs shared the machine; M-series Mac, 12 schedulers, OTP 29,
# Elixir 1.20). The quiet-machine run is defk-sgw.4.
#
# Elixir baseline: optimised. Best of 7, ms (100 and 316 hashes: the mean of
# 2000 calls); every variant returns the anchor's state byte for byte:
#
#                                              100     1k    10k   100k
#   E0 anchor: Backend.Pure.hll_update_many  0.044  0.17   3.1   17-24
#   E1 E0 with a top-down rank               0.036  0.10   2.5   10.3
#   E2 sorted integer keys + splice          0.019  0.058  1.6   9.2   <- baseline below 5k
#   E3 :atomics max ranks, one rebuild       0.48   0.21   0.50  3.3   <- baseline from 5k
#   E4 E3, hash split by bit syntax          0.48   0.21   0.48  4.0
#   E5 :array, one rebuild                   0.83   0.21   1.4   5.4
#   E6 tuple, put_elem per raised register   2.3    1.7    8.5   (not run)
#   E7 bit-syntax register update per hash   0.026  0.86   1.8   8.6
#   E8 E3 in one task per scheduler          0.53   0.28   0.67  4.4
#
# The anchor counts leading zeros by shifting one bit at a time (~50 steps
# per hash); counting from the top bit down stops after ~2 compares (E1).
# Below ~5k hashes the cheapest is to touch only the registers the batch
# raises: one integer per hash (bucket <<< 6 ||| rank), :lists.sort, and a
# splice of each bucket's last key (E2). From 5k up, an :atomics array of the
# batch's max ranks and one rebuilt binary (E3) wins: per-hash cost ~30 ns,
# mostly bsr/band on the half of the hashes that are bignums (>= 2^59). Bit
# syntax for the split (E4) is slower; :array (E5) and a tuple (E6, a 16k
# copy per raise) lose; the per-hash binary update (E7) is fine at 100 and
# poor beyond. Splitting across schedulers (E8) loses: sending the list
# chunks to the tasks copies them, and the work is only ~3 ms. The baseline
# (Hll.Elixir.update_many/3) is E2 below 5k hashes, E3 from 5k.
#
# defk: Hll.Kernels.update_many, the register loop over a [u64] of hashes,
# with clz(x) for the rank. The state binary is copied once, before the
# loop, and written in place. The list is packed end to end, and the pack
# is the cost: the kernel takes 0.07 ms of 0.36 ms at 100k.
#
#                                              100     1k    10k   100k
#   D  defk: pack + kernel                   0.002  0.006  0.031 0.36
#   D' the kernel alone, packed beforehand   0.001  0.001  0.008 0.07
#   P1 pack: append 4 at a time (defk's)     0.001  0.004  0.025 0.28
#   P2 pack: append 1 at a time              0.002  0.005  0.038 1.1
#   P3 pack: comprehension, into: <<>>       0.003  0.014  0.12  2.4
#   P4 pack: Enum.map + iodata (the NIF's)   0.002  0.015  0.12  2.3
#
# defk at 100k was 0.36-0.38 ms best of 7 but 1.06 ms best of 3 in the sweep
# (defk-9p6.27): Defk.Bench's full GC left the caller's 100k-element list in
# the young heap, and a minor GC that copied it (~0.6 ms) landed in some runs.
# Defk.Bench now follows the full sweep with a minor GC, so the list starts in
# the old heap: report and sweep both give 0.36-0.40 ms (loaded, provisional).
# The Elixir side allocates enough to have paid the copy in every run.
#
# Result at 100k: Elixir 3.4-3.5 ms, defk 0.36-0.38 ms: 9.2-9.4x, good (the
# sweep agrees now). At 100 hashes: Elixir 0.020 ms, defk
# 0.0013-0.0021 ms (mean of 5000 calls), 10-15x. Sweep (100 to 100k, x3.16):
# 2.7-5x at 100, 12-17x from 1k to 31k, 9x at 100k; the
# crossover is 100, the smallest size.
#
# Native: the NIF is 2.55-2.8 ms at 100k (defk 6.9-7.4x faster) and 0.003 ms at
# 100: its Enum.map + iodata pack is 2.3 ms of it. Fed by defk's packer it
# is 0.46 ms (variant N'), level with defk: the loops are the same, the
# difference is the Elixir glue. Tick gaps (1 ms ticker, one scheduler,
# 100k): ~2 ms max and p99 for Elixir, defk and the NIF alike, the loaded
# machine's floor; the jobs take 0.4-3.5 ms and the NIF runs on a dirty
# scheduler here.
#
# Agreement, checked on every run (a mismatch exits 1): the eight Elixir
# variants, the baseline, defk, the kernel's Elixir mode, the NIF and the NIF
# fed by defk's packer give Backend.Pure's state binary byte for byte, for
# p = 4, 10, 14, 16, an empty and a filled state, edge hashes (0, 2^64 - 1,
# an all-zero low field, each single bit set and cleared), 500 and 5000
# random hashes, and every sweep batch.

Mix.install([
  {:defk, path: Path.expand("..", __DIR__)},
  {:ex_data_sketch, "0.10.3"}
])

defmodule Hll.Kernels do
  use Defk, elixir_mode: true

  @mask64 0xFFFFFFFFFFFFFFFF

  # ex_data_sketch's HLL state: a 4-byte header (version, p, 2 reserved
  # bytes) and 2^p one-byte registers. The top p bits of a hash pick the
  # register; the rank is 1 + the leading zeros of the low 64 - p bits,
  # counted in a (64 - p)-bit field, so an all-zero field gives 64 - p + 1.
  # clz of the field shifted to the top counts the same zeros, and 64 for
  # zero, which min/2 caps at 64 - p. The input state is copied once, before
  # the loop (the caller's binary is never changed), and written in place.
  defk update_many(state :: [u8], hashes :: [u64], p :: i64) :: [u8] do
    if p < 4 or p > 16 or length(state) != 4 + bsl(1, p) do
      raise ArgumentError, "invalid HLL state length or p"
    end

    bits = 64 - p

    for h <- hashes do
      j = 4 + bsr(h, bits)
      r = min(clz(band(bsl(h, p), @mask64)), bits) + 1
      state[j] = max(state[j], r)
    end

    state
  end
end

defmodule Hll.Elixir do
  import Bitwise

  # ---- rank: 1 + leading zeros of w in a `bits`-bit field (bits + 1 for 0)

  # The anchor's count (Backend.Pure.count_leading_zeros/2 + 1): the bit
  # length of w by shifting right one bit at a time, ~50 steps for a random
  # hash at p = 14.
  def rank_bottom_up(w, bits), do: ExDataSketch.Backend.Pure.count_leading_zeros(w, bits) + 1

  # From the top bit down: half the hashes stop at the first compare, a
  # quarter at the second, so ~2 compares per hash on average.
  def rank_top_down(w, bits), do: td(w, 1 <<< (bits - 1), 1)

  defp td(w, t, r) when w >= t, do: r
  defp td(_w, 1, r), do: r + 1
  defp td(w, t, r), do: td(w, t >>> 1, r + 1)

  # ---- E0: the anchor, Backend.Pure.hll_update_many/3 (a map of bucket =>
  # max rank via Enum.reduce, sorted, spliced into the registers)
  def pure(state, hashes, p), do: ExDataSketch.Backend.Pure.hll_update_many(state, hashes, p: p)

  # ---- E1: E0 with the top-down rank
  def map_splice(state, hashes, p) do
    bits = 64 - p
    mask = (1 <<< bits) - 1
    top = 1 <<< (bits - 1)
    m = 1 <<< p
    <<header::binary-size(4), regs::binary-size(^m)>> = state
    updates = map_fold(hashes, bits, mask, top, %{})
    sorted = updates |> Map.to_list() |> List.keysort(0)
    IO.iodata_to_binary([header | splice(regs, sorted, 0, [])])
  end

  defp map_fold([], _bits, _mask, _top, acc), do: acc

  defp map_fold([h | t], bits, mask, top, acc) do
    b = h >>> bits
    r = td(h &&& mask, top, 1)

    acc =
      case acc do
        %{^b => old} when old >= r -> acc
        _ -> Map.put(acc, b, r)
      end

    map_fold(t, bits, mask, top, acc)
  end

  defp splice(rest, [], _offset, acc), do: :lists.reverse([rest | acc])

  defp splice(regs, [{b, r} | tail], offset, acc) do
    skip = b - offset
    <<before::binary-size(^skip), old, rest::binary>> = regs
    splice(rest, tail, b + 1, [max(old, r), before | acc])
  end

  # ---- E2: one integer per hash (bucket <<< 6 ||| rank), :lists.sort, then
  # one walk that splices the last (largest) rank of each bucket
  def sort_splice(state, hashes, p) do
    bits = 64 - p
    mask = (1 <<< bits) - 1
    top = 1 <<< (bits - 1)
    m = 1 <<< p
    <<header::binary-size(4), regs::binary-size(^m)>> = state
    keys = :lists.sort(keys(hashes, bits, mask, top, []))
    IO.iodata_to_binary([header | ksplice(regs, keys, 0, [])])
  end

  defp keys([], _bits, _mask, _top, acc), do: acc

  defp keys([h | t], bits, mask, top, acc),
    do: keys(t, bits, mask, top, [(h >>> bits) <<< 6 ||| td(h &&& mask, top, 1) | acc])

  defp ksplice(rest, [], _offset, acc), do: :lists.reverse([rest | acc])

  # skip to the last key of this bucket (the sort puts its largest rank last)
  defp ksplice(regs, [k1, k2 | tail], offset, acc) when k1 >>> 6 == k2 >>> 6,
    do: ksplice(regs, [k2 | tail], offset, acc)

  defp ksplice(regs, [k | tail], offset, acc) do
    b = k >>> 6
    skip = b - offset
    <<before::binary-size(^skip), old, rest::binary>> = regs
    ksplice(rest, tail, b + 1, [max(old, k &&& 63), before | acc])
  end

  # ---- E3: an :atomics array of the batch's max rank per register, then
  # the output binary rebuilt once, merging the old registers
  def atomics(state, hashes, p) do
    bits = 64 - p
    mask = (1 <<< bits) - 1
    top = 1 <<< (bits - 1)
    m = 1 <<< p
    <<header::binary-size(4), regs::binary-size(^m)>> = state
    a = :atomics.new(m, signed: false)
    atomics_fold(hashes, a, bits, mask, top)
    merge_atomics(regs, a, 1, header)
  end

  defp atomics_fold([], _a, _bits, _mask, _top), do: :ok

  defp atomics_fold([h | t], a, bits, mask, top) do
    i = (h >>> bits) + 1
    r = td(h &&& mask, top, 1)
    if r > :atomics.get(a, i), do: :atomics.put(a, i, r)
    atomics_fold(t, a, bits, mask, top)
  end

  defp merge_atomics(<<>>, _a, _i, acc), do: acc

  defp merge_atomics(<<old, rest::binary>>, a, i, acc),
    do: merge_atomics(rest, a, i + 1, <<acc::binary, max(old, :atomics.get(a, i))>>)

  # ---- E4: E3 with the hash split by bit syntax instead of bsr/band (the
  # hash is a bignum from 2^59 up, so bsr/band allocate)
  def atomics_bits(state, hashes, p) do
    bits = 64 - p
    top = 1 <<< (bits - 1)
    m = 1 <<< p
    <<header::binary-size(4), regs::binary-size(^m)>> = state
    a = :atomics.new(m, signed: false)
    atomics_bits_fold(hashes, a, p, bits, top)
    merge_atomics(regs, a, 1, header)
  end

  defp atomics_bits_fold([], _a, _p, _bits, _top), do: :ok

  defp atomics_bits_fold([h | t], a, p, bits, top) do
    <<b::size(^p), w::size(^bits)>> = <<h::64>>
    r = td(w, top, 1)
    if r > :atomics.get(a, b + 1), do: :atomics.put(a, b + 1, r)
    atomics_bits_fold(t, a, p, bits, top)
  end

  # ---- E5: an :array of the registers (decoded once), rebuilt once
  def array(state, hashes, p) do
    bits = 64 - p
    mask = (1 <<< bits) - 1
    top = 1 <<< (bits - 1)
    m = 1 <<< p
    <<header::binary-size(4), regs::binary-size(^m)>> = state
    arr = :array.from_list(:binary.bin_to_list(regs))
    arr = array_fold(hashes, arr, bits, mask, top)
    IO.iodata_to_binary([header | :array.to_list(arr)])
  end

  defp array_fold([], arr, _bits, _mask, _top), do: arr

  defp array_fold([h | t], arr, bits, mask, top) do
    b = h >>> bits
    r = td(h &&& mask, top, 1)
    arr = if r > :array.get(b, arr), do: :array.set(b, r, arr), else: arr
    array_fold(t, arr, bits, mask, top)
  end

  # ---- E6: a tuple of the registers, put_elem per raised register (each
  # put_elem copies the 2^p-element tuple)
  def tuple(state, hashes, p) do
    bits = 64 - p
    mask = (1 <<< bits) - 1
    top = 1 <<< (bits - 1)
    m = 1 <<< p
    <<header::binary-size(4), regs::binary-size(^m)>> = state
    t = regs |> :binary.bin_to_list() |> List.to_tuple()
    t = tuple_fold(hashes, t, bits, mask, top)
    IO.iodata_to_binary([header | Tuple.to_list(t)])
  end

  defp tuple_fold([], t, _bits, _mask, _top), do: t

  defp tuple_fold([h | rest], t, bits, mask, top) do
    i = (h >>> bits) + 1
    r = td(h &&& mask, top, 1)
    t = if r > elem(t, i - 1), do: put_elem(t, i - 1, r), else: t
    tuple_fold(rest, t, bits, mask, top)
  end

  # ---- E7: the bit-syntax register update per hash (Backend.Pure.hll_update
  # in a loop: each raised register rebuilds the 2^p + 4-byte binary)
  def bin_update(state, hashes, p) do
    bits = 64 - p
    mask = (1 <<< bits) - 1
    top = 1 <<< (bits - 1)
    bin_fold(hashes, state, bits, mask, top)
  end

  defp bin_fold([], s, _bits, _mask, _top), do: s

  defp bin_fold([h | t], s, bits, mask, top) do
    skip = 4 + (h >>> bits)
    r = td(h &&& mask, top, 1)
    <<before::binary-size(^skip), old, rest::binary>> = s
    s = if r > old, do: <<before::binary, r, rest::binary>>, else: s
    bin_fold(t, s, bits, mask, top)
  end

  # ---- E8: E3 on every scheduler: the list split into one chunk per
  # scheduler, each folded by a task into the one shared :atomics array
  def atomics_par(state, hashes, p) do
    bits = 64 - p
    mask = (1 <<< bits) - 1
    top = 1 <<< (bits - 1)
    m = 1 <<< p
    <<header::binary-size(4), regs::binary-size(^m)>> = state
    a = :atomics.new(m, signed: false)
    sched = System.schedulers_online()
    size = div(length(hashes) + sched - 1, sched)

    hashes
    |> Enum.chunk_every(max(size, 1))
    |> Task.async_stream(&atomics_max_fold(&1, a, bits, mask, top), max_concurrency: sched)
    |> Stream.run()

    merge_atomics(regs, a, 1, header)
  end

  # several writers: compare_exchange so a larger rank is never overwritten
  defp atomics_max_fold([], _a, _bits, _mask, _top), do: :ok

  defp atomics_max_fold([h | t], a, bits, mask, top) do
    i = (h >>> bits) + 1
    r = td(h &&& mask, top, 1)
    raise_to(a, i, r, :atomics.get(a, i))
    atomics_max_fold(t, a, bits, mask, top)
  end

  defp raise_to(_a, _i, r, old) when r <= old, do: :ok

  defp raise_to(a, i, r, old) do
    case :atomics.compare_exchange(a, i, old, r) do
      :ok -> :ok
      now -> raise_to(a, i, r, now)
    end
  end

  # ---- the optimised baseline: E2 (sorted keys + splice) below
  # `@atomics_min` hashes, E3 (:atomics, one rebuild) from there up; see the
  # header
  @atomics_min 5_000
  def update_many(state, hashes, p) do
    if length(hashes) < @atomics_min,
      do: sort_splice(state, hashes, p),
      else: atomics(state, hashes, p)
  end
end

defmodule Hll.Defk do
  # The caller has a list; packing it is part of defk's cost.
  def update_many(state, hashes, p), do: Hll.Kernels.update_many(state, pack(hashes), p)

  # Tail recursion appending four hashes at a time to one binary (the
  # runtime grows it in place): 2-5x faster than a comprehension or the
  # NIF's Enum.map + iodata.
  def pack(hashes), do: pack(hashes, <<>>)

  defp pack([a, b, c, d | t], acc),
    do:
      pack(
        t,
        <<acc::binary, a::unsigned-64-native, b::unsigned-64-native, c::unsigned-64-native,
          d::unsigned-64-native>>
      )

  defp pack([h | t], acc), do: pack(t, <<acc::binary, h::unsigned-64-native>>)
  defp pack([], acc), do: acc

  # packing variants (timed with HLL_VARIANTS=1)
  def pack_append(hashes), do: pack_append(hashes, <<>>)
  defp pack_append([], acc), do: acc
  defp pack_append([h | t], acc), do: pack_append(t, <<acc::binary, h::unsigned-64-native>>)

  def pack_for(hashes), do: for(h <- hashes, into: <<>>, do: <<h::unsigned-64-native>>)

  def pack_iodata(hashes),
    do: hashes |> Enum.map(&<<&1::unsigned-little-64>>) |> IO.iodata_to_binary()
end

alias ExDataSketch.Backend.{Pure, Rust}
import Bitwise

p = 14

# ---------------------------------------------------------------- data --

# Pre-hashed u64s, uniform over 0..2^64 - 1 (as xxh3 or murmur3 output is),
# held as an Elixir list, as the backend takes them. The sketch already
# holds 50k hashes: update_many folds a batch into a sketch in use.
:rand.seed(:exsss, {14, 14, 14})
rand_hashes = fn n -> for _ <- 1..n//1, do: :rand.uniform(1 <<< 64) - 1 end
state0 = Pure.hll_update_many(Pure.hll_new(p: p), rand_hashes.(50_000), p: p)

sizes = [100, 316, 1_000, 3_162, 10_000, 31_623, 100_000]
batches = Map.new(sizes, &{&1, rand_hashes.(&1)})
big = 100_000
small = 100

elixir_run = fn n -> fn -> Hll.Elixir.update_many(state0, batches[n], p) end end
defk_run = fn n -> fn -> Hll.Defk.update_many(state0, batches[n], p) end end
native_run = fn n -> fn -> Rust.hll_update_many(state0, batches[n], p: p) end end

# ----------------------------------------------------------- agreement --
# Every Elixir variant, defk (native and Elixir mode) and the NIF must give
# the anchor's state binary byte for byte; a mismatch stops the script.

fail = fn what ->
  IO.puts("DISAGREEMENT: #{what}")
  System.halt(1)
end

# The NIF the backend calls (dirty above its 10k threshold), with defk's
# packer in place of the backend's Enum.map + iodata.
nif_pack = fn s, hs, p ->
  bin = Hll.Defk.pack(hs)

  {:ok, out} =
    if length(hs) > 10_000,
      do: ExDataSketch.Nif.hll_update_many_dirty_nif(s, bin, p),
      else: ExDataSketch.Nif.hll_update_many_nif(s, bin, p)

  out
end

variants = [
  {"E1 map + splice, top-down rank", &Hll.Elixir.map_splice/3},
  {"E2 sorted keys + splice", &Hll.Elixir.sort_splice/3},
  {"E3 :atomics, one rebuild", &Hll.Elixir.atomics/3},
  {"E4 E3 + bit-syntax hash split", &Hll.Elixir.atomics_bits/3},
  {"E5 :array, one rebuild", &Hll.Elixir.array/3},
  {"E6 tuple, put_elem per raise", &Hll.Elixir.tuple/3},
  {"E7 bit-syntax register update", &Hll.Elixir.bin_update/3},
  {"E8 E3 in one task per scheduler", &Hll.Elixir.atomics_par/3},
  {"baseline", &Hll.Elixir.update_many/3},
  {"defk", &Hll.Defk.update_many/3},
  {"defk Elixir mode",
   fn s, hs, p -> Hll.Kernels.__defk_elixir__(:update_many, [s, Hll.Defk.pack(hs), p]) end},
  {"ex_data_sketch Rust NIF", fn s, hs, p -> Rust.hll_update_many(s, hs, p: p) end},
  {"ex_data_sketch Rust NIF, defk's pack", fn s, hs, p -> nif_pack.(s, hs, p) end}
]

# Edge hashes: 0 and 2^64 - 1, an all-zero low field (rank 64 - p + 1) in
# the first and last registers, each single low bit, small and bignum values.
edges =
  [0, (1 <<< 64) - 1, 1, 1 <<< (64 - p), ((1 <<< p) - 1) <<< (64 - p), (1 <<< (64 - p)) - 1] ++
    for(k <- 0..63, do: 1 <<< k) ++ for(k <- 0..63, do: (1 <<< 64) - 1 - (1 <<< k))

cases =
  for p <- [4, 10, 14, 16],
      s <- [
        Pure.hll_new(p: p),
        Pure.hll_update_many(Pure.hll_new(p: p), rand_hashes.(3_000), p: p)
      ],
      hs <- [[], edges, rand_hashes.(500), rand_hashes.(5_000)] do
    {p, s, hs}
  end

cases = cases ++ for n <- sizes, do: {p, state0, batches[n]}

for {p, s, hs} <- cases do
  ref = Pure.hll_update_many(s, hs, p: p)

  for {name, f} <- variants, f.(s, hs, p) != ref do
    fail.("#{name} vs Backend.Pure at p = #{p}, #{length(hs)} hashes")
  end
end

IO.puts(
  "agreement: #{length(variants)} variants, defk, its Elixir mode and the Rust NIF give Backend.Pure's state byte for byte (#{length(cases)} cases, p = 4..16)"
)

# ------------------------------------------------------------ variants --
# HLL_VARIANTS=1 times every variant (best of 7, ms) at every sweep size.

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

# Mean of many calls, for the small sizes where one call is a few us.
mean = fn fun, iters ->
  fun.()
  :erlang.garbage_collect()
  {us, _} = :timer.tc(fn -> for _ <- 1..iters, do: fun.() end)
  Float.round(us / iters / 1000, 4)
end

if System.get_env("HLL_VARIANTS") do
  timed =
    [{"E0 anchor: Backend.Pure.hll_update_many", &Hll.Elixir.pure/3}] ++
      Enum.take(variants, 9) ++
      [
        {"D  defk: pack + kernel", &Hll.Defk.update_many/3},
        {"D' kernel alone, list packed beforehand", :kernel},
        {"P1 pack: append 4 at a time (defk's)", :pack},
        {"P2 pack: append 1 at a time", :pack_append},
        {"P3 pack: comprehension", :pack_for},
        {"P4 pack: Enum.map + iodata (the NIF's)", :pack_iodata},
        {"N  ex_data_sketch Rust NIF", fn s, hs, p -> Rust.hll_update_many(s, hs, p: p) end},
        {"N' the same NIF, fed by defk's pack", :nif_pack}
      ]

  IO.puts("\nvariants (best of 7, ms; under 1k hashes the mean of 2000 calls):")

  IO.puts(
    "  " <>
      String.pad_trailing("", 44) <> Enum.map_join(sizes, "", &String.pad_leading("#{&1}", 10))
  )

  for {name, f} <- timed do
    cells =
      for n <- sizes do
        hs = batches[n]
        packed = Hll.Defk.pack(hs)

        fun =
          case f do
            :kernel -> fn -> Hll.Kernels.update_many(state0, packed, p) end
            :nif_pack -> fn -> nif_pack.(state0, hs, p) end
            :pack -> fn -> Hll.Defk.pack(hs) end
            :pack_append -> fn -> Hll.Defk.pack_append(hs) end
            :pack_for -> fn -> Hll.Defk.pack_for(hs) end
            :pack_iodata -> fn -> Hll.Defk.pack_iodata(hs) end
            f -> fn -> f.(state0, hs, p) end
          end

        slow = String.starts_with?(name, "E6") and n > 10_000

        cond do
          slow -> "-"
          n < 1_000 -> mean.(fun, 2_000)
          true -> best.(fun, 7)
        end
      end

    IO.puts(
      "  " <>
        String.pad_trailing(name, 44) <>
        Enum.map_join(cells, "", &String.pad_leading("#{&1}", 10))
    )
  end
end

# The small size beside the verdict: one call is a few us, below the
# report's 1 us timer resolution, so it is the mean of 5000 calls.
e_small = mean.(elixir_run.(small), 5_000)
d_small = mean.(defk_run.(small), 5_000)
n_small = mean.(native_run.(small), 5_000)

IO.puts(
  "#{small} hashes (mean of 5000 calls): Elixir #{e_small} ms, defk #{d_small} ms (#{Float.round(e_small / d_small, 2)}x), NIF #{n_small} ms"
)

# -------------------------------------------------------------- report --

Defk.Bench.report(
  name: "hll_update_many",
  expected: :good,
  baseline: :optimized,
  realistic_size: "#{big} pre-hashed u64s into a p = 14 sketch",
  runs: 7,
  elixir: elixir_run.(big),
  defk: defk_run.(big),
  native: {native_run.(big), "ex_data_sketch 0.10.3 Backend.Rust (DirtyCpu above 10k hashes)"},
  check: fn ->
    ref = Pure.hll_update_many(state0, batches[big], p: p)
    elixir_run.(big).() == ref and defk_run.(big).() == ref and native_run.(big).() == ref
  end,
  sweep: {sizes, fn n -> {elixir_run.(n), defk_run.(n)} end},
  responsiveness: true,
  reason:
    "the pack of the caller's list costs 4x the register loop, yet defk is 9x the best Elixir (:atomics, one rebuild) at 100k and 10-15x at 100; the Rust NIF is level with defk once fed the same packer, 7x slower with its own"
)
