# Verdict

## Conclusion

<!-- TODO(defk-sgw.5): 3-5 sentences including the go/no-go outcome. -->
TODO: filled by defk-sgw.5.

## "Should I use defk for X?" guide

<!-- TODO(defk-sgw.5): guide by job type (Elixir / defk / Nx / Rustler) plus the traps list. -->
TODO: filled by defk-sgw.5.

## Workload results

Frozen snapshot (defk-sgw.4): commit `f064e33`, 2026-10-13, Apple M4 Pro
(12 cores), macOS 26.7.1, OTP 29.0.3, Elixir 1.20.2, Apple clang 21.0.0.
Command: `mix defk.examples --bench --all --snapshot --fresh`, 1667 s of wall
time, every report measured in this run (nothing reused from the cache).
Load average 2.8 at the start and 5.7 at the end; nothing else ran on the
machine, and the examples that split their work over all schedulers raise
the load themselves, which is why the result cache (which stores a result
only at a load of 3.0 or less before and after it) kept none of them. Two
examples were rerun alone after their scripts were corrected (below).
Every speedup is defk against the optimised Elixir baseline at the realistic
size the script declares; "vs native" is defk against the anchor package's
own NIF; the tick gap is the worst wait of a 1 ms ticker on one scheduler
while each side runs once (the idle floor on this machine is about 2 ms).

### Scoreboard

One row per example, sorted by verdict and speedup. ✅ good (defk is at
least 1.9× the best Elixir), 🟡 marginal (0.95–1.9×: use Elixir), ❌ poor,
⛔ out of scope. **T** marks a target workload (a job reproduced from a named
package and measured against its NIF); the others are supporting examples,
which illustrate but do not count towards the verdict.

| | | Example | The job | defk vs best Elixir | vs the package's NIF |
|---|---|---|---|---|---|
| ✅ | T | hashes | xxHash64 of 4 MB | **209×** | SipHash level with its NIF; CRC32C 0.9× of crc32cer |
| ✅ | | fft | 4096-point FFT, FIR over audio | **73×** | – |
| ✅ | T | blake | BLAKE2b-512 of 64 KB | **32×** | 1.02× blake2_elixir |
| ✅ | T | matmul | 256×256 f64 | **19×** | 151× Nx binary backend (EXLA expected to win) |
| ✅ | | image_ops | resize 1080p → 480×270 | **14×** | – |
| ✅ | T | cdcl_sat | Crux's scenario enumeration, 109 vars | **13×** | 4.2× picosat |
| ✅ | T | cosine_topk | top-10 of 100k × 384 f32 | **13×** | 3.1× vettore (Nx + EXLA 6–8× faster than defk) |
| ✅ | | rolling_stats | 1M readings, 12 chunks | **11×** | – |
| ✅ | | geohash_crc | encode 100k points | **11×** | – |
| ✅ | T | hll_update_many | 100k hashes into p = 14 | **10×** | 7.3× the Rust NIF |
| ✅ | T | pcm_mix | 4 streams, 10 ms chunks | **8.6×** | 1.9× NativeAdder |
| ✅ | | byte_histogram | 16 MB, 12 chunks | **7.8×** | – |
| ✅ | | image_blur | 1080p, 12 bands | **7.3×** | – |
| ✅ | T | keccak | 10k × 32 B per call | **7.0×** | 0.64× ex_keccak |
| ✅ | T | codecs | base64 of 1 MB | **6.9×** | 4.3× fast64 |
| ✅ | | sort_u64_keys | 1M packed keys | **6.2×** | – |
| ✅ | T | lz4_snappy_decode | Snappy block of 64 KB | **5.0×** | 2.5× snappyer as installed |
| ✅ | | per_pair_distance | 50k pairs, one call each | **4.0×** | – |
| ✅ | | geo_nearest | 10 nearest of 500k | **3.3×** | – |
| ✅ | | monte_carlo_rtp | 100M spins | **3.0×** | – |
| ✅ | T | cdcl_sat_per_call | one solve per call, 26–28 vars | **2.8×** | 1.7× picosat |
| ✅ | T | gorilla_encode | 100-point blocks | **2.4×** | 3.9× gorilla_stream |
| 🟡 | T | batched_levenshtein | 234k words, 12 chunks | 1.7× | 13.6× ex_strsim per pair |
| 🟡 | | poor_substring_search | 64-byte needle in 16 MB | 1.1× | – |
| 🟡 | | utf8_valid | 16 MB | 1.05× | – |
| 🟡 | T | ws_masking | 125-byte frames | 1.0× | 0.87× bandit_native |
| ❌ | | hash_chain | 10M SHA-256 steps | 0.55× | – |
| ❌ | | poor_tiny_calls | one call per element | 0.28× | – |
| ❌ | T | argon2 | argon2_elixir's defaults | 0.25× | lane for lane level |
| ❌ | | poor_list_data | data as a list | 0.08× | – |
| ⛔ | | out_of_scope_word_count | strings in, a map out | – | – |

