# Vectorisation headroom and what target levels buy

Ticket: defk-ulk.1 (epic defk-ulk). Researched 2026-10-11.

## Question

Today `Defk.Build` compiles every kernel with no target flag. On macOS arm64,
Apple clang then targets `apple-m1`; on Linux it targets the architecture
baseline (armv8.0-a, or SSE2 on x86-64). Before building anything for the
epic's prototypes, this study answers five questions:

- Which catalogue loops does clang vectorise, and what blocks the rest?
- What do target levels buy, measured: arm64 baseline vs armv8.2-a vs
  `-mcpu=native`, and x86-64 SSE2 vs v2 / v3 / native?
- Do float results stay bit-exact with Elixir mode at every level?
- For the measured gaps to BIFs and NIFs (CRC, UTF-8, substring search,
  hashes, base64), would target flags, a hardware builtin or vector types
  close them?
- Which of the prototype tickets defk-ulk.2..5 are worth doing, and in what
  order?

## Summary

- **On arm64, target features buy nothing measurable for these kernels.**
  The default, armv8.2-a and `-mcpu=native` (Apple M4) builds vectorise the
  same 24 of 200 loops at the same widths. Over 42 kernels, three interleaved
  runs put them within noise of each other (about ±2%, a few noisy cases
  ±5-10%). NEON is baseline, and there are no wider vectors to unlock: SVE is
  not available on Apple silicon, and SME is a separate streaming mode clang
  never auto-vectorises for. **Tuning** does matter. A portable Linux/aarch64
  build (`-mcpu=generic`) was 5-22% slower on a quarter of the kernels and
  17-19% *faster* on SHA-256. `-mtune=generic` alone gives the same numbers,
  and features alone (`-march=armv8-a`) do not.
