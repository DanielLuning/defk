# defk examples

## Purpose

**The goal is not to show that defk beats Elixir.** It is to find the use
cases where defk can help Elixir, and to say plainly where it can't.

Elixir is the default. When an Elixir solution is as good or as fast, it is
the right choice: it's easier to read, debug, deploy and maintain than native
code. defk only earns a place where a well-optimised Elixir solution still
falls clearly short.

So every example answers one question: **after making the Elixir version as
fast as we can, is defk still clearly better?**

The format follows [mix_install_examples](https://github.com/wojtekmach/mix_install_examples):
one self-contained script per use case.

```bash
elixir examples/geo_nearest.exs     # one example, timed
mix defk.examples                   # every example `mix test` does not run: compile + agreement checks, no timing
mix defk.examples --bench           # the same, timed, with the scoreboard (exit 1 if any claim fails)
```

## Scoreboard

Measured on 2026-10-13 at commit `8d2d75f` on an otherwise idle Apple M4
Pro (12 cores, OTP 29.0.3, Elixir 1.20.2): `mix defk.examples --bench --all
--snapshot --fresh`, every report measured in that run. One row per example,
the line its runner reads; "In one line" quotes the script's other reports.
"defk vs best Elixir" is the speedup over the fastest Elixir version we
found, at the size the script declares as realistic; "vs the package's NIF"
is defk against the native library people use for that job today.

**One source for the numbers.** `mix defk.examples --bench --all --snapshot`
stores the run in `scoreboard.json`, `--bench --only <name> --snapshot`
replaces that example's row, and
`mix defk.docs` writes this table and the summary in the
repository README from it; the text around the numbers is in
[`_tables.exs`](_tables.exs). Do not type a measured number into either
table, or into the notes below: measure again. The notes say what each
script tried and what to take from it; the numbers behind them are in each
script's header.

<!-- scoreboard:start -->
Measured on Apple M4 Pro (12 logical cores) in 5 runs, from 2026-10-19 to 2026-10-20. The newest at commit `3602f17d`, OTP 29.0.3, Elixir 1.20.2: `mix defk.examples --bench --only threshold_cross --snapshot --fresh`. A quiet measurement: other processes used at most 1.0 cores before and after it. A row from an earlier run says when it was measured, and at which commit.

| | Example | The job | defk vs best Elixir | vs the package's NIF | In one line |
|---|---|---|---|---|---|
| ✅ | [`hashes`](hashes.exs) (measured 2026-10-19 at `8fa900b7`) | xxHash64 of a 4 MB message | **203×** | SipHash 1.2× of its NIF; CRC32C 0.82× of crc32cer | Elixir is bignum-bound at 64-bit hashes; Murmur3 and SipHash are the same story |
| ✅ | [`fft`](fft.exs) (measured 2026-10-19 at `8fa900b7`) | FFT of 4096 points; a 64-tap FIR over 2 s of audio | **82×** | – | bit-exact with Elixir; Nx's binary backend is slower than plain Elixir here |
| ✅ | [`blake`](blake.exs) (measured 2026-10-19 at `8fa900b7`) | BLAKE2b-512 of 64 KB | **32×** | 1.0× blake2_elixir (reference C) | BLAKE3 9.9× Elixir and 0.61× the NEON NIF; against `:crypto`'s BLAKE2b only 1.2× |
| ✅ | [`matmul`](matmul.exs) (measured 2026-10-19 at `8fa900b7`) | 256×256 f64 | **31×** | 0.21× Nx + EXLA (CPU, from binaries) | Nx with EXLA is 6× faster at 256×256 and 108× at 1024×1024; defk wins only at 64×64, where EXLA's dispatch and copies cost more than the product |
| ✅ | [`image_ops`](image_ops.exs) (measured 2026-10-19 at `8fa900b7`) | bilinear resize 1080p → 480×270 | **14×** | – | YUV420 19× and Floyd-Steinberg dither 21×; libvips not compared |
| ✅ | [`cosine_topk`](cosine_topk.exs) (measured 2026-10-19 at `8fa900b7`) | top-10 of 100k × 384 f32 embeddings | **13×** | 3.2× vettore | Nx + EXLA is faster than defk: use it for a plain dot-product top-k |
| ✅ | [`geohash_crc`](geohash_crc.exs) (measured 2026-10-19 at `8fa900b7`) | geohash encode of 100k points | **12×** | – | decode 19×; CRC-16 2.2× and CRC-64 2.5×; one point per call 1.3× |
| ✅ | [`cdcl_sat`](cdcl_sat.exs) (measured 2026-10-19 at `8fa900b7`) | Crux's whole scenario enumeration, 109 vars | **11×** | 3.6× Crux on picosat | picosat's search is stronger on hard random 3-SAT, and blocks a scheduler for the whole solve there |
| ✅ | [`hll_update_many`](hll_update_many.exs) (measured 2026-10-19 at `8fa900b7`) | 100k hashes into a p = 14 sketch | **10×** | 7.5× the Rust NIF | the NIF's time is its own packing; fed packed input it is level |
| ✅ | [`pcm_mix`](pcm_mix.exs) (measured 2026-10-19 at `8fa900b7`) | 4 PCM streams with clip prevention, 10 ms chunks | **9.7×** | 2.7× Membrane's NativeAdder | back-to-back NativeAdder calls are never preempted |
| ✅ | [`rolling_stats`](rolling_stats.exs) (measured 2026-10-19 at `8fa900b7`) | moving mean/stddev over 1M readings, 12 chunks each side | **9.4×** | – | one process against one call ~34× |
| ✅ | [`byte_histogram`](byte_histogram.exs) (measured 2026-10-19 at `8fa900b7`) | histogram of 16 MB, 12 chunks each side | **8.4×** | – | windowed entropy 11×; one process vs one call 11–18× |
| ✅ | [`keccak`](keccak.exs) (measured 2026-10-19 at `8fa900b7`) | Keccak-256 of 10k × 32 B per call | **7.7×** | 0.63× ex_keccak | the NIF blocks its scheduler on a 16 MB message; SHA3-256 against `:crypto` is 0.81× |
| ✅ | [`image_blur`](image_blur.exs) (measured 2026-10-19 at `8fa900b7`) | grayscale + 3×3 box blur, 1080p, 12 bands each side | **7.4×** | – | one process against one call 26–29× |
| ✅ | [`codecs`](codecs.exs) (measured 2026-10-19 at `684a3592`) | base64 round trip of 1 MB | **6.1×** | 4.2× fast64 | hex 4.4×, base58 3.5× per batch; one key per call is about as fast as Elixir |
| ✅ | [`sort_u64_keys`](sort_u64_keys.exs) (measured 2026-10-19 at `684a3592`) | sort 1M packed keys | **6.0×** | – | 3.8× when the caller needs a list back |
| ✅ | [`lz4_snappy_decode`](lz4_snappy_decode.exs) (measured 2026-10-19 at `8fa900b7`) | Snappy block decode of 64 KB | **5.1×** | 2.4× snappyer as installed (-O0) | slower than the same libraries built -O2; LZ4 the same picture |
| ✅ | [`monte_carlo_rtp`](monte_carlo_rtp.exs) (measured 2026-10-19 at `684a3592`) | 100M slot spins on all schedulers | **3.9×** | – | ≈1× at 1M spins: short kernel chunks stay on few schedulers |
| ✅ | [`per_pair_distance`](per_pair_distance.exs) (measured 2026-10-19 at `8fa900b7`) | Levenshtein on 50k short pairs, one call each | **3.6×** | – | stay in Elixir for very short strings |
| ✅ | [`geo_nearest`](geo_nearest.exs) (measured 2026-10-19 at `8fa900b7`) | 10 nearest of 500k locations | **3.2×** | – | 14× in one process; a grid prefilter helps both sides |
| ✅ | [`numeric_loader`](numeric_loader.exs) (measured 2026-10-20 at `0d6e7c78`) | numeric CSV of 26 MB into packed f64s | **2.7×** | – | a JSON array of numbers 4.0×; a fixed number grammar, and NimbleCSV or Jason for anything else |
| ✅ | [`cdcl_sat_per_call`](cdcl_sat_per_call.exs) (measured 2026-10-19 at `8fa900b7`) | one SAT solve per call, 26–28 vars | **2.6×** | 1.6× picosat | ≈1× on tiny formulas; batch the solves when one question makes several |
| ✅ | [`threshold_cross`](threshold_cross.exs) | first packet past a byte budget, 64k packets | **2.5×** | 13× Nx + EXLA `while` | EXLA costs ~40 µs a call and scales 1.9× over 48 callers; Elixir beats it up to ~1M packets |
| ✅ | [`gorilla_encode`](gorilla_encode.exs) (measured 2026-10-19 at `684a3592`) | Gorilla encoding of 100-point blocks | **2.4×** | 4.2× gorilla_stream's NIF | close to the bar at this size; 4.1× at 1M points |
| ✅ | [`tape_csv`](tape_csv.exs) (measured 2026-10-20 at `71e29777`) | CSV of 20 MB to NimbleCSV's rows, a fresh process per parse | **2.1×** | 0.38× rusty_csv | in a long-lived process 0.8–2.1× run to run; an [i64] tape of field events is slower than the cleaned copy |
| ✅ | [`fuzzy_search/`](fuzzy_search) | a search service over 234k words behind Bandit | its own measurement, see its README | – | Myers on both sides; `/health` latency stays at Elixir's while a blocking NIF raises it |
| 🟡 | [`batched_levenshtein`](batched_levenshtein.exs) (measured 2026-10-19 at `8fa900b7`) | one query against 234k words, 12 chunks each side | 1.5× | 13× ex_strsim per pair | Myers bit-parallel in plain Elixir is close; use it |
| 🟡 | [`ws_masking`](ws_masking.exs) (measured 2026-10-19 at `8fa900b7`) | mask 125-byte WebSocket frames | 1.5× | 1.2× bandit_native | the call is the cost; 3.4× at 1 MiB, crossover 1024 B |
| 🟡 | [`poor_substring_search`](poor_substring_search.exs) (measured 2026-10-19 at `8fa900b7`) | a 64-byte needle in 16 MB | 1.1× | – | `:binary.match` is Boyer-Moore in C already |
| 🟡 | [`utf8_valid`](utf8_valid.exs) (measured 2026-10-19 at `8fa900b7`) | validate 16 MB of UTF-8 | 1.0× | – | `String.valid?` is C already |
| ❌ | [`hash_chain`](hash_chain.exs) (measured 2026-10-19 at `8fa900b7`) | a 10M-step SHA-256 chain | 0.57× | – | `:crypto` runs on the SHA instructions; HMAC rounds 1.5× |
| ❌ | [`poor_tiny_calls`](poor_tiny_calls.exs) (measured 2026-10-19 at `8fa900b7`) | one kernel call per element | 0.28× | – | 13 ns per call against 2 ns for an Elixir call |
| ❌ | [`argon2`](argon2.exs) (measured 2026-10-19 at `8fa900b7`) | Argon2id at argon2_elixir's defaults | 0.27× | lane for lane 0.94× of the reference C | the C runs its four lanes on threads; the kernel runs them in sequence |
| ❌ | [`poor_list_data`](poor_list_data.exs) (measured 2026-10-19 at `8fa900b7`) | the data arrives as a list | 0.07× | – | packing the list costs more than the whole `Enum.sum` |
| ⛔ | [`out_of_scope_word_count`](out_of_scope_word_count.exs) (measured 2026-10-19 at `8fa900b7`) | strings in, a map out | – | – | not expressible: the compiler refuses, as it should |
<!-- scoreboard:end -->

✅ good: defk is at least 1.9× the best Elixir and worth the native code.
🟡 marginal (0.95–1.9×) and ❌ poor: use Elixir. ⛔ out of scope: cannot be a
kernel. The rules are in [How verdicts work](#how-verdicts-work).

## Notes per example

What each script tried on the Elixir side, what it found, and what to take
from it. A number a report measures is in the scoreboard above, not here;
the notes keep only figures no report records, and each script's header
has them in full.

**Where defk helps**

- [`hashes.exs`](hashes.exs): xxHash64, Murmur3 x64_128, SipHash-2-4 and
  CRC32C that must match other systems, against the murmur, xxhash, siphash
  and crc32cer packages. Elixir is bignum-bound on 64-bit hashes (0.06–0.12
  GB/s against 8–10 GB/s); the rewrites beat xxhash's and siphash's own
  fallbacks. SipHash is level with its C NIF; CRC32C uses the `crc32c/3`
  hardware builtin in three streams and lands just below crc32cer, with
  the table fallback 5× slower. On 1k 32-byte keys the gains are 19–25× (the
  packing shows). `:erlang.phash2` does 2.5 GB/s but is not portable.
- [`fft.exs`](fft.exs): radix-2 FFT and direct convolution, bit-exact with
  Elixir; four FFT and two convolution variants tried. Nx's binary backend
  is slower than plain Elixir here; EXLA was not measured.
- [`blake.exs`](blake.exs): BLAKE2b-512 (keyed) and BLAKE3 from scratch,
  against blake2_elixir (reference C), blake3 (Rust, NEON) and the
  pure-Elixir blake2 and b3 packages. 32-bit halves made the Elixir side 10×
  faster than 64-bit words. BLAKE2b is level with the reference C and only a
  little faster than `:crypto`, which is the Elixir answer for BLAKE2b;
  BLAKE3 is level with its portable C and slower than the NEON build. On a 64 MB message
  both NIFs block 34–49 ms, the kernels 2–3 ms.
- [`matmul.exs`](matmul.exs): 256×256 f64, 64 to 1024 swept. Nx with EXLA
  (XLA's multithreaded SIMD GEMM) is 6× faster than defk at 256×256 from the
  same packed binaries, 50× with resident tensors, and 108× at 1024×1024;
  defk wins only at 64×64, where EXLA's dispatch and buffer copies cost more
  than the product. Nx's binary backend is itself Elixir and 8× slower than
  plain lists. For tensor work use Nx with EXLA; defk fits a custom loop
  beside it.
- [`image_ops.exs`](image_ops.exs) and [`image_blur.exs`](image_blur.exs):
  resize, YUV420, dither and a separable box blur on raw 1080p frames,
  bit-exact. The blur baseline went from a 9-reads-per-pixel first pass
  (~800 ms) to a sliding sum on row bands; list and iodata outputs lose.
  libvips (SIMD) was not compared and is expected to win the resize.
- [`cdcl_sat.exs`](cdcl_sat.exs): a bounded CDCL solver (two watched
  literals, first-UIP learning, VSIDS, Luby restarts, LBD reduction; a step
  budget and a fixed learned-clause arena as declared limits) on Ash's
  authorisation job, Crux's `satisfying_scenarios`, in one call. The Elixir
  baseline is the same CDCL on one `:atomics` array. The kernel equals
  Elixir mode and the Elixir CDCL in status, model and conflict count, and
  returns a valid cover checked against picosat. On random 3-SAT at n = 300
  picosat's stronger search wins and the kernel did not finish 4 of 7 seeds
  in 60 s; picosat blocks a scheduler for the whole 1.3 s solve, the kernel
  yields. 2.35 MB of C, about 3 minutes of clang.
- [`cdcl_sat_per_call.exs`](cdcl_sat_per_call.exs): the same kernel as a
  per-call drop-in for simple_sat or picosat_elixir. Pre-registered marginal
  or poor, measured good from about 20 variables up (the call, pack and
  unpack cost 7–16 µs, about picosat's own); on tiny formulas (5–11
  variables) it sits around 1× and flips run to run, so stay in Elixir there. Whenever
  one question makes several solves, batch them: 2–4× faster than per call.
- [`cosine_topk.exs`](cosine_topk.exs): cosine top-10 against 100k resident
  384-dim f32 embeddings (pre-normalised on every side), against vettore's
  flat index and Nx. Eight Elixir variants (binaries, tuples, float lists in
  `:persistent_term` and in shard processes, 1–24 chunks). Nx with EXLA is
  6–8× faster than defk and the right tool for a plain dot-product top-k; the
  Nx binary backend takes 14 s.
- [`rolling_stats.exs`](rolling_stats.exs): moving mean and stddev over 1M
  readings, result as one packed binary. The first-pass float lists were
  100–308 ms; packed binary accumulation, four windows per step and 12
  scheduler chunks brought Elixir to about 10 ms.
- [`geohash_crc.exs`](geohash_crc.exs): geohash encode and decode of 100k
  points beside CRC-16/CCITT-FALSE and CRC-64/XZ. Both sides use
  quantise-and-bit-spread; the bisecting Elixir and the `geohash` package
  are 8× slower. CRC-64 as one integer goes bignum and costs 10× two 32-bit
  halves. The CRC lines sit on the 2× bar and cross it run to run: the crc
  NIF is only a little slower than the kernel and `:erlang.crc32` (zlib,
  another polynomial) is 100× faster than both. One point per call is no
  faster than Elixir; a batch of 10 breaks even.
- [`hll_update_many.exs`](hll_update_many.exs): 100k pre-hashed u64s into a
  p = 14 HyperLogLog, as ex_data_sketch's backends do. Nine Elixir variants;
  the best ranks top-down with `:atomics` and a rebuild above 5k. The Rust
  NIF spends most of its time in its own `Enum.map` and iodata pack; fed
  defk's packer it is level with defk. State byte-identical across all three.
- [`pcm_mix.exs`](pcm_mix.exs): mix N PCM streams with clip prevention,
  Membrane's ClipPreventingAdder job, byte-identical with the plugin and its
  NativeAdder on 144 cases. Six Elixir variants; a fused scan with appended
  output is 7–12× the plugin's own Elixir. Back-to-back NativeAdder calls are
  never preempted: 42 ms gaps against 2 ms for the kernel.
- [`byte_histogram.exs`](byte_histogram.exs): a 256-count histogram and
  the Shannon entropy of every 4 KiB window of 16 MB. Fourteen histogram
  variants; 16-bit pairs into `:atomics` won, 2.4× over 8-byte `:counters`
  steps. Entropies bit for bit.
- [`keccak.exs`](keccak.exs): Keccak-256 for Ethereum (no `:crypto`
  equivalent) and SHA3-256. 32-bit halves are 20× faster than 64-bit lanes in
  Elixir. ex_keccak (tiny-keccak) is faster on a batch of small messages and
  level at 16 MB, where it blocks its scheduler 19 ms. For SHA3-256,
  `:crypto` (OpenSSL) beats the kernel.
- [`codecs.exs`](codecs.exs): base64, hex and base58 round trips. base64 at
  4.5–5.5 GB/s, 4× the fast64 C NIF; hex 3.6× (encode alone 2.6× the
  BIF, decode 4.5×); base58 is good on a batch of 10k keys and about as
  fast as Elixir one key per call.
- [`sort_u64_keys.exs`](sort_u64_keys.exs): heapsort kernel on 1M packed
  keys against decode plus `:lists.sort`; still good when the caller needs a
  list back, with the decode counted.
- [`numeric_loader.exs`](numeric_loader.exs): a numeric CSV (26 MB) and a
  JSON array of embedding floats into packed f64s, in two passes (count,
  then parse into one alloc; the count is 6–11% of the time). A
  written-down grammar keeps the floats bit-exact with `String.to_float/1`.
  The best Elixir is a binary-matching parser that appends to one binary,
  5.7–5.9× faster than NimbleCSV with `String.to_float`; the kernel is 2.7×
  that on CSV, and about 4× on JSON against Jason, OTP's `:json` and the
  same parser.
- [`tape_csv.exs`](tape_csv.exs): CSV to NimbleCSV's rows of binaries
  through a kernel tape. An `[i64]` tape of field events loses to a
  cleaned copy (separators as bytes 30 and 31) that two `:binary.split`
  passes turn into rows. In a fresh process per parse the copy is 2.1–2.2× the
  best Elixir; rusty_csv's NIF builds the same sub-binaries in C, 2.6×
  faster again. Timed in one long-lived process, the verdict moved from
  0.8× to 2.1× run to run with the heap the earlier runs left.
- [`threshold_cross.exs`](threshold_cross.exs): the first packet whose
  running total passes a byte budget, an early-exit loop, in Elixir, a
  kernel and Nx `defn` on EXLA (a `while` with a stop flag, and a
  cumulative sum). The kernel is faster than EXLA at every size, 790× at
  16 packets and 2.9× at 16M; optimised Elixir beats EXLA up to about 1M.
  EXLA costs ~40 µs a call, scales 1.6–1.9× over 48 callers (one host
  lock), and compiles each new input length (~6.4 ms; power-of-two buckets
  bring 298 compiles down to 8).
- [`lz4_snappy_decode.exs`](lz4_snappy_decode.exs): Snappy and LZ4 block
  decode from scratch on untrusted input, against snappyer, lz4_erl and
  nimble_lz4. Against the NIFs as installed from Hex (built with no `-O`)
  defk is faster; against the same libraries built -O2 it is
  0.5–0.7× (Snappy) and 0.2–0.35× (liblz4): the cost is per element now,
  about 8 ns per LZ4 sequence against liblz4's 2 ns. Long copies run at
  memmove speed. 6,000 fuzz inputs under forced yields agree with Elixir mode,
  every rejection the kernel's own `ArgumentError`; see `verify/fuzz/`.
- [`per_pair_distance.exs`](per_pair_distance.exs): Levenshtein for 50k
  short pairs, one call each, as ex_strsim's API is shaped. Expected poor,
  measured good: a quadratic DP outweighs the call cost from about 8-byte
  strings. Batching from a list of pairs is slower than per pair (packing);
  batching pays only from an already-packed blob.
- [`geo_nearest.exs`](geo_nearest.exs): 10 nearest of 500k locations by
  haversine. Eight Elixir variants; packed column binaries were slower than
  tuples, and keeping the 500k tuples on the benchmark process's heap let
  GC triple the Elixir time (the index now lives where an app keeps it). A
  coarse-grid prefilter helps both sides.
- [`monte_carlo_rtp.exs`](monte_carlo_rtp.exs): 100M spins of a 5-reel slot
  on all schedulers, the kernel running `:rand`'s exsss generator bit for bit
  so the totals equal Elixir's. Four Elixir variants, including exsss inlined.
  At 1M spins the kernel chunks stay on 2–3 schedulers and the speedup is
  gone; see rule 7 in [Measuring correctly](#measuring-correctly).
- [`gorilla_encode.exs`](gorilla_encode.exs): delta-of-delta timestamps and
  XOR'd float bits, gorilla_stream's job, byte-identical across six Elixir
  variants, the C++ NIF and defk on 53 series. At 100-point blocks the shared
  header, the CRC32 and packing the list weigh and the result sits close to
  the bar; at 1M points, where packing the list is half of defk's time, it
  is clearly good.
  gorilla_stream's own Elixir is 5–8× slower than the optimised baseline.
- [`fuzzy_search/`](fuzzy_search) (an app): Levenshtein over 234k words
  behind Plug and Bandit, with Myers bit-parallel distance and the same
  early cut-off on both sides (an optimised baseline). Under load defk
  serves more requests per second with lower p99 latency, and `/health`
  latency stays at Elixir levels while a blocking NIF raises it. Yielding
  costs more than usual here, from a safepoint per word. Myers helps Elixir
  more than the kernel, so the gap is smaller than with the DP on both
  sides. The app measures itself; its numbers, still provisional, are in
  its README.

**Where Elixir is the right choice**

- [`batched_levenshtein.exs`](batched_levenshtein.exs): one query against
  all 234k words, as ex_strsim is batched with `Enum.map`. Myers bit-parallel
  Levenshtein in plain Elixir on small integers is 10× the DP and splits over
  all schedulers; the kernel's chunks stay on 2 of 12. In one process defk
  is 2.4–2.8×; over all schedulers, the scoreboard's line, it is marginal.
  Distances identical to ex_strsim.
- [`poor_substring_search.exs`](poor_substring_search.exs): a Horspool
  kernel against `:binary.match/2`, which is Boyer-Moore in C already, 7 GB/s
  on each side. For many patterns, `:binary.matches/2` with a compiled
  pattern.
- [`utf8_valid.exs`](utf8_valid.exs): a Hoehrmann DFA kernel against
  `String.valid?/1` and `:unicode.characters_to_binary/1`, which are C
  already; 0.6× at 64 KB, pure call cost at 1 KB. A SIMD validator (what
  bandit_native wraps) is a wrapper job.
- [`ws_masking.exs`](ws_masking.exs): Bandit's `ws_mask/2` with defk as a
  `primitive_ops_module`, against bandit_native's Rust NIF. At 125 bytes the
  call costs more than the XOR (keep Bandit's default); from 1 KiB defk is
  good and far ahead at 1 MiB, where the NIF is far slower than defk and
  blocks 9 ms. Only `:crypto.exor/2` with a doubled key beats the Elixir anchor,
  from about 600 bytes, so the baseline is a hybrid. Bytes identical across
  all four implementations.
- [`hash_chain.exs`](hash_chain.exs): a portable-C SHA-256 kernel against
  `:crypto`, which runs on the CPU's SHA instructions: 175 against 100 ns per
  step, flat from 1k to 10M steps. HMAC rounds are marginal (2.5× only against
  `:crypto.mac` per round, whose key setup costs more than RFC 2104 by hand).
- [`poor_tiny_calls.exs`](poor_tiny_calls.exs): one kernel call per element
  inside `Enum.map`: the call overhead exceeds the work.
- [`argon2.exs`](argon2.exs): Argon2id from scratch against argon2_elixir
  (reference C on a dirty scheduler, lanes on threads). Lane for lane the
  kernel is level with the C; at the defaults (4 lanes) it is poor because
  it runs the lanes in sequence. A process killed mid-hash frees the
  kernel's 256 MiB at once; the killed C hash holds its dirty scheduler and
  memory 400–500 ms more. RFC 9106 vectors pass; not audited, not
  constant-time. Use argon2_elixir.
- [`poor_list_data.exs`](poor_list_data.exs): the data arrives as a list
  (Ecto rows, JSON); packing it costs more than Elixir's whole `Enum.sum`.
- [`out_of_scope_word_count.exs`](out_of_scope_word_count.exs): strings in,
  a map out; a kernel cannot build BEAM terms and the compiler refuses. The
  example passes when the expected compile error is raised.

These numbers will shrink as the Elixir baselines are optimised; that's
expected and is the point. Each example's header lists what hasn't been
tried yet.

## Target workloads in progress

[`one_brc/`](one_brc/) is the One Billion Row Challenge (parse `<station>;<temp>\n` lines, min/mean/max per station), **baseline only, kernel pending**. `gen.exs` writes a deterministic file outside the repo (`$ONE_BRC_FILE`, default `/tmp/one_brc/measurements.txt`); `elixir.exs` is the pure-Elixir baseline, marked **optimised**: five variants measured at 10M and 100M rows, fastest `Task.async_stream` over `:file.pread` chunks with an `:atomics` accumulator, 1.66 s for 100M rows (1.4 GB) on 12 schedulers, checked against an independent Enum reference (`--check`). It is not run by `mix defk.examples` (a directory) and does not call `Defk.Bench.report` yet. [`one_brc/rustler.exs`](one_brc/rustler.exs) (with the Mix project `one_brc/rustler/`, Rust 1.94.1, rustler 0.37.4) is the hand-written-NIF comparison: the same chunking and output code driving a Rustler `aggregate(chunk)` (std `HashMap<&[u8], Stats>`, integer x10 parse, returns `{name, min, max, sum, count}` tuples), as a plain NIF and as `schedule = "DirtyCpu"`; both match the Elixir reference (`--check`, two seeds). End to end (12 schedulers, loaded machine, best of 3): plain NIF 67 ms / 760 ms at 10M / 100M rows, DirtyCpu 34 ms / 318 ms, against the Elixir `par_map` 342 ms / 3535 ms. Tick gap (1 ms ticker, one scheduler, 100M rows): Elixir `par_map` 13.3 ms max (p99 2.2), plain NIF 55 ms, DirtyCpu 5.6 ms (p99 2.2).

## Also not what defk is for

No script needed:

- **Wrapping an existing native library** (codecs, crypto, databases): use Rustler, Zigler or an existing binding.
- **Tensor and ML work at scale** (large fixed-shape arrays, linear algebra, gradients, GPU, batched serving), or any numeric job in an app already on Nx with EXLA: use Nx. Its speed comes from a compiled backend; `BinaryBackend` is slower than plain Elixir. [`matmul.exs`](matmul.exs) and [`cosine_topk.exs`](cosine_topk.exs) measure where the boundary lies. Overlap is fine: a numeric loop in an app that doesn't otherwise need Nx is a fair defk job, and an example may compare against Nx without having to beat it.
- **I/O-bound work**: native code doesn't make the network faster.

## Where a wrapper is the right choice

Nothing here is excluded on principle: each row names the condition that would reopen it. The issue tracker records what we do rewrite from scratch.

| Job | Wrapped today | Why not from scratch | What would change it |
|---|---|---|---|
| Signing, key exchange, secret-dependent crypto (secp256k1, ed25519, X25519, AEAD) | libsodium, secp256k1, ring via Rustler; `:crypto` | The one rule says nothing about timing: clang `-O3` may turn a select into a branch or a table lookup into a secret-dependent access, and a process dump or yielded frame holds key material. Public-input verification is allowed but gains little. | A constant-time mode: a restricted subset checked at compile time, codegen verified with dudect or ctgrind in CI, frame zeroisation, and an external audit. Until then, `:crypto`. |
| Parsers that produce trees or term streams (HTML, Markdown, tree-sitter, JSON/CSV to terms, protobuf, msgpack) | html5ever, comrak, tree-sitter, jsont, rusty_csv, protox | The product is BEAM terms and building them is the cost: `docs/research/string-workloads.md` measured a 13x gap between scanning and term creation. [`tape_csv`](tape_csv.exs) measured the tape route for CSV: a kernel cleans 20 MB in 36 ms, and two `:binary.split` passes then take 125–131 ms to build the rows, 2.1–2.2× the best Elixir in a fresh process per parse (in one long-lived process 0.8–2.1×, with the heap). rusty_csv builds the same sub-binaries in C, 2.6× faster again: a NIF builds terms far cheaper than Elixir does. A kernel cannot build terms. | Reopened narrowly for CSV to rows (`tape_csv`, good) where an extra NIF is not wanted; rusty_csv stays the fastest. JSON to terms is not measured. BPE tokenisation to `[i64]` ids is the exception: its product is packed, and so is a numeric CSV or JSON number array loaded into f64s (`numeric_loader`, good: about 2.7× and 4×). |
| Regular expressions | `:re` (PCRE in C), Rust regex via Rustler | `:re` is already native and compiled once per pattern; a kernel cannot take a pattern as data without becoming an interpreter, and fixed-string search is `:binary.match`. | A specific pattern class with a known kernel form (glob, or a simple byte DFA compiled at Elixir compile time) and a benchmark showing `:re` loses on it. |
| Large codecs and encoders (brotli, zstd encode, audio and video, PDF/typst rendering) | brotli, zstd, membrane_* FFmpeg/opus bindings, typst | The cost is spec surface and tuning, not the loop: 10^4-10^5 lines with SIMD everywhere. A kernel would be a worse implementation of a solved problem. | A narrow, named need: one compression level with fixed tables (zstd level 1 is the lz4-encode ticket plus FSE) or a decoder-only requirement for untrusted input. Each reopens one row, not the category. |
| Systems: databases, dataframes, tensor compilers (SQLite, DuckDB, Polars/Explorer, XLA/EXLA, LibTorch) | exqlite, duckdbex, explorer, exla, torchx | The value is the library: query planners, columnar engines, autodiff, device backends. defk is a kernel, not a system. | Interop, not rewriting: zero-copy views over their packed buffers so a per-element loop beside them runs as a kernel. `docs/research/nx-boundary.md` says where that line is; file an interop ticket when a workload asks. |
| Kernel-owned mutable state (SortedSet, in-place sketches, streaming decoders) | sorted_set_nif, xxh3 streaming, zstd streaming | A semantics question, not a rewrite one: ADR-0001 keeps state as values. | A design review of kernel-owned state. |

The verdict's Limitations section will cite this table.

## Running the examples: `mix defk.examples`

`mix test` compiles a few chosen examples ([Examples in mix test](#examples-in-mix-test)). `mix defk.examples` runs the rest, plus the `fuzzy_search` app's own tests. It is not part of `mix ci`: it takes about a quarter of an hour (argon2 and cdcl_sat compile for minutes) and some examples need `Mix.install` dependencies.

```bash
mix defk.examples                          # check-only, all but the mix test examples + fuzzy_search's tests
mix defk.examples --only keccak,hashes     # just these (any example; `fuzzy_search` names the app's tests)
mix defk.examples --all                    # also the examples mix test covers
mix defk.examples --list                   # print the selection and stop
mix defk.examples --timeout 600            # kill an example that runs longer than 600 s (default: no limit)
mix defk.examples --bench --only fft [--snapshot]  # timed, verdict checked; --snapshot stores that row
mix defk.examples --bench --all [--snapshot]       # the whole catalog (`--bench --all --snapshot` is the old run_all.exs)
mix defk.examples --bench --only fft --fresh       # the same, but measure every report (no cached results)
mix defk.examples --stale                          # stored rows whose kernels' C changed since measured (measures nothing)
```

**Check-only (the default).** Each example runs in its own `elixir` process with `DEFK_CHECK_ONLY=1`. In that mode `Defk.Bench.report/1` runs the example's `:check` (defk against Elixir) and returns: no timed runs, no Elixir baseline, no `:native`, `:sweep` or `:responsiveness`, no verdict. So the answer ("it compiles and agrees") does not depend on the machine's load, and the sanitizer build mode (`DEFK_SANITIZE`) is allowed, because nothing is timed. The `DEFK_RESULT` line then has `"check_only": true` and `"verdict": null` (the map `report/1` returns claims the expected verdict, so the scripts' own verdict assertions after it pass); every `DEFK_RESULT` line of a script counts, not just the first. An example passes when its process exits 0 and every check is `true` (or `skipped`, which the summary lists with its reason). `out_of_scope_word_count` passes when its expected compile error is raised (the script fails if the kernel compiles). The scripts need no change for this mode.

**fuzzy_search.** `cd examples/fuzzy_search && mix deps.get && mix test` (9 tests, about 20 s). It needs `/usr/share/dict/words`; if the file is missing the run fails with that message rather than skipping silently.

**`--bench`** replaces the old `examples/run_all.exs`: examples run one at a time with their timings; an example fails if it is incorrect, crashes, or measures a verdict other than the one it claims. The scoreboard lists `good` claims whose baseline is still provisional and the skipped checks. Run it on a quiet machine, and never across all examples on a loaded one: timings under load are meaningless. It measures only what it is given: `--only` names the examples, `--all` the whole catalog. A stored result stands until someone asks for that example to be measured again. `--snapshot` adds a markdown table sorted by verdict and speedup and stores the run in `examples/scoreboard.json`, which `mix defk.docs` turns into the [scoreboard](#scoreboard) and the repository README's summary. With `--all` it replaces the file; with `--only` it replaces those rows and keeps the others (from the same machine). Each row keeps its run's commit, versions and quiet limit, and whether it was measured quietly; each report keeps its stamp: the commit, defk's version, the time, the MD5 of each kernel module's C and the quiet test. A row from an earlier run says when and at which commit it was measured.

**Result cache (`--bench`).** A report whose inputs did not change is not measured again: `Defk.Bench.report/1` reuses the stored result (`Defk.Bench.Cache` in `dev/defk/bench/cache.ex`, the runner's adapter, loaded into each example's process with `elixir -r` and never packaged; the files live in `_build/<env>/defk_bench/`, one per example, outside git). The key is every loaded kernel module's `.beam` MD5 (the C source and the generated wrappers), `Defk.Build.cache_key("")` (cflags, `defk_runtime.h`, cc and its version, ERTS, sanitizer mode), the script and every file it requires, the `Mix.install` project's `mix.lock`, the MD5 of `Defk.Bench` and its helpers, the OTP and Elixir versions, the machine (architecture, CPU model, cores, schedulers) and the report's name. The example still runs and its `:check` still runs: correctness is never cached, and neither are `mix test` or check-only runs. Before each measurement the bench waits for the machine to settle: it samples `ps` every 2 s until processes outside the run use at most one core (`DEFK_BENCH_QUIET_CPU=<n>` overrides), for at most two minutes (`DEFK_BENCH_SETTLE_S`). Only quiet results are stored: the same test before and after the measurement, so a loaded run measures again next time. The run's own work never counts: an example that ended is gone from `ps`, and the runner and everything it started are left out. The 1-minute load average is not used: it counts the run's own compiles and threads and lags them by a minute or more, so a full run never looked quiet. Reuse is never silent: the task's start line says the cache is on, an example's status line says `CACHED: n of m report(s) reused, not measured`, the script's own output says `REUSED, NOT MEASURED` with the date, the scoreboard lists every reused report, and a `--snapshot` row is marked `(measured <date> at <commit>)`. On a miss the script says which key parts changed. `--fresh` measures everything (and stores the quiet results). Run directly (`elixir examples/x.exs`), a script always measures.

**Progress and time.** Long compiles are real (argon2 more than 7 minutes, cdcl_sat about 5, keccak about 1, hash_chain about 26 s per copy: see the table in [Examples in mix test](#examples-in-mix-test)). The task prints the example it is on (`[7/24] keccak`) and a line every 30 s of silence. Output of a passing example is not shown; a failing one prints its stdout and stderr. The exit status is non-zero if anything failed.

**Where the task lives.** `dev/mix/tasks/defk.examples.ex` (helpers in `dev/defk/`). `mix.exs` adds `dev` to `elixirc_paths` for `:dev` and `:test` only, so it is not compiled into a dependent's build, and `dev/` is not among the files Hex packages by default (nor is `examples/`). `mix defk.verify` goes in the same place.

## Measuring correctly

What we have learned about speed on the BEAM, with the numbers behind these rules, is collected in [`docs/performance.md`](../docs/performance.md).

1. **Optimise the Elixir side first.**
   - Use the stdlib, Erlang BIFs and modules (`:binary`, `:lists`, `:array`, ETS), and established Elixir libraries.
   - Pick a better data layout or algorithm.
   - Measure the alternatives; don't assume. For example, "`Enum.sum` is just `:lists.sum`" turned out to be false.
   - Record what you tried in the example's header.
2. **Mark the baseline honestly.** Use `baseline: :first_pass` until that work is done, and only then `baseline: :optimized`. A `good` verdict on a first-pass baseline is **provisional**, and the scoreboard says so.
3. **Better algorithms count on both sides.** If an algorithmic trick (an index, early exit, a cut-off) helps, apply it to the Elixir version too. Compare like with like.
4. **Measure end to end, from the data the caller really has, kept where a real app keeps it.**
   - If the data arrives as a list, packing it into a binary is part of the defk cost.
   - An index shared by every request belongs in `:persistent_term` or ETS, not on the benchmark process's heap. In `geo_nearest`, leaving 500k tuples on the heap let GC triple the Elixir time, inflating defk's lead from 13× to 44×.
   - `Defk.Bench` forces a full GC and then a minor GC before each timed run, so one run's garbage isn't billed to the next and the inputs start in the old heap (a minor GC copying them lands in no timed run).
5. **"As good" means Elixir wins.** Below the 2× bar (`marginal`), the recommendation is Elixir: the gain doesn't pay for native code.
6. **Keep the poor fits.** Examples where Elixir wins are as valuable as the wins. They tell people what not to do.
7. **Give each parallel kernel call a few milliseconds of work, or fewer, bigger chunks.** The BEAM wakes an idle scheduler when a crowded run queue has run enough reductions. A kernel charges one timeslice (4000 reductions) per 250 µs, while Elixir uses that many in about 5 µs. So kernel tasks under ~1 ms that one process spawns (`Task.async_stream` chunks) stay on 2–4 of 12 schedulers, while Elixir tasks of the same length spread over all 12. Chunks of ~5 ms spread (monte_carlo_rtp at 10M spins: 48 chunks on 11–12 schedulers). Starting every chunk at once also spreads: 48 short kernel tasks via `Task.async` + `Task.await_many` (or plain `spawn`) ran on 11 schedulers, against 3 under `Task.async_stream` with `max_concurrency: 12`. If the work can't be split that coarsely, `+swt very_low` (`elixir --erl "+swt very_low"`) spreads the short calls: batched_levenshtein's 12 chunks went from 5.1–5.6 to 2.3–2.5 ms and monte_carlo_rtp at 1M from 16.7 to 7.7 ms, while the Elixir chunks did not change (measured under load). Report the verdict on a default VM and give the flag's number beside it. Since the adaptive slice (`bench/adaptive_slice.exs`), a kernel on a crowded run queue yields every 50 µs for its first millisecond, which recovers most of the spread without the flag (batched_levenshtein's 12 chunks 3.8–3.9 → 1.9 ms, monte_carlo_rtp at 1M 12.7 → 5.5 ms; `+swt very_low` 1.0–1.1 and 4.6 ms; [`docs/performance.md`](../docs/performance.md) 4.9). Numbers measured before that change are with 250 µs slices.

## How verdicts work

Every script ends with `Defk.Bench.report/1`, which:

- checks that the Elixir and defk results agree (`:check` is required with
  `:defk`; opting out is explicit — `check: :none, reason: "..."` — reports
  `correct: skipped (<reason>)`, and `mix defk.examples` lists every skipped entry),
- takes the best of several timed runs for each side, measured end to end,
- prints a `DEFK_RESULT` JSON line, including the baseline status.

The verdict comes from the measurement and is a recommendation:

| Verdict | Rule | Recommendation |
|---|---|---|
| ✅ `good` | defk ≥ 1.9× faster than the Elixir baseline (the 2× bar less a 5% tie band) | defk helps, **once** the baseline is `optimized` |
| 🟡 `marginal` | 0.95×–1.9× (the 1× line less the same band) | use Elixir |
| ❌ `poor` | below 0.95× | use Elixir |
| ⛔ `out_of_scope` | can't be written as a kernel | use Elixir |

**Tie band.** A speedup within 5% below a threshold counts as reaching it: 1.9× is `good`, 1.899× is `marginal`; 0.95× is `marginal`, 0.949× is `poor`. Noise of a few percent on a result that sits on a line (a 1.0× tie, a 2.0× bar) then does not flip the verdict, and the recommendation was the same on both sides of the 1× line anyway. Examples still prefer inputs with a clear margin. The sweep's `crossover` stays at a plain 2×.

**Lines on a boundary.** A script whose secondary line sits on the 1× line or the 2× bar and flips with noise from run to run keeps its pre-registered expectation and accepts the neighbouring verdict in its own check, with a comment saying so (the CRC lines of `geohash_crc`, the tiny-formula line of `cdcl_sat_per_call`). The first line of a script, the one the runner reads, is always held to its claim.

Target workloads add optional keys to `report/1`. None of them changes the verdict, and
scripts that do not pass them need no change:

| Key | Reports (JSON keys) |
|---|---|
| `native: {fun, "pkg x.y.z"}` | the anchor package's NIF, timed like the other sides: `native_ms`, `native_label`, `native_speedup` (defk against the NIF) |
| `responsiveness: true` (or `[elixir: f, defk: f, native: f]`) | max and p99 gap of a 1 ms ticker on one scheduler while each side runs once (`Defk.Bench.TickGap`, the `bench/tick_gap.exs` method): `elixir_gap_ms`, `defk_gap_ms`, `native_gap_ms`, each `{max, p99}` |
| `realistic_size: "n = 4096"` | the size the anchor package is really called with, which the verdict is measured at: `realistic_size` |
| `sweep: [{label, elixir_fun, defk_fun}]` or `{sizes, fn size -> {elixir_fun, defk_fun} end}` | best-of (`sweep_runs`, default 3) per-size times and speedups, and the `crossover`: the first size where defk is at least 2x, or `null` |

`mix defk.examples --bench` prints these on a second line per example, and
`--snapshot` adds the results as a markdown table, sorted by verdict and
speedup with the marks above, for the scoreboard here and the "Workload
results" section of `docs/verdict.md`.

Each example also declares the verdict it **expects**. `mix defk.examples --bench` fails if an
example is incorrect, crashes, or measures a different verdict than it claims,
and it lists every `good` claim whose baseline is still provisional and every
example that skipped its agreement check, with the reason.

Both directions of change are progress:

- An optimised Elixir baseline turns a `good` into `marginal`: we learned Elixir is enough.
- A defk improvement turns a `poor` into a `good`: defk now helps.

Either way the catalog gets updated.

## Examples in mix test

`mix test` compiles a few examples' kernels (`Defk.Catalog`, `test/support/catalog.ex`) and checks them against their Elixir mode (`test/agreement_test.exs`). The rest of the examples are the job of `mix defk.examples` (above). This section is the measurement and the choice behind that split, and the change that followed.

**Rules.** An example whose expected verdict is `:poor` or `:out_of_scope` never runs in `mix test`: it measures where Elixir wins, and its kernels teach the compiler nothing the others don't. Pick the fewest, fastest examples whose kernels together cover the most compiler areas. Budget: a few seconds of cold compile in total.

**How it was measured** (2026-10-13, MIX_ENV=test, one VM per example, `_build/test/defk` emptied first so the C compile counts):

- Compile: the example's top-level `defmodule`s compiled the way `Defk.Catalog.load` does (no `Mix.install`, no benchmark). Examples that build their kernels with `Module.create` (argon2, blake, keccak) were evaluated up to that call. The number is the time of the kernel modules only.
- Check: 100 draws per kernel of `Defk.Test.assert_agrees` with forced yields, with arguments from `Defk.Generators` (i64 parameters in -2..24, arrays up to 64 elements plus the 2047..2049 strip lengths). Most draws raise early, so this is a floor; for scale, the hand-written properties of `test/agreement_test.exs` (27 properties, no `:deep`) take 0.5 s together. A kernel whose i64 parameter sets a trip count or an allocation, or whose arrays make Elixir mode quadratic, needs a bounded generator; where the stock `Defk.Properties` generator was tried instead, its total is given in brackets ("bound" says what to bound).
- Load: every run printed `uptime`. The host is shared (12 cores) and the one-minute load was 2.5 to 6 during the runs: all numbers are **provisional**. Three passes agree within about 25%; the quietest pass (load 2.5-3.5) is the low end of each range. Compile is single-threaded C, so load moves it little.

Areas: F floats (bit-exact, `-ffp-contract=off`, libm), U64 u64 / `wrap64` / u64 words, OV i64 overflow checks, BS bitstring accumulator and returns, RZ `raise`, MC multi-clause / case dispatch, YR long loops with yields (every agreement run forces yields; `Examples.Kernels.count_primes*` covers the rest), UA unzeroed `alloc`, 2D 2-D index arithmetic, INL kernel-to-kernel inlining, HW hardware and bit builtins (`crc32c`, `clz`/`ctz`, `rotl`, `mulhi`), EB elided bounds checks, VS value-semantics copy of an input, RA reduce accumulators (tuples), BL binary literals and attribute tables, CP range copies (`copy`, `copy_back`), NE narrow element types (f32, i16, i32), MG kernels generated by macros, EX early exit (`Enum.reduce_while`), YF `yield: false`, RT tuple and array returns.

| Example | Expected verdicts | Kernel modules | Compile s (cold) | Check s | Areas | Script deps (`Mix.install`) | mix test |
|---|---|---|---|---|---|---|---|
| `_template` | good | Example.Kernels | 0.40-0.43 | 0.02-0.04 | F, RA | none | drop (duplicates `Examples.Kernels.sum`; two tests name it, see below) |
| `argon2` | poor, marginal | Argon2Ex.Kernels (`Module.create`) | > 420 (two runs, 5+ and 7 min, neither finished) | not reached | U64, HW (`mulhi`), RZ, MC, INL, MG | argon2_elixir | no: poor, and minutes of compile |
| `batched_levenshtein` | marginal | Lev.Kernels | 0.54 | 0.07-0.09 (stock generator: 1.4; bound the 2049-element draws) | UA, EB, EX, shifts on i64 | ex_strsim | no |
| `blake` | good, marginal, good | Blake.Kernels (`Module.create`) | 18.4 | 0.08 | HW (`clz`/`ctz`), RZ, MC, INL, MG | blake2_elixir, blake2, b3, blake3, rustler | no: 18 s |
| `byte_histogram` | good, good | Hist.Kernels | 0.49-0.65 | 0.1-1.5 (`entropy*` on long windows: bound them) | OV, F (`log2`), EB, zeroed alloc | none | no |
| `cdcl_sat` | good, good, good | SatEx.Kernels (2.35 MB of C) | 295 | 0.4 | EX, RZ, MC, YR, INL | crux, picosat_elixir, simple_sat | no: 5 minutes |
| `cdcl_sat_per_call` | good, poor | none of its own (loads `cdcl_sat.exs`) | 295 (same kernel) | n/a | n/a | the same | no: poor, and the same compile |
| `codecs` | good, good, good | Codecs.Kernels | 0.82-1.0 | 0.13 (stock generator: 6.6-8.4; bound `encode58` keys) | BL, EB, UA, RZ (via `alloc(-1)`), RT, MG, EX | fast64, b58, erl_base58 | no: 1 s for areas the others cover |
| `cosine_topk` | good | Cosine.Kernels (+ Cosine.NxSearch, needs Nx: does not compile without it) | 0.42-0.71 | 0.04-0.06 | NE (f32), F, RT, RZ, EB | nx, exla, vettore | **yes** (load only the kernel module) |
| `fft` | good | FFT.Kernels | 0.48-0.62 | 0.07-0.10 | F (`sin`/`cos`), RT, RZ, EX | none | no: floats covered by geo, rolling, cosine |
| `fuzzy_search/.../kernels.ex` | none (an app) | FuzzySearch.Kernels | 0.48-0.57 | 0.06-0.09 | YF, MG, EX | n/a | stays |
| `geo_nearest` | good | Geo.Kernels | 0.44-0.57 | 0.16-0.27 | F (libm), RA, top-k arrays, EB | none | **stays** |
| `geohash_crc` | good, good, marginal, marginal, **poor** | GeoCrc.Kernels, KernelsEM (a second copy for the script) | 0.92-1.28 (one copy 0.45-0.62) | 0.16-0.19 | F (trunc/float), U64 masks, RZ, BL, INL | geohash, crc | no: one of its verdicts is poor |
| `gorilla_encode` | good, good | Gorilla.Kernels | 0.39-0.52 | 0.02 (needs a point generator) | BS, MC (guards), INL, HW (`clz`/`ctz`), RA, RT | gorilla_stream | **yes** |
| `hash_chain` | poor, marginal | HashChain.Kernels, KernelsEM | 52 (26 + 26) | `sha256_chain` draws do not finish | HW (`rotl`), U64, word loads, MG | none | no: poor, 26 s per copy |
| `hashes` | good, good, good, good | Hashes.Kernels (+ CRC32CPortable) | 1.27-1.43 (+ 0.47-0.62) | 0.14-0.16 | HW (`crc32c`), U64, OV (`wrap64`), INL (159 sites), BL, MG, EB | murmur, xxhash, siphash, crc32cer | **yes** (`Hashes.Kernels` only; the portable copy needs `DEFK_PORTABLE_BUILTINS`) |
| `hll_update_many` | good | Hll.Kernels | 0.32-0.45 | 0.03 | U64 (`[u64]`), HW (`clz`), VS, RZ | ex_data_sketch | **yes** |
| `image_blur` | good | Blur.Kernels | 0.45-0.59 | 0.02 (stock generator: does not finish; the catalog's own generators are part of the 0.5 s) | 2D, UA, narrow u8 | none | **stays** |
| `image_ops` | good, good, good | ImageOps.Kernels | 0.53-0.82 | 0.03 | 2D, RZ, OV | none | no: 2D covered by `image_blur` |
| `keccak` | good, **poor** | Keccak.Kernels (`Module.create`) | 63 | 0.12 | U64 (`wrap64`), word loads, 25-tuple accumulator | ex_keccak, ex_sha3 | no: poor, and a minute of compile |
| `lz4_snappy_decode` | good, good | LzSnappy.Kernels | 0.52-0.64 | 0.02-0.29 | RZ (20 sites), CP, word loads, EX, INL, RT | snappyer, lz4_erl, nimble_lz4 | **yes** |
| `matmul` | good | Matmul.Kernels | 0.39-0.51 | 0.07-0.09 | F (sum order), 2D | nx | no: floats covered |
| `monte_carlo_rtp` | good | RTP.Kernels | 0.49-0.60 | 0.05 (`simulate` with a stock generator: does not finish; bound spins) | YR (a 2^62-trip loop), INL, F, 5-tuple return | none | no: YR and INL covered; U64 by hashes |
| `out_of_scope_word_count` | out_of_scope | none (the compile error is the point) | n/a | n/a | n/a | none | no: out_of_scope |
| `pcm_mix` | good, good | PCM.Kernels | 0.95-1.15 | 0.17 (`mix_*` with a stock generator: does not finish; bound sizes) | NE (i16, i32), MG, RA, RT | membrane_audio_mix_plugin | no: 1 s for the narrow types; the first to add if they need coverage |
| `per_pair_distance` | good | Pairs.Kernels | 0.38-0.62 | 2.7-4.8 (`lev` on the 2047-2049-element strip lengths, Elixir mode is quadratic: bound the strings; the rest is 0.02) | UA, EB | none | no |
| `poor_list_data` | poor | Orders.Kernels | 0.40-0.41 | 0.04 | F | none | **drop** (poor) |
| `poor_substring_search` | marginal | Search.Kernels | 0.46 | 0.04 | EX | none | no |
| `poor_tiny_calls` | poor | Clamp.Kernels | 0.40 | 0.01 | F | none | **drop** (poor) |
| `rolling_stats` | good | Rolling.Kernels | 0.33-0.45 | 0.03 | F (sliding sums, `sqrt`), alloc size overflow cases | none | **stays** |
| `sort_u64_keys` | good, good | Keys.Kernels | 0.34-0.45 | 0.12-0.27 | VS, EX | none | no: VS covered by hll |
| `utf8_valid` | marginal | Utf8.Kernels | 0.35-0.45 | 0.02 | EB, tables built per call | none | no |
| `ws_masking` | marginal, good | Ws.Defk | 0.36-0.48 | 0.02 | RZ, `@impl true` | bandit, bandit_native | no |

No example's kernel module needs a `Mix.install` dependency to compile; only `Cosine.NxSearch` (a helper in the same script) fails without Nx. `Defk.Catalog.load` therefore names the modules it compiles for each script, in order (the kernel module, its macro or table helpers, and for the three older scripts the `*.Elixir` module their tests compare with), instead of every top-level `defmodule`. It also never sees `argon2`, `blake` and `keccak`, which define their kernels with `Module.create`.

### The choice

Eight examples (plus `fuzzy_search`'s `kernels.ex`):

| Example | Why it is in |
|---|---|
| `geo_nearest` (stays) | floats and libm, a top-k kept in arrays; has hand-written agreement properties |
| `rolling_stats` (stays) | sliding float sums, `sqrt`, hostile allocation sizes |
| `image_blur` (stays) | 2-D indices, unzeroed `u8` arrays, row bands |
| `gorilla_encode` | the only bitstring accumulator and bitstring return, the only guarded multi-clause kernels, `clz`/`ctz`, helper kernels inlined |
| `lz4_snappy_decode` | the heaviest `raise` use, `copy`/`copy_back`, word loads, early-exit loops, a kernel calling a kernel |
| `hashes` | the only hardware `crc32c`, u64 returns, `wrap64` mixing, 159 inlined helper calls, attribute tables, macro-generated kernels; the most expensive pick (1.3-1.4 s) |
| `hll_update_many` | a `[u64]` input, `clz`, the one deliberate value-semantics copy, the cheapest of all (0.3-0.45 s) |
| `cosine_topk` | the only f32 element type, eight-way float accumulators, a tuple of two arrays as the return |

Cost, measured before the change: cold compile of the kernel modules is about 4.8 s in one VM (the six scripts of the old catalog took 2.2 s), and 2.0 s when the modules compile in parallel (the old six took 0.9 s).

`Defk.Catalog` now loads exactly the eight chosen examples, one explicit module list per script (`test/support/catalog.ex`), the scripts compiling in parallel (`Task.async_stream`; the modules of one script in order). `Hashes.Kernels` is loaded without `Hashes.CRC32CPortable`, `Cosine.Kernels` without `Cosine.NxSearch`. `poor_list_data`, `poor_tiny_calls` (poor) and `_template` (a placeholder verdict; `Examples.Kernels.sum` covers the same kernel) left the catalog.

Tests that changed with it:

- `test/agreement_test.exs`: one agreement property per kernel of `Gorilla.Kernels`, `LzSnappy.Kernels`, `Hashes.Kernels` (37 kernels), `Hll.Kernels` and `Cosine.Kernels`, with bounded generators (`test/support/catalog_generators.ex`): Gorilla series with deltas of deltas on every bucket edge and values that flip a few bits; Snappy streams and LZ4 blocks encoded in Elixir (valid, then mutated: a changed, cut, added, dropped or inserted byte) plus arbitrary bytes, so decode and raise paths both run; byte windows and offset tables for the hashes (and 6 KB windows for the three-stream `crc32c`); HLL states of the demanded length and hashes with every leading-zero count; Cosine rows from a seeded generator, with ties and wrong shapes.
- `test/elixir_mode_test.exs`: the test that named `Orders`, `Example` and `Clamp` is replaced by known-answer tests of the new kernels in Elixir mode (the CRC-32C and xxHash64 check values, a Snappy stream and an LZ4 block, HLL registers, the cosine ordering, the Gorilla value stream against `Defk.GorillaReference`).
- `test/value_semantics_test.exs`: the catalog's kernels have no copies, except exactly one in `Hll.Kernels.update_many` (the input state is copied once before the loop, on purpose). `Gorilla`, `LzSnappy`, `Hashes` and `Cosine` have none.

**Before and after** (2026-10-13, MIX_ENV=test, 12 cores, shared host: every number is **provisional**; the load swung between 4 and 10 during the runs and wall time with it, so CPU time is given too). Before (commit 1cab26f): warm cache 83.3 s ExUnit time, 85.3 s wall, 49.7 s user+sys, at load 8.6. After: warm cache 46.3 s, 50.1 s and 46.3 s ExUnit time (47-51 s wall) at load 4.6-10, 50.5-55.1 s user+sys. The difference between the runs is the host's load, not the change: CPU time grew by about 1-5 s. `Defk.Catalog.load` alone takes 1.4 s cold (a fresh `_build/test/defk`) and 0.33 s warm; `test/agreement_test.exs` went from 0.5 s to 1.4 s of test time (27 to 75 properties). A cold `_build/test/defk` run: before 66.7 s ExUnit time, after 82.1 s, both at load 6-10.

### Not covered by an example in mix test

- `popcount`, `mulhi` and `rotl`/`rotr` in real code: only `argon2`, `blake` and `hash_chain` use them (minutes of compile, poor verdicts); `test/bit_builtins_test.exs` and `test/crc32c_test.exs` cover the builtins.
- Narrow integer element types (`[i16]`, `[i32]`): `pcm_mix` (+1 s) is the one example.
- Kernels with a 25-element tuple accumulator (`keccak`, 63 s) and very large C (`cdcl_sat`, 2.35 MB, 295 s): compile-time scaling is not tested.
- `Enum.reduce_while` with a `case` on patterns in a body (`blake`, `argon2`), `max_owned_bytes` and `adaptive_slice` options: no example uses them; unit tests do.
- Bit-exact libm beyond what `geo_nearest` and `rolling_stats` use (`sin`/`cos` in `fft`).
- Dense 2-D float loops (`matmul`) and the blocked variant.
- Anything that needs deps: `cosine_topk`, `hll_update_many`, `gorilla_encode`, `hashes` and `lz4_snappy_decode` compile without them, but their Elixir baselines and anchors (and so their benchmarks) are not run.

## Adding an example

1. Copy [`_template.exs`](_template.exs) to `examples/<use_case>.exs` (files starting with `_` are skipped by the runner).
2. Describe the real job and why people reach for a NIF, in the header.
3. Write the Elixir version, then optimise it as far as you can. Note in the header what you tried and what you haven't yet.
4. Give both versions the same input, in the form a real caller would have.
5. Compile the kernels with `use Defk, elixir_mode: true` and check in the script that each agrees with its Elixir mode (`Mod.__defk_elixir__(name, args)` against the native call, on small and bad inputs). The option works in a `Mix.install` script; the default call path stays native, so timing is unaffected.
6. Call `Defk.Bench.report/1` with the `expected` verdict, the `baseline` status and a one-sentence `reason`.
7. Run `mix defk.examples --only <use_case>` (agreement) and `mix defk.examples --bench --only <use_case>` (timed). Add its row's text to [`_tables.exs`](_tables.exs) (the job, the native comparison, one line; a measured number is a placeholder) and a note below the scoreboard. Its numbers reach the tables with a quiet `mix defk.examples --bench --only <use_case> --snapshot` and `mix defk.docs`.
8. Add or update the entries in [`docs/performance.md`](../docs/performance.md) for what you learned, including what didn't help: the numbers, the conditions (size, load: mark loaded runs provisional) and this script as the source.

Planned examples, and the work to optimise each first-pass baseline, are
tracked in the project's issue tracker.