The fuzzy_search app is not a scoreboard row: its 7 tests pass, and its own
measurement (4.4× per query, `/health` p99 10–12 ms against 75–82 ms behind
a blocking NIF) is in `examples/README.md`.

### Measured figures

**Target workloads** (jobs reproduced from a named package, measured
against its Elixir version and its NIF):

| Workload | Realistic size | Verdict | Speedup | Elixir ms | defk ms | vs native | Tick gap ms, max / p99 | Crossover |
|---|---|---|---|---|---|---|---|---|
| ws_masking | 125 B frames (the largest 7-bit length), 10,000 frames per timed run | marginal | 1.01x | 1.797 | 1.781 | 0.87x (bandit_native 0.1.2, Rust, byte at a time) | elixir 2.016 / 2.016; defk 2.222 / 2.222; native 9.088 / 9.088 | 1024 B |
| pcm_mix | N = 4 streams, 48 kHz stereo s16le, 10 ms chunks (1 s of audio: 100 mix calls + flush) | good | 8.56x | 3.346 | 0.391 | 1.87x (membrane_audio_mix_plugin 0.16.5 NativeAdder) | elixir 3.225 / 3.166; defk 2.098 / 2.098; native 41.591 / 41.591 | 1 ms |
| hll_update_many | 100000 pre-hashed u64s into a p = 14 sketch | good | 10.08x | 3.466 | 0.344 | 7.33x (ex_data_sketch 0.10.3 Backend.Rust, DirtyCpu above 10k hashes) | elixir 2.274 / 2.274; defk 2.012 / 2.012; native 1.988 / 1.988 | 100 |
| cosine_topk | 100k x 384 f32, k = 10 | good | 12.68x | 51.277 | 4.043 | 3.13x (vettore 0.3.5 flat, inner product on unit vectors) | elixir 2.109 / 2.072; defk 2.03 / 2.03; native 2.002 / 2.002 | 1000 |
| batched_levenshtein | 234454 words (a dictionary), one 12-byte query | marginal | 1.73x | 4.562 | 2.64 | 13.55x (ex_strsim 0.1.0, Rust strsim, per pair via Enum.map) | elixir 2.027 / 2.027; defk 2.197 / 2.197; native 2.156 / 2.156 | 1000 |
| gorilla_encode | 100-point blocks (a Gorilla/Prometheus chunk), 1,000 series per timed run, one call each | good | 2.41x | 5.874 | 2.436 | 3.88x (gorilla_stream 3.0.3 NIF) | elixir 2.751 / 2.751; defk 2.373 / 2.373; native 2.032 / 2.032 | 100 pts |
| hashes (xxHash64) | one 4 MB message | good | 208.75x | 37.157 | 0.178 | the script's other lines: SipHash level with the siphash NIF, CRC32C 0.84-0.91x of crc32cer | - | 1k x 32 B |
| codecs (base64) | 1 MB | good | 6.87x | 3.6 | 0.524 | 4.26x (fast64 0.1.3) | elixir 7.187 / 7.187; defk 2.279 / 2.279; native 4.307 / 4.307 | 65536 |
| keccak | 10k x 32 B messages per call | good | 6.97x | 24.519 | 3.519 | 0.64x (ex_keccak 0.7.8, tiny-keccak) | elixir 2.132 / 2.123; defk 2.16 / 2.16; native 19.293 / 19.293 | 10k x 32 B, one call each |
| blake (BLAKE2b) | one 64 KB message (content hashing, dedup) | good | 32.1x | 1.348 | 0.042 | 1.02x (blake2_elixir 0.9.0, reference C) | elixir 8.717 / 6.924; defk 2.418 / 2.418; native 44.142 / 44.142 | 1 KB |
| lz4_snappy_decode (Snappy) | 64 KB block (JSON-like events) | good | 5.03x | 0.196 | 0.039 | 2.51x (snappyer 1.2.10 as installed, -O0) | elixir 2.029 / 2.029; defk 1.847 / 1.847; native 2.001 / 2.001 | 4 KB |
| cdcl_sat | Crux.satisfying_scenarios on an Ash-shaped formula, P = 12 policies (109 vars, 280 clauses) | good | 12.88x | 221.529 | 17.195 | 4.22x (Crux 0.1.4 + picosat_elixir 0.2.3) | - | - |
| cdcl_sat_per_call | Crux.satisfying_scenarios on two Ash-shaped formulas, P = 4 policies (26-28 vars), the kernel called once per solve, 20 enumerations each | good | 2.79x | 17.131 | 6.137 | 1.7x (picosat_elixir 0.2.3) | - | P=4 seed 1, 26 vars |
| argon2 | argon2_elixir's defaults: t_cost 3, m_cost 64 MiB, parallelism 4, 32-byte tag | poor | 0.25x | 18.112 | 73.321 | - (the C runs its four lanes on threads; lane for lane the kernel is level) | elixir 2.009 / 2.009; defk 2.287 / 2.195 | none |
| matmul | 256x256 | good | 18.56x | 321.917 | 17.343 | 150.76x (Nx 0.13.1 binary backend; EXLA, not measured here, is expected to win) | - | 64 |

