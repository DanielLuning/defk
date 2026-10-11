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
   - `Defk.Bench` forces a full GC before each timed run, so one run's garbage isn't billed to the next.
5. **"As good" means Elixir wins.** Below the 2× bar (`marginal`), the recommendation is Elixir: the gain doesn't pay for native code.
6. **Keep the poor fits.** Examples where Elixir wins are as valuable as the wins. They tell people what not to do.
7. **Give each parallel kernel call a few milliseconds of work, or fewer, bigger chunks.** The BEAM wakes an idle scheduler when a crowded run queue has run enough reductions. A kernel charges one timeslice (4000 reductions) per 250 µs, while Elixir uses that many in about 5 µs. So kernel tasks under ~1 ms that one process spawns (`Task.async_stream` chunks) stay on 2–4 of 12 schedulers, while Elixir tasks of the same length spread over all 12 (`defk-8qs`). Chunks of ~5 ms spread (monte_carlo_rtp at 10M spins: 48 chunks on 11–12 schedulers). Starting every chunk at once also spreads: 48 short kernel tasks via `Task.async` + `Task.await_many` (or plain `spawn`) ran on 11 schedulers, against 3 under `Task.async_stream` with `max_concurrency: 12`. If the work can't be split that coarsely, `+swt very_low` (`elixir --erl "+swt very_low"`) spreads the short calls: batched_levenshtein's 12 chunks went from 5.1–5.6 to 2.3–2.5 ms and monte_carlo_rtp at 1M from 16.7 to 7.7 ms, while the Elixir chunks did not change (measured under load). Report the verdict on a default VM and give the flag's number beside it. Runtime options are in `defk-6lr`.

## Where defk helps

Loops over numbers or bytes, where the data is already packed, or is packed
once and reused.

