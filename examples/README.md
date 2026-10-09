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
elixir examples/geo_nearest.exs     # one example
elixir examples/run_all.exs         # all of them + scoreboard (exit 1 if any claim fails)
```

## Measuring correctly

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
   - `Defk.Bench` forces a full GC before each timed run, so one run's garbage isn't billed to the next.
5. **"As good" means Elixir wins.** Below the 2× bar (`marginal`), the recommendation is Elixir: the gain doesn't pay for native code.
6. **Keep the poor fits.** Examples where Elixir wins are as valuable as the wins. They tell people what not to do.

## Where defk helps

Loops over numbers or bytes, where the data is already packed, or is packed
once and reused.

| Example | Real-world job | defk vs Elixir | Elixir baseline |
|---|---|---|---|
| [`rolling_stats.exs`](rolling_stats.exs) | Moving mean/stddev over 1M sensor readings | 149–178× (≈30× on arithmetic alone; the rest is Elixir materialising 2M floats as lists) | first pass: **provisional** |
| [`geo_nearest.exs`](geo_nearest.exs) | 10 nearest of 500k locations (haversine) | 12–13× | first pass: **provisional** |
| [`image_blur.exs`](image_blur.exs) | Grayscale + 3×3 box blur on a raw 1080p frame | 37–41× | first pass: **provisional** |
| [`fft.exs`](fft.exs) | Radix-2 FFT of a 2^20-point signal; direct convolution of 2 s of 48 kHz audio with a 64-tap FIR | FFT 63–91× (62× at n = 4096); convolution 28–38×; bit-exact with Elixir. Nx `binary` backend is slower than pure Elixir here; EXLA not measured | optimised (4 FFT variants, 2 convolution variants) |
| [`fuzzy_search/`](fuzzy_search) (app) | Typo-tolerant search service: Levenshtein over 234k words behind Plug + Bandit | 4.2× per query with the early cut-off on both sides (noisy-machine numbers, re-measure pending); before the cut-off 6.2× req/s, 5.4× lower p99 under load; `/health` latency stays at Elixir levels (a blocking NIF pushes it to ~80–90 ms p99). Elixir with Myers bit-parallel comes within ~1.3× of the DP kernel; defk can't express it until `defk-w38` | first pass: **provisional** |
| [`image_ops.exs`](image_ops.exs) | Bilinear resize 1080p to 480x270, RGB to YUV420, Floyd-Steinberg dither on raw 1080p frames (the script reports three verdicts; `run_all` shows the resize one) | resize ~12×, YUV420 14–18×, dither 21–26×; bit-exact with Elixir. libvips (SIMD) not compared; expected to win resize | optimised (3, 3 and 2 variants) |
| [`sort_u64_keys.exs`](sort_u64_keys.exs) | Sort 1M random i64 keys that arrive as a packed binary (heapsort kernel vs decode + `:lists.sort`) | `sort_packed` 4.3–5.3× when the result stays packed; `sort_to_list` 2.3–2.7× when the caller needs a list (decode cost included). The script prints two `DEFK_RESULT` lines; `run_all.exs` reads the first (`sort_packed`) and the script checks the second itself | optimised (`:lists.sort`, `Enum.sort`) |
| [`per_pair_distance.exs`](per_pair_distance.exs) | Levenshtein for 50k short string pairs, one kernel call per pair (ex_strsim's API shape) | 3.2–3.4× at 8–16 bytes; 1.1–1.2× at 4 bytes (stay in Elixir below ~8 bytes). Expected poor, measured good: a quadratic DP outweighs the call cost. Batching from a *list of pairs* is slower than per-pair (packing); batching pays only from an already-packed blob (4.2–4.6× at 4 bytes). | optimised |
| [`monte_carlo_rtp.exs`](monte_carlo_rtp.exs) | Slot RTP certification run: 100M spins of a 5-reel, 10-line slot on all schedulers, reel stops from `:rand`'s exsss | 3.2–3.3× at 100M spins (2.9× at 10M, ~1× at 1M where the kernel tasks stay on 2–3 schedulers); 5.3× on one scheduler. The kernel matches `:rand` bit for bit (draws, floats, the `uniform_s/2` redraw), so totals equal Elixir's exactly | optimised (4 variants, incl. exsss inlined in Elixir) |
| [`geohash_crc.exs`](geohash_crc.exs) | Geohash encode/decode of 100k points (packed f64 columns, fixed-width hashes) beside CRC-16/CCITT-FALSE and CRC-64/XZ of 1 and 16 MB buffers. Five `DEFK_RESULT` lines in the order geohash_encode, geohash_decode, crc16, crc64, geohash_encode_single; `run_all` reads the first | encode 7.3-7.5x, decode 10.2-10.5x (both sides use quantise-and-bit-spread; the bisecting Elixir and the `geohash` package are 8x slower than the baseline); CRCs only 1.65-1.8x (marginal, see below); one point per call 0.77-0.85x (poor, a batch of 10 breaks even) | optimised (bisecting vs quantised Elixir; CRC-64 as one integer vs two 32-bit halves) |
| [`codecs.exs`](codecs.exs) | base64, hex and base58 encode + decode round trips (fast64, b64fast, ex_base58 territory); three `DEFK_RESULT` lines, `run_all.exs` reads the first (base64) and the script checks the other two | base64 at 1 MB 2.9–3.0× over `Base` (2–2.5 GB/s; 2.1× faster than the fast64 C NIF; 2.6–3.4× from 64 KB to 16 MB); hex 2.02–2.04× over `:binary.encode_hex/decode_hex`, at the 2× line (encode alone 1.5×: use the BIF); base58 2.6–2.7× on 10k 32-byte keys per call, but one key per call is no faster than Elixir (1.04 vs 0.94 µs) | optimised (`Base`, `:base64`, `:binary`, b58, erl_base58, a 58^9-chunk bignum) |
| [`hashes.exs`](hashes.exs) | xxHash64, Murmur3 x64_128 and SipHash-2-4 that must match other systems, vs the murmur, xxhash and siphash packages (four reports; `run_all` shows xxHash64) | xxHash64 90–101× and Murmur3 133–145× on a 4 MB message (10 and 8 GB/s; Elixir is bignum-bound at 0.06–0.12 GB/s), 19–25× on 1k 32-byte keys; SipHash 77–89× on 1k keys, level with siphash's C NIF (0.96–1.0×) and 1.36× ahead of it at 4 MB. `:erlang.phash2` 2.5 GB/s for comparison (not portable) | optimised (xxhash and siphash's fallback each beaten by a rewrite, murmur kept) |

These numbers will shrink as the Elixir baselines are optimised; that's
expected and is the point. Each example's header lists what hasn't been
tried yet.

## Target workloads in progress

[`one_brc/`](one_brc/) is the One Billion Row Challenge (parse `<station>;<temp>\n` lines, min/mean/max per station), **baseline only, kernel pending (defk-n4r.6)**. `gen.exs` writes a deterministic file outside the repo (`$ONE_BRC_FILE`, default `/tmp/one_brc/measurements.txt`); `elixir.exs` is the pure-Elixir baseline, marked **optimised**: five variants measured at 10M and 100M rows, fastest `Task.async_stream` over `:file.pread` chunks with an `:atomics` accumulator, 1.66 s for 100M rows (1.4 GB) on 12 schedulers, checked against an independent Enum reference (`--check`). It is not run by `run_all.exs` (a directory) and does not call `Defk.Bench.report` yet.

## Where Elixir is the right choice

| Example | The trap | defk vs Elixir | Elixir baseline |
|---|---|---|---|
| [`poor_list_data.exs`](poor_list_data.exs) | Data arrives as a list (Ecto rows, JSON); packing it costs more than Elixir's whole `Enum.sum` | 0.35–0.37× (≈3× slower) | optimised |
| [`poor_tiny_calls.exs`](poor_tiny_calls.exs) | One kernel call per element inside `Enum.map`; the call overhead exceeds the work | 0.38–0.43× | optimised |
| [`out_of_scope_word_count.exs`](out_of_scope_word_count.exs) | Strings in, a map out; kernels can't build BEAM terms, and the compiler refuses | not expressible | n/a |
| [`poor_substring_search.exs`](poor_substring_search.exs) | Find a 64-byte needle in a 16 MB binary with a Horspool kernel; `:binary.match/2` is already Boyer-Moore in C (multi-pattern: `:binary.matches/2` with a compiled pattern) | 1.03–1.11× (marginal; found and absent alike, 7 GB/s each side) | optimised |
| [`utf8_valid.exs`](utf8_valid.exs) | Validate a 16 MB UTF-8 binary with a Hoehrmann DFA kernel, as bandit_native wraps simdutf8 to do; `String.valid?/1` and `:unicode.characters_to_binary/1` are C already (a SIMD validator is a wrapper job) | 1.05–1.09× at 16 MB (marginal; 0.57 vs 0.52 GB/s, `String.valid?` 0.27 GB/s); 0.6× at 64 KB, 0.0 vs 0.002 ms at 1 KB (call cost) | optimised |
| [`geohash_crc.exs`](geohash_crc.exs) (CRC lines) | CRC-16/CCITT-FALSE and CRC-64/XZ of a 1 MB and 16 MB binary with a table-driven kernel, as device protocols and archive formats do; the `crc` package is a C NIF and `:erlang.crc32/1` (zlib, another polynomial) is a BIF | crc16 1.6-1.85x, crc64 1.65-1.8x over the best Elixir (about 300 vs 500 MB/s); the kernel is only 1.0-1.4x the `crc` NIF; `:erlang.crc32` is 100x faster than both (0.03 ms per MB) | optimised (CRC-64 in two 32-bit halves; a single integer goes bignum, 10x slower) |
| [`hashes.exs`](hashes.exs) (CRC32C) | CRC32C of a 4 MB message, as crc32cer does for Kafka; the values are 32-bit, so Elixir stays in small integers and the JIT runs slicing-by-8 at 1.6 GB/s | 1.39–1.65× at 4 MB (marginal, same slicing-by-8 on both sides); 0.5× on 1k keys; crc32cer (hardware CRC32C) is 14× faster than the kernel, `:erlang.crc32` (another polynomial) 40 GB/s. Use crc32cer | optimised |
| [`matmul.exs`](matmul.exs) | Dense matrix multiply, 256x256 f64 (64 to 1024 swept), the job Nx exists for: defk is 25x over the best pure Elixir, but Nx's binary backend is itself Elixir (~210x slower than defk, 8x slower than plain lists) and EXLA's BLAS (did not compile here, not measured) is expected to win; for tensor work use Nx, defk fits a custom loop beside it | 17–38× vs Elixir; 210× vs Nx binary backend | optimised |

Also not what defk is for (no script needed):

- **Wrapping an existing native library** (codecs, crypto, databases): use Rustler, Zigler or an existing binding.
- **Tensor and ML work**: use Nx, which compiles to XLA or LibTorch. [`matmul.exs`](matmul.exs) (defk-9p6.3) measures where the boundary lies.
- **I/O-bound work**: native code doesn't make the network faster.

Numbers are from an M-series Mac (OTP 29, Elixir 1.20); ranges cover the runs so far.
The scoreboard, not these tables, is the source of truth: rerun `run_all.exs`.

## Where a wrapper is the right choice

Nothing here is excluded on principle: each row names the condition that would reopen it. The from-scratch epic `defk-52v` tracks what we do rewrite.

| Job | Wrapped today | Why not from scratch | What would change it |
|---|---|---|---|
| Signing, key exchange, secret-dependent crypto (secp256k1, ed25519, X25519, AEAD) | libsodium, secp256k1, ring via Rustler; `:crypto` | The one rule says nothing about timing: clang `-O3` may turn a select into a branch or a table lookup into a secret-dependent access, and a process dump or yielded frame holds key material. Public-input verification is allowed but gains little. | A constant-time mode: a restricted subset checked at compile time, codegen verified with dudect or ctgrind in CI, frame zeroisation, and an external audit. Until then, `:crypto`. |
| Parsers that produce trees or term streams (HTML, Markdown, tree-sitter, JSON/CSV to terms, protobuf, msgpack) | html5ever, comrak, tree-sitter, jsont, rusty_csv, protox | The product is BEAM terms and building them is the cost: `docs/research/string-workloads.md` measured a 13x gap between scanning and term creation, and a NIF builds terms serially at the same price. A kernel cannot build terms, and if it could it would be no faster. | A "tape" output (flat `[i64]` of kind/start/len events, `defk-9p6.21` is the fused CSV form), plus a benchmark showing tape plus Elixir tree building beats Jason or NimbleCSV end to end. BPE tokenisation to `[i64]` ids is the exception: its product is packed. |
| Regular expressions | `:re` (PCRE in C), Rust regex via Rustler | `:re` is already native and compiled once per pattern; a kernel cannot take a pattern as data without becoming an interpreter, and fixed-string search is `:binary.match`. | A specific pattern class with a known kernel form (glob, or a simple byte DFA compiled at Elixir compile time) and a benchmark showing `:re` loses on it. |
| Large codecs and encoders (brotli, zstd encode, audio and video, PDF/typst rendering) | brotli, zstd, membrane_* FFmpeg/opus bindings, typst | The cost is spec surface and tuning, not the loop: 10^4-10^5 lines with SIMD everywhere. A kernel would be a worse implementation of a solved problem. | A narrow, named need: one compression level with fixed tables (zstd level 1 is the lz4-encode ticket plus FSE) or a decoder-only requirement for untrusted input. Each reopens one row, not the category. |
| Systems: databases, dataframes, tensor compilers (SQLite, DuckDB, Polars/Explorer, XLA/EXLA, LibTorch) | exqlite, duckdbex, explorer, exla, torchx | The value is the library: query planners, columnar engines, autodiff, device backends. defk is a kernel, not a system. | Interop, not rewriting: zero-copy views over their packed buffers so a per-element loop beside them runs as a kernel. `docs/research/nx-boundary.md` says where that line is; file an interop ticket when a workload asks. |
| Kernel-owned mutable state (SortedSet, in-place sketches, streaming decoders) | sorted_set_nif, xxh3 streaming, zstd streaming | A semantics question, not a rewrite one: ADR-0001 keeps state as values. | The design review of the kernel-owned-state epic (`defk-sve`). |

The verdict's Limitations (`defk-sgw.5`) will cite this table.

## How verdicts work

Every script ends with `Defk.Bench.report/1`, which:

- checks that the Elixir and defk results agree,
- takes the best of several timed runs for each side, measured end to end,
- prints a `DEFK_RESULT` JSON line, including the baseline status.

The verdict comes from the measurement and is a recommendation:

| Verdict | Rule | Recommendation |
|---|---|---|
| `good` | defk ≥ 2× faster than the Elixir baseline | defk helps, **once** the baseline is `optimized` |
| `marginal` | 1×–2× | use Elixir |
| `poor` | defk slower | use Elixir |
| `out_of_scope` | can't be written as a kernel | use Elixir |

Target workloads add optional keys to `report/1`. None of them changes the verdict, and
scripts that do not pass them need no change:

| Key | Reports (JSON keys) |
|---|---|
| `native: {fun, "pkg x.y.z"}` | the anchor package's NIF, timed like the other sides: `native_ms`, `native_label`, `native_speedup` (defk against the NIF) |
| `responsiveness: true` (or `[elixir: f, defk: f, native: f]`) | max and p99 gap of a 1 ms ticker on one scheduler while each side runs once (`Defk.Bench.TickGap`, the `bench/tick_gap.exs` method): `elixir_gap_ms`, `defk_gap_ms`, `native_gap_ms`, each `{max, p99}` |
| `realistic_size: "n = 4096"` | the size the anchor package is really called with, which the verdict is measured at: `realistic_size` |
| `sweep: [{label, elixir_fun, defk_fun}]` or `{sizes, fn size -> {elixir_fun, defk_fun} end}` | best-of (`sweep_runs`, default 3) per-size times and speedups, and the `crossover`: the first size where defk is at least 2x, or `null` |

`elixir examples/run_all.exs` prints these on a second line per example, and
`--snapshot` adds the results as a markdown table for the "Workload results"
section of `docs/verdict.md`.

Each example also declares the verdict it **expects**. `run_all.exs` fails if an
example is incorrect, crashes, or measures a different verdict than it claims,
and it lists every `good` claim whose baseline is still provisional.

Both directions of change are progress:

- An optimised Elixir baseline turns a `good` into `marginal`: we learned Elixir is enough.
- A defk improvement turns a `poor` into a `good`: defk now helps.

Either way the catalog gets updated.

## Adding an example

1. Copy [`_template.exs`](_template.exs) to `examples/<use_case>.exs` (files starting with `_` are skipped by the runner).
2. Describe the real job and why people reach for a NIF, in the header.
3. Write the Elixir version, then optimise it as far as you can. Note in the header what you tried and what you haven't yet.
4. Give both versions the same input, in the form a real caller would have.
5. Call `Defk.Bench.report/1` with the `expected` verdict, the `baseline` status and a one-sentence `reason`.
6. Run `elixir examples/run_all.exs` and add a row to the right table above.

Planned examples, and the work to optimise each first-pass baseline, are
tracked as children of epic `defk-9p6` (`bw show defk-9p6`).