**Supporting examples** (not tied to a package; they illustrate but do not
count towards the verdict):

| Example | Realistic size | Verdict | Speedup | Elixir ms | defk ms | Tick gap ms, max / p99 | Crossover |
|---|---|---|---|---|---|---|---|
| rolling_stats | 1M readings, 12 chunks each side | good | 10.72x | 10.431 | 0.973 | - | - |
| geo_nearest | 10 nearest of 500k locations | good | 3.32x | 3.529 | 1.064 | - | - |
| image_blur | 1080p, 12 row bands each side | good | 7.29x | 10.157 | 1.393 | - | - |
| image_ops (resize) | 1080p to 480x270 | good | 13.63x | 19.101 | 1.401 | - | - |
| fft | n = 4096 | good | 73.36x | 4.475 | 0.061 | elixir 50.382 / 5.801; defk 2.235 / 2.235 | 4096 |
| byte_histogram | 16 MB, 12 chunks each side | good | 7.78x | 7.823 | 1.006 | - | 4096 |
| monte_carlo_rtp | 100M spins | good | 2.96x | 1404.08 | 474.852 | elixir 2.843 / 2.02; defk 2.39 / 2.228 | 1000000 |
| sort_u64_keys (packed) | 1M keys | good | 6.15x | 379.008 | 61.659 | - | - |
| per_pair_distance | 50k short pairs, one call each | good | 4.03x | 53.971 | 13.407 | - | - |
| geohash_crc (encode) | 100k points | good | 10.7x | 19.125 | 1.787 | - | 100 |
| geohash_crc (the other lines, from the rerun before) | decode 100k hashes 14.1x; CRC-16 of 1 MB 2.13x (1.35x the crc NIF); CRC-64 of 1 MB 2.17x (1.13x the NIF); one point per call 0.7-0.95x | | | | | | |
| fuzzy_search (app) | 234k words behind Plug + Bandit | its 7 tests pass; the measured figures are in `examples/README.md` | | | | | |

**Where Elixir is the right choice** (the poor fits, kept on purpose):

| Example | Realistic size | Verdict | Speedup | Elixir ms | defk ms | Crossover |
|---|---|---|---|---|---|---|
| poor_list_data | data arriving as a list | poor | 0.08x | 5.374 | 68.621 | - |
| poor_tiny_calls | one call per element | poor | 0.28x | 14.645 | 52.076 | - |
| poor_substring_search | a 64-byte needle in 16 MB (`:binary.match` is C) | marginal | 1.11x | 5.311 | 4.781 | - |
| utf8_valid | 16 MB (`String.valid?` is C) | marginal | 1.05x | 30.903 | 29.508 | none |
| hash_chain | 10000000 SHA-256 steps (`:crypto` uses the SHA instructions) | poor | 0.55x | 952.349 | 1735.602 | none |
| out_of_scope_word_count | strings in, a map out | out_of_scope | - | 23.239 | - | - |

**Lines on a verdict boundary.** Two scripts failed the full run because a
secondary line measured the neighbouring verdict: CRC-64 read 2.16-2.17x
(pre-registered marginal) and CRC-16 1.7-2.13x across three runs; the
tiny-formula SAT line read 1.27x and then 0.71x minutes apart
(pre-registered poor); one geohash point per call 0.7-0.95x. The
recommendation is the same on both sides of each line, so the scripts keep
their pre-registered expectation and their own check now accepts the
neighbouring verdict for those lines; the first line of each script, the
one the runner reads, is held to its claim. The two examples were then
rerun alone; their rows above come from those runs.

