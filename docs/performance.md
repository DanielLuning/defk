# Performance on the BEAM: what is fast, what isn't, and how to fix it

A living guide to what we have measured about speed on the BEAM, in plain
Elixir and in defk kernels. It is written for defk's maintainers first and
users second: read it before you measure something, so you don't re-measure
what we already know or repeat a mistake we already made.

Elixir is the default (see [Purpose](../README.md#purpose-help-elixir-not-compete-with-it)).
Most of this guide is about making Elixir fast. A defk kernel is the answer
only where a well-optimised Elixir solution still falls clearly short.

## How to read an entry

Each entry has:

- **the claim**, in one sentence (the heading and the first line);
- **numbers** and the **conditions** they hold under;
- a small **sketch** of the fast and the slow spelling, taken from the source;
- the **source** (example file, ticket, commit) so you can re-check it;
- a **status**:
  - *measured*: a recorded run with no load noted. Most of these are single
    runs or a few runs on a developer machine, not a quiet-machine snapshot;
  - *provisional*: the source says the machine was loaded (other agents'
    builds and benchmarks running). Re-check against the quiet-machine
    snapshot (`defk-sgw.4`) when it lands;
  - *superseded*: replaced by a later result, which the entry names.

Unless an entry says otherwise, the machine is an M-series Mac (12
schedulers, performance and efficiency cores), OTP 29 and Elixir 1.20, and
the kernels are built by Apple clang. Times are best of N runs from
`Defk.Bench` or the example's own timer. Numbers are tied to these versions:
when OTP or Elixir changes, re-check the entries you rely on.

Commits are the last commit that touched the source file when this guide was
written. Example headers are the primary record; this guide points at them
and does not replace them. Nothing here was re-measured for the guide.

### Keeping it alive

When a workload, example or ticket teaches you something about speed, add or
update the entries here, **including what didn't help**. Give the numbers,
the conditions and the source; mark loaded runs provisional; never write a
number you did not measure or cannot cite. When a result is replaced, keep
the old entry, mark it superseded and say by what.

## Contents

1. [Measuring honestly](#1-measuring-honestly)
2. [Fast Elixir on binaries and numbers](#2-fast-elixir-on-binaries-and-numbers)
3. [BIFs and OTP libraries that are already native](#3-bifs-and-otp-libraries-that-are-already-native)
4. [Parallelism and schedulers](#4-parallelism-and-schedulers)
5. [The NIF boundary](#5-the-nif-boundary)
6. [Making a defk kernel fast](#6-making-a-defk-kernel-fast)
7. [When a hand-written or wrapper NIF is still the answer](#7-when-a-hand-written-or-wrapper-nif-is-still-the-answer)
8. [Myths we disproved and open questions](#8-myths-we-disproved-and-open-questions)

---

## 1. Measuring honestly

The rules are in [examples/README.md, "Measuring correctly"](https://github.com/DanielLuning/defk/blob/main/examples/README.md#measuring-correctly).
These entries are the evidence behind them.

### 1.1 Measure the Elixir alternatives; don't assume which is fastest

Spellings that look equivalent are not: `Enum.sum/1` is not just
`:lists.sum/1`, and `Enum.reduce/3` with a float accumulator is the slowest.

- **Numbers:** sum of 1M floats: `Enum.sum/1` 4.6 ms, `:lists.sum/1` 4.9 ms,
  tail recursion 5.0 ms, `Enum.reduce/3` from `0.0` 7.2 ms. Clamp of 1M
  floats: `Enum.map` with `min/max` 8.2 ms, body recursion 13.2 ms, a `for`
  comprehension 14.6 ms, guard clauses 14.7 ms.
- **Conditions:** 1M floats; load not recorded.
- **Source:** [`poor_list_data.exs`](https://github.com/DanielLuning/defk/blob/main/examples/poor_list_data.exs), [`poor_tiny_calls.exs`](https://github.com/DanielLuning/defk/blob/main/examples/poor_tiny_calls.exs) (commit 9116a42).
- **Status:** measured.

<!-- defk-example run: totals = [1.5, 2.5, 4.0]; readings = [-20.0, 5.0, 95.0] | defs: defp clamp_by_guards(x) when x < -10.0, do: -10.0; defp clamp_by_guards(x) when x > 90.0, do: 90.0; defp clamp_by_guards(x), do: x -->
```elixir
# fast
Enum.sum(totals)
Enum.map(readings, &min(max(&1, -10.0), 90.0))
# slow
Enum.reduce(totals, 0.0, &(&1 + &2))
for x <- readings, do: clamp_by_guards(x)
```

### 1.2 Keep shared inputs where a real app keeps them, not on the benchmark process's heap

A large input on the timing process's heap is copied by every major GC, and
that cost lands on whichever side triggers the GC.

- **Numbers:** `geo_nearest`: 500k tuples on the heap let GC triple the
  Elixir time, inflating defk's lead from 13x to 44x. `gorilla_encode`: a
  1M-point list on the heap doubled defk's time (~28-44 ms against 12.6-14.6
  ms from `:persistent_term`). `pcm_mix`: 1 s chunks measured 10 ms instead
  of 4 ms with the chunks on the heap.
- **Conditions:** geo_nearest load not recorded; gorilla_encode and pcm_mix under load.
- **Source:** [examples/README.md](https://github.com/DanielLuning/defk/blob/main/examples/README.md#measuring-correctly) rule 4, [`geo_nearest.exs`](https://github.com/DanielLuning/defk/blob/main/examples/geo_nearest.exs) (baf7d5f), [`gorilla_encode.exs`](https://github.com/DanielLuning/defk/blob/main/examples/gorilla_encode.exs) (a28db62), [`pcm_mix.exs`](https://github.com/DanielLuning/defk/blob/main/examples/pcm_mix.exs) (6b894ed).
- **Status:** measured (geo_nearest); provisional (gorilla_encode, pcm_mix).

<!-- defk-example run: records = [1, 2]; points = [3, 4] | defs: defp build_index(points), do: points -->
```elixir
# fast: built once, read by every request
:persistent_term.put(:geo_idx, records)
idx = :persistent_term.get(:geo_idx)
# slow: the index is a variable on the benchmark process's heap
idx = build_index(points)
```

Also keep only the last result of a repeated job (`Enum.reduce(blocks, nil, fn s, _ -> f.(s) end)`): a held list of results makes every GC walk it (`gorilla_encode.exs`).

### 1.3 A forced full GC leaves the caller's input list in the young heap

`Defk.Bench` runs `:erlang.garbage_collect()` before each timed run. A big
input list then sits in the young heap, and a minor GC inside the timed run
copies it. Low-allocating sides (a kernel) pay it only sometimes.

- **Numbers:** 100k-element u64 list (~500k words): the minor-GC copy is
  ~0.6 ms. `hll_update_many` defk side 0.36-0.38 ms best of 7, but 1.06 ms
  best of 3 in the sweep (4 of 4 runs), which reads as 3.2x instead of
  9.2-9.4x. Packing 100k hashes: ~270-460 us with 0 GCs, ~850-1100 us with 1 GC.
- **Conditions:** under load.
- **Source:** `defk-9p6.27` (open), `defk-9p6.15` comment 2026-10-10, [`hll_update_many.exs`](https://github.com/DanielLuning/defk/blob/main/examples/hll_update_many.exs) (070a179).
- **Status:** provisional; the fix (a second GC, or a fresh process per timed call) is not chosen yet.

### 1.4 Give a process that holds a chunk's lists a heap big enough for them

Without it the Elixir side regrows its heap after every forced GC.

- **Numbers:** `pcm_mix` Elixir 3.4 ms instead of 2.7 ms at 10 ms chunks,
  4-10 ms instead of 2.5 ms at 1 s chunks; the Membrane plugin 40-70 ms
  without it, ~20 ms with it.
- **Conditions:** under load; `min_heap_size` 32 MB, applied to every side.
- **Source:** [`pcm_mix.exs`](https://github.com/DanielLuning/defk/blob/main/examples/pcm_mix.exs) (6b894ed), `defk-9p6.14` comment 2026-10-10.
- **Status:** provisional.

```elixir
Process.flag(:min_heap_size, 4_000_000)   # words, ~32 MB
```

### 1.5 Compare like with like: parallel against parallel, one process against one call

One process of Elixir against one kernel call overstates defk when the
Elixir job can use every scheduler.

- **Numbers:** `image_blur`: one process against one call 26-29x (Elixir
  141-160 ms, defk 5.4-5.8 ms); both sides in 12 row bands 3.8-4.2x (Elixir
  9.1-9.9 ms, defk 2.3-2.5 ms). `rolling_stats`: one call ~34x (65 vs 1.9 ms);
  12 chunks each 5.0-7.8x (Elixir 10.8-11.7 ms, defk 1.5-2.3 ms).
  `geo_nearest`: 14x over one Elixir process, 3.2-3.9x over Elixir on all
  schedulers.
- **Conditions:** image_blur and rolling_stats under load.
- **Source:** [`image_blur.exs`](https://github.com/DanielLuning/defk/blob/main/examples/image_blur.exs) (4355011), [`rolling_stats.exs`](https://github.com/DanielLuning/defk/blob/main/examples/rolling_stats.exs) (7bfbe4c), [`geo_nearest.exs`](https://github.com/DanielLuning/defk/blob/main/examples/geo_nearest.exs) (baf7d5f), `defk-9p6.6`, `defk-9p6.7`, `defk-9p6.8`.
- **Status:** provisional (image_blur, rolling_stats); measured (geo_nearest).

### 1.6 Give both sides the same algorithm; a better Elixir algorithm can flip the verdict

- **Numbers:** `batched_levenshtein` was pre-registered as good. With Myers
  bit-parallel on both sides and Elixir chunked over all schedulers it is
  0.86-0.99x (Elixir 3.9-4.2 ms, defk 4.3-4.6 ms at 234k words): poor.
  `fuzzy_search`: the early cut-off gained 1.9x in Elixir (112 -> 60 ms per
  query) but 1.5x in the kernel (20.4-20.8 -> 14.1-14.2 ms), so the gap went
  from 5.4x to 4.2x. `geo_nearest`'s coarse-grid prefilter: Elixir 0.14 ms,
  defk 0.017 ms (8x), against 3.2-3.9x for the full scan.
- **Conditions:** batched_levenshtein and fuzzy_search under load (fuzzy_search load average 5-90).
- **Source:** [`batched_levenshtein.exs`](https://github.com/DanielLuning/defk/blob/main/examples/batched_levenshtein.exs) (27b5a8c), `defk-9p6.11`; [`fuzzy_search/README.md`](https://github.com/DanielLuning/defk/blob/main/examples/fuzzy_search/README.md) (4b8d17d), `defk-8i4`; [examples/README.md](https://github.com/DanielLuning/defk/blob/main/examples/README.md) geo_nearest row.
- **Status:** provisional (batched_levenshtein, fuzzy_search); measured (geo_nearest grid).

### 1.7 Load makes numbers provisional, and some differences are noise

- **Numbers:** under load a 1 ms ticker on one scheduler never reads below
  ~2 ms, for every side (cosine_topk, hll_update_many, gorilla_encode). Code
  layout alone moves a kernel about ±3% (count_primes yielding 177 vs 180-182
  ms, with `count_primes_via_call` moving the other way). Verdicts near a
  line flip run to run: `poor_substring_search` 1.03-1.11x read 1.0x on the
  scoreboard; `codecs` hex 2.02-2.04x reads marginal on a slow run;
  `gorilla_encode` 1.96-2.38x was marginal in 1 run of 8.
- **Conditions:** loaded runs (load average 5-90 across sessions).
- **Source:** `defk-wnu` (open), `defk-9p6.24` (open: proposes a ±5% tie band), `defk-9p6.13`/`.15`/`.16` comments.
- **Status:** provisional.

What to do: interleave the variants in one VM, alternate which goes first,
take best of 5 per round over several rounds, and report the run medians and
the range ([`bench/float_checks.exs`](https://github.com/DanielLuning/defk/blob/main/bench/float_checks.exs) is the
pattern). Don't assert wall-clock times in unit tests (`defk-m4b`), and run
examples one at a time (`run_all.exs` does).

### 1.8 Measure responsiveness with a ticker on one scheduler, and read the floor

`Defk.Bench.TickGap` (`responsiveness: true` in `Defk.Bench.report/1`) runs
a 1 ms ticker on one scheduler while each side runs once and reports the max
and p99 gap. A result at the ticker's floor says "not worse", not "yields":
`ws_masking`'s kernel shows 0.44 ms because the whole 16 MiB call fits inside
one tick. One run of a short job gives only 15-45 ticks, so p99 equals max
(`gorilla_encode`).

- **Source:** `lib/defk/bench/tick_gap.ex`, [`bench/tick_gap.exs`](https://github.com/DanielLuning/defk/blob/main/bench/tick_gap.exs), [`ws_masking.exs`](https://github.com/DanielLuning/defk/blob/main/examples/ws_masking.exs) (2ae646a), [`gorilla_encode.exs`](https://github.com/DanielLuning/defk/blob/main/examples/gorilla_encode.exs).
- **Status:** measured (method).

---

## 2. Fast Elixir on binaries and numbers

### 2.1 Append to a binary accumulator instead of building a list and packing it

`<<acc::binary, x::float-64-native>>` is optimised in place by the runtime,
and it avoids boxing every float result and the cons cells. Building a list
and packing it afterwards is the slowest option.

- **Numbers:** rolling mean/stddev of 1M samples, one process: two float
  lists (cons, reverse) ~100-110 ms; the same then packed with iodata
  ~335-370 ms (3x worse); two binary accumulators ~62-68 ms; plus 4 windows
  per step ~53-60 ms. (The first pass measured 308 ms inside `Defk.Bench`, GC
  and load dependent.)
- **Conditions:** 1M samples, window 60, best of 7, under load.
- **Source:** [`rolling_stats.exs`](https://github.com/DanielLuning/defk/blob/main/examples/rolling_stats.exs) (7bfbe4c), `defk-9p6.6`.
- **Status:** provisional.

<!-- defk-example skip: a fragment, a function head with its arguments elided -->
```elixir
# fast: sliding sums over two cursors into one binary, results appended
walk(<<v::float-64-native, rest::binary>>, <<old::float-64-native, trail::binary>>, w, s, q, means, stds)
#   ... s = s + v - old; means = <<means::binary, m::float-64-native>>
# slow: a list of floats, reversed, then packed
for x <- :lists.reverse(acc), into: <<>>, do: <<x::float-64-native>>
```

### 2.2 Handle several items per recursion step

One bigger match and several appends per step beat one item per step.

- **Numbers:** packing 100k u64s into a binary: append 4 at a time 0.28 ms,
  1 at a time 1.1 ms, comprehension `into: <<>>` 2.4 ms, `Enum.map` +
  iodata 2.3 ms. `gorilla_encode`: one point per append is ~3x slower to pack
  than four. `rolling_stats`: 4 windows per step ~53-60 ms against ~62-68 ms.
- **Conditions:** under load.
- **Source:** [`hll_update_many.exs`](https://github.com/DanielLuning/defk/blob/main/examples/hll_update_many.exs) (070a179), [`gorilla_encode.exs`](https://github.com/DanielLuning/defk/blob/main/examples/gorilla_encode.exs) (a28db62), [`rolling_stats.exs`](https://github.com/DanielLuning/defk/blob/main/examples/rolling_stats.exs).
- **Status:** provisional.

<!-- defk-example skip: a fragment, one clause of pack/2 beside the comprehensions it replaces -->
```elixir
# fast
defp pack([a, b, c, d | t], acc),
  do: pack(t, <<acc::binary, a::unsigned-64-native, b::unsigned-64-native,
                c::unsigned-64-native, d::unsigned-64-native>>)
# slow
for h <- hashes, into: <<>>, do: <<h::unsigned-64-native>>
hashes |> Enum.map(&<<&1::unsigned-little-64>>) |> IO.iodata_to_binary()
```

### 2.3 Walk binaries with patterns; avoid `:binary.at/2` random access

- **Numbers:** `image_blur` 1080p: a first pass reading 9 neighbours with
  `:binary.at/2` per pixel ~780-830 ms; a sliding three-row binary walk ~140
  ms in one process. Grayscale by binary comprehension 8 ms, by list
  accumulation + `list_to_binary` 23-59 ms. `image_ops` resize: `:binary.at`
  on the whole frame 42-43 ms, `binary_part` source rows + iodata rows
  17.6-18.4 ms; YUV420: `:binary.at` chroma 103-107 ms, row pairs walked with
  binary patterns 55-70 ms.
- **Conditions:** image_blur under load; image_ops load not recorded.
- **Source:** [`image_blur.exs`](https://github.com/DanielLuning/defk/blob/main/examples/image_blur.exs) (4355011), [`image_ops.exs`](https://github.com/DanielLuning/defk/blob/main/examples/image_ops.exs) (7f0904d).
- **Status:** provisional (image_blur); measured (image_ops).

<!-- defk-example run: rgb = <<1, 2, 3, 4, 5, 6>>; px = :binary.copy(<<7>>, 64); y0 = 1; stride = 8; gray = :binary.copy(<<9>>, 64); yy = 1; xx = 1; w = 8 -->
```elixir
# fast
for <<r, g, b <- rgb>>, into: <<>>, do: <<div(77 * r + 150 * g + 29 * b, 256)>>
row0 = binary_part(px, y0 * stride, stride)   # then :binary.at(row0, a)
# slow
for dy <- -1..1, dx <- -1..1, reduce: 0, do: (acc -> acc + :binary.at(gray, yy * w + xx))
```

What didn't help in `image_blur`: a separable blur in 16-bit rows (~124-180
ms against ~111 ms for the walk), and iodata or byte-list output (113 vs 111
ms).

### 2.4 Keep integers below 2^59: split 64-bit work into 32-bit halves

Integers above about 2^59 are bignums on the BEAM, allocated on the heap, and
every 64-bit multiply makes a 128-bit value before the mask. Two 32-bit
halves keep every value a small integer.

- **Numbers:** Keccak-256 per 32-byte message: 25 lanes as 64-bit integers
  ~50-62 us, lanes as two 32-bit halves ~2.6-2.9 us (about 20x). CRC-64: one
  integer goes bignum and is 10x slower than two halves. Gorilla encode
  (1,000 x 100 points): 64-bit float patterns as bignums 15.1-15.6 ms, 32-bit
  halves with 256-entry zero-count tuples 4.8-4.9 ms. Pure-Elixir 64-bit
  hashes (xxHash64, Murmur3, SipHash) run at 0.01-0.12 GB/s.
- **Conditions:** keccak, geohash_crc, hashes load not recorded; gorilla under load.
- **Source:** [`keccak.exs`](https://github.com/DanielLuning/defk/blob/main/examples/keccak.exs) (f81c2cd), [`geohash_crc.exs`](https://github.com/DanielLuning/defk/blob/main/examples/geohash_crc.exs) (ad7b46b), [`gorilla_encode.exs`](https://github.com/DanielLuning/defk/blob/main/examples/gorilla_encode.exs) (a28db62), [`hashes.exs`](https://github.com/DanielLuning/defk/blob/main/examples/hashes.exs) (0bc56d4).
- **Status:** measured; gorilla provisional.

<!-- defk-example run: crc64_halves("abc", 0, 0); crc64_whole("abc", 0) | defs: @t64_hi List.to_tuple(List.duplicate(0, 256)); @t64_lo List.to_tuple(List.duplicate(0, 256)); @t64_whole List.to_tuple(List.duplicate(0, 256)); defp crc64_halves(<<>>, hi, lo), do: {hi, lo}; defp crc64_whole(<<>>, crc), do: crc -->
```elixir
# fast: CRC-64 state in two small halves
defp crc64_halves(<<b, rest::binary>>, hi, lo) do
  idx = band(bxor(lo, b), 255)
  crc64_halves(rest, bxor(hi >>> 8, elem(@t64_hi, idx)),
               bxor(bor(lo >>> 8, band(hi, 0xFF) <<< 24), elem(@t64_lo, idx)))
end
# slow: one integer, a bignum above 2^59
defp crc64_whole(<<b, rest::binary>>, crc),
  do: crc64_whole(rest, bxor(elem(@t64_whole, band(bxor(crc, b), 255)), crc >>> 8))
```

When 32-bit values suffice the JIT is fast: CRC32C by slicing-by-8 runs at
1.6 GB/s in Elixir, and a kernel is only 1.39-1.65x ahead (`hashes.exs`).

### 2.5 Bit syntax does not beat `bsr`/`band` for splitting a bignum

- **Numbers:** HLL fold at 100k hashes: `<<b::size(^p), w::size(^bits)>> = <<h::64>>` 4.0 ms against `bsr`/`band` 3.3 ms (parity at 10k).
- **Conditions:** under load.
- **Source:** [`hll_update_many.exs`](https://github.com/DanielLuning/defk/blob/main/examples/hll_update_many.exs) (variant E4), `defk-9p6.15`.
- **Status:** provisional.

### 2.6 The JIT's 32-bit append loop beats 64-bit words

Widening a byte loop to 64-bit words makes it slower: the bigger append and
the word-wide integers cost more than the halved iteration count.

- **Numbers:** WebSocket masking, ns per frame at 125 B / 1 KiB / 1 MiB:
  Bandit's 32-bit loop 184 / 991 / 926,375; 64-bit words appended 335 / 1,888
  / 1,920,625; binary comprehension over 64-bit words 373 / 1,775 /
  1,844,625; 64-bit words as a list, joined 449 / 3,042 / 3,767,000. XOR as
  one big integer (`:binary.decode_unsigned`): 299 ns at 125 B, 58,422 ns at
  64 KiB, and a 1 MiB frame did not finish in two minutes.
- **Conditions:** best of 7 interleaved rounds, under load (load average ~15).
- **Source:** [`ws_masking.exs`](https://github.com/DanielLuning/defk/blob/main/examples/ws_masking.exs) (2ae646a), `defk-9p6.12`.
- **Status:** provisional.

<!-- defk-example skip: a fragment, one clause of b32/3 beside the comprehension it replaces -->
```elixir
# fast (about 1 GB/s)
defp b32(<<h::32, r::binary>>, m, acc), do: b32(r, m, <<acc::binary, bxor(h, m)::32>>)
# slow
for <<w::64 <- head>>, into: <<>>, do: <<bxor(w, m64)::64>>
```

See 3.6 for the one Elixir spelling that beats the 32-bit loop.

### 2.7 Choose the algorithm that fits small integers: Myers bit-parallel Levenshtein

For one short query (up to ~58 bytes, so the bit vectors stay small
integers) against many words, Myers/Hyyrö bit-parallel distance in plain
Elixir is about 10x the row DP.

- **Numbers:** 234k words: per-pair DP 179 ms; DP with the query row built
  once 157-158 ms; Myers over binary words 28.1 ms; Myers over charlists 18.9
  ms; plus a branch-free score step 16.3 ms; candidates in one
  `:persistent_term` tuple 16.0 ms; in 12 chunks 3.6-4.2 ms. A binary
  comprehension walk was 56.9 ms. In `fuzzy_search` Myers was 18-19 ms per
  query against 60-62 ms for the shipped DP with cut-off.
- **Conditions:** under load.
- **Source:** [`batched_levenshtein.exs`](https://github.com/DanielLuning/defk/blob/main/examples/batched_levenshtein.exs) (27b5a8c), `defk-9p6.11`; [`fuzzy_search/README.md`](https://github.com/DanielLuning/defk/blob/main/examples/fuzzy_search/README.md), `defk-l2g`.
- **Status:** provisional.

<!-- defk-example skip: a fragment, the loop body is elided (...) -->
```elixir
# fast: walk a charlist; branch-free score
defp mc([c | rest], peq, mask, hi, pv, mv, score) do
  eq = elem(peq, c)
  xh = bxor((eq &&& pv) + pv, pv) ||| eq
  # ... ph, mh ...
  score = score + (ph >>> (m - 1) &&& 1) - (mh >>> (m - 1) &&& 1)
# slow: binary walk, or a cond for the score
defp mb(<<c, rest::binary>>, ...)
cond do (ph &&& hi) != 0 -> score + 1; (mh &&& hi) != 0 -> score - 1; true -> score end
```

Charlists are cheaper to walk than `<<c, rest::binary>>` here (18.9 vs 28.1
ms for Myers; no difference for the DP, 157 vs 158 ms).

### 2.8 Row DP layouts: tail-recursive list rows win

- **Numbers:** `fuzzy_search`, ms per query: list rows by tail recursion
  60-62; `Enum.reduce_while` over the word 66-69; words as binaries 66-67;
  `:lists.min/1` for the row minimum 69-70; rows as tuples 79-82; rows as
  `:array` 287-288; rows as u16 binaries built by appending 322-330.
  `per_pair_distance`: body recursion without the reverse measured the same
  as tail recursion (44.6 ms for 50k pairs of 12 bytes).
- **Conditions:** noisy machine (load average 5-90), two runs within ~10%.
- **Source:** [`fuzzy_search/README.md`](https://github.com/DanielLuning/defk/blob/main/examples/fuzzy_search/README.md) (4b8d17d), [`per_pair_distance.exs`](https://github.com/DanielLuning/defk/blob/main/examples/per_pair_distance.exs) (83c1a12).
- **Status:** provisional.

<!-- defk-example skip: a fragment, the loop body is elided (...) -->
```elixir
# fast
defp cells([bc | bt], [diag, up | prest], left, c, acc) do
  # ... v = min(...)
  cells(bt, [up | prest], v, c, [v | acc])
end            # then :lists.reverse(acc) once per row
# slow: :array.set/3 per cell, or <<row::binary, v::16>> per cell
```

### 2.9 Floats from binaries: match eight at a time, keep f32, bound the top-k

- **Numbers:** cosine top-10 over 100k x 384 f32 rows, one process: one
  float per match 756-913 ms; eight per match with eight accumulators
  366-372 ms (2.4x); widened to f64 582-646 ms; every score kept and sorted
  790-818 ms. Float lists are 1.3x faster per element at 10k rows but take 8x
  the memory: at 100k they are 1.2 GB, over `:persistent_term`'s 1 GB literal
  area, and in shard processes they took 73 ms against 50-57 ms for the
  chunked binary.
- **Conditions:** under load (load average ~6-7 on 12 cores).
- **Source:** [`cosine_topk.exs`](https://github.com/DanielLuning/defk/blob/main/examples/cosine_topk.exs) (9235cd4), `defk-9p6.13`.
- **Status:** provisional.

<!-- defk-example skip: a fragment, the unrolled arguments are elided (...) -->
```elixir
# fast
dot8(<<x0::float-32-native, x1::float-32-native, ..., x7::float-32-native, rest::binary>>,
     [q0, q1, ..., q7 | qs], a0, a1, ..., a7)   # a0 + x0 * q0, ...
# slow
dot1(<<x::float-32-native, rest::binary>>, [q | qs], a), do: dot1(rest, qs, a + x * q)
```

### 2.10 Interleave per-point fields in one binary, and skip expensive math with an exact early exit

- **Numbers:** 10 nearest of 500k points, one process: list of tuples ~24 ms;
  three packed f64 column binaries walked in lockstep ~31 ms (slower than
  tuples); one interleaved 24-byte-record binary ~22 ms; plus an exact early
  exit that skips the second `:math.sin` ~14 ms. Bounded top-k as a tuple or
  `:gb_trees` ~30 ms. A trig-free formula with wider records ~17.6 ms ("wider
  records cost more than the sin saved").
- **Conditions:** best of 5; load not recorded.
- **Source:** [`geo_nearest.exs`](https://github.com/DanielLuning/defk/blob/main/examples/geo_nearest.exs) (baf7d5f), `defk-9p6.7`.
- **Status:** measured.

<!-- defk-example skip: a fragment, the arguments and the body are elided (...) -->
```elixir
# fast
walk(<<lat::float-64-native, lon::float-64-native, coslat::float-64-native, rest::binary>>, ...)
#   if s2 < worst, do: (sdlon = :math.sin((lon - qlon) / 2); ...)
# slow: three column binaries matched in lockstep
```

### 2.11 Per-row term creation is the cost of aggregation, not the scan

- **Numbers:** One Billion Row Challenge layout, ms at 10M / 100M rows on 12
  schedulers: static name-to-slot map + `:atomics` 145 / 1663; ETS 206 /
  2293; a map rebuilt per row 309 / 3620; `:binary.split` per line 367 /
  4683 (5.0 GB peak); float temperatures 1631 / 16086. One `:binary.match`
  per row instead of a byte-by-byte name scan: 2391 vs 1663 ms at 100M.
  Research (2M rows, one core): a byte scan 505 MB/s, `:binary.split` on
  lines 621 MB/s, split + parse + `Map.update` 45 MB/s (a 13x gap).
- **Conditions:** page cache, best of 3 (parallel); one_brc load not
  recorded in `elixir.exs`; research numbers are single runs on a noisy machine.
- **Source:** [`one_brc/elixir.exs`](https://github.com/DanielLuning/defk/blob/main/examples/one_brc/elixir.exs) (0323114), `defk-n4r.1`; [`docs/research/string-workloads.md`](https://github.com/DanielLuning/defk/blob/main/docs/research/string-workloads.md) (d78d854).
- **Status:** measured (one_brc); provisional (research).

<!-- defk-example run: acc = %{}; name = "x"; t = 5; temp_sub_binary = "1.5" -->
```elixir
# fast: parse the temperature as an integer x10 by pattern, one :atomics slot per statistic
# slow
Map.update(acc, name, {t, t, t, 1}, fn {mn, mx, s, c} -> {min(mn, t), max(mx, t), s + t, c + 1} end)
:erlang.binary_to_float(temp_sub_binary)
```

### 2.12 Dense counters: `:atomics` plus one rebuild for big batches, sorted keys for small ones

For counting bytes (a 256-bin histogram, per window or over a whole binary) see 2.16, "Counting bytes".

- **Numbers:** fold hashes into a 16k-register HyperLogLog, ms at 100 / 1k /
  10k / 100k: anchor (bit-by-bit rank) 0.044 / 0.17 / 3.1 / 17-24; top-down
  rank 0.036 / 0.10 / 2.5 / 10.3; sorted integer keys + splice 0.019 / 0.058
  / 1.6 / 9.2; `:atomics` + one rebuild 0.48 / 0.21 / 0.50 / 3.3; `:array`
  0.83 / 0.21 / 1.4 / 5.4; tuple `put_elem` 2.3 / 1.7 / 8.5 / not run;
  bit-syntax register update per hash 0.026 / 0.86 / 1.8 / 8.6.
- **Conditions:** best of 7, under load.
- **Source:** [`hll_update_many.exs`](https://github.com/DanielLuning/defk/blob/main/examples/hll_update_many.exs) (070a179), `defk-9p6.15`.
- **Status:** provisional.

<!-- defk-example skip: a fragment, the per-hash code is only described in comments -->
```elixir
# fast (from ~5k hashes)
a = :atomics.new(m, signed: false)
# per hash: if r > :atomics.get(a, i), do: :atomics.put(a, i, r)   ... then rebuild the binary once
# fast rank: count from the top bit down (~2 compares, not ~50 shifts)
defp td(w, t, r) when w >= t, do: r
defp td(w, t, r), do: td(w, t >>> 1, r + 1)
# slow
t = put_elem(t, i - 1, r)
```

### 2.13 More Elixir spellings that won or lost

Each is from one example; numbers as in the source.

| Job | Fast | Slow | Source, status |
|---|---|---|---|
| Floyd-Steinberg error rows | rolling error lists 124-149 ms | `Map.update` rows 1650 ms | [`image_ops.exs`](https://github.com/DanielLuning/defk/blob/main/examples/image_ops.exs), measured |
| Matrix multiply 64 / 256 | lists, transposed right matrix, tail-recursive dot 3.7 / 333 ms | i-k-j on lists 4.3 / 483 ms; binary-pattern dot 5.4 / 948 ms | [`matmul.exs`](https://github.com/DanielLuning/defk/blob/main/examples/matmul.exs) (e305956), measured |
| FFT n = 4096 / 2^20 | recursive lists 2.8 / 4420 ms; per-stage tuple rebuild 3.5 / 2032-2326 ms | in-place `:array` 6.0 / 21637 ms | [`fft.exs`](https://github.com/DanielLuning/defk/blob/main/examples/fft.exs) (7f0904d), measured |
| 64-tap FIR over 96k samples | shift-and-add over lists 74-101 ms | `elem/2` per output on tuples 90-204 ms | [`fft.exs`](https://github.com/DanielLuning/defk/blob/main/examples/fft.exs), measured |
| Slot spin (per spin) | precomputed per-stop windows 111 ns | `rem/2` per line 139 ns; tables in `:array` 325 ns | [`monte_carlo_rtp.exs`](https://github.com/DanielLuning/defk/blob/main/examples/monte_carlo_rtp.exs) (ff2fcd6), measured |
| SipHash state | four variables | a record updated field by field (1.1x at 4 MB, 1.1-2x on the batch) | [`hashes.exs`](https://github.com/DanielLuning/defk/blob/main/examples/hashes.exs), measured |
| xxHash64 | little-endian matches, one mask per step, inlined helpers (1.4x over the package) | big-endian read + byte swap through a new binary per word | [`hashes.exs`](https://github.com/DanielLuning/defk/blob/main/examples/hashes.exs), measured |
| base58 | divide the bignum by 58^9 per step: encode 3.8x over b58, 7x over erl_base58 | one digit per bignum division | [`codecs.exs`](https://github.com/DanielLuning/defk/blob/main/examples/codecs.exs) (e81ee3f), measured |
| PCM mix, 4 streams, per 1 s of audio | fused scan from binaries, output appended 2.6-2.7 ms | plugin 19-20 ms; `Enum.zip_with` + `Enum.sum` 7.0 ms | [`pcm_mix.exs`](https://github.com/DanielLuning/defk/blob/main/examples/pcm_mix.exs), provisional |
| Gorilla bit streams (1,000 x 100 / 1M points) | appended bitstrings 4.8-4.9 / 41.6-43.4 ms | iolist + `list_to_bitstring` 16.9-19.3 / ~930 ms; pre-packing the list 5.3-5.6 / 118-122 ms | [`gorilla_encode.exs`](https://github.com/DanielLuning/defk/blob/main/examples/gorilla_encode.exs), provisional |
| Sort 1M packed i64 | decode + `:lists.sort` (sort 230+ ms, decode 40 ms) | (`Enum.sort` on a list is `:lists.sort`) | [`sort_u64_keys.exs`](https://github.com/DanielLuning/defk/blob/main/examples/sort_u64_keys.exs) (ad7b46b), measured |

In `gorilla_encode` a word buffer and two passes were within 5% of the
appended-bitstring baseline: no gain.

### 2.14 BLAKE2b in Elixir: halves give 10x; BLAKE3's 32-bit words need no trick

The 2.4 rule again, on a 64-bit hash with 12 unrolled rounds: two 32-bit
halves per word, with the carry of each add taken by hand, beat 64-bit
words by 10x. BLAKE3 is all 32-bit, so a plain unrolled Elixir version is
already in small integers, and the kernel's lead is 3x smaller.

- **Numbers:** BLAKE2b-512 of 64 KB: Hex `blake2` 1.0.4 (lists,
  `Tuple.insert_at`) 31-67 ms; 64-bit words, unrolled 14.4-14.6 ms; 32-bit
  halves, unrolled 1.37-1.43 ms (46 MB/s). BLAKE3 of 64 KB: Hex `b3` 0.2.1
  0.60-0.63 ms; one pass without structs, CV stack as a list 0.56-0.58 ms
  (5-10%, the only gain over b3). Kernel over the best Elixir: BLAKE2b
  31.8-32.7x at 64 KB (21-22x at 1 KB, 32.5-33.3x at 64 MB), BLAKE3
  10.6-10.9x (8-9x at 1 KB, 10.1x at 64 MB).
- **Conditions:** best of 5-9 interleaved rounds, under load (load averages 13-135).
- **Source:** [`blake.exs`](https://github.com/DanielLuning/defk/blob/main/examples/blake.exs), `defk-52v.2`.
- **Status:** provisional.

<!-- defk-example skip: a fragment, one step of the BLAKE2b G function on 32-bit halves -->
```elixir
# fast: a 64-bit add on halves, then rotr 24 across the halves
t = al + bl + xl
ah = band(ah + bh + xh + bsr(t, 32), 0xFFFFFFFF)
al = band(t, 0xFFFFFFFF)
bh = band(bsr(th, 24) + bsl(tl, 8), 0xFFFFFFFF)   # th, tl: b ^ c
# slow: one word, a bignum above 2^59
a = band(a + b + x, 0xFFFFFFFFFFFFFFFF)
```

### 2.15 LZ-style decoders in Elixir: copy each match with `binary_part/3`, and match the input

An LZ4 or Snappy decoder appends to one output binary, and a match copies
earlier output. Copying a match as one `binary_part/3` of the output (or
`:binary.copy/2` of the offset-long pattern when the match overlaps itself)
is 3-4x faster than copying it byte by byte with `:binary.at/2`; reading the
input by matching the rest of the binary beats indexing it with
`binary_part/3` and `:binary.at/2`. iodata output is not an option: a match
reads output up to 64 KB back. A block stored as one literal (incompressible
data) is a sub-binary of the input in Elixir, with no copy at all.

- **Numbers:** 64 KB JSON-like block, Snappy / LZ4: byte-by-byte match
  copies 650-820 us / 0.7-1.4 ms; `binary_part` copies 175-240 us /
  230-450 us; positional input 310-325 us / 295-320 us; the kernels 63-72 us
  / 70-77 us. Incompressible 64 KB: Elixir 0.6-1 us, kernel 15 us (it copies
  every byte); 4 MB: 0.08-0.7 ms against 0.95 ms. The `binary_part` times
  were bimodal (230 or 450 us for the same LZ4 call in one run, a GC before
  every sample).
- **Conditions:** best of interleaved rounds, three runs, load averages 24-85.
- **Source:** [`lz4_snappy_decode.exs`](https://github.com/DanielLuning/defk/blob/main/examples/lz4_snappy_decode.exs), `defk-52v.3`.
- **Status:** provisional.

<!-- defk-example skip: a fragment, the match copy of the Elixir decoders without its offset checks -->
```elixir
# fast: one copy per match, the overlap as a repeated pattern
if off >= l do
  <<out::binary, binary_part(out, size - off, l)::binary>>
else
  pat = binary_part(out, size - off, off)
  <<out::binary, :binary.copy(pat, div(l, off))::binary, binary_part(pat, 0, rem(l, off))::binary>>
end
# slow: a byte at a time
bytes(<<out::binary, :binary.at(out, from)>>, from + 1, l - 1)
```

### 2.16 Counting bytes: 16-bit pairs into `:atomics`, eight per step; a kernel is still 6-12x faster

A byte histogram (256 counts) or a histogram per window (entropy) is an
indexed increment per byte, and Elixir's cheapest one is a BIF call:
`:atomics.add/3`. Fewer calls is what helps: count 16-bit pairs into a
65,536-slot `:atomics` (one call per two bytes) and fold the pairs into the
256 bins once. The fold costs ~0.35 ms, so below ~512 KB count single bytes,
eight per binary-pattern step. `:atomics` beats `:counters`, and anything
that copies (a map, a tuple) or scans per value (`:binary.matches/2` 256
times) loses. For windows, read and reset each bin with one
`:atomics.exchange(a, i, 0)`. Split over the schedulers with a table per
chunk and sum them; a shared `:counters` with `write_concurrency` is slower.
No OTP BIF counts bytes.

- **Numbers:** histogram of 16 MB, one process, ms: pairs into `:atomics`
  43.0-43.9 (390 MB/s); `:atomics` 8 bytes per step 75-77, 1 byte 91-92;
  `:counters` 8 bytes per step 101-103 (163 MB/s), 1 byte 112-115,
  comprehension 116-123; at 1 MB (x16 for 16 MB) `Enum.frequencies` of
  `bin_to_list` 136-169, `Map.update` 202-209, a 256-tuple with `setelement`
  62-80, `:binary.matches/2` per value 24.7-26.4. In 12 chunks: pairs
  8.7-9.9, `:atomics` 8-byte 12.1-13.3, `:counters` 8-byte 15.9-17.7, one
  shared `:counters` 23-26. Pairs against bytes, one process: 4 KB 0.38 /
  0.023, 64 KB 0.95-0.98 / 0.30, 512 KB 2.24-2.34 / 2.31, 1 MB 3.6-3.8 /
  4.7. Entropy of 4,096 windows of 4 KiB: `:counters` get + put 121-123,
  `:atomics` exchange 90-91, plus a tuple of per-count terms (no log per
  bin) 83.5-84.3; in 12 chunks 13.4-14.4. The kernel: 3.6-3.8 ms one call
  (4.6 GB/s), 1.40-1.71 ms in 12 chunks (5.5-6.6x parallel vs parallel,
  11.4-12.7x one process vs one call, 19-28x at 4-64 KB); entropy 4.7-5.2
  ms one call, 1.83-2.0 ms in 12 chunks (6.7-10.2x, 17.0-17.9x).
- **Conditions:** 16 MB, half random bytes and half text; best of 5 in two
  interleaved rounds (variants), best of 9 (`Defk.Bench`, seven runs);
  under load (load average 12-31 on 12 cores).
- **Source:** [`byte_histogram.exs`](https://github.com/DanielLuning/defk/blob/main/examples/byte_histogram.exs), `defk-9p6.28`; the cold test that asked for it, `docs/cold-tests/hexdocs-entropy.md` (`defk-djy.9`).
- **Status:** provisional.

<!-- defk-example run: bin = :binary.copy(<<1, 2, 3>>, 6) -->
```elixir
# fast (from ~512 KB): 16-bit pairs, one :atomics.add per two bytes (unrolled 8 per step in the source)
a = :atomics.new(65_536, signed: false)
for <<pair::16 <- bin>>, do: :atomics.add(a, pair + 1, 1)
# then fold slot i into bins (i >>> 8) + 1 and (i &&& 255) + 1 once
# fast below ~512 KB: bytes, 8 per step
c = :atomics.new(256, signed: false)
for <<b <- bin>>, do: :atomics.add(c, b + 1, 1)
# slow
bin |> :binary.bin_to_list() |> Enum.frequencies()
for <<b <- bin>>, reduce: %{}, do: (m -> Map.update(m, b, 1, &(&1 + 1)))
```

---

## 3. BIFs and OTP libraries that are already native

Check these before writing a kernel. They are C inside ERTS or OpenSSL, and
they are reduction-counted, so they already keep the scheduler responsive.

### 3.1 `:binary.match/2` is Boyer-Moore in C; a Horspool kernel only ties

- **Numbers:** 16 MB haystack: both sides about 2.2-2.4 ms (about 7 GB/s),
  kernel 1.03-1.11x ahead with a 64-byte needle, 1.16x with a 16-byte
  needle. Research: `:binary.match` on a miss 10.3 GB/s; `:binary.matches`
  880 MB/s for one pattern, 527 MB/s for five.
- **Conditions:** best of 5 (report runs 15); load not recorded. Research
  numbers single runs, noisy machine.
- **Source:** [`poor_substring_search.exs`](https://github.com/DanielLuning/defk/blob/main/examples/poor_substring_search.exs) (a00f961), `defk-9p6.23`; [`string-workloads.md`](https://github.com/DanielLuning/defk/blob/main/docs/research/string-workloads.md).
- **Status:** measured; research provisional.

<!-- defk-example run: needle = "ab"; hay = "xxabxx"; needles = ["ab", "xx"] -->
```elixir
compiled = :binary.compile_pattern(needle)   # once, e.g. in :persistent_term
:binary.match(hay, compiled)                 # {pos, len}, no copy
:binary.matches(hay, :binary.compile_pattern(needles))   # many needles
```

### 3.2 `:erlang.crc32/1` runs at memory speed

- **Numbers:** 0.03 ms per MB (35 GB/s), 100x a table-driven CRC-16/CRC-64
  kernel and the `crc` NIF; 0.10-0.11 ms for 4 MB (~40 GB/s) in `hashes`.
  `:erlang.phash2/1` 2.4-2.6 GB/s (not portable across OTP versions). It is
  zlib's polynomial: it does not replace CRC32C or CRC-64.
- **Conditions:** load not recorded.
- **Source:** [`geohash_crc.exs`](https://github.com/DanielLuning/defk/blob/main/examples/geohash_crc.exs) (ad7b46b), [`hashes.exs`](https://github.com/DanielLuning/defk/blob/main/examples/hashes.exs) (0bc56d4), `defk-9p6.2`, `defk-52v.4`.
- **Status:** measured.

### 3.3 UTF-8 validation: `:unicode.characters_to_binary/1` is faster than `String.valid?/1`

- **Numbers:** 16 MB mixed text: `String.valid?` 62 ms (0.27 GB/s),
  `:unicode.characters_to_binary` 32 ms (0.52 GB/s), a scalar DFA kernel
  29.6 ms (1.05-1.09x). Research on a 15.9 MB mostly ASCII/Latin input:
  463 MB/s against 2,057 MB/s.
- **Conditions:** best of 5, load not recorded; research a single run, noisy machine.
- **Source:** [`utf8_valid.exs`](https://github.com/DanielLuning/defk/blob/main/examples/utf8_valid.exs) (eddafd8), `defk-9p6.22`; [`string-workloads.md`](https://github.com/DanielLuning/defk/blob/main/docs/research/string-workloads.md).
- **Status:** measured; research provisional.

<!-- defk-example run: bin = "hello" -->
```elixir
is_binary(:unicode.characters_to_binary(bin))   # fast on large inputs
String.valid?(bin)                              # fine for a WebSocket frame (what Bandit uses)
```

For GB/s validation wrap simdutf8; a scalar kernel cannot beat the BIF by much.

### 3.4 Hex and base64: use the BIFs; `Base.encode16` is the slow one

- **Numbers:** research, 16 MiB random: `:binary.encode_hex` 1,091 MB/s,
  `Base.encode16` 475 MB/s, `Base.encode64` 764 MB/s, `Base.decode64!` 551
  MB/s. `codecs`: `:binary.encode_hex/decode_hex` beat `Base` both ways; a hex
  encode kernel is only 1.5x the BIF (now ~2.6x after `defk-upc`, under
  load); `Base` encodes base64 faster than `:base64`, and `:base64` decodes
  about 4% faster.
- **Source:** [`string-workloads.md`](https://github.com/DanielLuning/defk/blob/main/docs/research/string-workloads.md), [`codecs.exs`](https://github.com/DanielLuning/defk/blob/main/examples/codecs.exs) (e81ee3f), `defk-9p6.19`, `defk-upc` comment 2026-10-10.
- **Status:** research provisional; codecs measured.

### 3.5 `:crypto` is OpenSSL on the CPU's SHA instructions

- **Numbers:** chained `:crypto.hash(:sha256, h)` 98-113 ns per step
  (`Enum.reduce`) or 98-136 (tail recursion), within noise of each other;
  `hash_init` once with `hash_update` + `hash_final` per step 348-390 ns (each
  update copies the context). HMAC-SHA256 per round: `:crypto.mac` 1.03-1.09
  us; `mac_init/update/final` the same; two reused hash contexts 0.90-0.99
  us; RFC 2104 by hand with two `:crypto.hash` calls 0.47-0.70 us. A
  portable-C SHA-256 kernel loses the chain (0.57-0.58x); a from-scratch
  SHA3-256 kernel is 0.71x of `:crypto.hash(:sha3_256, m)`.
- **Conditions:** hash_chain under load (load 13-36); keccak load not recorded.
- **Source:** [`hash_chain.exs`](https://github.com/DanielLuning/defk/blob/main/examples/hash_chain.exs) (df9258e), `defk-9p6.18`; [`keccak.exs`](https://github.com/DanielLuning/defk/blob/main/examples/keccak.exs) (f81c2cd), `defk-52v.1`.
- **Status:** provisional (hash_chain); measured (keccak).

<!-- defk-example run: op = :binary.copy(<<1>>, 64); ip = :binary.copy(<<2>>, 64); key = :binary.copy(<<3>>, 32); client = "c1"; nonce = 7 -->
```elixir
# fast: HMAC by hand with precomputed pads
:crypto.hash(:sha256, [op | :crypto.hash(:sha256, [ip, client, ?:, Integer.to_string(nonce)])])
# slow: per-call key setup
:crypto.mac(:hmac, :sha256, key, [client, ?:, Integer.to_string(nonce)])
```

### 3.6 `:crypto.exor/2` XORs two binaries in C; build the key by doubling

The only Elixir that beats Bandit's 32-bit masking loop, from about 600 B.

- **Numbers:** ns per frame at 125 B / 1 KiB / 8 KiB / 1 MiB: key by
  doubling 318 / 720 / 4,195 / 532,125; key by `:binary.copy/2` 374 / 1,664
  / 12,063 / 1,530,000; Bandit's loop 184 / 991 / 6,906 / 926,375. So the
  baseline is a hybrid: the loop below 512 B, `exor` from there (1.4x at 1
  KiB, 1.7x from 8 KiB).
- **Conditions:** best of 7 interleaved rounds, under load.
- **Source:** [`ws_masking.exs`](https://github.com/DanielLuning/defk/blob/main/examples/ws_masking.exs) (2ae646a).
- **Status:** provisional.

<!-- defk-example run: exor2("abc", 7) -->
```elixir
def exor2(p, m), do: :crypto.exor(p, key(<<m::32>>, byte_size(p)))
defp key(k, n) when byte_size(k) >= n, do: binary_part(k, 0, n)
defp key(k, n), do: key(<<k::binary, k::binary>>, n)
```

### 3.7 `:rand` is pure Erlang, not a BIF

- **Numbers:** `:rand.uniform_s/1` 160 ns per draw, `:rand.normal_s/1` 175 ns
  (single run, including `Enum.reduce`). Inlining exsss in Elixir saves only
  the plug-in dispatch, about 2-8% (within noise between runs). A kernel that
  reproduces exsss bit for bit ran the slot simulation at 34 ns per spin
  against 109 ns.
- **Source:** `defk-9p6.17`, [`monte_carlo_rtp.exs`](https://github.com/DanielLuning/defk/blob/main/examples/monte_carlo_rtp.exs) (ff2fcd6).
- **Status:** measured (single run for the per-draw numbers).

### 3.8 Nx needs a compiled backend; `BinaryBackend` is Elixir

- **Numbers:** `Nx.dot` on `BinaryBackend` 2790 ms at 256x256 (plain Elixir
  lists 333 ms; defk 13.4 ms). `Nx.fft` on `BinaryBackend` 9719 ms at 2^20
  (best Elixir 2032-2326 ms). Cosine top-k at 100k: `BinaryBackend` 14.3-15 s;
  Nx + EXLA 0.13.1 1.0-1.22 ms, 6-8x faster than defk's 7.2-9.6 ms.
- **Conditions:** matmul and fft load not recorded; cosine under load.
- **Source:** [`matmul.exs`](https://github.com/DanielLuning/defk/blob/main/examples/matmul.exs), [`fft.exs`](https://github.com/DanielLuning/defk/blob/main/examples/fft.exs), [`cosine_topk.exs`](https://github.com/DanielLuning/defk/blob/main/examples/cosine_topk.exs), `defk-9p6.3`, `defk-9p6.13`, [`nx-boundary.md`](https://github.com/DanielLuning/defk/blob/main/docs/research/nx-boundary.md).
- **Status:** measured (matmul, fft); provisional (cosine). EXLA matmul not measured yet (`defk-7tk`).

### 3.9 `:crypto` has BLAKE2b; a from-scratch kernel only ties it

`:crypto.hash(:blake2b, m)` (BLAKE2b-512) and `:blake2s` are in OTP's
`:crypto` when OpenSSL has them (`:crypto.supports(:hashs)`). It is the
Elixir answer for BLAKE2b; BLAKE3 is not in OpenSSL.

- **Numbers:** BLAKE2b-512, 64 KB: `:crypto` 0.050-0.064 ms, kernel
  0.042-0.049 ms, blake2_elixir (reference C) 0.043-0.046 ms. 64 MB:
  `:crypto` 50.1-56.2 ms, kernel 43.2-48.3 ms. The kernel is 1.16-1.19x
  (marginal; 1.0x at 1 KB).
- **Conditions:** under load (load averages 13-135).
- **Source:** [`blake.exs`](https://github.com/DanielLuning/defk/blob/main/examples/blake.exs), `defk-52v.2`.
- **Status:** provisional.

---

## 4. Parallelism and schedulers

### 4.1 Short kernel calls under `Task.async_stream` stay on 2-3 of 12 schedulers

- **Numbers:** 48 tasks of ~0.65 ms, wall ms / schedulers used:
  `Task.async_stream` (ordered or not) kernel 15-18 / 3, Elixir 4.6-6.8 / 12;
  plain `spawn` of all 48 kernel 7.1 / 11; `Task.async` + `Task.await_many`
  kernel 6.7 / 11; 10 ms calls kernel 59-65 / 12 (long calls spread).
  `batched_levenshtein`: 12 kernel calls of ~0.5 ms ran on 2 of 12
  schedulers; `cosine_topk`: 12 kernel chunks were only 2.8x one call;
  `monte_carlo_rtp` at 1M spins: 48 kernel tasks of ~0.7 ms on 2-3
  schedulers, verdict ~1x, while at 10M (~5 ms chunks) they spread.
- **Conditions:** under load (load average 5-7 on 12 cores), OTP 29.0.3.
- **Source:** `defk-8qs` comments 2026-10-10, `defk-6lr`, [`batched_levenshtein.exs`](https://github.com/DanielLuning/defk/blob/main/examples/batched_levenshtein.exs), [`cosine_topk.exs`](https://github.com/DanielLuning/defk/blob/main/examples/cosine_topk.exs), [`monte_carlo_rtp.exs`](https://github.com/DanielLuning/defk/blob/main/examples/monte_carlo_rtp.exs).
- **Status:** provisional.

<!-- defk-example run: chunks = [1, 2, 3] | defs: defmodule Kernels do def work(chunk), do: chunk end -->
```elixir
# spreads: start every chunk at once
chunks |> Enum.map(&Task.async(fn -> Kernels.work(&1) end)) |> Task.await_many(:infinity)
# stays on 2-3 schedulers with sub-ms kernel chunks
Task.async_stream(chunks, &Kernels.work/1, max_concurrency: 12)
```

### 4.2 Why: idle schedulers are woken by reductions, and a kernel charges few

ERTS wakes a helper scheduler when a crowded run queue has run enough
reductions. A kernel charges one timeslice (4000 reductions) per 250 us
slice; Elixir uses that many in about 5 us.

- **Numbers:** a 0.69 ms kernel call is 9.6k reductions and 2 context
  switches; 0.72 ms of Elixir is 597k reductions and ~150 context switches
  (~50x more reductions per ms).
- **Source:** `defk-8qs` comment 2026-10-10T12:28:18Z, `defk-6lr` (reads `erl_process.c` `wakeup_other_check`).
- **Status:** provisional.

### 4.3 Fixes for short parallel kernel calls, and what didn't help

1. Fewer, bigger chunks: ~5 ms or more per call spreads.
2. Start every chunk at once (`Task.async` + `Task.await_many`, or `spawn`).
3. `+swt very_low` (`elixir --erl "+swt very_low"`). Report the verdict on a default VM and give the flag's number beside it.

- **Numbers (default -> `+swt very_low`, ms / schedulers):** synthetic 48
  tasks kernel 15-18 / 3 -> 5.3-6.1 / 11-12 (`low` 6.9-7.8 / 9, `very_high`
  29-30 / 2); `batched_levenshtein` 12 chunks 5.1-5.6 / 2 -> 2.3-2.5 / 11-12,
  Elixir chunks unchanged (5.4 -> 4.9-5.8); `monte_carlo_rtp` 1M, 48 chunks
  16.7 / 4 -> 7.7 / 11; `image_blur` 12 bands 2.3-2.5 -> 1.7 ms. `spawn_opt`
  with `{:scheduler, n}` (works on OTP 29, undocumented) 7.2 ms / 12.
- **Didn't help:** `+sbwt none` or `very_long`, `+sws legacy` (no change);
  `:erlang.yield()` before the call (still 2 schedulers); `Process.sleep(1)`
  before it (4); `bump_reductions(4000)` + yield before the call (15-18 ->
  12-13 ms, 3 -> 4 schedulers). Shortening the kernel slice to 50 us spreads
  (12 schedulers, 5.8-7.4 ms) but costs 11-18% on one scheduler, so it was
  not adopted.
- **Conditions:** under load.
- **Source:** `defk-8qs`, `defk-6lr` (open), [examples/README.md](https://github.com/DanielLuning/defk/blob/main/examples/README.md#measuring-correctly) rule 7, [`image_blur.exs`](https://github.com/DanielLuning/defk/blob/main/examples/image_blur.exs).
- **Status:** provisional.

### 4.4 Elixir: one chunk per scheduler, and more chunks don't help

- **Numbers:** cosine scan at 100k, ms: one process 366-368; 2 chunks
  188-192; 4 chunks 99-106; 12 chunks 50-57; 24 chunks 50-54.
  `rolling_stats`: 12 chunks ~9.6 ms, 4 chunks ~16-20 ms (one process ~53-60).
  `image_blur`: 12 bands 9.1-11.5 ms against ~140 ms in one process. 1BRC:
  12-13x from 12 schedulers (`par_atomics` against `seq_atomics`).
- **Conditions:** cosine, rolling_stats, image_blur under load; one_brc load not recorded.
- **Source:** [`cosine_topk.exs`](https://github.com/DanielLuning/defk/blob/main/examples/cosine_topk.exs), [`rolling_stats.exs`](https://github.com/DanielLuning/defk/blob/main/examples/rolling_stats.exs), [`image_blur.exs`](https://github.com/DanielLuning/defk/blob/main/examples/image_blur.exs), [`one_brc/elixir.exs`](https://github.com/DanielLuning/defk/blob/main/examples/one_brc/elixir.exs).
- **Status:** provisional; one_brc measured.

<!-- defk-example run: bin = :binary.copy(<<0>>, 64); chunks = [{0, 2}, {1, 2}]; w = 1 | defs: defp run(bin, _w), do: byte_size(bin) -->
```elixir
Task.async_stream(chunks, fn {start, k} -> run(binary_part(bin, start * 8, (k + w - 1) * 8), w) end,
  max_concurrency: System.schedulers_online(), timeout: :infinity)
```

### 4.5 Fanning out a short job can lose: sending lists to tasks copies them

- **Numbers:** HLL fold of 100k hashes: one process 3.3 ms; the same split
  over one task per scheduler 4.4 ms (and slower at every size). Batched
  Levenshtein: below ~10k words one process beats 12 chunks.
- **Conditions:** under load.
- **Source:** [`hll_update_many.exs`](https://github.com/DanielLuning/defk/blob/main/examples/hll_update_many.exs) (variant E8), [`batched_levenshtein.exs`](https://github.com/DanielLuning/defk/blob/main/examples/batched_levenshtein.exs).
- **Status:** provisional.

### 4.6 Chunk sizes for a large file: tens of MB per `:file.pread`

- **Numbers:** 1BRC 100M rows, `par_atomics`, best of 3: 4 MB chunks 2116 ms,
  8 MB 1884, 16 MB 2120, 32 MB 1818, 64 MB 1807; the default (at most 32 MB,
  at least 4 chunks per scheduler) is 28 MB there.
- **Source:** [`one_brc/elixir.exs`](https://github.com/DanielLuning/defk/blob/main/examples/one_brc/elixir.exs) (0323114).
- **Status:** measured.

### 4.7 Scaling flattens past the performance cores

- **Numbers:** 10M spins in 48 chunks, schedulers 1 / 2 / 4 / 8 / 12:
  Elixir 1854 / 786 / 351 / 166 / 139 ms; defk 347 / 177 / 93 / 52 / 48 ms;
  defk's lead 5.3x / 4.5x / 3.8x / 3.2x / 2.9x. Elixir on a one-scheduler VM
  is slower per spin than one process on a 12-scheduler VM (185 vs 109 ns),
  not investigated.
- **Source:** [`monte_carlo_rtp.exs`](https://github.com/DanielLuning/defk/blob/main/examples/monte_carlo_rtp.exs) (ff2fcd6).
- **Status:** measured.

### 4.8 A fast kernel call may not need chunking at all

- **Numbers:** `geo_nearest`: one kernel call ~1.0-1.3 ms; K chunked kernel
  calls (K = 2..24) 0.9-1.3 ms, no gain. `rolling_stats`: defk in 12 chunks
  1.5-2.3 ms against ~1.9 ms for one call.
- **Source:** [`geo_nearest.exs`](https://github.com/DanielLuning/defk/blob/main/examples/geo_nearest.exs), [`rolling_stats.exs`](https://github.com/DanielLuning/defk/blob/main/examples/rolling_stats.exs).
- **Status:** measured (geo_nearest); provisional (rolling_stats).

---

## 5. The NIF boundary

### 5.1 A call costs tens to a hundred-odd nanoseconds; never call per element

- **Numbers:** README micro-benchmark: kernel call 12 ns against 1.6 ns for
  an Elixir call. `poor_tiny_calls`: "each NIF call adds ~10 ns", about the
  whole per-element cost of the Elixir version, so a kernel call per element
  inside `Enum.map` is 0.38-0.43x. `ws_masking`: at 125 B the call is the
  cost, ~0.12-0.13 us for a kernel and about the same for a NIF.
  `hashes`: a kernel call costs ~35 ns more than siphash's NIF call (one call
  per key 0.085 ms for 1k keys, the batch 0.048-0.055 ms). These figures
  disagree (see 8.2, open questions).
- **Conditions:** README "noisy, single runs"; ws_masking under load.
- **Source:** [README Results](../README.md), [`poor_tiny_calls.exs`](https://github.com/DanielLuning/defk/blob/main/examples/poor_tiny_calls.exs), [`ws_masking.exs`](https://github.com/DanielLuning/defk/blob/main/examples/ws_masking.exs), [`hashes.exs`](https://github.com/DanielLuning/defk/blob/main/examples/hashes.exs).
- **Status:** measured; ws_masking provisional.

<!-- defk-example run: packed = <<1.0::float-64-native>>; readings = [1.0, 2.0] | defs: defmodule Clamp.Kernels do def clamp_all(packed), do: packed; def clamp(x, lo, hi), do: x |> max(lo) |> min(hi) end -->
```elixir
# fast: one call per batch
Clamp.Kernels.clamp_all(packed)
# slow: one call per element
Enum.map(readings, &Clamp.Kernels.clamp(&1, -10.0, 90.0))
```

### 5.2 A kernel that returns a bitstring costs ~0.1 us more per call than a scalar one

- **Numbers:** returning `len(p)` as an `i64` 0.015-0.04 us per call; the
  same as a one-byte bitstring 0.12-0.17 us. ~5% of a 2.1 us Gorilla block
  encode. Suspect (not profiled): the owned buffer doubling from 64 bytes.
- **Conditions:** best of 15 over 10k calls, under load.
- **Source:** `defk-cao` (open), [`gorilla_encode.exs`](https://github.com/DanielLuning/defk/blob/main/examples/gorilla_encode.exs).
- **Status:** provisional.

### 5.3 Packing a list often costs more than the kernel

If the data arrives as a list, packing it is part of the defk cost, and it
is often most of it.

- **Numbers:** `poor_list_data`: pack + kernel sum is 0.35-0.37x of
  `Enum.sum` (about 3x slower). `hll_update_many` at 100k: kernel 0.07 ms of
  0.36 ms, the rest is the pack. `gorilla_encode` at 1M points: about half of
  defk's time is the pack (~6 ns per point). `geohash` encode of 100k
  points: packing two lists costs another 5.5 ms on a 1.9-2.0 ms kernel; the
  decode's list output adds 2.4 ms.
- **Conditions:** hll and gorilla under load; others load not recorded.
- **Source:** [`poor_list_data.exs`](https://github.com/DanielLuning/defk/blob/main/examples/poor_list_data.exs), [`hll_update_many.exs`](https://github.com/DanielLuning/defk/blob/main/examples/hll_update_many.exs), [`gorilla_encode.exs`](https://github.com/DanielLuning/defk/blob/main/examples/gorilla_encode.exs), [`geohash_crc.exs`](https://github.com/DanielLuning/defk/blob/main/examples/geohash_crc.exs).
- **Status:** measured; hll and gorilla provisional.

<!-- defk-example run: totals = [1.0, 2.0] | defs: defmodule Sum.Kernels do def sum(packed), do: byte_size(packed) end -->
```elixir
# loses for one pass over a list
packed = for x <- totals, into: <<>>, do: <<x::float-64-native>>
Sum.Kernels.sum(packed)
# wins: data already packed (a binary from a file, a socket, :persistent_term), or packed once and reused
```

If you must pack, see 2.2.

### 5.4 Batch break-even: the work per call must outweigh the call

- **Numbers:**
  - `per_pair_distance`: one kernel call per string pair is 3.2-3.4x at
    8-16 bytes (a quadratic DP outweighs the call), 1.1-1.2x at 4 bytes.
    Batching from a *list of pairs* was slower than per-pair calls (18 vs 13
    ms for 50k pairs: the packing costs more); from an already-packed blob
    it was 4.2-4.6x at 4 bytes.
  - `geohash` one point per call 0.77-0.85x (10k calls).
  - `codecs` base58: one 32-byte key per call 1.04 us against Elixir 0.94
    us; 100 keys 2.5x; 10k keys 2.59-2.68x.
  - `hash_chain` HMAC: 1 nonce 0.5x, 100 nonces 0.86-0.91x, 10k 1.1-1.2x, 1M
    1.33-1.47x.
  - `utf8_valid`: at 1 KB the kernel's fixed cost (tables built per call)
    loses, 0.56-0.68x at 64 KB.
- **Conditions:** hash_chain under load; others load not recorded.
- **Source:** [`per_pair_distance.exs`](https://github.com/DanielLuning/defk/blob/main/examples/per_pair_distance.exs), [`geohash_crc.exs`](https://github.com/DanielLuning/defk/blob/main/examples/geohash_crc.exs), [`codecs.exs`](https://github.com/DanielLuning/defk/blob/main/examples/codecs.exs), [`hash_chain.exs`](https://github.com/DanielLuning/defk/blob/main/examples/hash_chain.exs), [`utf8_valid.exs`](https://github.com/DanielLuning/defk/blob/main/examples/utf8_valid.exs).
- **Status:** measured; hash_chain provisional. The geohash break-even size is contradictory (see 8.2, open questions).

### 5.5 Keep results packed; decode to a list only when the caller needs one

- **Numbers:** sort 1M i64 keys: packed in and out 4.3-5.3x (kernel 63-76
  ms against 300-380 ms); decoded to a list 2.3-2.7x (the decode is 40 ms).
  `batched_levenshtein`: converting the 234k distances to a list costs
  ~1.0 ms of 6.7 ms.
- **Source:** [`sort_u64_keys.exs`](https://github.com/DanielLuning/defk/blob/main/examples/sort_u64_keys.exs) (ad7b46b), [`batched_levenshtein.exs`](https://github.com/DanielLuning/defk/blob/main/examples/batched_levenshtein.exs).
- **Status:** measured; batched_levenshtein provisional.

<!-- defk-example run: packed = <<3::signed-64-native, 1::signed-64-native>>; q = "a"; blob = "b"; offs = <<>>; n = 1 | defs: defmodule Keys.Kernels do def sort_i64(packed), do: packed end; defmodule K do def lev_myers(_q, _blob, _offs, _start, _n), do: <<1, 2>> end -->
```elixir
packed |> Keys.Kernels.sort_i64()                     # stays packed
:binary.bin_to_list(K.lev_myers(q, blob, offs, 0, n)) # [u8] result, list only if needed
```

### 5.6 What crosses the boundary for free, and what doesn't

Array inputs are views over the caller's binary (zero copy); a sub-binary at
an unaligned offset is copied once. Outputs are `enif_alloc_binary` buffers
handed over without a copy. Returning many terms is the expensive direction:
an external report has a 6 us Elixir function becoming 60-160 us as a NIF
because of term encoding. The kernel's error path uses `sigsetjmp(jb, 0)`:
plain `setjmp` saves the signal mask on macOS, a syscall that cost 160 ns
per call.

- **Source:** [README design decisions](../README.md#design-decisions-the-benchmarks-validated), [`beam-nifs.md`](https://github.com/DanielLuning/defk/blob/main/docs/beam-nifs.md), [`nif-workloads.md`](https://github.com/DanielLuning/defk/blob/main/docs/research/nif-workloads.md) (external number).
- **Status:** measured (the 160 ns); external (the term-encoding numbers).

### 5.7 A large `alloc` used to block the scheduler; it is now zeroed in strips

- **Numbers:** one 85 MB `alloc` held the scheduler ~5 ms (`codecs`: a
  kernel that only allocs 85 MB gives a 5.0 ms tick gap, and the kernel
  encoding 64 MB, which yields in its loop, still showed 4.6-4.8 ms). After zeroing in 1 MiB strips with a safepoint after each: one
  cold 85 MB alloc 3.88 ms -> 2.00-2.55 ms; 20 warm allocs 6.70-6.92 ms ->
  1.94-2.28 ms. 64 KiB strips were ~30% slower than one memset (461 vs 350
  us); 1 MiB strips showed no difference. Skipping the zeroing when every
  element is provably written: `scale` of 1M f64 170 -> 131 us (-23%),
  `encode16` 1 MB 338 -> 297 us (-12%), base64 unchanged.
- **Conditions:** under load (load average 4-5).
- **Source:** `defk-ktw` comment 2026-10-10, `defk-i5r` (open), [`codecs.exs`](https://github.com/DanielLuning/defk/blob/main/examples/codecs.exs). Other whole-buffer copies still have no safepoint (`defk-oed`, open).
- **Status:** provisional; the `codecs` 4.6-4.8 ms numbers are superseded by `defk-ktw`.

<!-- defk-example skip: kernel-subset code (alloc, indexing, the kernel builtins), not plain Elixir; the kernels are checked where they are examples -->
```elixir
# not zeroed: the first statement mentioning x writes every element
x = alloc(f64, 2 * n)
for i <- 0..(n - 1)//1 do
  x[2 * i] = a[i]
  x[2 * i + 1] = b[i]
end
```

---

## 6. Making a defk kernel fast

Start with the fast-path report: `Defk.Report.print(Mod)`, or
`use Defk, report: :full` for clang's vectorisation verdict per loop. It
names each kept bounds check and the fact that would drop it. See
[`fast-path-report.md`](https://github.com/DanielLuning/defk/blob/main/docs/fast-path-report.md).

### 6.1 At its best a kernel loop runs at plain-C speed

- **Numbers:** ns per element over 5M f64: `sum` Elixir 8.5 (list) / 16.7
  (binary comprehension), defk 0.58, C 0.64; `dot` Elixir 12.2 (list), defk
  0.50, C 0.50. `count_primes(1M)`: Elixir 1400 ms, defk 180, C 186.
- **Conditions:** "noisy, single runs".
- **Source:** [README Results](../README.md), `bench/native.c`.
- **Status:** measured. Later runs give `dot` ~0.56 and `sum` 0.50-0.53 ns/elem (`defk-jlk`).

### 6.2 Write loops whose indices the compiler can prove in range

- **Numbers:** cosine top-k one call, 100k x 384: literal `@dim 384` 20 ms,
  `dim = len(q)` 25 ms (every access kept its check). Range facts for `2 * i`
  (`defk-upc`): 1 MB hex encode 0.601 -> 0.333 ms, decode 0.644 -> 0.503 ms.
  `pcm_mix`: a variable block offset keeps two bounds checks in the sum loop,
  which then runs scalar and takes ~70% of the kernel (0.2-0.29 of 0.3-0.37
  ms); the check-free clamp loop beside it vectorises at width 8.
- **Conditions:** under load.
- **Source:** [`cosine_topk.exs`](https://github.com/DanielLuning/defk/blob/main/examples/cosine_topk.exs), `defk-n7k`; `defk-upc` comment 2026-10-10; [`pcm_mix.exs`](https://github.com/DanielLuning/defk/blob/main/examples/pcm_mix.exs), `defk-siy`.
- **Status:** provisional. Still open: `defk-siy`, `defk-n7k`, `defk-pic`, `defk-fun`, `defk-9za`.

<!-- defk-example skip: kernel-subset code (alloc, indexing, the kernel builtins), not plain Elixir; the kernels are checked where they are examples -->
```elixir
# proven: no bounds checks
n = min(len(a), len(b))
for i <- 0..(n - 1)//1, reduce: 0.0, do: (acc -> acc + a[i] * b[i])
table[band(h, 255)]                 # into a 256-element alloc or attribute
@dim 384                            # literal stride: m[r * @dim + j]
out = alloc(i16, len(a))            # alloc with len(a), loop to min(len(a), len(b)) - 1
# kept
a[i + 1]                            # nothing proves i + 1 < len(a)
bufs[j * m + i]                     # m = div(len(bufs), n): variable block offset (defk-siy)
for ..., reduce: out do o -> o[2 * i] = a[i]; o end   # reduce accumulator drops alloc facts (defk-fun)
```

### 6.3 Flat loops run in strips with one safepoint each

A per-iteration safepoint check stops clang vectorising a loop. A flat inner
loop (no nested loop) runs as a plain loop under `DEFK_STRIP` (2048) trips,
and in strips of 2048 with one safepoint each above that.

- **Numbers:** `dot` yielding 0.78-0.81 ns/elem with a per-iteration
  safepoint counter (C 0.48-0.50, `yield: false` without checks 0.50-0.51),
  0.50 after strips (= C); `fuzzy_search` yielding vs `yield: false`
  1.20x originally, 1.10-1.12x after bounds-check elimination, 1.08-1.09x
  after strips. `DEFK_STRIP` 512 split `prime?`'s 1000-trip loop into two
  strips, +5-6% against `yield: false`; at 2048 the ratio is back to ~1.00.
- **Source:** `defk-88q`, `defk-5s3` comments 2026-10-05 (commit a6bca78), `defk-jaj` comment 2026-10-05, [README](../README.md#design-decisions-the-benchmarks-validated).
- **Status:** measured; the 1.08-1.09x is superseded by 6.4.

### 6.4 Resume through loop headers; yielding is then nearly free

Re-entering a resumed loop in the middle made the control flow irreducible
for LLVM. Resuming through each loop's header fixed it.

- **Numbers:** yielding vs `yield: false` 1.11x -> 0.99-1.02x;
  `fuzzy_search` 20 ms vs 20 ms. A shared spill-and-return block was worse
  (1.04-1.05x). Yielding every 250 us instead of 1 ms (~78 yields per query
  instead of 18) cost nothing measurable and brought `/health` median from 3
  ms to 1.1 ms. Each yield costs ~6-9 us of scheduler work, mostly the I/O
  poll (macOS): 2-3% on `count_primes`, which yields ~3,300 times a second.
- **Conditions:** load not recorded; Linux not measured.
- **Source:** `defk-nua` comment 2026-10-05, `defk-j3h` comment 2026-10-05, [`fuzzy_search/README.md`](https://github.com/DanielLuning/defk/blob/main/examples/fuzzy_search/README.md), [README](../README.md).
- **Status:** measured; a later loaded run disagrees (see 8.2, open questions).

### 6.5 Float checks: flag the strip, replay on failure

Raising on inf/NaN like Elixir costs a branch per operation, and a branch
per element stops vectorisation. A flat strip now ORs "inf or NaN" into a
flag with no branch, tests it once at the strip's end, and replays the strip
with raising checks if it is set.

- **Numbers:** 1M elements, checks on vs compiled out. Per-operation checks:
  `dot` 30%, cosine 82%, `mean_std` 48%, `scale` (`out[i] = a[i] * k`) 150%.
  One check per expression: `dot` +24%, cosine +17%, `mean_std` +23%, `scale`
  +87-91%. Flagged strips (`defk-6tt`): `dot` 0.0-0.2%, cosine -0.3-0.2%,
  `scale` 0.5-3.6% (clang vectorises it 16 elements per iteration), `mean_std`
  unchanged at 29-33% (it has bounds and overflow checks too). Mixed flagged
  strips (`defk-hki`): `mean_std` +7.1-8.5% (main in the same session
  37-39%), checks on 1937-1956 us against main's 2621-2637 us.
- **Didn't help:** testing the flag before each other check (41%); branchless
  flags alone on a loop that does not vectorise (6-15% slower than predicted
  branches). What paid was leaving out checks whose inf/NaN always reaches a
  later checked expression, `sqrt(max(x, 0.0))` needing no check, and `sqrt`
  as one instruction.
- **Conditions:** 3 runs of 11 interleaved rounds, best of 5 per round;
  shared machine; `defk-hki` under load (load average 5-7.5).
- **Source:** [README Known limitations](../README.md#known-limitations), [`bench/float_checks.exs`](https://github.com/DanielLuning/defk/blob/main/bench/float_checks.exs) (3737d1a), `defk-6tt`, `defk-hki` comment 2026-10-10 (897e9c4, 042c2f4).
- **Status:** per-expression numbers superseded by `defk-6tt` and `defk-hki`; `defk-hki` provisional.

### 6.6 What still blocks vectorisation

- **In-order float reductions.** Kernels build with `-ffp-contract=off` and
  no reassociation, so `acc + a[i] * b[i]` stays in Elixir's order: clang
  vectorises the loads and multiplies but not the adds across lanes. The flag
  itself costs nothing measurable (`dot` ~0.56, `sum` 0.50-0.53, `mean_var`
  3.8-4.3 ns/elem either way). Write independent partial sums when the order
  is yours to choose: `cosine_topk`'s eight partial sums run as 2 x f64 NEON
  lanes. (`defk-jlk`, `defk-t11.5`, [`cosine_topk.exs`](https://github.com/DanielLuning/defk/blob/main/examples/cosine_topk.exs); measured.)
- **In-place accumulate.** `out[r] = out[r] + x[i] * c` keeps per-operation
  float checks, because a strip that writes memory cannot be replayed: a
  dimension-major cosine scan ran ~26 ms against 20 ms for the row-major dot
  with eight partial sums. (`defk-agp`, open; measured.)
- **Exact mixed comparisons.** `defk_cmp_i64_f64(x, t)` (an exact i64-vs-f64
  compare) is scalar in a loop where `(double)x < t` would vectorise; no
  catalog kernel needs it. (`defk-t11.2` comment 2026-10-08, 6f8a075; measured.)
- **Early-exit loops with writes** ("Cannot vectorize early exit loop with
  writes to memory" in the report). (`defk-agp`.)

<!-- defk-example skip: kernel-subset code (alloc, indexing, the kernel builtins), not plain Elixir; the kernels are checked where they are examples -->
```elixir
# vectorises: eight partial sums
{a0, a1, a2, a3, a4, a5, a6, a7} = for j <- 0..(div(@dim, 8) - 1)//1, reduce: {0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0} do ... end
s = a0 + a1 + (a2 + a3) + (a4 + a5 + (a6 + a7))
# does not: in-place accumulate
out[r] = out[r] + m[i] * s
```

### 6.7 Pure arithmetic arms become selects; arms with division should stay branches

A raising check inside one `if` arm stopped clang turning the `if` into a
select, and clang then threaded the branch into the inner loop.

- **Numbers:** `count_primes(1M)` ~317 ms against C ~188 ms before; 180 ms
  against C 186 ms after (`cond` 309 -> 181 ms). A select whose arm contains
  `rem` cost 48 ns per spin against 41.5 for a plain `rem`, so arms with
  division are no longer speculated. A branch-free run count was slower (45
  ns per spin) than a `cond` that stops at the first mismatch (27 ns).
- **Conditions:** `defk-id9` under load.
- **Source:** `defk-jp3`, `defk-7q5` comments 2026-10-05, `defk-id9` comment 2026-10-10, [`monte_carlo_rtp.exs`](https://github.com/DanielLuning/defk/blob/main/examples/monte_carlo_rtp.exs).
- **Status:** measured; `defk-id9` provisional.

<!-- defk-example skip: kernel-subset code (alloc, indexing, the kernel builtins), not plain Elixir; the kernels are checked where they are examples -->
```elixir
if prime?(i), do: count + 1, else: count     # pure arithmetic arms: a select
i = if pow2, do: band(v, n - 1), else: rem(v, n)   # an arm with division: keep the branch
```

### 6.8 Register pressure: safepoints spill only live locals

Before `defk-zep` every safepoint spilled every kernel local, so round
temporaries in Keccak became loop-carried values, and statement order
changed speed by 1.5x.

- **Numbers:** Keccak on 16 MB, four orderings: before 27.1 / 29.3 / 37.6 /
  41.9 ms (26-51 stack stores per round), after 20.7 / 21.0 / 21.0 / 21.0 ms
  (9-11 stores per round); `yield: false` 18.2-18.6 ms with 0 spills. Side
  effects: `xxh64` 4 MB 0.36-0.40 -> 0.175-0.182 ms (about 2x); siphash 1k
  keys 0.054-0.057 -> 0.043-0.044 ms. The remaining ~10% against `yield:
  false` is yield bookkeeping held in registers (`defk-w8l`, open).
- **Conditions:** under load (spill counts do not depend on load).
- **Source:** `defk-zep` comment 2026-10-10 (f81c2cd, merge 522e7f2), [`keccak.exs`](https://github.com/DanielLuning/defk/blob/main/examples/keccak.exs).
- **Status:** provisional (timings); the older "28 ms" and "0.55x of ex_keccak" figures are superseded.

### 6.9 The algorithm still matters inside a kernel

- **Numbers:** geohash encode, bisecting kernel 14-31 ms, quantise and
  bit-spread 1.9-2.0 ms. `image_blur`: 9 reads per pixel 15.3 ms in one call,
  separable horizontal then vertical sums 5.4-5.8 ms. `batched_levenshtein`:
  DP kernel 31.3 ms, Myers kernel 6.7 ms. `matmul`: i-k-j order vectorises;
  64x64 tiling is no faster (0.27 vs 0.20 ms at 64, 13.9 vs 13.4 at 256, 983
  vs 827 ms at 1024). Sorting with no recursion: an in-place heapsort kernel
  still beats decode + `:lists.sort` 4.3-5.3x.
- **Source:** [`geohash_crc.exs`](https://github.com/DanielLuning/defk/blob/main/examples/geohash_crc.exs), [`image_blur.exs`](https://github.com/DanielLuning/defk/blob/main/examples/image_blur.exs), [`batched_levenshtein.exs`](https://github.com/DanielLuning/defk/blob/main/examples/batched_levenshtein.exs), [`matmul.exs`](https://github.com/DanielLuning/defk/blob/main/examples/matmul.exs), [`sort_u64_keys.exs`](https://github.com/DanielLuning/defk/blob/main/examples/sort_u64_keys.exs).
- **Status:** measured; image_blur and batched_levenshtein provisional.

### 6.10 Byte loops: process four bytes per iteration with no per-byte index arithmetic

- **Numbers:** WebSocket masking kernel 32-36 GB/s from 64 KiB up (memory
  bandwidth), 27 us per 1 MiB frame (38 GB/s).
- **Conditions:** under load.
- **Source:** [`ws_masking.exs`](https://github.com/DanielLuning/defk/blob/main/examples/ws_masking.exs) (2ae646a).
- **Status:** provisional.

<!-- defk-example skip: kernel-subset code (alloc, indexing, the kernel builtins), not plain Elixir; the kernels are checked where they are examples -->
```elixir
for i <- 0..(div(n, 4) - 1)//1 do
  j = 4 * i
  out[j] = bxor(payload[j], k0)
  out[j + 1] = bxor(payload[j + 1], k1)
  out[j + 2] = bxor(payload[j + 2], k2)
  out[j + 3] = bxor(payload[j + 3], k3)
end
# the 0..3 trailing bytes take their key byte by position
```

### 6.11 Hashes: masked arithmetic, literal shift counts, unrolled rounds

Masked arithmetic (`band(expr, 2^k - 1)`) computes with wrapping machine
arithmetic and no overflow checks. A rotate written as
`bor(wrap64(bsl(x, n)), band(bsr(x, 64 - n), 2^n - 1))` with a literal `n`
compiles to one `ror`. A shift by a variable count is a checked operation.

- **Numbers:** SHA-256 kernel: a first version with a `rotr32(x, n)` helper
  taking `n` and unmasked `t1` 236 ns per step; rounds as loops 190-211 ns;
  unrolled with literal rotates 173-186 ns.
- **Conditions:** under load (load 13-36).
- **Source:** [`hash_chain.exs`](https://github.com/DanielLuning/defk/blob/main/examples/hash_chain.exs), [`keccak.exs`](https://github.com/DanielLuning/defk/blob/main/examples/keccak.exs), [`hashes.exs`](https://github.com/DanielLuning/defk/blob/main/examples/hashes.exs); builtin rotates are `defk-52v.6`.
- **Status:** provisional.

<!-- defk-example skip: kernel-subset code (alloc, indexing, the kernel builtins), not plain Elixir; the kernels are checked where they are examples -->
```elixir
band(bsr(x, 7) + bsl(x, 25), 0xFFFFFFFF)   # literal n: wrapped, no checks
rotr32(x, n)                                # n as a parameter: a checked bsl
```

### 6.12 Tables: module attributes, read with a masked index

A binary module attribute is a static `[u8]` in the library: no allocation
and no copy per call, and `@b64[band(x, 63)]` needs no bounds check.

- **Numbers:** building tables inside the kernel cost ~2 us per call
  (`geohash_crc`, written before attributes existed). Emitting each binary
  attribute once per module instead of at every inlined use site shrank the
  generated C for `hashes.exs` from 2,115,100 to 326,375 bytes.
- **Source:** [`codecs.exs`](https://github.com/DanielLuning/defk/blob/main/examples/codecs.exs), [`geohash_crc.exs`](https://github.com/DanielLuning/defk/blob/main/examples/geohash_crc.exs), `defk-ivt`, `defk-qx3` comment 2026-10-10.
- **Status:** measured; the per-call table build in `geohash_crc` and `utf8_valid` is superseded by `defk-ivt`.

<!-- defk-example skip: kernel-subset code (alloc, indexing, the kernel builtins), not plain Elixir; the kernels are checked where they are examples -->
```elixir
@b64 "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
out[o] = @b64[band(bsr(x, 18), 63)]
```

### 6.13 Build flags cost little

- **Numbers:** `-fstack-protector-strong`, `-D_FORTIFY_SOURCE=2` and
  `-fno-strict-overflow` together +0.33-1.64% (sum, dot, count_primes,
  count_primes_early). `-fno-builtin` (needed so `cos` and `sin` are not
  fused into a `sincos` that differs from `:math.sin` in the last bit): sum
  -0.71%, dot -0.16%, count_primes +0.15%, count_primes_early +0.88-2.30%.
- **Conditions:** Apple clang 17; interleaved rounds; the `-fno-builtin` run noisy.
- **Source:** `defk-j5n` comment 2026-10-08, `defk-6g6` comment 2026-10-09.
- **Status:** measured.

### 6.14 32-bit rotates: write `rotr(x, n, 32)`; unroll rounds with literal word names

Since `defk-52v.2` the runtime rotates a 32-bit field as a `uint32_t`, so
`rotr(x, n, 32)` with a literal `n` compiles to one `ror w`. The masked
spelling `band(bsr(x, n) + bsl(x, 32 - n), 0xFFFFFFFF)` is checked-free but
clang gives it a shift and a bit-field insert on a 64-bit register. For
64-bit words `rotr64/2` is already one `ror`.

- **Numbers:** BLAKE3 of 64 KB: masked spelling 79-80 us; `rotr(x, n, 32)`
  before the runtime change 95-98 us; after it 54-55 us, level with the
  portable C (52 us at 64 KB, 54.9-55.1 ms at 64 MB, against the kernel's
  54.9-59.7 ms). BLAKE2b: rounds unrolled with the message words as 16
  locals 43 us at 64 KB; a round loop reading SIGMA from a binary attribute
  into an `[i64]` of words 48-49 us (12% slower).
- **Conditions:** under load; Apple clang; portable C built from the blake3
  crate 1.3.3's `c/` directory with `-O3 -DBLAKE3_USE_NEON=0`.
- **Source:** [`blake.exs`](https://github.com/DanielLuning/defk/blob/main/examples/blake.exs) (header), `defk-52v.2`.
- **Status:** provisional. The other 32-bit hashes (`hash_chain.exs` SHA-256 uses the masked spelling) were not re-measured.

<!-- defk-example skip: kernel-subset code (rotr/3 builtin), two spellings of one kernel line -->
```elixir
d = rotr(bxor(d, a), 16, 32)                               # one ror
d = band(bsr(t, 16) + bsl(t, 16), 0xFFFFFFFF)              # lsl + bfxil
```

### 6.15 Byte copies: eight bytes per `u64_le`, and call an array-writing helper outside branches

A kernel can only store one element at a time, so a byte-copy loop (an LZ
decoder's literals and matches) pays a bounds check and an overflow check
per byte; clang does not merge eight checked byte stores into one 64-bit
store. Loading a word with `u64_le` and storing its eight bytes, with a
7-byte overshoot when the buffers have slack, is the best spelling today;
a word store or copy builtin (`defk-52v.16`) would remove the per-byte
checks. Separately, a helper kernel that writes and returns the output must
be called at the top of the loop body: called in one branch of an `if`
whose other branch reads the array, it copies the whole buffer on every
iteration and keeps every copy until the kernel returns (`defk-33b`).

- **Numbers:** 4 MB of text, LZ4 / Snappy: byte loops 5.3 / 9.6-10.1 ms,
  byte loops over the destination index 5.7-6.2 / 9.0-9.6 ms, words 4.7-4.8
  / 8.0 ms; `yield: false` saved 10-20% (it blocks the scheduler, so it is not used). Per LZ4 sequence about 13 ns against
  optimised liblz4's 2 ns. The helper in a branch: 47-53 ms instead of 0.1
  ms at 64 KB, and the BEAM was SIGKILLed (out of memory) at 4 MB; a 1-byte
  reproduction is quadratic (40k iterations 202 ms against 7 us hoisted).
- **Conditions:** under load (load averages 13-85).
- **Source:** [`lz4_snappy_decode.exs`](https://github.com/DanielLuning/defk/blob/main/examples/lz4_snappy_decode.exs) (header), `defk-52v.3`, `defk-33b`, `defk-52v.16`.
- **Status:** provisional.

<!-- defk-example skip: kernel-subset code (u64_le, array writes, helper kernels), not plain Elixir -->
```elixir
# fast: both helpers on every element, one length 0
out = copy_lit(out, op, src, s, lit)
out = copy_back(out, op + lit, off, ln - lit)
# slow: the helper in one branch, the array read in the other
if last, do: {:halt, {out, op}}, else: (out = copy_back(out, op, off, ml); {:cont, {out, op + ml}})
```

### 6.16 Target flags: on arm64 the CPU features buy nothing, the tuning does

A kernel built for the host CPU (`-mcpu=native`, Apple M4) or for armv8.2-a
is no faster than today's build, which Apple clang already targets at
`apple-m1`. The same 24 of the catalogue's 200 loops vectorise, at the same
widths, at every arm64 level. NEON is the baseline; SVE is not available on
Apple silicon. What changed speed is the *tuning*: a generic build
(`-mcpu=generic`, what a portable Linux/aarch64 build gets) won or lost on
some kernels, and `-mtune=generic` alone reproduced it while
`-march=armv8-a` (fewer features, same tuning) did not.

- **Numbers:** these are speedups over the default build, as medians of 7-9
  interleaved rounds in two runs.
  - native and armv8.2-a: within ±3% on all 42 timed kernels where the runs
    agree (`matmul`, Horspool, `mix_s16` and the image kernels are noisier
    between rounds than between levels).
  - generic, slower: `sort_i64` 0.78 / 0.78 (0.94 in a third run), cosine
    0.93, `keccak256` 0.93, `convolve` 0.93-0.95, `dot` 0.95, HLL 0.94-0.95,
    `decode64` 0.95.
  - generic, faster: the SHA-256 chain 1.18-1.19 (171 -> 145 ns per step).
  - `-mtune=generic` alone: `sort_i64` 0.94, SHA-256 1.17, `keccak256` 0.92.
  - `-march=armv8-a` alone: 1.00-1.03 on the same kernels.
- **Conditions:** Apple M4 Pro, Apple clang 21, kernels timed alone at the
  examples' shapes (`bench/simd/cases.exs`). Load averages were 13-154 at
  the start of the runs. The levels were built through a `CC` wrapper per
  level.
- **Source:** [`docs/research/simd.md`](https://github.com/DanielLuning/defk/blob/main/docs/research/simd.md), [`bench/simd/time.exs`](https://github.com/DanielLuning/defk/blob/main/bench/simd/time.exs), `defk-ulk.1`.
- **Status:** provisional (loaded machine). Linux/aarch64 hardware and
  upstream clang were not measured.

```bash
# time every catalogue kernel at each target level of this machine, interleaved
mix run bench/simd/time.exs 9
SIMD_LEVELS="default:,tune:-mtune=generic" mix run bench/simd/time.exs 7
```

### 6.17 On x86-64, no level vectorises an in-order float reduction (remarks only)

These are clang's loop-vectorize remarks for x86-64 targets, compiled on the
Mac. Nothing was timed.

- `sum`, `dot` and cosine stay scalar at SSE2, v2, v3 and v4 ("cannot prove
  it is safe to reorder floating-point operations"). On arm64 they vectorise
  as ordered reductions.
- Write partial sums (6.6) where the order is yours to choose: `topk`'s
  eight partial sums vectorise on both.
- v3 doubles the width of the loops that do vectorise (4 x f64, 32 bytes).
  It also vectorises `ws_mask`'s main 4-byte loop, which SSE2 and v2 leave
  scalar.
- v4 keeps 256-bit vectors.
- No level emits an FMA under `-ffp-contract=off`. With
  `-ffp-contract=on`, v3 emits 11-87 per float module.

- **Source:** [`docs/research/simd.md`](https://github.com/DanielLuning/defk/blob/main/docs/research/simd.md), `bench/simd/remarks.exs`, `bench/simd/fma_check.sh`, `defk-ulk.1`.
- **Status:** static, not timed. The timing run on x86-64 hardware is
  described in the research note.

### 6.18 Counting into a table: four interleaved tables, and window bounds as `max`/`min`

`h[b] = h[b] + 1` on consecutive equal bytes waits on its own previous
store. Counting bytes `i`, `i + 1`, `i + 2`, `i + 3` into four 256-entry
tables and summing them at the end breaks that chain. For a loop over one
window of a buffer, write the bounds as `lo = max(k * w, 0)` and
`hi = min(lo + w, len(data))` so the reads are proven in range.

- **Numbers:** 16 MB histogram, one call: one table 5.8-6.0 ms, four
  tables 3.6-3.7 ms (1.6x). Entropy of 4 KiB windows: one table and a
  `log2` per bin 7.6 ms, four tables 5.8-5.9, four tables and a table of
  per-count terms 4.7-4.8; with the window range written
  `(k * w)..(k * w + w - 1)` every byte read kept its bounds check (four
  tables 8.5 ms, with the term table 7.0).
- **Conditions:** under load (load average 12-23).
- **Source:** [`byte_histogram.exs`](https://github.com/DanielLuning/defk/blob/main/examples/byte_histogram.exs) (header), `defk-9p6.28`.
- **Status:** provisional.

<!-- defk-example skip: kernel-subset code (alloc, array writes), not plain Elixir; the kernels are checked in the example -->
```elixir
# fast: four tables, proven window bounds
lo = max(k * w, 0)
hi = min(lo + w, len(data))
for i <- lo..(hi - 4)//4 do
  a = data[i]; b = data[i + 1]; c = data[i + 2]; d = data[i + 3]
  h[a] = h[a] + 1; h[256 + b] = h[256 + b] + 1; h[512 + c] = h[512 + c] + 1; h[768 + d] = h[768 + d] + 1
end
# slow: one table, and a range the compiler cannot prove inside data
for i <- (k * w)..(k * w + w - 1)//1, do: (b = data[i]; h[b] = h[b] + 1)
```

---

## 7. When a hand-written or wrapper NIF is still the answer

### 7.1 Hardware instructions and SIMD libraries beat a portable kernel

- **Numbers:** CRC32C: crc32cer (hardware CRC32C) is 14x faster than the
  kernel. SHA-256: `:crypto` on the SHA instructions 100-104 ns per chain step
  against 175-178 for the portable kernel. Dense dot-product top-k: Nx +
  EXLA 6-8x faster than defk. Keccak: ex_keccak (tiny-keccak) is ~1.7x faster
  than the kernel on 10k x 32-byte messages (per-message overhead) and level
  at 16 MB (19.1 vs 20.7 ms, under load).
- **Source:** [`hashes.exs`](https://github.com/DanielLuning/defk/blob/main/examples/hashes.exs), [`hash_chain.exs`](https://github.com/DanielLuning/defk/blob/main/examples/hash_chain.exs), [`cosine_topk.exs`](https://github.com/DanielLuning/defk/blob/main/examples/cosine_topk.exs), [`keccak.exs`](https://github.com/DanielLuning/defk/blob/main/examples/keccak.exs).
- **Status:** measured; hash_chain, cosine, the keccak 16 MB comparison provisional.

A target flag does not close these gaps. At every arm64 level, and as
remarks for x86-64 up to v4, clang emits no CRC32, SHA or SHA3 instruction
from the kernels' scalar code: `crc32c` runs at 1.00x with `-mcpu=native`.
Closing them needs a hardware builtin (CRC32C) or vector values (UTF-8,
base64, substring search). See [`simd.md`](https://github.com/DanielLuning/defk/blob/main/docs/research/simd.md) (`defk-ulk.1`;
provisional).

The wrapper jobs and what would reopen each are in
[examples/README.md, "Where a wrapper is the right choice"](https://github.com/DanielLuning/defk/blob/main/examples/README.md#where-a-wrapper-is-the-right-choice).

### 7.2 A hand-written NIF is not automatically fast

- **Numbers:**
  - Membrane NativeAdder (generic C, a byte loop with format branches)
    0.72-0.75 ms per 1 s of audio; the typed kernel 0.41-0.49 ms.
  - bandit_native (Rust, one byte at a time) 548 us per 1 MiB frame, slower
    than the Elixir hybrid (513 us) and 20x the kernel (27 us).
  - ex_strsim called per pair with `Enum.map`: 35-38 ms for 234k words, 2.2x
    slower than one-process Elixir Myers.
  - ex_data_sketch's Rust HLL NIF: 2.55-2.8 ms at 100k, of which 2.3 ms is
    its Elixir pack (`Enum.map` + iodata); fed defk's packer it takes 0.46 ms.
  - gorilla_stream's C++ NIF (dirty CPU, a scheduler hop per call): 6.0-7.2
    ms for 1,000 100-point blocks, defk 2.1-2.45 ms.
  - vettore's `flat_new_cosine` recomputes norms per row: 33.6-34.2 ms
    against 12.6-12.7 ms for its inner-product index on pre-normalised
    vectors.
  - Level: siphash's C NIF and the kernel batch on 1k keys (0.96-1.0x); the
    fast64 C NIF is 2.1x slower than the base64 kernel.
- **Conditions:** pcm_mix, ws_masking, batched_levenshtein, hll, gorilla,
  cosine under load; hashes and codecs load not recorded.
- **Source:** [`pcm_mix.exs`](https://github.com/DanielLuning/defk/blob/main/examples/pcm_mix.exs), [`ws_masking.exs`](https://github.com/DanielLuning/defk/blob/main/examples/ws_masking.exs), [`batched_levenshtein.exs`](https://github.com/DanielLuning/defk/blob/main/examples/batched_levenshtein.exs), [`hll_update_many.exs`](https://github.com/DanielLuning/defk/blob/main/examples/hll_update_many.exs), [`gorilla_encode.exs`](https://github.com/DanielLuning/defk/blob/main/examples/gorilla_encode.exs), [`cosine_topk.exs`](https://github.com/DanielLuning/defk/blob/main/examples/cosine_topk.exs), [`hashes.exs`](https://github.com/DanielLuning/defk/blob/main/examples/hashes.exs), [`codecs.exs`](https://github.com/DanielLuning/defk/blob/main/examples/codecs.exs).
- **Status:** mostly provisional.

### 7.3 A NIF on a normal scheduler that doesn't yield blocks it for the whole call

- **Numbers (worst gap of a 1 ms ticker on one scheduler):** NativeAdder 60
  back-to-back 0.7 ms calls 41-43 ms (Elixir 3.2-5.6, defk 2.2-2.3);
  bandit_native one 16 MiB frame 8.9-9.0 ms (Elixir 2.0-2.1, defk 0.44-0.66);
  1BRC Rustler plain NIF on a ~28 MB chunk 55 ms (Elixir 13.3, DirtyCpu
  5.6); ex_keccak on 16 MB ~20 ms (kernel ~2 ms); picosat on a hard random
  3-SAT instance 3,870 ms (`+S 1`); a `yield: false` kernel 867 ms (README;
  500-570 ms in later runs). Under HTTP load, a blocking kernel pushed
  `/health` to 33 ms median and 77-90 ms p99 against 1.1 ms and 8-10 ms for
  the yielding kernel.
- **Conditions:** most under load; fuzzy_search before its cut-off.
- **Source:** [`pcm_mix.exs`](https://github.com/DanielLuning/defk/blob/main/examples/pcm_mix.exs), [`ws_masking.exs`](https://github.com/DanielLuning/defk/blob/main/examples/ws_masking.exs), [`one_brc/rustler.exs`](https://github.com/DanielLuning/defk/blob/main/examples/one_brc/rustler.exs) (dae1457), [`keccak.exs`](https://github.com/DanielLuning/defk/blob/main/examples/keccak.exs), [`sat-solver.md`](https://github.com/DanielLuning/defk/blob/main/docs/research/sat-solver.md) (2ed5c84), `defk-yzw`, [`fuzzy_search/README.md`](https://github.com/DanielLuning/defk/blob/main/examples/fuzzy_search/README.md).
- **Status:** provisional.

### 7.4 Dirty CPU or yielding

A dirty CPU NIF keeps normal schedulers free, but the process can't be
suspended or garbage-collected until it returns, a killed process doesn't
stop it, and each call pays a hop to the dirty scheduler. defk yields from
normal schedulers instead ([`beam-nifs.md`](https://github.com/DanielLuning/defk/blob/main/docs/beam-nifs.md)).

- **Numbers:** 1BRC 10M / 100M rows: Rustler plain NIF 67 / 760 ms,
  `schedule = "DirtyCpu"` 34 / 318 ms (2.4x faster: the plain NIF shared
  cores with the pread and merge work), Elixir `par_map` 342 / 3535 ms. Small
  calls pay the hop: gorilla_stream's dirty NIF is 2.75-2.9x slower than the
  kernel at 100-point blocks.
- **Conditions:** 1BRC under load (load average ~21), best of 3; Rust 1.94.1, rustler 0.37.4.
- **Source:** [`one_brc/rustler.exs`](https://github.com/DanielLuning/defk/blob/main/examples/one_brc/rustler.exs), `defk-n4r.8`, [`gorilla_encode.exs`](https://github.com/DanielLuning/defk/blob/main/examples/gorilla_encode.exs).
- **Status:** provisional.

### 7.5 BLAKE3's NEON build beats a portable kernel; reference-C BLAKE2b ties it

- **Numbers:** BLAKE3, 64 KB / 64 MB: blake3 1.0.2 (Rust blake3 1.3.3,
  NEON on aarch64 by default) 0.033-0.036 ms / 33.7-34.3 ms, kernel
  0.054-0.059 ms / 54.9-59.7 ms (0.6x). BLAKE2b: blake2_elixir 0.9.0 (the
  BLAKE2 reference C, -O3) 0.043-0.046 ms / 44.4-47.8 ms, kernel 1.0x. Both
  NIFs run on a normal scheduler and block it for the whole call: tick gaps
  of 45-49 ms (BLAKE2b) and 34-37 ms (BLAKE3) on a 64 MB hash, against
  2.1-2.7 ms for the kernels.
- **Conditions:** under load (load averages 13-135).
- **Source:** [`blake.exs`](https://github.com/DanielLuning/defk/blob/main/examples/blake.exs), `defk-52v.2`.
- **Status:** provisional.

### 7.6 Hex NIFs built by rebar3's port compiler may be unoptimised; check the flags before comparing

rebar3's `pc` plugin adds no `-O` flag: a package that sets none builds its
C at `-O0`. lz4_erl 0.2.4 (liblz4 1.7.5) sets no CFLAGS; snappyer 1.2.10
sets `-O2` in CFLAGS but compiles its C++ with CXXFLAGS, which has none. So
`mix deps.get` gives -O0 builds of both reference libraries. Rebuilt with
`CFLAGS=-O3 CXXFLAGS=-O2` (a separate `MIX_INSTALL_DIR`, or `mix deps.compile
--force` with the variables set), they are the speed the libraries are known
for, and much faster than a from-scratch kernel.

- **Numbers:** 64 KB / 4 MB JSON-like block: snappyer as installed 99-184 us
  / 5.9-6.8 ms, rebuilt 23-26 us / 1.6 ms; lz4_erl as installed 92-97 us /
  5.2-5.5 ms, rebuilt 8-9 us / 0.9 ms; nimble_lz4 (lz4_flex, a precompiled
  Rust release build) 20-24 us / 1.1-2.3 ms. The kernels 63-77 us / 4.1-4.9
  ms: 1.3-1.6x faster than the as-installed NIFs, 3x (Snappy) and 9x (LZ4)
  slower than the optimised builds. lz4_erl runs on a normal scheduler: a
  4 MB decode gaps a 1 ms ticker by 5.1-11.3 ms as installed, 0.9 ms
  rebuilt; the kernels stay at the ~2 ms floor.
- **Conditions:** under load (load averages 24-85).
- **Source:** [`lz4_snappy_decode.exs`](https://github.com/DanielLuning/defk/blob/main/examples/lz4_snappy_decode.exs) (`LZ_NIF_OPT=1`), `defk-52v.3`.
- **Status:** provisional.

---

## 8. Myths we disproved and open questions

### 8.1 Myths

| Myth | What we measured | Entry |
|---|---|---|
| `Enum.sum` is just `:lists.sum` | 4.6 vs 4.9 ms on 1M floats | 1.1 |
| Wider words make Elixir byte loops faster | 64-bit words are about 2x slower than Bandit's 32-bit loop | 2.6 |
| Packed column binaries beat tuples in Elixir | ~31 ms vs ~24 ms (tuples) vs ~22 ms (one interleaved binary) | 2.10 |
| Bit syntax beats shifts for splitting a bignum | 4.0 vs 3.3 ms | 2.5 |
| Batching always beats one call per item | batching from a list of pairs was slower (18 vs 13 ms) | 5.4 |
| Per-pair NIF calls are always too expensive | a quadratic DP per pair outweighs the call: 3.2-3.4x at 8-16 bytes | 5.4 |
| A hand-written NIF beats Elixir | ex_strsim 2.2x slower than Elixir Myers; bandit_native slower than the Elixir hybrid at 1 MiB | 7.2 |
| Nx makes numerics fast | only with EXLA; `BinaryBackend` is slower than plain Elixir | 3.8 |
| Parallel chunks always help | HLL fan-out 4.4 vs 3.3 ms; short kernel chunks stay on 2-3 schedulers | 4.5, 4.1 |
| Branch-free code is always faster | `cond` 27 vs branch-free 45 ns per spin; branchless check flags 6-15% slower on a scalar loop | 6.7, 6.5 |
| Tiling helps a matrix multiply kernel | no faster at 64 to 1024 | 6.9 |
| Yielding costs throughput | ~0% after reducible resume (one loaded run disagrees) | 6.4 |
| `-ffp-contract=off` makes float kernels slow | no measurable cost on dot, sum, mean_var | 6.6 |

### 8.2 Open questions

- **Per-call cost.** Sources give ~10 ns (`poor_tiny_calls`), 12 ns (README
  micro-benchmark), ~35 ns more than a NIF call (`hashes`), ~0.1-0.2 us
  (`per_pair_distance`) and ~0.12-0.13 us (`ws_masking`, under load), and a
  bitstring result adds ~0.1 us (`defk-cao`). No source says which costs are
  included in each. A single micro-benchmark on a quiet machine would settle it.
- **Yielding vs blocking on fuzzy_search.** `defk-nua` measured 0.99-1.02x
  (20 vs 20 ms); `defk-klw` measured 27-28 ms vs ~21 ms at load average 30+
  and later +4.7-4.9% after the cut-off (~55 yields per query). Open until
  the quiet re-measure (`defk-klw`).
- **Geohash batch break-even.** The `geohash_crc.exs` header says the encode
  crossover is about 100 points (1 point 0.5x); its report reason and the
  catalog row say a batch of 10 breaks even.
- **`mean_std` float-check cost** reads 23%, 29-33%, ~30% and 37-39% on main
  in different sessions, depending on load; only the `defk-hki` result
  (+7.1-8.5%) has its own same-session comparison.
- **`yield: false` worst gap**: 867 ms in the README, 500-570 ms in later
  demo runs (`defk-yzw`).
- **Not tried or not profiled yet:** Elixir on a one-scheduler VM is slower
  per spin than one process on 12 (185 vs 109 ns, `monte_carlo_rtp`); why
  Gorilla's middle block sizes gain most; parallel Elixir sorting
  (`sort_u64_keys`); 64-bit hashes in 16-bit limbs in Elixir (`hashes`); the
  per-call state copy of value semantics (`defk-sve.1`); EXLA for matmul
  (`defk-7tk`); libvips for the image jobs; x86-64 timings at the target
  levels (`defk-ulk.1`, remarks only so far); Linux (every number here is macOS
  on arm64).
- **Quiet-machine snapshot.** Most provisional entries wait for `defk-sgw.4`.
- **Tie band.** Verdicts at 1.0x and 2x flip with noise until `defk-9p6.24` lands.

---

## Sources covered

The first harvest (`defk-djy.10`) read every source below. When you add an
example or close a workload ticket, add its entries and its line here.

- Example headers and code: every `examples/*.exs` (including `run_all.exs`
  and `_template.exs`, which hold no findings), `examples/fuzzy_search/`,
  `examples/one_brc/`, `examples/release_debian/` (build cost only, no
  runtime findings).
- [`examples/README.md`](https://github.com/DanielLuning/defk/blob/main/examples/README.md): every row, "Measuring
  correctly", "How verdicts work", "Where a wrapper is the right choice".
- [`beam-nifs.md`](https://github.com/DanielLuning/defk/blob/main/docs/beam-nifs.md), [`verdict.md`](https://github.com/DanielLuning/defk/blob/main/docs/verdict.md) (no numbers yet),
  [`fast-path-report.md`](https://github.com/DanielLuning/defk/blob/main/docs/fast-path-report.md), the README's Results, design
  decisions and Known limitations, `docs/adr/`, `docs/cold-tests/` (no
  performance content), [`language.md`](language.md) (copies, bounds facts,
  strips), `bench/`.
- Research: [`nif-workloads.md`](https://github.com/DanielLuning/defk/blob/main/docs/research/nif-workloads.md),
  [`string-workloads.md`](https://github.com/DanielLuning/defk/blob/main/docs/research/string-workloads.md),
  [`nx-boundary.md`](https://github.com/DanielLuning/defk/blob/main/docs/research/nx-boundary.md) (inferred from source, not
  measured), [`sat-solver.md`](https://github.com/DanielLuning/defk/blob/main/docs/research/sat-solver.md),
  [`predictable-subsets.md`](https://github.com/DanielLuning/defk/blob/main/docs/research/predictable-subsets.md) (no performance
  findings).
- Tickets: the children of `defk-9p6` and `defk-52v`, and `defk-8qs`,
  `defk-6lr`, `defk-6tt`, `defk-hki`, `defk-agp`, `defk-88q`, `defk-5s3`,
  `defk-nua`, `defk-j3h`, `defk-jaj`, `defk-jp3`, `defk-7q5`, `defk-id9`,
  `defk-zep`, `defk-w8l`, `defk-ktw`, `defk-i5r`, `defk-oed`, `defk-upc`,
  `defk-siy`, `defk-n7k`, `defk-pic`, `defk-fun`, `defk-cao`, `defk-jlk`,
  `defk-t11.5`, `defk-6g6`, `defk-j5n`, `defk-qx3`, `defk-z69`, `defk-t11.2`,
  `defk-wnu`, `defk-9p6.24`, `defk-9p6.27`, `defk-m4b`, `defk-klw`,
  `defk-l2g`, `defk-yzw`, `defk-dtw.2`, `defk-dtw.20`, `defk-dtw.21`,
  `defk-sve`, `defk-ulk`, `defk-ulk.1` ([`simd.md`](https://github.com/DanielLuning/defk/blob/main/docs/research/simd.md)), `defk-33b`.