| Example | Real-world job | defk vs Elixir | Elixir baseline |
|---|---|---|---|
| [`rolling_stats.exs`](rolling_stats.exs) | Moving mean/stddev over 1M sensor readings, result as one packed binary (means then stddevs) | 5.0–7.8× parallel vs parallel (12 chunks each, Elixir 10.8–11.7 ms vs defk 1.5–2.3 ms; **provisional, measured under load**); one process / one call ~34× (65 vs 1.9 ms). The first-pass float lists were 100–308 ms (172×). Packed binary accumulation, 4 windows per step and 12 scheduler chunks account for the drop; still above 2×, but a supporting example that does not count towards the verdict | optimised (7 variants: lists, lists + iodata pack (3× worse), binary accumulators, batch of 4, 4 or 12 chunks) |
| [`geo_nearest.exs`](geo_nearest.exs) | 10 nearest of 500k locations (haversine) | 3.2–3.9× over the best Elixir (parallel chunks on all schedulers, early exit, one interleaved binary: 4.7 ms vs defk 1.2 ms); 14× over the same Elixir in one process. Coarse-grid prefilter on both sides (algorithm change, exact): Elixir 0.14 ms, defk 0.017 ms (8×) | optimised (8 variants; packed column binaries slower than tuples) |
| [`image_blur.exs`](image_blur.exs) | Grayscale + 3×3 box blur on a raw 1080p frame | **provisional (measured under load):** 3.8–4.2× with both sides in 12 row bands (Elixir 9.1–9.9 ms vs defk 2.3–2.5 ms, one `Task.async` per band; 5.6× with `+swt very_low`, defk 1.7 ms). One process against one call: 26–29× (141–160 vs 5.5 ms). Both sides use the sliding/separable sum; was 37–41× against the 9-reads-per-pixel first pass (~800 ms). Bit-exact | optimised (3 variants: first pass, three-row walk, walk on bands; separable 16-bit rows, list/iodata output lose) |
| [`fft.exs`](fft.exs) | Radix-2 FFT of a 2^20-point signal; direct convolution of 2 s of 48 kHz audio with a 64-tap FIR | FFT 63–91× (62× at n = 4096); convolution 28–38×; bit-exact with Elixir. Nx `binary` backend is slower than pure Elixir here; EXLA not measured | optimised (4 FFT variants, 2 convolution variants) |
| [`fuzzy_search/`](fuzzy_search) (app) | Typo-tolerant search service: Levenshtein over 234k words behind Plug + Bandit | 4.2× per query with the early cut-off on both sides (noisy-machine numbers, re-measure pending); before the cut-off 6.2× req/s, 5.4× lower p99 under load; `/health` latency stays at Elixir levels (a blocking NIF pushes it to ~80–90 ms p99). Elixir with Myers bit-parallel comes within ~1.3× of the DP kernel; defk can run Myers too now (bitwise ops, defk-w38): see [`batched_levenshtein.exs`](batched_levenshtein.exs), where Myers on both sides leaves defk 2.4–2.8× ahead in one process but level with Elixir chunked over all schedulers | first pass: **provisional** |
| [`image_ops.exs`](image_ops.exs) | Bilinear resize 1080p to 480x270, RGB to YUV420, Floyd-Steinberg dither on raw 1080p frames (the script reports three verdicts; `run_all` shows the resize one) | resize ~12×, YUV420 14–18×, dither 21–26×; bit-exact with Elixir. libvips (SIMD) not compared; expected to win resize | optimised (3, 3 and 2 variants) |
| [`sort_u64_keys.exs`](sort_u64_keys.exs) | Sort 1M random i64 keys that arrive as a packed binary (heapsort kernel vs decode + `:lists.sort`) | `sort_packed` 4.3–5.3× when the result stays packed; `sort_to_list` 2.3–2.7× when the caller needs a list (decode cost included). The script prints two `DEFK_RESULT` lines; `run_all.exs` reads the first (`sort_packed`) and the script checks the second itself | optimised (`:lists.sort`, `Enum.sort`) |
| [`per_pair_distance.exs`](per_pair_distance.exs) | Levenshtein for 50k short string pairs, one kernel call per pair (ex_strsim's API shape) | 3.2–3.4× at 8–16 bytes; 1.1–1.2× at 4 bytes (stay in Elixir below ~8 bytes). Expected poor, measured good: a quadratic DP outweighs the call cost. Batching from a *list of pairs* is slower than per-pair (packing); batching pays only from an already-packed blob (4.2–4.6× at 4 bytes). | optimised |
| [`monte_carlo_rtp.exs`](monte_carlo_rtp.exs) | Slot RTP certification run: 100M spins of a 5-reel, 10-line slot on all schedulers, reel stops from `:rand`'s exsss | 3.2–3.3× at 100M spins (2.9× at 10M, ~1× at 1M where the kernel tasks stay on 2–3 schedulers); 5.3× on one scheduler. The kernel matches `:rand` bit for bit (draws, floats, the `uniform_s/2` redraw), so totals equal Elixir's exactly | optimised (4 variants, incl. exsss inlined in Elixir) |
| [`geohash_crc.exs`](geohash_crc.exs) | Geohash encode/decode of 100k points (packed f64 columns, fixed-width hashes) beside CRC-16/CCITT-FALSE and CRC-64/XZ of 1 and 16 MB buffers. Five `DEFK_RESULT` lines in the order geohash_encode, geohash_decode, crc16, crc64, geohash_encode_single; `run_all` reads the first | encode 7.3-7.5x, decode 10.2-10.5x (both sides use quantise-and-bit-spread; the bisecting Elixir and the `geohash` package are 8x slower than the baseline); CRCs only 1.65-1.8x (marginal, see below); one point per call 0.77-0.85x (poor, a batch of 10 breaks even) | optimised (bisecting vs quantised Elixir; CRC-64 as one integer vs two 32-bit halves) |
| [`codecs.exs`](codecs.exs) | base64, hex and base58 encode + decode round trips (fast64, b64fast, ex_base58 territory); three `DEFK_RESULT` lines, `run_all.exs` reads the first (base64) and the script checks the other two | base64 at 1 MB 2.9–3.0× over `Base` (2–2.5 GB/s; 2.1× faster than the fast64 C NIF; 2.6–3.4× from 64 KB to 16 MB); hex 2.02–2.04× over `:binary.encode_hex/decode_hex`, at the 2× line (encode alone 1.5×: use the BIF); base58 2.6–2.7× on 10k 32-byte keys per call, but one key per call is no faster than Elixir (1.04 vs 0.94 µs) | optimised (`Base`, `:base64`, `:binary`, b58, erl_base58, a 58^9-chunk bignum) |
| [`hashes.exs`](hashes.exs) | xxHash64, Murmur3 x64_128 and SipHash-2-4 that must match other systems, vs the murmur, xxhash and siphash packages (four reports; `run_all` shows xxHash64) | xxHash64 90–101× and Murmur3 133–145× on a 4 MB message (10 and 8 GB/s; Elixir is bignum-bound at 0.06–0.12 GB/s), 19–25× on 1k 32-byte keys; SipHash 77–89× on 1k keys, level with siphash's C NIF (0.96–1.0×) and 1.36× ahead of it at 4 MB. `:erlang.phash2` 2.5 GB/s for comparison (not portable) | optimised (xxhash and siphash's fallback each beaten by a rewrite, murmur kept) |
| [`keccak.exs`](keccak.exs) | Ethereum Keccak-256 of 10k 32-byte messages per call (addresses, transactions), and one 16 MB message; :crypto has no Keccak-256 | 8.3x batch, 5x one call per message, 10.6x at 1 KB, 13x at 16 MB. ex_keccak (tiny-keccak NIF) is 1.7x faster on the batch (0.59x, per-message overhead) and level at 16 MB (20.7 vs 19.1 ms, under load; 28 ms before defk-zep's spill fix) but blocks its scheduler ~20 ms on 16 MB where the kernel yields. Bit-exact with ex_keccak, :crypto and the FIPS 202 vectors | optimised (ex_sha3, 64-bit lanes, 32-bit halves: the halves are 20x faster than 64-bit lanes) |
| [`blake.exs`](blake.exs) | BLAKE2b-512 (RFC 7693, keyed) and BLAKE3 from scratch for content hashing and dedup, at one 64 KB message (64 MB and 1 KB swept), vs blake2_elixir (reference C NIF), blake3 (Rust NIF, NEON) and the pure-Elixir blake2 and b3 packages; three `DEFK_RESULT` lines (blake = BLAKE2b, blake_crypto, blake3), `run_all` reads the first | **provisional (measured under load, load 13-135):** BLAKE2b 31.8-32.7x at 64 KB (Elixir 1.37-1.43 ms vs defk 0.042-0.049 ms, 1.5 GB/s), 32.5-33.3x at 64 MB, 21-22x at 1 KB; level with blake2_elixir's reference C (1.02x) and 1.16-1.19x over `:crypto` (see below). BLAKE3 10.6-10.9x at 64 KB (0.56-0.65 vs 0.054-0.059 ms), 10.1x at 64 MB; level with BLAKE3's portable C (52 us at 64 KB), 0.6x of the NEON NIF. Tick gap (64 MB): both NIFs block 34-49 ms, kernels 2.1-2.7 ms. RFC 7693 and official BLAKE3 vectors pass; equal to `:crypto`, both NIFs, blake2 and b3 on 661 random messages | optimised (BLAKE2b: blake2 package, 64-bit words, 32-bit halves 10x faster; BLAKE3: b3 package, a struct-free rewrite 5-10% faster) |
| [`hll_update_many.exs`](hll_update_many.exs) | Fold 100k pre-hashed u64s into a p = 14 HyperLogLog sketch, as ex_data_sketch 0.10.3's backend `hll_update_many` does (Pure and Rust NIF backends); the caller's list is packed end to end | 9.2–9.4× at 100k (Elixir 3.4–3.5 ms vs defk 0.36–0.38 ms, of which the kernel is 0.07 ms and the pack the rest; 3.2× when a GC copy of the caller's list lands in the run); 10–15× at 100 hashes (0.020 vs ~0.002 ms); 12–17× from 1k to 31k. The Rust NIF is 2.55–2.8 ms (defk 6.9–7.4×), 2.3 ms of it its Enum.map + iodata pack; fed defk's packer it is 0.46 ms, level with defk. Tick gaps ~2 ms for all three (the floor; NIF dirty above 10k). State byte-identical across Elixir, defk and the NIF. **Provisional, measured under load** | optimised (9 variants: top-down rank, sorted keys + splice below 5k, `:atomics` + one rebuild from 5k; `:array`, tuple, bit-syntax update, parallel tasks lose) |
| [`pcm_mix.exs`](pcm_mix.exs) | Mix N PCM streams with clip prevention (scale each overflowing half-wave down at its zero crossings), Membrane's ClipPreventingAdder job, at N = 4 streams of 48 kHz stereo s16le in 10 ms chunks; two `DEFK_RESULT` lines (10 ms, then 1 s chunks), `run_all` reads the first | **provisional (measured under load, quiet run defk-sgw.4):** 5.4-6.6x at 10 ms chunks (Elixir 2.6-2.7 ms vs defk 0.41-0.49 ms per 1 s of audio), 6.6-8.5x at 1 s chunks, 2.8-3x at 1 ms; the plugin's own Elixir is ~20 ms. NativeAdder (C, unifex) 0.72-0.75 ms: defk 1.5-1.8x faster at 10 ms, 1.9-2.5x at 1 s. Tick gap (60 s in 1 s chunks): Elixir 3.2-5.6 ms, defk 2.2 ms, NativeAdder 41-43 ms (back-to-back NIF calls never preempted). Byte-identical across all four (s16le and s32le, 144 cases). The kernel's sum loop keeps a bounds check (defk-siy) | optimised (6 variants: fused scan with appended output, ~7-12x the plugin) |
| [`gorilla_encode.exs`](gorilla_encode.exs) | Gorilla compression (delta-of-delta timestamps, XOR of float bits) of a list of `{ts, float}`, gorilla_stream's job, at 100-point blocks (1,000 series per run, one call each); two `DEFK_RESULT` lines (100-point blocks, then one 1M-point series), `run_all` reads the first | **provisional (measured under load, quiet run defk-sgw.4):** 1.96-2.38x at 100-point blocks (Elixir 4.6-5.1 ms vs defk 2.1-2.45 ms per 1,000 blocks; close to the bar, one run of eight marginal: the shared header and CRC32 code and packing the list weigh at this size), 3.1-3.4x at 1M points (42-44.5 vs 12.6-14.6 ms; packing the list is half of defk's time); sweep 2.3-4.7x from 100 to 1M-point blocks, crossover 100. gorilla_stream's own `encode_elixir` is 5x (blocks) to 8x (1M) slower than the optimised Elixir. Its C++ NIF (built from source on OTP 29, dirty CPU) 6.0-7.2 / 31.5-33.3 ms: defk 2.75-2.9x and 2.3-2.5x faster. Tick gaps (1M points) all at the loaded ~2 ms floor. Byte-identical (creation time zeroed) across `encode_elixir`, 6 variants, the NIF and defk on 53 series | optimised (6 variants: 32-bit halves with table zero counts, appended bitstrings, word buffer, two passes, packed layout) |
| [`lz4_snappy_decode.exs`](lz4_snappy_decode.exs) | Snappy and LZ4 block decode from scratch on untrusted input (Kafka batches, RocksDB/LevelDB blocks, caches) at a 64 KB JSON-like block (4 KB to 4 MB swept, five data kinds), vs snappyer (snappy C++) and lz4_erl (liblz4 1.7.5), nimble_lz4 (lz4_flex) beside; two `DEFK_RESULT` lines (snappy_decode, lz4_block_decode), `run_all` reads the first | **provisional (measured under load, load 24-85):** Snappy 2.8-3.1x at 64 KB (Elixir 0.19-0.20 ms vs defk 0.063-0.072 ms; one run at load 71-85 measured 1.3x, marginal), 2.25-3.3x from 4 KB to 4 MB; LZ4 3.5-3.6x at 64 KB (0.25-0.26 vs 0.070-0.075 ms), 2.8-8x swept. Against the NIFs as installed from Hex (built -O0: rebar3's `pc` adds no `-O`) defk is 1.3-1.6x faster; against the same libraries built -O2/-O3 (`LZ_NIF_OPT=1`) it is 0.36x (snappy) and 0.11x (liblz4), and 0.3x of nimble_lz4: not parity (a checked store per byte, `defk-52v.16`). Incompressible blocks: Elixir wins (a sub-binary of the input, no copy). Tick gap (4 MB): lz4_erl 5-11 ms, defk and snappyer (dirty) at the ~2 ms floor. Safety: 20 corpus blocks from four encoders byte-identical; 6,000 fuzz inputs (random and mutated) under forced yields agree with Elixir mode and the Elixir decoder, every rejection the kernels' own `ArgumentError`, VM never down (fault containment `defk-7dm` not done: the checks are what keep it up) | optimised (3 variants per format: byte-by-byte matches, `binary_part` copies 3-4x faster, positional input slower) |
| [`byte_histogram.exs`](byte_histogram.exs) | Byte histogram (256 counts) of a 16 MB binary, and the Shannon entropy of every 4 KiB window (binwalk -E, file-type sniffing, "is this block compressible or encrypted?"); two `DEFK_RESULT` lines (byte_histogram, windowed_entropy), `run_all` reads the first | **provisional (measured under load, load 12-31):** histogram 5.5-6.6x parallel vs parallel (12 chunks each, Elixir 8.7-10.9 ms vs defk 1.40-1.71 ms); one process vs one call 11.4-12.7x (43-47 vs 3.6-3.8 ms, 0.39 vs 4.6 GB/s), 19-28x from 4 KB to 64 KB. Entropy 6.7-10.2x parallel vs parallel (12.5-18.6 vs 1.83-2.0 ms), 17.0-17.9x one process vs one call (82-89 vs 4.7-5.2 ms). Histograms exact, entropies bit for bit (`log2` on both sides) | optimised (14 histogram variants: `Enum.frequencies`, `Map.update`, a tuple, `:binary.matches` per value, `:counters`/`:atomics` at 1 and 8 bytes per step, 16-bit pairs into `:atomics` (best, 2.4x faster than 8-byte `:counters` steps), shared `:counters`, chunks; 8 entropy variants incl. a term table) |

These numbers will shrink as the Elixir baselines are optimised; that's
expected and is the point. Each example's header lists what hasn't been
tried yet.

## Target workloads in progress

[`one_brc/`](one_brc/) is the One Billion Row Challenge (parse `<station>;<temp>\n` lines, min/mean/max per station), **baseline only, kernel pending (defk-n4r.6)**. `gen.exs` writes a deterministic file outside the repo (`$ONE_BRC_FILE`, default `/tmp/one_brc/measurements.txt`); `elixir.exs` is the pure-Elixir baseline, marked **optimised**: five variants measured at 10M and 100M rows, fastest `Task.async_stream` over `:file.pread` chunks with an `:atomics` accumulator, 1.66 s for 100M rows (1.4 GB) on 12 schedulers, checked against an independent Enum reference (`--check`). It is not run by `run_all.exs` (a directory) and does not call `Defk.Bench.report` yet. [`one_brc/rustler.exs`](one_brc/rustler.exs) (with the Mix project `one_brc/rustler/`, Rust 1.94.1, rustler 0.37.4) is the hand-written-NIF comparison: the same chunking and output code driving a Rustler `aggregate(chunk)` (std `HashMap<&[u8], Stats>`, integer x10 parse, returns `{name, min, max, sum, count}` tuples), as a plain NIF and as `schedule = "DirtyCpu"`; both match the Elixir reference (`--check`, two seeds). End to end (12 schedulers, loaded machine, best of 3): plain NIF 67 ms / 760 ms at 10M / 100M rows, DirtyCpu 34 ms / 318 ms, against the Elixir `par_map` 342 ms / 3535 ms. Tick gap (1 ms ticker, one scheduler, 100M rows): Elixir `par_map` 13.3 ms max (p99 2.2), plain NIF 55 ms, DirtyCpu 5.6 ms (p99 2.2).

## Where Elixir is the right choice

| Example | The trap | defk vs Elixir | Elixir baseline |
|---|---|---|---|
| [`poor_list_data.exs`](poor_list_data.exs) | Data arrives as a list (Ecto rows, JSON); packing it costs more than Elixir's whole `Enum.sum` | 0.35–0.37× (≈3× slower) | optimised |
| [`poor_tiny_calls.exs`](poor_tiny_calls.exs) | One kernel call per element inside `Enum.map`; the call overhead exceeds the work | 0.38–0.43× | optimised |
| [`ws_masking.exs`](ws_masking.exs) | Small WebSocket frames (125 B, the largest 7-bit length; Bandit 1.12.5's `ws_mask/2`, with defk packaged as a `primitive_ops_module`, Bandit's real plug-in point, vs bandit_native 0.1.2's Rust NIF: Jan 2023, byte at a time, normal scheduler, unused by current Bandit): the call costs more than the XOR. From 1 KiB defk is good; two `DEFK_RESULT` lines (125 B, then 1 MiB), `run_all` reads the first | **provisional (measured under load, quiet run defk-sgw.4):** 125 B frames 1.18-1.31x (marginal: Elixir 158 ns per frame vs defk 134 ns, the NIF 141 ns; the call is the cost, keep Bandit's default for small frames); 1 MiB 18.8-18.9x (good: 513 vs 27 us per frame, 2 vs 38 GB/s; NIF 548 us, 20x slower than defk); sweep 1.25-1.31x at 125 B, 4.8-5.1x at 1 KiB (crossover), 9-10x at 8 KiB, 14x at 64 KiB, 18-19x at 1 MiB, 23x at 16 MiB. Tick gap (one 16 MiB frame, one scheduler): Elixir 2.0-2.1 ms, defk 0.44-0.66 ms, NIF 8.9-9.0 ms (one uninterrupted call). Bytes identical across Elixir, defk, NIF and Bandit's own `Frame.deserialize/2` | optimised (9 variants: 64-bit words, comprehension, whole-integer XOR and `:crypto.exor/2` all tried; only `:crypto.exor/2` with a doubled key beats the anchor, from ~600 B, so the baseline is a hybrid) |
| [`out_of_scope_word_count.exs`](out_of_scope_word_count.exs) | Strings in, a map out; kernels can't build BEAM terms, and the compiler refuses | not expressible | n/a |
| [`poor_substring_search.exs`](poor_substring_search.exs) | Find a 64-byte needle in a 16 MB binary with a Horspool kernel; `:binary.match/2` is already Boyer-Moore in C (multi-pattern: `:binary.matches/2` with a compiled pattern) | 1.03–1.11× (marginal; found and absent alike, 7 GB/s each side) | optimised |
| [`utf8_valid.exs`](utf8_valid.exs) | Validate a 16 MB UTF-8 binary with a Hoehrmann DFA kernel, as bandit_native wraps simdutf8 to do; `String.valid?/1` and `:unicode.characters_to_binary/1` are C already (a SIMD validator is a wrapper job) | 1.05–1.09× at 16 MB (marginal; 0.57 vs 0.52 GB/s, `String.valid?` 0.27 GB/s); 0.6× at 64 KB, 0.0 vs 0.002 ms at 1 KB (call cost) | optimised |
| [`geohash_crc.exs`](geohash_crc.exs) (CRC lines) | CRC-16/CCITT-FALSE and CRC-64/XZ of a 1 MB and 16 MB binary with a table-driven kernel, as device protocols and archive formats do; the `crc` package is a C NIF and `:erlang.crc32/1` (zlib, another polynomial) is a BIF | crc16 1.6-1.85x, crc64 1.65-1.8x over the best Elixir (about 300 vs 500 MB/s); the kernel is only 1.0-1.4x the `crc` NIF; `:erlang.crc32` is 100x faster than both (0.03 ms per MB) | optimised (CRC-64 in two 32-bit halves; a single integer goes bignum, 10x slower) |
| [`hashes.exs`](hashes.exs) (CRC32C) | CRC32C of a 4 MB message, as crc32cer does for Kafka; the values are 32-bit, so Elixir stays in small integers and the JIT runs slicing-by-8 at 1.6 GB/s | 1.39–1.65× at 4 MB (marginal, same slicing-by-8 on both sides); 0.5× on 1k keys; crc32cer (hardware CRC32C) is 14× faster than the kernel, `:erlang.crc32` (another polynomial) 40 GB/s. Use crc32cer | optimised |
| [`keccak.exs`](keccak.exs) (second `DEFK_RESULT`) | SHA3-256 from scratch, when `:crypto.hash(:sha3_256, m)` is OpenSSL in C | 0.71x on 10k x 32 B (0.5x one call each, 0.72x at 16 MB); the same kernel is 7x pure Elixir, but pure Elixir is not the Elixir answer here | optimised (`:crypto`) |
| [`blake.exs`](blake.exs) (blake_crypto) | BLAKE2b-512 from scratch, when `:crypto.hash(:blake2b, m)` is OpenSSL's portable C | 1.16-1.19x at 64 KB and 64 MB, 1.0x at 1 KB (marginal: 0.042-0.049 vs 0.050-0.064 ms); the same kernel is 32x pure Elixir, but `:crypto` is the Elixir answer for BLAKE2b (BLAKE3 is not in OpenSSL). **Provisional, measured under load** | optimised (`:crypto`) |
| [`batched_levenshtein.exs`](batched_levenshtein.exs) | One query's Levenshtein distance to all 234k words of a dictionary, as ex_strsim (Rust strsim NIF) is batched with `Enum.map`. Myers bit-parallel Levenshtein runs in plain Elixir on small integers, 10x faster than the DP, and splits across schedulers; the kernel's chunks stay on 2 of 12 schedulers (`defk-8qs`) | 0.86–0.99× at 234k words (Elixir 3.8–4.2 ms vs defk 4.3–4.6 ms, both Myers in 12 chunks; poor or a 1.0× marginal, use Elixir); in one process 2.4–2.8× (16–18 vs 6.6 ms) and 2.9–4× at 1k words (0.07 vs 0.025 ms). ex_strsim per pair 35–38 ms, 2.2× slower than one-process Elixir Myers; tick gaps ~2 ms for all three. Distances identical to ex_strsim. **Provisional, measured under load** | optimised (DP variants, Myers on binaries/charlists/comprehension, branch-free score, chunks) |
| [`matmul.exs`](matmul.exs) | Dense matrix multiply, 256x256 f64 (64 to 1024 swept), the job Nx exists for: defk is 25x over the best pure Elixir, but Nx's binary backend is itself Elixir (~210x slower than defk, 8x slower than plain lists) and EXLA's BLAS (did not compile here, not measured) is expected to win; for tensor work use Nx, defk fits a custom loop beside it | 17–38× vs Elixir; 210× vs Nx binary backend | optimised |
| [`cosine_topk.exs`](cosine_topk.exs) | Semantic search: cosine top-10 of a query against 100k resident 384-dim f32 embeddings (vectors pre-normalised on every side, so a dot product), vs vettore 0.3.5's flat index and Nx | 5.3–7.3x at 100k (Elixir 48–57 ms in 12 chunks vs defk 7.2–9.6 ms in 12 chunks; defk in one call 21 ms, held back by `defk-8qs`), 10–12x at 1k (0.23 ms; 5.7x over Elixir float lists in shard processes, the best Elixir there); sweep 3.9–12x, crossover at 1k. vettore (DirtyCpu, one thread) 12.7 ms with an inner-product index, 34 ms with `flat_new_cosine`. **Nx + EXLA 0.13.1 is 6–8x faster than defk (1.0–1.2 ms): for a plain dot-product top-k use Nx with EXLA**; Nx BinaryBackend 14–15 s. Tick gaps ~2 ms on every side. Same indices everywhere, Elixir and defk scores bit-identical, others within 2e-6. **Provisional, measured under load** | optimised (f32/f64 binaries, 1 vs 8 per match, tuples, float lists in `:persistent_term` and in shard processes, sort vs bounded top-k, 1–24 chunks) |
| [`hash_chain.exs`](hash_chain.exs) | Provably-fair RNG verification: a 10M-step SHA-256 hash chain from a server seed, and HMAC-SHA256(server seed, client seed:nonce) for 1M nonces, with a portable-C SHA-256 kernel; `:crypto` is OpenSSL on the CPU's SHA-256 instructions. Two `DEFK_RESULT` lines; `run_all` reads the chain | chain 0.57-0.58x (poor: 175-178 vs 100-104 ns per step, flat from 1k to 10M steps); HMAC 1.3-1.47x (marginal; 2.5x only against `:crypto.mac` per round, whose key setup costs more than RFC 2104 by hand with two `:crypto.hash` calls). Use `:crypto`; the seed is secret until revealed (see the crypto row below) | optimised (`Enum.reduce`, tail recursion, hash contexts; `:crypto.mac`, hash contexts, two `:crypto.hash` calls) |

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
5. Compile the kernels with `use Defk, elixir_mode: true` and check in the script that each agrees with its Elixir mode (`Mod.__defk_elixir__(name, args)` against the native call, on small and bad inputs). The option works in a `Mix.install` script; the default call path stays native, so timing is unaffected.
6. Call `Defk.Bench.report/1` with the `expected` verdict, the `baseline` status and a one-sentence `reason`.
7. Run `elixir examples/run_all.exs` and add a row to the right table above.
8. Add or update the entries in [`docs/performance.md`](../docs/performance.md) for what you learned, including what didn't help: the numbers, the conditions (size, load: mark loaded runs provisional) and this script as the source.

Planned examples, and the work to optimise each first-pass baseline, are
tracked as children of epic `defk-9p6` (`bw show defk-9p6`).