**Tally for the go/no-go rule.** Of the six pre-registered target workloads,
four are good on an optimised baseline (PCM mixing, HLL, cosine top-k,
Gorilla) and two are marginal (WebSocket masking at small frames, the
dictionary-wide Levenshtein batch). Of the eight target workloads added
later, seven are good (hashes, codecs, Keccak, BLAKE, Snappy and LZ4
decode, the SAT solver at Ash size, and matrix multiply against Nx's binary
backend) and one is poor (Argon2). The good results span byte transforms,
hashing and checksums, sketch updates, f32 vectors, time-series encoding,
codecs, decoders on untrusted input and a search algorithm: more than two of
the NIF survey's categories. Against the anchor NIFs, defk is faster in
nine rows, level in two (BLAKE2b, SipHash) and slower in three (Keccak
0.64x, WebSocket masking 0.87x, CRC32C 0.84-0.91x). No kernel's tick gap
left the 2 ms floor by more than 0.5 ms; three anchor NIFs block their
scheduler for 19-44 ms per call.

## Runtime contract

<!-- TODO(defk-sgw.5): one row per promise with linked test/bench, measured figure, known gaps. -->
TODO: filled by defk-sgw.5.

## Developer experience

<!-- TODO(defk-sgw.5): three-part bar with evidence. -->
TODO: the rest of this section is filled by defk-sgw.5.

### Cold test (defk-sgw.3)

A fresh agent session, given only README.md, docs/language.md and the
compiler's output (no lib/ source, no prior context), wrote a count-min
sketch `update_many` over `[u64]` hashes, a job not in the catalog. Full log:
[docs/cold-tests/count-min.md](cold-tests/count-min.md).

- Result: the first kernel it wrote compiled and agreed with a plain Elixir
  reference and with Elixir mode (`Mod.__defk_elixir__/2`, and
  `Defk.Test.assert_agrees/3` over random sketch shapes, empty batches and
  hashes with the top bit set). One attempt, no compile error.
- Compile errors: none were hit, so this run gives no evidence on whether
  the errors' hints get an author unstuck. That half of the bar needs a run
  on a job that meets the subset's limits (defk-dig).
- Doc gaps it reported, fixed: no example combined a hash-to-bucket index
  with a counter bump in a `[u64]` table (the kernel is now the third example
  under docs/language.md "Writing", checked by the docs example test), and
  README did not say that a `mix run` script needs
  `use Defk, elixir_mode: true` for `__defk_elixir__/2`.

### Second cold test (defk-dig)

The same setup on a job chosen to meet the subset's limits: a batch decoder
for packed LEB128 varints (raising on a truncated one) and a streaming top-k
over `[f64]` with a small sorted buffer and early exit. The prompt did not
mention any limit. Full log:
[docs/cold-tests/leb128-topk.md](cold-tests/leb128-topk.md).

- Result: both kernels compiled and agreed with plain Elixir references
  (fixed cases and 200 random inputs each) and with Elixir mode after four
  attempts, from the docs alone.
- Compile errors: four were hit, all with the full why/hint/code frame.
  Rated by the author: unknown-type (`binary` -> `[u8]`) helped,
  array-in-branch ("do the array work inside each branch") helped,
  clause-head helped for its line but hid the real blocker (binary patterns
  in clause heads, ticketed defk-x4o), unsupported-list helped for inputs
  and only partly for a result. The redesign (array in, `{array, count}`
  out) came from docs/language.md; the error catalogue was never needed.
- One runtime error, an `i64` overflow in `bsl(1, 63)`, named its cause; the
  `u64` masking fix was in the docs but spread over two places.
- Fixed after the run: unsupported-list's hint and a docs row for results of
  unknown length; a bug the bitstring recipe exposed (`u64` segment values
  of 2^63 and up raised natively, not in Elixir mode); a docs note that a
  mask drops high bits silently; README instructions for depending on defk.

### Third cold test, from the built HexDocs (defk-djy.9)

A fresh session that could read only the built HexDocs (no repo source)
installed defk as a dependency of a new project and wrote a kernel for the
Shannon entropy of each 4096-byte window of a binary, then tested, measured
and deployed it, and answered scope and "defk or Elixir?" questions from the
docs. Full log, with the resolution of each point:
[docs/cold-tests/hexdocs-entropy.md](cold-tests/hexdocs-entropy.md).

- Result: the second attempt compiled and passed unit tests, an agreement
  property and a forced-yield test on the first run; ~25 minutes of reading.
  Measured by the tester on a loaded machine (provisional): ~16x an
  optimised Elixir baseline, one process against one call.
