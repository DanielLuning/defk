# The per-call state copy: value semantics against in-place state

Ticket: defk-sve.1 (epic defk-sve). Measured 2026-10-11.

## Question

[ADR-0001](../adr/0001-state-travels-as-binaries.md) decided that state
travels as binaries: a kernel takes the state, writes a copy and returns the
copy. It accepted the per-call copy and left kernel-owned mutable state as an
expansion candidate. The epic's first step is to find where that copy stops
being acceptable, before any design work. The rule: if the copy is under about
10% of the call at every realistic size in the catalog, value semantics is
enough and the exploration ends here.

The sizes, from the ticket:

- **HLL:** 16 KiB of registers (p = 14), batches of 100, 1k and 10k hashes.
  This is the ADR-0001 case.
- **Bloom filter:** 1 MiB and 16 MiB of bits, batches of 1, 100 and 10k
  inserts.
- **Streaming window:** 128 MiB of `[u8]` passed in and returned with one
  byte touched (the zstd/xxh3 streaming shape), and the same window with a
  128 KiB block appended.

The ticket also asks how the BEAM's binary GC behaves with 16 MiB outputs at
10k calls/s.

## Summary

- **The copy costs the same as Elixir's own copy.** It is one
  `enif_alloc_binary` and one `memcpy`: 0.35-0.39 us for 16 KiB, 14-15 us
  per MiB at 1 MiB, 0.26-0.30 ms at 16 MiB and 2.2-2.5 ms at 128 MiB (about
  45 GB/s at 16 KiB and 55-75 GB/s from 1 MiB up). Elixir's `:binary.copy/1`
  of the same size costs the same, less about 0.1 us. defk adds no overhead;
  the memory system sets the cost.
- **Per-size verdict.** The share is the copy's part of the whole call;
  value semantics is enough under about 10%.

  | state | batch | share | verdict |
  |---|---|---|---|
  | HLL 16 KiB | 100 hashes | 75-83% | not enough by the rule; 0.35 us in absolute terms |
  | HLL 16 KiB | 1k hashes | 30-33% | not enough by the rule; 0.35 us in absolute terms |
  | HLL 16 KiB | 10k hashes | 4-5% | **value semantics is enough** |
  | Bloom 1 MiB | 1 insert | ~100% | not enough |
  | Bloom 1 MiB | 100 inserts | 95-100% | not enough |
  | Bloom 1 MiB | 10k inserts | 20-25% | not enough |
  | Bloom 16 MiB | 1 insert | ~100% | not enough |
  | Bloom 16 MiB | 100 inserts | 94-100% | not enough |
  | Bloom 16 MiB | 10k inserts | 43-46% (87-89% counting the cache cost) | not enough |
  | Window 128 MiB | 1 byte | 100% | not enough |
  | Window 128 MiB | 128 KiB block | ~100% | not enough |

- **Small states:** HLL is fine in practice. The copy is a fixed 0.35-0.39 us
  per call, and the whole call at 100 hashes (0.47 us) is still far below
  the best Elixir version (0.019 ms, `hll_update_many.exs`). In-place
  registers would save 0.35 us per call, which does not justify a semantics
  change.
- **From 1 MiB up the copy is the call.** This holds below ~10k inserts at
  1 MiB and at every measured batch at 16 MiB. A 16 MiB copy also evicts the
  state from the caches: the write phase after it runs 4x slower than the
  same probes on a warm buffer. Elixir already has an in-place answer:
  - an `:atomics` Bloom filter inserts one key in 0.08 us, against 15 us
    (1 MiB) and 260-280 us (16 MiB) for the value-semantics kernel;
  - at 100 inserts `:atomics` takes 8-9 us, the kernel 15 us (1 MiB) and
    250-310 us (16 MiB).
- **The window copy holds the scheduler.** A 128 MiB window costs 2.2-2.5 ms
  per call whatever the kernel does. The copy is one `memcpy` with no
  safepoint (`defk-oed`, open), so each call also holds a normal scheduler
  for that long.
- **GC is not the problem.** A process that chains a 16 MiB state through a
  kernel collects once per call. Its binary memory stays at one or two
  states (peak 32 MiB, once 48 MiB) and is freed when the process exits.
  - **10k calls/s of 16 MiB is out of reach.** That is 168 GB/s of copy.
    One process reaches 3.7-3.8k calls/s (62-64 GB/s). Twelve processes
    reach 5.0-6.4k calls/s in total (85-107 GB/s), holding 128-320 MiB of
    binaries at the peak.
  - **A process that also holds other large binaries copies 1.7-2.0x slower.**
    Its binary virtual heap is large, so it collects every 4-5 calls and
    each output lands in memory that has gone cold.