- **x86-64: remarks only; no x86 timing.** Neither emulated nor real x86
  hardware was available, so nothing was timed. clang's remarks
  predict:
  - x86-64-v3 doubles the vector width of the 20 loops that vectorise (2 → 4
    lanes of i64/f64, 16 → 32 bytes);
  - it brings in two byte loops that SSE2 leaves scalar, one of them
    `ws_mask`'s main loop;
  - no level vectorises an in-order float reduction (`sum`, `dot`, cosine).
    arm64 does, as ordered reductions.
  The run that would measure all this is under
  [Not measured](#not-measured-x86-64-timings) below.
- **Float results stay bit-exact.** These checks passed at every arm64 level:
  - 331 agreement, property and float tests;
  - the 42 timed kernels against Elixir mode;
  - every level against the default build on the timed inputs.
  Statically, no level emits an FMA under `-ffp-contract=off`, including
  x86-64-v3/v4, which do have FMA. The `-ffp-contract=on` control does emit
  them, which shows the check would catch one. No level touches the FP
  control registers (MXCSR or FPCR). libm calls stay calls (`-fno-builtin`),
  to the same libm `:math` uses.
- **The gaps are not flag-shaped.** The vectoriser never emits CRC32, SHA,
  SHA3 or carry-less-multiply instructions from scalar code, at any level.
  Base64, hex, UTF-8 validation and substring search need byte shuffles,
  table lookups and lane masks, which no flag produces. The gaps close
  through hardware builtins (CRC32C first) or vector values, not target
  levels.
- **Recommendation:**
  1. defk-ulk.4 (crc32c builtin) first.
  2. defk-ulk.5 (vector-value ceiling study) next.
  3. The x86 timing run.
  4. defk-ulk.2, opt-in architecture builds, only if that run shows v3
     gains on real kernels. On arm64 the evidence says not to.
  5. defk-ulk.3 last, if at all.
  Details under [Recommendation](#recommendation).

## Machine, method and limits

- **Machine:** Apple M4 Pro (arm64, 12 cores: performance and efficiency),
  macOS 26, OTP 29 (ERTS 17.0.3), Elixir 1.20, Apple clang 21.0.0
  (clang-2100.3.34.2). The CPU reports `FEAT_CRC32`, `FEAT_SHA3`,
  `FEAT_SHA512`, `FEAT_DotProd`, `FEAT_I8MM`, `FEAT_BF16`, `FEAT_FP16`,
  `FEAT_LSE`, `FEAT_SME`/`SME2`, and no SVE (`sysctl hw.optional.arm`).
- **Load:** the machine was shared with other agents running `mix ci` and
  benchmarks. Load averages at measurement time (`uptime`):
  - run 1: 154/85/49 at start, 16/59/54 at end;
  - run 2: 13/56/53 at start, 12/41/47 at end;
  - run 3 (tuning): 31/29/38 at start, 14/17/30 at end;
  - the remark pass: up to 211.
  **Every timing here is provisional.** The numbers that count are ratios
  between builds of the same kernel, interleaved in the same rounds. Each
  round runs the levels in a rotated order and takes the best of 3-25 calls
  per level (calibrated to about 50 ms). The ratio is reported as the median
  over 7-9 rounds, with min..max. Absolute microseconds are best-of across
  rounds and are given for scale only.
- **What the levels mean on this compiler.** `clang -###` shows:

  | Level | Flags | `-target-cpu` | Features (abridged) | Stands for |
  |---|---|---|---|---|
  | default | (none) | apple-m1 | v8.5a, crc, lse, rdm, dotprod, fp16, sha3, aes | what defk builds today on macOS |
  | generic | `-mcpu=generic` | generic | v8a, neon | a portable Linux/aarch64 build |
  | armv8.2-a | `-march=armv8.2-a` | apple-m1 | v8.2a, crc, lse, rdm, neon | the ticket's named level |
  | native | `-mcpu=native` | apple-m4 | v8.7a, + bf16, i8mm, sme, sme2 | an architecture build |
  | x86-64 | `-target x86_64-apple-macos13 -march=x86-64` | x86-64 | SSE2 | the x86 portable build (remarks only) |
  | x86-64-v2/v3/v4 | `-march=x86-64-v2` ... | x86-64-v2 ... | SSE4.2+POPCNT / AVX2+FMA+BMI / AVX-512 | x86 architecture builds (remarks only) |

  On Apple clang, `-march=armv8.2-a` changes the feature set but keeps
  `apple-m1` tuning. It is a feature *downgrade* from the default, which is
  already v8.5-a.
- **How the levels were built** (no change to `lib/`). `Defk.Build` takes
  `CC` from the environment and keys its cache on the compiler path and its
  version. A small `cc` wrapper per level (`exec cc <flags> "$@"`) therefore
  builds and caches each level's `.so` separately. The remark pass
  (`Defk.Report.full/3`, what `report: :full` runs) goes through the same
  wrapper. This is the route `bench/float_checks.exs` already uses. The tools
  are in [`bench/simd/`](../../bench/simd):
  - `load.exs` loads every kernel module of `examples/*.exs`,
    `examples/fuzzy_search` and `bench/` into one `mix run`. It evaluates only
    the top-level `defmodule`, `quote` and `Module.create` forms, so the
    examples' own benchmarks are skipped. It recompiles a module under
    another name with a given `CC` and with `elixir_mode: true`.
  - `remarks.exs` writes the per-loop verdict at all eight levels.
  - `time.exs` runs the interleaved timing and both agreement checks; on an
    x86-64 host it picks the x86 levels.
  - `cases.exs` holds the 42 timed kernels and their inputs. The sizes are
    the examples' sizes, or smaller where a call would take seconds.
  - `fma_check.sh` is the static FMA check.
  - `agree_levels.sh` runs the test suite's agreement and float tests with
    every kernel built at each level.
- **Not measured:** x86-64 timings (no hardware; Rosetta and qemu timings
  don't count), Linux arm64 (Graviton, Ampere), GCC, and quiet-machine
  absolute numbers.

## Vectorisation verdict per kernel

There are 200 loops in 30 kernel modules. One "loop" is one defk loop. One
defk loop can lower to several C loops (short loop, strip loop, replay), and
inlined helpers repeat their callee's loops. clang's verdicts by level:

| Verdict | default | generic | armv8.2-a | native | x86-64 (SSE2) | x86-64-v2 | x86-64-v3 | x86-64-v4 |
|---|---|---|---|---|---|---|---|---|
| vectorised | 24 | 24 | 24 | 24 | 14 | 16 | 20 | 20 |
| partly (some C forms) | 15 | 15 | 15 | 15 | 15 | 17 | 15 | 15 |
| not vectorised | 126 | 126 | 126 | 126 | 136 | 132 | 130 | 130 |
| no remark (outer loops) | 35 | 35 | 35 | 35 | 35 | 35 | 35 | 35 |

x86 columns: **remarks only, not timed**.

The four arm64 columns are identical loop by loop, not just in total. The
widths are the same as well: f64/i64 ×2, i32 ×4, i16 ×8, bytes ×16.

The loops whose verdict or width changes with the level:

| Kernel (defk loop) | arm64, all four levels | x86-64 | v2 | v3 | v4 | Why |
|---|---|---|---|---|---|---|
| `sum`, `dot`, cosine, `Orders.sum` | V ×2 | no | no | no | no | in-order float reduction: "cannot prove it is safe to reorder floating-point operations". AArch64 does ordered (strict) reductions; x86 does not, at any level |
| `scale` (`out[i] = a[i] * k`) | V ×4 | V ×2 | V ×2 | V ×4 | V ×4 | width |
| `ws_mask` main 4-byte loop | V ×16 | no | no | V ×32 | V ×16 | the SSE2/SSE4 cost model rejects the stride-4 store; AVX2 takes it |
| `ws_mask` tail | V ×16 | V ×16 | V ×16 | V ×32 | V ×32 | width |
| `valid_utf8?` class-table build (256 trips, not the hot loop) | no | no | no | V ×32 | V ×32 | AVX2 only |
| `flush_s16` (i64 → i16 clamp) | V ×2/×8 | no | partly | V ×4 | V ×4 | needs SSE4.1 packs and compares |
| `lev_dp` row init, `topk` dot, `nearest` distance pass, `simulate` setup, `lev`/`lev_batch` row init, Horspool skip-table init, `sort_i64` copy, `valid_utf8?` table | V ×2 | V ×2 | V ×2 | V ×4 | V ×4 | width |
| `Search.lower` | V ×16 | V ×16 | V ×16 | V ×32 | V ×32 | width |

Every other loop has the same verdict at all eight levels.

What vectorises, at every level, is element-wise maps and fills:
- `scale`, `lower`, `ws_mask` and the PCM clamp/flush;
- the 8-partial-sum dot in `topk`;
- table and row initialisation.

What does not vectorise is everything with a loop-carried state:
hashes, CRCs, DFAs, Keccak, SHA-256, Myers, heaps and the DP inner loops.
That is most of the catalogue, and it is the shape of the work, not a
missing flag.

### What blocks the rest

The 126 missed loops (arm64 default) give these reasons; a loop usually has
several:

| Blocker | Remark (count of loops) | Where | Removable? |
|---|---|---|---|
| **Loop-carried recurrence**: hash state, CRC, DFA state, Myers bit vectors, running min/max with index | "value that could not be identified as reduction is used outside the loop" (101) | `crc16/64`, `crc32c`, `xxh64`, `murmur3`, `siphash24`, `keccak`, `sha256`, `valid_utf8?` DFA, `lev_myers`, `streams`, `mean_var`/`mean_std` (Welford, sliding sums), `draws` | No, by design: serial algorithms. Only a different algorithm helps: interleaved lanes, which hashes already use, or CRC folding with carry-less multiply |
| **Remaining per-operation checks**: bounds, overflow, a `raise` | "Cannot vectorize early exit loop (with more than one early exit / with writes to memory)" (93 + 20 + 14), "call instruction cannot be vectorized" (53, the `defk_fail` call) | `histogram` (`counts[b] + 1` overflow), `gray_blur`, `rgb_to_yuv420`, `resize_bilinear`, `dither_fs` (i64 arithmetic on u8 pixels), `update_many`, `mix_s16` sum loop (`defk-siy`), `matmul` in-place accumulate (`defk-agp`) | Partly. Each check that a range fact drops (`defk-siy`, `defk-n7k`, `defk-pic`, `defk-fun`) or that becomes a strip flag (as `defk-6tt` did for floats) removes an early exit. Masked/wrapping arithmetic already has no check |
| **Gathers and scatters through computed indices** | "cannot identify array bounds" (30) | `encode64`/`decode64`/`encode16`/`decode16` (`@b64[band(x, 63)]`, `out[4*i+k]`), `histogram`, Horspool's skip table, `update_many` | Not by flags. NEON has no gather; AVX2 has gathers but clang did not use them here. Base64 and hex need byte shuffles (`tbl`/`pshufb`) and their vector algorithms, which is vector-value territory (defk-ulk.5) |
| **Early exits by design**: `reduce_while`, search | "Cannot vectorize early exit loop", "could not determine number of loop iterations", "uncountable loop" (31 + 15) | Horspool `find`, `prime_early?`, `sort_i64` sift-down, `encode58`/`decode58`, `crc16`/`crc64` with a non-literal step | No: data-dependent control flow. A SIMD prefilter (compare 16 bytes against the needle's first and last byte, then a lane mask) needs vector compares and mask extraction (defk-ulk.5) |
| **In-order float reductions** | "cannot prove it is safe to reorder" (x86 only) | `sum`, `dot`, cosine, `convolve` | No, by design: bit-exactness (`-ffp-contract=off`, no reassociation). Writing partial sums by hand (`topk`'s eight) is the portable fix, and it vectorises on both architectures |
| **Branchy bodies** | "Control flow cannot be substituted for a select" (28), "unsupported switch" (8) | geohash, Gorilla, `crc16`, `simulate`, `prime?` | Rarely; a select only pays where the arms are cheap (performance.md 6.7) |
| **Safepoints** | (none: the outer loops have no remark; inner strips carry one safepoint per strip) | the 35 "no remark" rows are outer loops with a safepoint every iteration | Already solved for flat loops by strips (`defk-88q`, `defk-5s3`); outer loops are not vectorisation candidates |

## What target levels buy on arm64 (measured, provisional)

Three runs, on the same day and machine: run 1 is 7 rounds, run 2 is 9
rounds, run 3 is 7 rounds for the tuning check. Speedup = default / level.
Above 1.0 means the level is faster. Each cell is the median over rounds.
Run 1 and run 2 are shown side by side as "run 1 / run 2".

| Kernel (input) | default µs (best) | generic | armv8.2-a | native |
|---|---|---|---|---|
| `sum` 1M f64 | 534-540 | 0.96 / 0.96 | 1.01 / 1.00 | 1.00 / 1.00 |
| `dot` 1M f64 | 558-559 | 0.95 / 0.95 | 1.00 / 1.00 | 1.00 / 1.00 |
| `mean_var` 1M f64 | 3819-3905 | 1.02 / 1.02 | 1.00 / 1.00 | 1.00 / 1.00 |
| `scale` 1M f64 | 146-147 | 0.99 / 1.00 | 1.00 / 1.01 | 0.99 / 1.01 (memory-bound, noisy) |
| `histogram` 1 MB | 270-273 | 1.00 / 1.00 | 0.98 / 1.01 | 0.98 / 1.00 |
| `count_primes` 200k | 20095-20181 | 1.00 / 1.00 | 1.00 / 1.00 | 1.00 / 1.00 |
| cosine 1M f64 | 607-608 | 0.93 / 0.93 | 1.00 / 1.00 | 1.00 / 1.00 |
| `mean_std` 1M, w = 100 | 1935-1941 | 0.99 / 0.99 | 1.00 / 1.00 | 1.00 / 1.00 |
| `encode64` 1 MB | 252-253 | 1.00 / 1.00 | 1.00 / 1.05 | 1.00 / 1.00 |
| `decode64` 1 MB | 266-271 | 0.95 / 0.95 | 0.99 / 1.00 | 1.00 / 1.01 |
| `encode16` 1 MB | 352-357 | 1.02 / 1.02 | 1.00 / 1.00 | 0.97 / 0.98 (noisy) |
| `decode16` 1 MB | 405 | 0.94 / 1.02 | 1.00 / 1.01 | 1.00 / 1.03 |
| `encode58` 10k × 32 B | 1661-1669 | 0.99 / 1.01 | 0.98 / 1.01 | 1.00 / 1.01 |
| `topk` 10k × 384 f32 | 2094-2101 | 1.00 / 0.99 | 1.00 / 1.00 | 1.00 / 1.00 |
| `fft` 2^16 | 1532-1569 | 1.00 / 0.95 | 1.00 / 0.97 | 1.02 / 1.02 |
| `convolve` 96k × 64 taps | 5438-5499 | 0.95 / 0.93 | 1.00 / 1.00 | 1.00 / 0.99 |
| `nearest` 100k, k = 10 | 665-669 | 0.99 / 1.00 | 1.01 / 1.00 | 0.96 / 1.02 |
| `geohash_encode` 100k, p = 12 | 1862-1865 | 0.98 / 0.96 | 1.00 / 0.96 | 1.00 / 1.00 |
| `crc16` 1 MB | 2204 | 1.00 / 1.01 | 1.00 / 0.99 | 1.00 / 1.00 |
| `crc64` 1 MB | 1945 | 1.00 / 1.00 | 1.00 / 1.00 | 1.00 / 0.99 |
| Gorilla `streams` 100k points | 909-923 | 1.00 / 1.00 | 1.00 / 1.00 | 1.00 / 0.99 |
| SHA-256 chain, 20k steps | 3416-3418 | **1.18 / 1.19** | 1.00 / 1.00 | 1.00 / 1.00 |
| `xxh64` 1 MB | 43-44 | 0.98 / 1.02 | 1.00 / 1.02 | 1.00 / 1.02 |
| `murmur3_128` 1 MB | 132 | 1.00 / 1.00 | 1.00 / 1.01 | 1.00 / 1.00 |
| `siphash24` 1 MB | 347-350 | 1.01 / 1.01 | 0.99 / 1.01 | 1.00 / 1.01 |
| `crc32c` 1 MB | 448-454 | 0.98 / 0.98 | 1.00 / 1.00 | 1.00 / 1.00 |
| HLL `update_many` 100k | 73-75 | 0.94 / 0.95 | 1.00 / 1.00 | 1.00 / 1.01 |
| `gray_blur` 1080p | 5342-5352 | 1.01 / 1.00 | 1.05 / 0.99 | 1.02 / 1.00 (noisy) |
| `resize_bilinear` 1080p → ¼ | 1430-1434 | 1.02 / 0.99 | 1.00 / 0.99 | 1.00 / 1.00 |
| `rgb_to_yuv420` 1080p | 3965-3979 | 1.00 / 1.04 | 0.99 / 1.05 | 1.00 / 1.01 (noisy) |
| `dither_fs` 1080p | 5915-5922 | 1.00 / 0.95 | 1.01 / 1.03 | 1.00 / 0.99 (noisy) |
| `keccak256` 1 MB | 1346-1355 | **0.93 / 0.93** | 1.00 / 1.00 | 1.00 / 1.01 |
| `matmul` 256 | 13236-13454 | 1.03 / 1.10 | 0.91 / 1.12 | 0.89 / 1.03 (noisy: rounds 0.78-1.28) |
| RTP `simulate` 100k spins | 2952-2983 | 0.99 / 0.98 | 1.01 / 1.00 | 1.00 / 0.98 |
| `mix_s16` 4 × 1 s | 446-452 | 0.99 / 1.10 | 0.98 / 1.01 | 0.99 / 0.94 (noisy) |
| `lev_batch` 10k pairs | 949-965 | 0.99 / 0.97 | 1.02 / 1.00 | 1.04 / 0.99 (noisy) |
| `lev_myers` 50k words | 1056-1070 | 0.98 / 0.98 | 1.00 / 1.00 | 1.00 / 1.00 |
| fuzzy `search` 50k words | 4128-4186 | 0.98 / 0.99 | 1.00 / 1.00 | 1.00 / 1.01 |
| Horspool `find` 4 MB | 76-80 | 0.79 / 0.94 | 0.89 / 1.05 | 0.99 / 0.94 (noisy: rounds 0.70-1.32) |
| `sort_i64` 1M | 61223-62338 | **0.78 / 0.78** | 1.00 / 0.96 | 1.00 / 1.01 |
| `valid_utf8?` 1M chars | 2220-2224 | 0.99 / 0.99 | 1.00 / 1.00 | 1.00 / 0.99 |
| `ws_mask` 1 MB | 26 | 1.00 / 1.00 | 1.00 / 1.00 | 1.00 / 1.00 (38 GB/s, memory-bound) |

Reading the table:

- **`-mcpu=native` (M4) and armv8.2-a against today's default: no kernel
  gains.** Every case where both runs agree lies within ±3%. The outliers,
  `matmul`, Horspool, `mix_s16` and the image kernels, swing more between
  rounds than between levels. The M4's extra features (BF16, I8MM, SME) are
  ones the auto-vectoriser does not use on this C.
- **`-mcpu=generic` is a different story, and it is tuning, not features.**
  Run 3 (`SIMD_LEVELS`, 7 rounds) built two more levels:
  - `-march=armv8-a`: apple-m1 tuning with only v8.0 features;
  - `-mtune=generic`: v8.5 features with generic tuning.

  | Kernel | generic | `-march=armv8-a` | `-mtune=generic` |
  |---|---|---|---|
  | `sort_i64` | 0.94 (rounds 0.81-1.00) | 1.01 | 0.94 |
  | SHA-256 chain | 1.18 | 1.00 | 1.17 |
  | `keccak256` | 0.93 | 1.00 | 0.92 |
  | cosine | 0.93 | 1.00 | 0.94 |
  | `convolve` | 0.94 | 1.00 | 0.94 |
  | `dot` | 0.95 | 1.00 | 0.95 |
  | HLL | 0.94 | 1.03 | 0.96 |

  Features alone change nothing; tuning alone reproduces `generic`. The
  `sort_i64` heap sift-down has 13 `csel` in the apple-m1 build and 9 in the
  generic one, with more conditional branches. On random keys that
  plausibly explains the loss, but the cause was not profiled. SHA-256 is
  the other way round: the apple-m1 schedule emits about 15% more
  instructions (83k against 72k lines of assembly for the module) and runs
  slower. Apple's tuning model does not suit that round function.
- **What this means for a Linux/aarch64 deploy.** A portable build there gets
  the generic tuning: 5-22% slower on a quarter of these kernels, 18%
  faster on one. That was measured on an M4 with Apple clang, not on a
  Neoverse core with upstream clang, where `generic` tunes for different
  cores. The safe knob is `-mtune`, which changes scheduling and never the
  instruction set, so it can never cause SIGILL. It needs no load-time check
  and is a different question from `-march`.

## x86-64

### Remarks (static, valid here)

See the verdict tables above. On x86-64, compared with arm64 today:

- **SSE2 baseline (a portable x86 build):**
  - vectorises 14 loops, against 24 on arm64;
  - leaves `ws_mask`'s main loop scalar;
  - never vectorises the f64 reductions, which arm64 runs as strict ordered
    reductions;
  - has no POPCNT or LZCNT, so `popcount`/`clz` in `Defk.Bits` (HLL rank,
    Myers) lower to bit tricks or `bsr` with a zero test (inferred from the
    psABI level contents; not counted per kernel).
- **x86-64-v2** adds SSE4.1/4.2 and POPCNT. Two more loops vectorise
  (`flush_s32` fully, `flush_s16` partly).
- **x86-64-v3** (AVX2, FMA, BMI1/2, LZCNT, MOVBE):
  - 20 loops vectorise, at twice the width (4 × f64/i64, 32 bytes);
  - `ws_mask`'s main loop vectorises;
  - FMA stays unused (below).
- **x86-64-v4** (AVX-512) gives the same verdicts and widths as v3. clang
  keeps 256-bit vectors by default (`prefer-vector-width=256`); `ws_mask`'s
  main loop even drops back to 16 bytes.
- `-march=native` on x86 cannot be judged here: it depends on the box.

### Not measured: x86-64 timings

| Kernel set | x86-64 (SSE2) | x86-64-v2 | x86-64-v3 | native |
|---|---|---|---|---|
| the 42 kernels in `bench/simd/cases.exs` | not measured: needs real x86-64 hardware | not measured | not measured | not measured |

To run it on an x86-64 Linux box with clang (or GCC; the remarks need clang)
and OTP/Elixir as in `mix.exs`:

```bash
git checkout defk-ulk.1/simd-research    # or main once merged
mix deps.get
uptime                                   # record the load
SIMD_CC=clang mix run bench/simd/time.exs 9 /tmp/simd-x86.etf
# levels: default (SSE2), x86-64-v2, x86-64-v3, -march=native; prints the table
# and checks every level against the default build and against Elixir mode
SIMD_CC=clang bench/simd/agree_levels.sh   # the agreement + float tests at v2, v3, native
SIMD_LEVELS="default:,v4:-march=x86-64-v4" SIMD_CC=clang mix run bench/simd/time.exs 9   # optional, on AVX-512 hardware
```

Record the CPU model (`lscpu`), the clang version, the load, and whether the
box is a VM.
What to look for:

- Do `scale`, `ws_mask`, `topk`, `nearest`, `lower` and the PCM flush gain at
  v3? `ws_mask` is memory-bound at large sizes; its 8-64 KiB sweep sizes are
  the place to look.
- Does anything lose at v3? AVX frequency effects are worth checking on older
  Intel parts.
- How far do `sum`/`dot`/cosine stay behind arm64 per element? They are
  scalar there at every level.

## Bit-exactness at each level

| Check | arm64 default / generic / armv8.2-a / native | x86-64 levels |
|---|---|---|
| Agreement suite: `agreement_test`, `fp_contract_test`, `sincos_test`, `non_finite_test`, `elixir_mode_test`, `element_types_test`, `masked_arith_test`, `u64_test`, `bit_builtins_test`, `comparison_test` (331 tests: 188 properties, 119 tests, 24 doctests), every kernel rebuilt at the level (`bench/simd/agree_levels.sh`) | **passed** at generic, armv8.2-a and native (default is `mix test` itself) | not run: needs hardware |
| The 42 timed kernels, native === Elixir mode on small inputs, at each level | **passed** (3 runs) | not run |
| The 42 timed kernels at each level === the default build, on the timed inputs | **passed** (3 runs) | not run |
| FMA instructions in the assembly under defk's flags (`bench/simd/fma_check.sh`, 13 float modules) | **0** at every level; control with `-ffp-contract=on`: 6-87 per module | **0** at x86-64, v2, v3, v4; control with `-ffp-contract=on` at v3/v4: 11-87 per module (`vfmadd*`) |
| FP control registers (FTZ/DAZ: `mxcsr`, `fpcr`) touched by the generated code | none (native) | none (v4) |
| libm | `sin`, `cos`, `exp`, `log`, `pow`, `round` stay calls (`-fno-builtin`) at every level, to the same libm `:math` calls | same; `__builtin_sqrt` is one correctly rounded instruction everywhere |

What can't be verified without x86 hardware:

- **glibc's libm picks variants at run time by CPU feature (ifunc).** A
  given machine computes `sin` the same in a kernel and in `:math`, so
  agreement holds. Results may differ between machines with different
  features, but the defk-vs-Elixir comparison is unaffected.
- **No `-march` level sets FTZ/DAZ.** Only `-ffast-math` linking does, and
  defk never passes it. The static check above covers the generated code,
  not a library loaded later that might change MXCSR. That is a runtime
  question for the BEAM process, not for the target level.
- **Whether v3's AVX2 versions of `scale` or the PCM clamp match the SSE2
  ones bit for bit.** They should: element-wise IEEE operations with no
  contraction. Only the hardware run confirms it.

## Gaps to BIFs and NIFs: what would close each

The numbers are taken from `examples/README.md`, `docs/performance.md`
(sections 3 and 7.1) and this study's timings; nothing was re-measured for
this section except the kernels above.

| Gap (measured) | Target flags? | Hardware builtin? | Vector types? |
|---|---|---|---|
| **CRC32C:** kernel slicing-by-8 2.2-2.3 GB/s (454 µs/MB here); crc32cer (hardware CRC32C) is 14× faster | **No.** 1.00× at every arm64 level. No level emits `crc32cx` from the table code, and the default build already has the `crc` feature | **Yes: this is the gap.** `crc32c(crc, word)` over the ARMv8 CRC32C instructions (mandatory from v8.1; in the macOS default) and SSE4.2 `crc32` (x86-64-v2), with a table fallback and an Elixir-mode table version that defines the result | Not needed |
| **CRC-16/CCITT, CRC-64/XZ:** table kernels about 0.5 GB/s (2.2 and 1.95 ms/MB here), 1.6-1.85× over Elixir, about 1.0-1.4× the `crc` NIF; `:erlang.crc32` (zlib, another polynomial) runs at 35-40 GB/s | **No** (1.00×) | **Partly.** No instruction computes these polynomials. A carry-less multiply builtin (PMULL on arm64 with `aes`; PCLMULQDQ on x86, which no psABI level includes) allows CRC folding | Folding works on 128-bit carry-less products, so a `clmul` builtin is the smaller step |
| **UTF-8 validation:** scalar DFA 0.57 GB/s, 1.05-1.09× over `:unicode.characters_to_binary` (0.52 GB/s); simdutf8-class validators do many GB/s (quoted, not measured) | **No** (0.99-1.00×). The DFA is a recurrence; v3 vectorises only the 256-entry table build | No single instruction | **Yes.** It needs 16/32-byte lanes, byte table lookup (`tbl`/`pshufb`), shifts across lanes and a lane-mask "any" (defk-ulk.5). An ASCII fast path with `u64_le` word loads is expressible today (not measured) |
| **Substring search:** Horspool kernel ties `:binary.match` (1.03-1.11×, about 7 GB/s each) | **No** (noisy, about 1.0×) | No | **Yes.** A first/last-byte SIMD prefilter (vector compare, mask to integer, `ctz`) is how memchr/memmem beat Boyer-Moore; it needs vector compares and lane masks (defk-ulk.5) |
| **SHA-256:** portable kernel 171-175 ns per chain step against `:crypto` 100-104 ns (OpenSSL on the SHA instructions) | **Tuning only:** `-mtune=generic` gave 145 ns (1.18×), still behind `:crypto`. Features: no | Yes in principle (`sha256h`/`sha256su0/1`; x86 SHA-NI is outside every psABI level), but `:crypto` already exists and the wrapper table says to use it | No |
| **SHA3/Keccak:** kernel level with ex_keccak at 16 MB and 0.71× of `:crypto.hash(:sha3_256, ...)` | **No** (1.00× native; 0.93× generic tuning). No level emits `eor3`/`rax1`/`bcax` from scalar code, although the default build has `sha3` | Possible (`eor3`, `rax1`, `bcax`, `xar` as builtins), but a narrow gain on one algorithm | No |
| **Hashes (xxHash64, Murmur3, SipHash):** already 8-10 GB/s, level with or ahead of their NIFs | No gap to close | — | — |
| **base64 / hex:** base64 kernel 2-2.5 GB/s, already 2.1× faster than fast64's C NIF; SIMD base64 libraries are several times faster (quoted, not measured); hex encode only about 1.5-2.6× the BIF | **No** (1.00×). The loops miss on "cannot identify array bounds": table lookups and strided stores | No | **Yes.** Base64 in SIMD is byte shuffles plus lookups. Same for hex (defk-ulk.5) |

In short: one target flag closes no gap. **CRC32C needs one builtin and
closes a 14× gap.** CRC-64/16 need a carry-less multiply builtin. UTF-8,
base64, hex and substring search need vector values with shuffles and masks.
SHA-256 and SHA3 are `:crypto`'s job.

## Prior art

Each source was read on 2026-10-11 unless marked *(memory)*.

- **Zig `@Vector`** ([language reference](https://ziglang.org/documentation/master/)):
  a vector of any width is "operated on in parallel, using SIMD instructions
  if possible". Longer vectors split into several instructions, and without
  SIMD the backend scalarises element by element. Zig builds for the
  *native* CPU by default: `zig build-obj` reported `apple_m4` here, and
  [the build system docs](https://ziglang.org/learn/build-system/) say "no
  choice means to target the host system". Cross targets get `baseline`.
  *For defk:* portable vector values can lower to any width. A native
  default is the reproducibility trap defk avoids by staying portable.
- **WebAssembly SIMD128**
  ([explainer](https://raw.githubusercontent.com/WebAssembly/simd/main/proposals/simd/W3CTAG-SIMDExplainer.md),
  [relaxed-simd overview](https://github.com/WebAssembly/relaxed-simd/blob/main/proposals/relaxed-simd/Overview.md)):
  one fixed 128-bit width "supported across common hardware", with lanes
  following scalar IEEE semantics *(memory)*. Relaxed-simd results are
  "host-dependent": `relaxed f32x4.madd` may round once or twice. *For
  defk:* a fixed 128-bit lane set with exact semantics is the precedent that
  fits the one rule. An FMA must be an explicit `fma/3`, never a
  contraction, and no relaxed mode may slip in.
- **Rust `std::simd`** ([std docs](https://doc.rust-lang.org/std/simd/index.html),
  [RFC 2977](https://raw.githubusercontent.com/rust-lang/rfcs/master/text/2977-stdsimd.md),
  [target_feature](https://doc.rust-lang.org/reference/attributes/codegen.html),
  [multiversion](https://docs.rs/multiversion/latest/multiversion/)):
  - It is still nightly-only (`portable_simd`) and has up to 64 lanes.
  - Where SIMD is missing, it falls back to scalar code.
  - Calling a `#[target_feature]` function on a CPU without the feature is
    undefined behaviour, so `is_x86_feature_detected!` plus dispatch (the
    multiversion crate) is the safe pattern.

  *For defk:* portable vectors give portability. Speed past the baseline
  still needs either a build-time level or runtime dispatch.
- **Go** ([minimum requirements](https://go.dev/wiki/MinimumRequirements),
  [`rt0_go`](https://raw.githubusercontent.com/golang/go/master/src/runtime/asm_amd64.s),
  [`simd/archsimd`](https://raw.githubusercontent.com/golang/go/master/src/simd/archsimd/doc.go),
  [SIMD blog post](https://go.dev/blog/simd-experiment)):
  - For years Go had no SIMD in the language, with assembly in the standard
    library.
  - `GOAMD64=v1..v4` picks a psABI level; v1 is the default. Binaries "check
    at startup", and `rt0_go` prints "This program can only be run on AMD64
    processors with vN microarchitecture support." and exits 1.
  - `GOARM64=v8.0..v9.5[,lse][,crypto]`, with newer instructions "guarded by
    dynamic checks".
  - `simd/archsimd` is an experiment behind `GOEXPERIMENT=simd`: per
    architecture, not portable, with feature variables to check first.
  - The blog post announces a portable `simd` package with emulation. Its
    "panic on a missing instruction" claim was read only in the post.

  *For defk:* a load-time refusal naming the missing level is the model.
  defk can do better than exit 1 by falling back to the portable library.
- **Julia** ([system image](https://docs.julialang.org/en/v1/devdocs/sysimg/),
  [package images](https://docs.julialang.org/en/v1/devdocs/pkgimg/),
  [`@simd`](https://raw.githubusercontent.com/JuliaLang/julia/master/base/simdloop.jl),
  [LoopVectorization](https://github.com/JuliaSIMD/LoopVectorization.jl)):
  - `JULIA_CPU_TARGET` takes several targets. The official x86 binaries carry
    `generic;sandybridge,...,clone_all;haswell,...,base(1)` and pick "the
    highest ISA level possible" at load.
  - Package images can be multi-versioned.
  - `@simd` allows reduction operations to be "reordered or contracted,
    possibly causing different results", and `@turbo` "can and will
    re-order operations".

  *For defk:* one artifact carrying several CPU targets, picked at load, is
  proven at scale. The opt-in reordering macros are what defk must not
  copy.
- **ISPC** ([user guide](https://ispc.github.io/ispc.html)):
  - SPMD "program instances" run as a gang whose width is set by the target
    (`avx2-i32x8`, `neon-i32x4`).
  - `--target` with a comma-separated list builds every ISA and an
    auto-dispatcher.
  - From 1.26 the dispatcher raises SIGILL when no ISA matches.

  *For defk:* multi-target plus dispatch in one object works. Even here the
  nothing-matches case is a crash, which defk must turn into a fallback or
  an error at load.
- **Erlang/OTP**:
  - The BeamAsm JIT detects CPU features at runtime: asmjit's
    `CpuInfo::host()` in `erts/emulator/beam/jit/beam_jit_main.cpp`. On
    x86 it uses AVX, BMI2, LZCNT and MOVBE when present, and LSE on arm64
    (`jit/x86/instr_*.cpp`, `jit/arm/instr_common.cpp`). The
    [BeamAsm docs](https://www.erlang.org/doc/apps/erts/beamasm.html) don't
    mention this. So one ERTS binary already dispatches on the CPU.
  - `erlang:crc32` is zlib, the system zlib by default. The bundled zlib
    uses ARM CRC32 instructions only when compiled with
    `__ARM_FEATURE_CRC32`, with no runtime dispatch, and braided tables on
    x86. It is CRC-32/IEEE; the x86 `crc32` instruction computes only
    CRC-32C *(memory)*, so a defk builtin needs its own software reference.
  - OpenSSL (`:crypto`) fills its capability vector from CPUID at
    initialisation, overridable through `OPENSSL_ia32cap`
    ([doc](https://raw.githubusercontent.com/openssl/openssl/master/doc/man3/OPENSSL_ia32cap.pod)).
    That is runtime dispatch with an environment override for testing the
    fallbacks, a pattern worth copying for defk's tests.
  - No `erlang:system_info` key reports CPU features *(memory)*.
- **rustler_precompiled**
  ([`config.ex`](https://raw.githubusercontent.com/philss/rustler_precompiled/main/lib/rustler_precompiled/config.ex),
  [`rustler_precompiled.ex`](https://raw.githubusercontent.com/philss/rustler_precompiled/main/lib/rustler_precompiled.ex)):
  - It ships 10 default target triples: aarch64/x86_64 for darwin,
    linux-gnu and linux-musl; arm and riscv64 Linux; two Windows triples.
  - NIF versions 2.14-2.18; the default is 2.15.
  - Artifacts are named
    `lib<name>-v<version>-nif-<nif_version>-<triple>.so.tar.gz`, with a
    `checksum-<Module>.exs` file.
  - Its `variants` option is documented for "restrict[ed] CPU features, like
    AVX on x86_64", but the variant callback runs **at compile time on the
    build host**, so it never sees the deploy host's CPU.

  *For defk:* per-triple artifacts are the Elixir norm. CPU variants chosen
  at build time are exactly the release and Docker hazard defk-ulk.3 must
  avoid.
- **Function multiversioning and glibc-hwcaps**
  ([GCC](https://gcc.gnu.org/onlinedocs/gcc/Common-Attributes.html),
  [clang](https://clang.llvm.org/docs/AttributeReference.html),
  [glibc NEWS 2.33](https://sourceware.org/git/?p=glibc.git;a=blob_plain;f=NEWS;hb=HEAD),
  [x86-64 psABI levels](https://gitlab.com/x86-psABIs/x86-64-ABI/-/raw/master/x86-64-ABI/low-level-sys-info.tex)):
  - `target_clones("default", "avx2")` builds several clones and resolves
    them at load through an ifunc.
  - glibc-hwcaps looks in `glibc-hwcaps/x86-64-v3/` subdirectories of the
    *library search path*. `:erlang.load_nif` dlopens an explicit path, so
    hwcaps would not apply (inference).
  - psABI v3 = AVX, AVX2, BMI1, BMI2, F16C, FMA, LZCNT, MOVBE, OSXSAVE.
    v3 and v4 need an XCR0 check (`xgetbv`) as well as CPUID, so a
    load-time check must do both.

  *For defk:* `target_clones` on a kernel function, or defk picking one of
  several `.so` files itself, are the two ways to ship variants in one
  release.

## Recommendation

The evidence for these recommendations is:

- **arm64:** measured on one Apple M4 Pro with Apple clang, under load.
- **x86-64:** clang's static remarks only.

Neither Linux arm64 nor any x86 timing was measured.

1. **defk-ulk.4, hardware builtins with exact meanings, crc32c first: do
   it first.**
   - It is the only measured gap that is large (14×) and has a known fix.
   - The study shows that no flag reaches it: the vectoriser never emits
     CRC32C at any level, and the default macOS build already has the
     feature.
   - A builtin has an exact meaning (the CRC32C polynomial), a table-driven
     Elixir mode, and a portable fallback for CPUs without the instruction.
     The fallback can be picked inside the kernel at run time (feature test,
     table path otherwise), so it needs no architecture build and no
     load-time refusal.
   - `clmul` (carry-less multiply, for CRC-64/16 folding) is the natural
     second builtin. On x86 it is outside every psABI level, so it needs
     that runtime test.
2. **defk-ulk.5, the portable vector-value ceiling study: do it second, as a
   study.** The remaining gaps (UTF-8 validation, base64/hex, substring
   search) all need lanes, byte shuffles and lane masks, which no flag
   gives.
   - Prior art points to a fixed 128-bit lane set with exact IEEE lanes:
     Wasm SIMD128, not relaxed-simd and not Julia's `@simd`.
   - It would also lift the x86-only loss on float reductions, as explicit
     lane-wise partial sums.
   - Write one hand-vectorised C version of `valid_utf8?` and of `encode64`
     first. They measure the ceiling before any language work.
3. **Finish the x86-64 timing run before deciding defk-ulk.2.** It is one
   command (above) on one Linux x86-64 box. The remarks predict modest gains
   from v3:
   - twice the width on the loops that already vectorise, several of them
     memory-bound;
   - `ws_mask`'s main loop vectorised at v3, where SSE2 leaves it scalar;
   - nothing for the recurrence-bound majority.
4. **defk-ulk.2, opt-in architecture build with a load-time CPU check:
   only if step 3 shows real gains.**
   - On arm64 the evidence is negative: the M4 `native` build and armv8.2-a
     gain nothing over today's default.
   - The one arm64 effect found is *tuning*, which `-mtune` gives with no
     CPU-feature risk and so needs no check. That knob, a per-OS default
     tuning, is worth a separate small ticket, measured on a real
     Linux/aarch64 host (Graviton or Ampere) with upstream clang.
   - If x86 v3 proves worth it, the check must test CPUID and XCR0 (Go's
     `rt0_go` and the psABI are the references). On a mismatch it should
     fall back to the portable library rather than exit.
5. **defk-ulk.3, deploying architecture builds: last, and only after ulk.2
   is accepted** (and after defk-n8f ships `.so` files in releases).
   - rustler_precompiled's build-host `variants` show the trap to avoid.
   - One release carrying the portable and v3 libraries, picked at load by
     defk itself, or `target_clones` inside one library, keeps mixed fleets
     and Docker builds safe. glibc-hwcaps does not apply to an explicit
     dlopen path.

## Limits

- Every timing is from a loaded, shared machine, one CPU and one compiler.
  Ratios between interleaved builds of the same kernel are the result, and
  absolute times are for scale. Cases marked noisy swung more between rounds
  than between levels.
- The timed inputs are the examples' shapes but not always their sizes (1 MB
  instead of 16 MB, 10k instead of 100k embeddings). The kernels are timed
  alone, not end to end through `Defk.Bench`; the level is a property of the
  kernel, and the catalogue's end-to-end numbers are unchanged.
- The `csel`/branch and instruction-count explanations for `sort_i64` and
  SHA-256 come from counting assembly, not from profiling.
- Remarks show the vectoriser's verdict. They do not show SLP vectorisation
  of straight-line code, so none of the hash kernels has a remark. The
  study also did not inspect instruction selection beyond the FMA, FPCR,
  libm, CRC and SHA3 greps.
- The x86 remarks used `-target x86_64-apple-macos13`, i.e. the macOS SDK
  headers. A Linux x86 build sees glibc headers; the kernels' loops do not
  depend on them, but the run on hardware will confirm.
- Prior-art facts marked *(memory)* were not re-read today. The Go blog's
  panic/GODEBUG claims, cc_precompiler's docs (404) and the Rust RFC body
  were not verified.
