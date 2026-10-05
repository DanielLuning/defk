# Which jobs do people write NIFs for today?

Ticket: defk-dtw.1. Researched 2026-10-05.

## Question

Survey real NIF code and group it into workload categories. For each: representative
packages, data shapes, call pattern, scheduler behaviour, and why the author went
native. Separate "wraps an existing native library" (defk can't help) from "a
hand-written algorithm" (defk might). End with a ranked list of target workloads.

## Method and sources

- **Hex.pm dependents API** (primary): the packages that depend on `rustler`,
  `rustler_precompiled`, `zigler`, `elixir_make`, `cc_precompiler`, `bundlex` and
  `unifex`, sorted by all-time downloads (`https://hex.pm/api/packages?search=depends:hexpm:<dep>&sort=downloads`).
  That is about 600 distinct packages. The top 200 of each list were read by description.
- **Package source** (primary): the release tarballs of about 55 packages were fetched
  from `repo.hex.pm` and read: their native sources, `Cargo.toml` dependencies,
  `ErlNifFunc` tables / `#[rustler::nif(schedule = ...)]` attributes, and READMEs. A
  script counted dirty-scheduler annotations, `enif_schedule_nif` and
  `enif_consume_timeslice`. Every "wraps X" / "hand-written" verdict below comes from the
  package's own `[dependencies]` or C sources, not from its description alone.
- **First-party write-ups**: the Discord SortedSet blog post, the ERTS `erl_nif` manual,
  and ElixirForum threads.

Download counts are Hex all-time totals as of 2026-10-05.

## Headline findings

1. **Most NIFs wrap a library.** Of the top 50 Rustler dependents by downloads, at most 3
   contain an algorithm their author wrote: `sorted_set_nif`, `evil_crc32c`, and the
   JSON codec `jsont`, which drives `serde_json`. The other 47 bind an existing crate
   (Polars, mrml, html5ever, tokenizers, tiny-keccak, secp256k1, comrak, tree-sitter,
   brotli, typst ...). The `elixir_make` list is the same story: bcrypt and argon2
   (vendored reference C), libvips, SQLite, DuckDB, XLA, OpenCV, libsodium, plus Nerves
   hardware access (GPIO, I2C, UART). defk cannot help with any of these.
2. **The hand-written algorithms are a long tail of small packages**, mostly
   10^3–10^5 downloads. They cluster into a few shapes, and the shape most of them share
   is defk's: **a loop over a packed binary that returns a number or a new binary.**
3. **Many simple hand-written NIFs ignore scheduling.** The work grows with the input,
   yet `evil_crc32c`, `bandit_native` (WebSocket masking), `ex_strsim`, `spirit_fingers`,
   `ex_keccak`, `ex_base58` and Membrane's audio mixer all run on normal schedulers with
   no size limit. The careful authors build their own workarounds:
   - `ex_data_sketch` keeps two NIF variants per function and switches to the dirty one
     above 10,000 items.
   - `ecsv` cuts its input into blocks sized to "10-15% of timeslice" and calls
     `enif_consume_timeslice`.
   - `gorilla_stream`, `rusty_csv` and `vettore` mark everything `DirtyCpu`.

   defk's automatic yielding replaces all of these, and this is its clearest selling
   point in the survey.
4. **Several hand-written NIFs ship with a pure Elixir version next to them.** That gives
   defk a ready-made Elixir baseline, as the project's Elixir-first rule requires:
   - Bandit's `ws_mask` is a pluggable `primitive_ops_module`, with `bandit_native` as the
     NIF version.
   - Membrane's `Adder`/`ClipPreventingAdder` sit next to `NativeAdder`.
   - `ex_data_sketch` has `Backend.Pure` next to `Backend.Rust`.
   - `gorilla_stream` falls back to "Pure-Elixir encode".
5. **The main gaps for defk are bitwise operators and narrower element types.** Almost
   every top candidate below needs `band`/`bor`/`bxor`/`bsl`/`bsr` (CRC, masking,
   pixel packing, hash-bucket splitting, bit-packing). Many also need `[f32]`, `[i16]` or
   `[i32]` views (audio samples, embeddings, image tensors) or unsigned 64-bit hashes.
   defk has none of these today (README, "Language").

## Categories

Each category says whether its packages **wrap** an existing library or are
**hand-written**.

### A. Byte-buffer transforms and checksums (hand-written): best fit

| Package | Downloads | What | Native code |
|---|---|---|---|
| [evil_crc32c](https://github.com/ayrat555/evil_crc32c) | 38k | CRC32C / CRC16 of a binary | 66 lines of Rust, no crate: bit-at-a-time loop |
| [bandit_native](https://github.com/moogle19/bandit_native) | 3.6k | RFC 6455 WebSocket masking (XOR with a 4-byte key), UTF-8 validation | 28 lines; `mask` is hand-written, UTF-8 uses `simdutf8` |
| [cvt_color](https://github.com/cocoa-xu/cvt_color) | small | RGB888 → RGB565/666 for Nerves displays | about 200 lines of C++, optional OpenMP |
| [dither](https://github.com/protolux-electronics/dither) | 0.7k | dithering for e-paper | wraps the `dither` crate, but the algorithm is a short error-diffusion loop |
| [image_qrcode](https://github.com/elixir-image/image_qrcode) | 0.4k | QR encode/decode | vendored quirc and nayuki C (a wrapper) |

- **Shape:** binary in, binary or integer out. The output is often the same length as the
  input.
- **Call pattern:** one call per payload (a frame, a packet, an image). Payloads range from
  bytes (WebSocket frames) to megabytes (images).
- **Scheduling:** `evil_crc32c` and `bandit_native` run on normal schedulers with no size
  limit. `cvt_color` marks its NIF `ERL_NIF_DIRTY_JOB_IO_BOUND`, although the work is
  CPU-bound.
- **Why native:** speed. Elixir has to rebuild the binary with bitstring matching. Bandit's
  default implementation (`Bandit.PrimitiveOps.WebSocket.ws_mask/2`) is a recursive
  `<<h::32, rest::binary>>` loop using `Bitwise.bxor`. Bandit made masking a pluggable
  behaviour so that a NIF could be swapped in.
- **defk fit:** high. This is defk's existing `[u8]` → `alloc`'d `[u8]` shape. It is
  blocked only by the missing bitwise operators. Small payloads need care: defk's call
  costs about 12 ns against 1.6 ns for an Elixir call.

### B. Numeric arrays: signal, audio, vectors, geometry (mostly hand-written)

| Package | Downloads | What | Native code |
|---|---|---|---|
| [membrane_audio_mix_plugin](https://github.com/membraneframework/membrane_audio_mix_plugin) | 58k | mixes N PCM buffers with clipping prevention | 350 lines of hand-written C via Unifex; the Elixir `Adder` sits next to it (`native_mixer: false` is the default) |
| [vettore](https://github.com/elchemista/vettore) | 9.5k | vector search | hand-written SIMD distance kernels (`distances.rs`: L2, cosine, inner product, Hamming ...) plus HNSW; 59 dirty NIFs |
| [postdnn](https://github.com/shoz-f/postdnn) | 1.3k | non-max suppression on detector output | hand-written C++ over f32 box/score binaries |
| [scenic_math](https://github.com/boydm/scenic_math) | 1.7k | 4×4 matrix and 2D line math for the Scenic UI | hand-written C over small f32 binaries |
| [matrex](https://github.com/versilov/matrex) | 56k | matrix library | hand-written C plus CBLAS `sgemm`; now superseded by Nx |
| [gorilla_stream](https://github.com/awksedgreep/gorilla_stream), [ex_alp](https://github.com/awksedgreep/ex_alp) | 2.4k / 3.8k | float time-series compression | Gorilla/Chimp is hand-written C++ (1,458 lines, `DIRTY_JOB_CPU_BOUND`); ALP vendors the reference implementation |

- **Shape:** packed numeric binaries (f32, i16/i32 PCM, f64), sometimes lists of
  `{ts, float}` tuples (`gorilla_stream` walks a list with `enif_get_list_cell`).
- **Call pattern:**
  - Membrane mixes one buffer per chunk (milliseconds of audio): many medium calls with
    state carried between them.
  - `scenic_math` makes many tiny calls. This is a likely defk loss, as with the
    one-kernel-call-per-element case in the README.
  - Vector search and compression make one big call.
- **Why native:** speed, plus mutation in place. The ElixirForum thread
  ["Can Nx replace Rust for number crunching?"](https://elixirforum.com/t/can-nx-replace-rust-for-number-crunching/59786)
  is exactly this case: immutable array updates in loops. The replies point at Nx/EXLA,
  which itself is native.
- **defk fit:** high for the loop-shaped ones (the mixer, distances, NMS, rolling stats),
  which is already defk's sweet spot. Blockers:
  - no `[f32]`, `[i16]` or `[i32]` element types (audio and embeddings are rarely f64);
  - Membrane's mixer keeps a queue in a resource between calls;
  - Nx is the Elixir-side competitor for dense linear algebra, so leave matrix
    multiplication to Nx.

### C. Probabilistic sketches and batched hashing (hand-written)

| Package | Downloads | What | Native code |
|---|---|---|---|
| [ex_data_sketch](https://github.com/thanos/ex_data_sketch) | 1.2k | HLL, ULL, CMS, Theta, KLL, Bloom, Cuckoo, XOR filter ... | hand-written Rust (only `xxhash-rust`, `rand`); a pure Elixir backend implements the same algorithms |
| [spirit_fingers](https://github.com/holsee/spirit_fingers) | 6.8k | SimHash plus Hamming distance | about 150 lines of hand-written Rust over `siphasher` |
| [bloom_filter_ex](https://github.com/aspett/bloom_filter_elixir) | 10k | Bloom filter | wraps `fastbloom` |

- **Shape:** the sketch state is a binary (16 KiB of registers for p = 14). Items come as a
  list of terms, or as a binary of pre-hashed u64s.
- **Call pattern:** batches. `ex_data_sketch` chunks `update_many/2` at 10,000 items and
  deliberately does not accelerate single-item `update/2`: "fixed overhead of ~200 ns ...
  dominates the actual register write (~30 ns)"
  ([hll_performance guide](https://github.com/thanos/ex_data_sketch/blob/main/guides/hll_performance.md)).
- **Scheduling:** a normal NIF below the threshold and a `DirtyCpu` twin above it (51
  `DirtyCpu` annotations in the package).
- **Why native:** speed. The guide reports "Pure HLL caps at ~2 M items/sec while Rust HLL
  exceeds 30 M items/sec", and blames per-item allocation of hashes and tuples.
  `spirit_fingers` reports being "400-900x faster" than Elixir/Erlang SimHash.
- **defk fit:** medium-high, and a good test of the automatic-yield claim, since it would
  remove the normal/dirty split. It needs:
  - bitwise operators and leading-zero count;
  - u64 hash arithmetic, i.e. wrapping instead of defk's checked i64;
  - a hash function such as xxh3/murmur3 written as a kernel;
  - hashing of arbitrary terms stays in Elixir, i.e. defk's "path 2", pre-hashed binary
    in.

### D. String distance and fuzzy matching (crate wrappers over short algorithms)

| Package | Downloads | Native code |
|---|---|---|
| [ex_strsim](https://hex.pm/packages/ex_strsim) / [strsim](https://hex.pm/packages/strsim) | small | wraps the `strsim` crate (Levenshtein, Jaro-Winkler, Damerau ...) |
| [fuzler](https://hex.pm/packages/fuzler) | small | 766 lines of Rust over `triple_accel` (SIMD Levenshtein) plus Jaccard and partial-ratio |
| [aho_corasearch](https://hex.pm/packages/aho_corasearch), [aho_corasick_nif](https://github.com/morgahl/aho_corasick_nif) | 51k / 34k | wrap `daachorse` / `aho-corasick` (automaton held in a resource) |

- **Shape:** two strings in, a number out. The strings are UTF-8, and the crates work on
  `char`s.
- **Call pattern:** often one call per candidate pair, which is many small calls.
- **Scheduling:** `ex_strsim` runs on normal schedulers with unbounded string length;
  `fuzler` uses dirty schedulers.
- **Why native:** speed. The algorithms are short, so they count as "wrappers" only by
  convenience.
- **defk fit:** medium. defk already has a Levenshtein fuzzy-search example over `[u8]`.
  Limits:
  - byte-level only, so no grapheme or codepoint semantics;
  - the per-pair call pattern hits defk's boundary cost. The batch form (one query
    against N candidates, packed) is where defk wins.

### E. Mutable data structures held across calls (hand-written or crate)

[sorted_set_nif](https://github.com/discord/sorted_set_nif) (Discord, 308k), `trie_hard`,
`ex_rstar` (wraps `rstar`), `bloom_filter_ex`, `aho_corasick_nif`.

- **Shape:** a resource handle plus terms; many small calls.
- **Why native:** O(log n) in-place mutation of a large structure. Discord measured
  insertion into 250k items at 170,000 µs for a list wrapper, 27,000 µs for ordsets and
  640 µs for an OrderedSet, against 3.68 µs worst case for the Rust SortedSet at 1M items
  ([Discord blog](https://discord.com/blog/using-rust-to-scale-elixir-for-11-million-concurrent-users)).
- **defk fit:** low. defk has no persistent mutable state between calls, and each call is
  tiny. This is out of scope unless defk adds resource-backed arrays.

### F. Parsers, codecs and serialisers producing BEAM terms (mixed)

- **JSON:** `jsonrs` (335k, `serde_json`), `jsont` (140k), `jaxon` (1.3M, hand-written C
  event parser), `jason_native`.
- **CSV:** `rusty_csv` (hand-written SIMD Rust, all `DirtyCpu`), `ecsv` (hand-written C,
  manual timeslice chunking).
- **Base58/Bech32:** `ex_base58`, `ex_bech32`, which wrap crates.

**Shape:** binary in, nested lists, maps or tuples of sub-binaries out. **Why native:**
speed. `rusty_csv` says "Pure Elixir parsing, while well-optimized, can't match native
code with SIMD acceleration" and returns sub-binaries that reference the input. The
counter-evidence is the ElixirForum thread
["Rust NIFs can slow down Elixir"](https://elixirforum.com/t/rust-nifs-can-slow-down-elixir/24870):
a 6 µs Elixir function became 60–160 µs as a NIF, because of term encoding.

**defk fit:** low. Output terms (maps, lists, strings) are not expressible in defk. A
possible later niche is the *scanning* half: a kernel that returns an `[i64]` index of
delimiter offsets, with Elixir building the sub-binaries.

### G. Wraps an existing native library: defk can't help

This is the bulk of the survey by package count and by downloads.

| Category | Packages (downloads) |
|---|---|
| Password hashing / crypto | `bcrypt_elixir` (54M), `argon2_elixir` (8.7M), `ex_keccak` (1.3M, `tiny-keccak`), `ex_secp256k1`, `libsalty2`, `blake3`, `ex_pbkdf2`; all hashing ones run on dirty CPU schedulers |
| Media and imaging | `vix`/`image` (libvips, 2M/1.5M), `evision` (OpenCV), `stb_image`, Membrane codecs (FFmpeg, Opus, FDK-AAC, x264), `turbojpeg`, `resvg` |
| Data and ML | `explorer` (Polars, 2.3M), `exla`/`xla`, `tokenizers`, `ortex`, `exgboost`, `hnswlib`, `tsne`, `leidenfold` |
| Databases | `exqlite` (3M), `duckdbex`, `adbc`, `rox` (RocksDB), `ecto_libsql` |
| Docs and markup | `mjml` (1.6M), `mdex_native`, `lazy_html` (lexbor), `html5ever`, `typst`, `cmark`, syntax highlighting (`lumis`, tree-sitter) |
| Compression | `nimble_lz4`, `ex_brotli`, `r_zstd`, `bzip2`, `xz` |
| Embedded runtimes | `pythonx`, `wasmex`, `deno_rider`, `quickbeam` (Zig) |
| System and hardware access | `circuits_gpio`/`i2c`/`uart`/`spi`, Nerves, `expty`, `exile`, `muontrap`, `wireguardex` |

Why native: an existing, large, well-tested library, or OS/hardware access. These often
release the scheduler through dirty NIFs or threads, because the library's loop is not
theirs to instrument.

## Ranked candidates for defk

Ranked by (fits defk's model) × (evidence that people need it) × (an Elixir baseline to
measure against).

| Rank | Workload | Evidence | Elixir baseline | What defk needs |
|---|---|---|---|---|
| 1 | **Byte transforms over binaries**: WebSocket masking, CRC32C/CRC16, pixel format conversion, XOR/obfuscation | `bandit_native` (pluggable `primitive_ops_module`), `evil_crc32c`, `cvt_color`; none of them yields | Bandit's own `ws_mask/2`; bitstring comprehensions; `:erlang.crc32` covers CRC32 but not CRC32C | bitwise ops (`band`/`bor`/`bxor`/`bsl`/`bsr`); byte-wise or 32-bit-word reads from `[u8]` |
| 2 | **PCM audio mixing / gain / clipping** | Membrane `NativeAdder` vs `Adder`/`ClipPreventingAdder`, the same algorithm in both languages | the Membrane Elixir adders | `[i16]`/`[i32]`/`[f32]` views, or decoding from `[u8]` with shifts; output carried over between calls stays in Elixir |
| 3 | **Batched sketch / hash updates** (HLL, CMS, Bloom over pre-hashed u64s) | `ex_data_sketch` (normal/dirty threshold switch, 2M vs 30M items/s), `spirit_fingers` | `ExDataSketch.Backend.Pure` | bitwise ops, leading-zero count, wrapping u64 arithmetic; the state binary in as `[u8]` and out as a new `alloc` |
| 4 | **Vector kernels**: distances, top-k over embedding matrices, NMS | `vettore` `distances.rs`, `postdnn`; defk's "nearest of 500k" example | `Nx` on the binary backend; plain Elixir | `[f32]`; otherwise already expressible |
| 5 | **Batch string distance** (one query against N packed candidates) | `ex_strsim`, `fuzler`, defk's fuzzy-search example | the Elixir Levenshtein in `examples/` | already works on `[u8]`; per-pair calls should stay in Elixir |
| 6 | **Time-series encode / stats** (delta, XOR-float, rolling windows) | `gorilla_stream` (hand-written plus a pure Elixir fallback), `timeless_metrics`, defk's "rolling sensor statistics" example | `gorilla_stream`'s pure encoder | bitwise ops; reading float bit patterns (`f64` ↔ `i64` reinterpretation); variable-length bit output is hard |
| — | Not targets: persistent data structures (E), term-producing parsers (F), library wrappers (G), tiny per-frame math (`scenic_math`, where call overhead dominates) | | | |

## Gaps to raise as follow-up tickets

1. **Bitwise operators** (`Bitwise.band/bor/bxor/bsl/bsr/bnot`). These unblock ranks 1, 3
   and 6.
2. **More element types:** `[f32]` (embeddings, ML tensors, audio), `[i16]`/`[i32]` (PCM),
   possibly `[u16]`/`[u32]`. Or a reinterpreting read from `[u8]`.
3. **Unsigned / wrapping 64-bit arithmetic** for hashes. This conflicts with defk's checked
   i64 overflow, so it would need an explicit opt-in.
4. **Show the yield story against real dirty-scheduler code.** Every candidate above
   either blocks a normal scheduler or hand-rolls chunking or a dirty twin. A demo on
   `ex_data_sketch`'s HLL or Bandit's mask, with tick-gap numbers, would make the case.

## Sources

- Hex.pm API, dependents by downloads: `https://hex.pm/api/packages?search=depends:hexpm:rustler&sort=downloads` (also `rustler_precompiled`, `zigler`, `elixir_make`, `cc_precompiler`, `bundlex`, `unifex`)
- Package tarballs from `https://repo.hex.pm/tarballs/<name>-<version>.tar`, read for the packages linked above. Key files:
  - `evil_crc32c/native/evil_crc32c/src/lib.rs`
  - `bandit_native/native/bandit_native/src/lib.rs`
  - `bandit/lib/bandit/primitive_ops/websocket.ex`
  - `membrane_audio_mix_plugin/c_src/membrane_audio_mix_plugin/mixer.c`
  - `membrane_audio_mix_plugin/lib/membrane_audio_mixer.ex` (the `native_mixer` option)
  - `ex_data_sketch/guides/hll_performance.md`
  - `ex_data_sketch/lib/ex_data_sketch/backend/rust.ex`
  - `ecsv/src/ecsv.erl` (lines 230–232)
  - `gorilla_stream/c_src/gorilla_nif.cpp`
  - `cvt_color/c_src/cvt_color.cpp`
  - `vettore/native/vettore/src/distances.rs`
  - `rusty_csv/README.md`
  - `spirit_fingers/README.md`
- ERTS manual, erl_nif ("return to its caller within 1 millisecond"; yielding vs threaded vs dirty NIFs): https://www.erlang.org/doc/apps/erts/erl_nif.html
- Discord, "Using Rust to Scale Elixir for 11 Million Concurrent Users": https://discord.com/blog/using-rust-to-scale-elixir-for-11-million-concurrent-users
- ElixirForum, "Rust NIFs can slow down Elixir": https://elixirforum.com/t/rust-nifs-can-slow-down-elixir/24870
- ElixirForum, "Can Nx replace Rust for number crunching?": https://elixirforum.com/t/can-nx-replace-rust-for-number-crunching/59786

## Limits

- Only Hex packages were surveyed in depth. Private and in-house NIFs (likely more
  hand-written loops) are not visible.
- GitHub code search and ElixirForum "a NIF for X" threads were sampled, not searched
  exhaustively.
- The "wrapper vs hand-written" split was checked from source for about 55 packages. For
  the rest it is inferred from Cargo dependencies or the description.