- **Recommendation:** go on to the design review (defk-sve.2), scoped to
  fixed-size buffers of about 1 MiB and up updated in small batches. Keep
  ADR-0001 for HLL-sized state. Details under
  [Recommendation](#recommendation).

## Machine, method and limits

- **Machine:** Apple M4 Pro (arm64, 12 cores), macOS 26, OTP 29, Elixir 1.20,
  Apple clang, `:dev` build (`mix run`).
- **Load:** other agents' builds and benchmarks shared the machine. Load
  averages (`uptime`) were 28-37 over the recorded runs: 34.0 at the start of
  final run 1 and 29.6 at the end of run 2. **Every absolute number here is
  provisional.** The shares are more robust:
  - each share is a ratio of two numbers taken back to back in the same
    round;
  - the variants run interleaved in a shuffled order every round, so load
    hits them alike;
  - the shares agreed within a few points across five runs (two trial runs
    with 2-3 rounds and the three recorded runs with 2 and 7 rounds).
- **Script:** [`bench/state_copy_cost.exs`](../../bench/state_copy_cost.exs),
  `mix run bench/state_copy_cost.exs [timings|gc]`, `ROUNDS=n` (default 7).
  Each cell is the best of 7 rounds. The tables give the range over the two
  final runs.
- **What is timed.** Each kernel takes the state as its first argument, and
  the timed loop chains it through n calls (`s = f.(s)`), as a caller that
  keeps a sketch between batches does. Batches are pre-packed `[u64]`
  hashes, so packing a list is not part of these numbers. For each size:
  - **full:** the workload kernel. It writes the state in a loop, so the
    compiler copies it once, before the loop, and writes the copy in place.
    `Defk.Report` lists exactly one `:copy` per kernel.
  - **touch:** the memcpy-equivalent. The same state is copied, one byte is
    written, and the copy is returned: an output allocation plus a copy of
    the untouched bytes, which is the whole cost of value semantics. An
    input binary is read in place, so nothing is copied on the way in.
  - **nop:** the same call with the same argument, returning `len(state)`.
    This is the call and loop overhead without the copy.
  - **copy** = touch - nop, and **share** = copy / full.
  - **no-copy twin:** the same probes reading instead of writing (a Bloom
    membership query, an HLL "would this raise a register"). It returns an
    `i64`, so there is no copy and no output binary. It is a direct measure
    of the in-place work, to check full - copy against.
  - Context, not part of the share: Elixir's `:binary.copy/1` of the same
    size, and an `:atomics` Bloom filter in plain Elixir with the same
    probes (64-bit words, `bor` per probe). That is the in-place structure
    Elixir already has.
- **Fresh process per loop.** Each timed loop runs in a fresh process with
  default heap settings, as a GenServer owning the state would. The first
  trial ran the loops in the script process, which holds every state
  (128 MiB of binaries). There the 1 MiB copy measured 46-60 us instead of
  14-15 us; see [GC](#gc-and-binary-memory).
- **Not measured:**
  - Linux, or x86-64;
  - a quiet machine;
  - the scheduler hold of the 128 MiB copy with a ticker (it is inferred:
    the copy is one `memcpy` with no safepoint);
  - a `[u64]`-word Bloom filter. The kernel uses `bsl`/`bor`/`band` on
    `[u8]` bytes, since `bsl(1, 63)` overflows `i64`. The copy is
    byte-for-byte the same either way.

## Measurements (us per call, best of 7, two runs)

| state | batch | full | touch | nop | copy | share | full - copy | no-copy twin | `:binary.copy` | `:atomics` (Elixir) |
|---|---|---|---|---|---|---|---|---|---|---|
| HLL 16 KiB | 100 | 0.467-0.471 | 0.363-0.400 | 0.013 | 0.349-0.386 | 75-82% | 0.08-0.12 | 0.115-0.117 | 0.256-0.279 | - |
| HLL 16 KiB | 1k | 1.14-1.15 | 0.362-0.386 | 0.013 | 0.348-0.372 | 30-33% | 0.77-0.81 | 0.858-0.878 | 0.259-0.279 | - |
| HLL 16 KiB | 10k | 8.21-8.52 | 0.365-0.403 | 0.013 | 0.351-0.389 | 4-5% | 7.8-8.2 | 8.93-9.38 | 0.264-0.288 | - |
| Bloom 1 MiB | 1 | 14.4-14.6 | 13.8-14.8 | 0.014 | 13.8-14.8 | 94-102% | ~0 | 0.041-0.042 | 13.1-13.4 | 0.081-0.084 |
| Bloom 1 MiB | 100 | 15.1-15.6 | 14.8-15.2 | 0.014 | 14.8-15.2 | 95-100% | 0-0.8 | 0.53-0.55 | 13.1-13.5 | 8.2-8.7 |
| Bloom 1 MiB | 10k | 67-73 | 14.2-14.8 | 0.013 | 14.2-14.8 | 20-22% | 52-59 | 51-55 | 13.0-13.6 | 907-991 |
| Bloom 16 MiB | 1 | 259-282 | 263-283 | <0.05 | 263-283 | ~100% | ~0 | 0.05 | 249-290 | 0.10 |
| Bloom 16 MiB | 100 | 246-308 | 245-290 | <0.05 | 245-290 | 94-100% | 1-18 | 0.75-0.80 | 245-297 | 10.5-11.0 |
| Bloom 16 MiB | 10k | 632-637 | 269-296 | <0.05 | 269-296 | 43-46% | 341-363 | 70-79 | 246-278 | 999-1405 |
| Window 128 MiB | 1 byte | 2209-2375 | 2213-2454 | <0.3 | 2213-2454 | ~100% | ~0 | - | 2161-2431 | - |
| Window 128 MiB | 128 KiB block | 2213-2338 | 2210-2378 | <0.3 | 2210-2378 | ~100% | ~0 | - | 2194-2354 | - |

Notes on the table:

- **"1 byte" is the touch kernel itself.** Its full and touch columns are the
  same kernel, so their difference (up to 4%) is the run-to-run noise at
  this size. The 128 KiB block write is about 2-3 us at the measured copy
  rate, 0.1% of the call.
- **Copy rate:** 42-47 GB/s at 16 KiB, where a fixed ~0.1 us of
  allocation and return is a large part of 0.35 us (see performance.md 5.2).
  It is 69-76 GB/s at 1 MiB, 57-68 GB/s at 16 MiB and 55-61 GB/s at 128 MiB.
- **full - copy agrees with the twin** for HLL and for 1 MiB: 0.08-0.12 vs
  0.115, 0.77-0.81 vs 0.86, 52-59 vs 51-55. A share by subtraction is then
  the copy's real part of the call.
- **At 16 MiB and 10k inserts it does not agree.** full - copy is 341-363
  us, the twin 70-79 us. Copying 16 MiB streams 32 MiB through the caches,
  so the 70k random probe writes that follow land on lines the copy just
  evicted. The in-place work is the twin's ~75 us, and the copy costs
  full - twin, 553-567 us, **87-89%** of the call, not the 43-46% the
  subtraction gives. At 1 MiB the state and its copy fit in the cache, and
  the two estimates agree.
- **The HLL twin is slower than full at 10k.** It folds a sum, a dependent
  chain through every iteration, which the register writes don't have. It
  bounds the in-place work from above here.

## Against Elixir

The share decides whether value semantics is enough. Whether defk still
helps decides whether it matters.

- **HLL:** the best Elixir at 100 hashes is 0.019 ms (sorted keys + splice),
  0.058 ms at 1k and 0.50 ms at 10k (`:atomics` + one rebuild), all from
  [`hll_update_many.exs`](../../examples/hll_update_many.exs) and
  provisional. The value-semantics kernel is 0.47 us, 1.1 us and 8.2-8.5 us:
  40x, 50x and 60x faster. The copy is real but small next to that gap. The
  per-call cost that matters for HLL is packing a list of hashes
  (performance.md 5.3), not the 16 KiB copy.
- **Bloom, today's kernel against Elixir `:atomics`:**

  | batch | 1 MiB | 16 MiB |
  |---|---|---|
  | 1 | Elixir 170x faster | Elixir ~2700x faster |
  | 100 | Elixir 1.8x faster | Elixir ~25x faster |
  | 10k | kernel 12-15x faster | kernel 1.6-2.2x faster |

- **Bloom, an in-place kernel (the twin as its proxy) against `:atomics`:**

  | batch | 1 MiB | 16 MiB |
  |---|---|---|
  | 1 | ~2x | ~2x |
  | 100 | 15-16x | 13-15x |
  | 10k | 16-19x | 13-20x |

  At one insert both sides are mostly the cost of the call.

  So for a filter of a megabyte or more updated in small batches, value
  semantics makes defk the wrong tool today and Elixir `:atomics` the right
  one. A single-owner buffer would make defk the right tool from about 100
  inserts per call.
- **Streaming window:** no batch size helps. Each call costs 2.2-2.5 ms of
  copy, and the zstd and xxh3 streaming wrappers stay the answer, as the
  epic expects.

## GC and binary memory

From the `gc` part of the script. The state is chained through
`bloom_add` with one insert per call, for 3 s per row, in one process.
Another process samples `:erlang.memory(:binary)` every 5 ms.

| row | calls/s reached | GB/s out | binary above base: peak / mean | GCs per call |
|---|---|---|---|---|
| 16 MiB, as fast as it goes | 3.7-3.8k | 62-64 | 32-48 / 22-30 MiB | 1.00 |
| 16 MiB, paced at 10k/s | 3.7-3.8k (pace not reached) | 62-64 | 32 / 21-23 MiB | 1.00 |
| 16 MiB, paced at 1k/s | 1.0k | 16.8 | 16 / 16 MiB | 1.07-1.08 |
| 1 MiB, paced at 10k/s | 10.0k | 10.5 | 1 / 1 MiB | 1.01 |
| 1 MiB, as fast as it goes | 64.7k | 68 | 2 / 1 MiB | 1.00 |
| 16 MiB, 10k/s over 12 processes | 5.0-6.4k in total | 85-107 | 128-320 / 117-176 MiB | - |

- **One GC per call keeps memory bounded.** A 16 MiB (or 1 MiB) output
  overflows the process's binary virtual heap every time. Every call
  triggers a minor GC, which drops the previous state's reference, and the
  refc binary is freed at once. Binary memory stays at one or two states
  per process, and nothing is left after the process exits. There is no
  refc pile-up and no growth over 3 s at any rate tried. The GC is cheap:
  its cost is inside the fresh-process copy times above.
- **10k calls/s of 16 MiB cannot happen.** It needs 168 GB/s of `memcpy`.
  One process tops out at 3.7-3.8k calls/s. Twelve processes reach
  5.0-6.4k calls/s together (85-107 GB/s, the machine's memory bandwidth
  under this load), with 128-320 MiB of binaries live at the peak.
- **A process that holds other big binaries copies slower.** The same
  chained touch, in a fresh process against one that also holds four live
  64 MiB binaries:

  | state | fresh process | holding 256 MiB | slowdown | GCs per call |
  |---|---|---|---|---|
  | 16 KiB | 0.37-0.41 us | 0.38-0.41 us | 1.0-1.1x | 0.045 vs 0.044 |
  | 1 MiB | 14.0-15.0 us | 24-27 us | 1.6-1.9x | 1.00 vs 0.26 |
  | 16 MiB | 260-289 us | 460-587 us | 1.8-2.2x | 1.00 vs 0.20 |

  Its binary virtual heap has grown to fit the live data, so it collects
  only every 4-5 calls. The dead outputs pile up in between, and each new
  output goes to memory that has gone cold instead of the block just freed.
  The first trial, run in the script process, showed the same effect at 3-4x
  (46-60 us for 1 MiB). A state owner that also keeps other large binaries
  pays this on top of the copy.

## Recommendation

**Go on to the design review (defk-sve.2), and scope it to fixed-size,
single-owner byte or word buffers of about 1 MiB and up updated in small
batches.**

- **Small states stay as they are.** For HLL-sized state (16 KiB),
  value semantics is enough in practice, and ADR-0001 should stand. The copy
  is a fixed 0.35-0.39 us that only passes 10% below a few thousand items,
  and the kernel is 40-60x the best Elixir at every batch anyway.
- **From about 1 MiB the copy is the whole call.** It costs 14-18 us per
  MiB at 55-75 GB/s, no better than Elixir's own copy. It is about 100% of
  a Bloom insert of 1 or 100 keys and 20-25% of 10k keys at 1 MiB. At
  16 MiB it is 87-89% of even a 10k batch, once its cache eviction is
  counted, and it holds a normal scheduler 2.2-2.5 ms for a 128 MiB window.
  Elixir's `:atomics` already gives the in-place answer and beats today's
  kernel by 1.8-2700x on small batches. The measured in-place work (the
  no-copy twin) says a single-owner buffer would make defk 13-20x faster
  than `:atomics` from about 100 inserts per call.
- **Questions for the review.** GC does not argue either way: binary memory
  stays bounded at one or two states per owning process. The review should
  still weigh:
  - the cheaper value-semantics alternatives: batching calls to 10k+ keys,
    or splitting a large filter into separately-passed blocks so that a call
    copies only the blocks it touches;
  - whether `:atomics`, which Elixir already treats as a mutable, referenced
    buffer, is a closer Elixir meaning for a kernel buffer than ETS or the
    process dictionary.