- Compile errors: 2 hit (unknown-function helped, for-collect partly), and 7
  deliberate probes (2 helped, 5 partly). The weak spots were generic hints
  for data-shape errors and a footer that pointed at a local path.
- 15 confusing points, all fixed in the docs or the messages or ticketed:
  footers are URLs outside the repo; the Markdown copies of the pages had
  dead links, now rewritten and checked by `mix docs`; new hints and
  rewrites for `:math.log2`, lists, `String.t()` and counter maps; guides now
  cover alloc in loops, errors in rounds, comparing over all schedulers,
  `[u8]` properties and the release workaround. Ticketed: log2 builtins
  (defk-ngj), errors inside rejected constructs (defk-uw9), a for-collect
  rewrite (defk-djy.13), a byte-histogram catalog entry (defk-9p6.28), the
  HexDocs main page (defk-djy.14, for a human), and a report note for alloc
  in a loop (defk-djy.15).

## Limitations

<!-- TODO(defk-sgw.5): limitations and what would change the verdict. -->
TODO: filled by defk-sgw.5.

## Method

Pre-registered: this section was committed before any workload row was filled (commit date is the pre-registration).

The workload-results table is generated from `mix defk.examples --bench --all --snapshot` output once defk-9p6.10 lands. See `examples/README.md` for the measurement details.

<!-- Source: defk-dtw.4 resolution comment (2026-10-05T19:30:53Z), quoted verbatim below. -->

Evidence bar per row:

> Evidence bar per row: baseline :optimized (no provisional verdict counts), quiet-machine run_all.exs, best of N with spread, machine/OTP/Elixir/commit, Elixir attempts linked from the example header. One machine; other architectures go under Limitations.

<!-- Source: defk-dtw.4 resolution comment (2026-10-05T19:30:53Z). -->

Go/no-go rule:

> Pre-registered go/no-go (recorded in Method before rows are filled): grow into a library only if (a) >= half the target workloads are good on optimised baselines, spanning >= 2 NIF-survey categories; (b) no open safety gap in the runtime contract (performance gaps OK); (c) devex bar met and the cold test completed a kernel from the docs alone; (d) the C-compiler-at-build-time stance is settled. Otherwise: a research result, not a library. The conclusion may argue against the rule's outcome only explicitly.

<!-- Source: defk-dtw.4 amendment comment (2026-10-05T21:21:53Z), by defk-dtw.15. -->

Amendment:

> Amended by 'Plan the catalog build for the six target workloads' (defk-dtw.15): each workload verdict is measured at a realistic size declared in the script before any numbers (recorded in Method beside the go/no-go rule); the other size and the crossover are reported beside it.

### Correctness runs before the snapshot (defk-sgw.4)

Machine: Apple M4 Pro (12 cores), macOS 26.7.1, OTP 29.0.3, Elixir 1.20.2,
Apple clang 21.0.0. Commit `f064e33` (fault containment merged). Date:
2026-10-13. The load average during these runs was 4.7-8.5: they check
correctness, not speed.

- **Deep agreement run** (about 10k cases per property instead of 100):
  `MIX_ENV=test mix test --only deep --seed 20261013`. Result: 684
  properties passed, 0 failures, 260 s.
- **UBSan**: the whole suite with every kernel built under
  UndefinedBehaviorSanitizer, stopping at the first report
  (`MIX_BUILD_PATH=<own path> DEFK_SANITIZE=undefined MIX_ENV=test mix test
  --seed 20261013`). Result: 0 sanitizer reports; 1703 of 1730 passed. The
  27 failures are artefacts of the build mode, read one by one: 25 tests
  call `Defk.Bench.report/1`, which refuses to time sanitized kernels by
  design (the bench and bench-cache tests, and two `measuring.md` scripts);
  one checks the library's file name, which carries the `-san-undefined`
  suffix in this mode; one copies the build directory and trips over the
  `.so.dSYM` directory that `-g` adds.
- **ASan**: the same suite under AddressSanitizer, with the runtime
  inserted into the VM and the ERTS allocators off so binaries are plain
  `malloc` blocks (`DEFK_SANITIZE=address ERL_AFLAGS="-env
  DYLD_INSERT_LIBRARIES <libclang_rt.asan_osx_dynamic.dylib> +Mea min" ...
  --exclude erlang_memory`, the two tests that read `:erlang.memory/1` being
  excluded as it raises `notsup` with the allocators off). Result: 0
  sanitizer reports; 1701 of 1728 passed; the same 27 artefacts.
