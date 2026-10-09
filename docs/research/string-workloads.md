# Which text and byte-processing jobs push Elixir developers to NIFs?

Ticket: defk-dtw.20. Researched 2026-10-09.

## Question

defk is "Elixir over numbers and binaries". A UTF-8 string is already a `[u8]`, so
byte-level text work is in reach, but the subset has no bitwise operators, no sub-array
views, no word loads, no growable output and no hash table except over `alloc`'d arrays.
Before planning text support (the 1BRC epic, `defk-n4r`), survey the string and
byte-processing jobs Elixir developers write NIFs for today, and what each needs from the
kernel subset: the anchor packages with download counts, hand-written or wrapped native
code, input and output shapes, realistic input size, the pure-Elixir baseline and its speed,
and the subset additions named against existing tickets. End with a ranked list, the
out-of-scope cases, and the minimal ordered set of additions that unlocks the top three.

## Method and sources

- **Hex.pm API** (primary): `https://hex.pm/api/packages/<name>` for all-time download
  counts and latest versions, read on 2026-10-09 for the 60 packages named below, plus
  `https://hex.pm/api/packages?search=<q>&sort=downloads` for "utf8 nif", "base64 nif",
  "hash nif", "csv nif", "sort nif", "search nif", "trigram" and "hex encode" to find
  anchors the ticket did not list (`crc32cer`, `fast64`, `b64fast`, `jchash`, `trigram`).
  Every count below is from that API; `murmurhash3`, `ex_siphash`, `simdutf8`,
  `fast_base64`, `wyhash`, `cityhash` and `ex_hashids` returned 404 and are not cited.
- **Package tarballs** (primary): `https://repo.hex.pm/tarballs/<name>-<version>.tar` for
  29 packages, unpacked and read: native sources, `Cargo.toml` dependencies,
  `#[rustler::nif(schedule = ...)]` / `ErlNifFunc` flags, `enif_consume_timeslice`,
  `enif_make_sub_binary`, and the Elixir side next to the NIF. Every "hand-written" or
  "wraps X" verdict comes from that source, not the description.
- **Erlang docs** (primary): the `binary` module, `erl_nif`, and `erlang:phash2/crc32`.
- **1BRC** (primary): the challenge README and the two Elixir Forum threads, fetched as
  Discourse JSON so posts could be quoted exactly.
- **This repo**: CONTEXT.md, README.md, examples/README.md, and the tickets `defk-w38`,
  `defk-cmr`, `defk-gqk`, `defk-ivt`, `defk-4ai`, `defk-auo`, `defk-n4r.2..5`, read with
  `bw show`.

**Measured vs quoted.** Package authors' numbers are *quoted* and marked so. The only
numbers *measured* here are the pure-Elixir/BIF baselines in the "Elixir baseline" columns,
from a 40-line script run once on an M-series Mac (OTP 29, Elixir 1.20.2, single runs,
noisy machine, `scratchpad/baselines.exs`, not committed). They are order-of-magnitude
guides for choosing workloads, not catalog measurements; a catalog entry re-measures under
`Defk.Bench` with an optimized baseline.

## Headline findings

1. **The BEAM already does the scan.** `:binary.match/matches/split` are Boyer-Moore and
   Aho-Corasick in ERTS C and ran at 0.5–10 GB/s here; `:erlang.crc32` at ~39 GB/s;
   `:unicode.characters_to_binary` validated UTF-8 at ~2 GB/s; `:binary.encode_hex` at
   ~1.1 GB/s. A kernel that only *finds* delimiters or *validates* bytes competes with a
   BIF and will land `marginal` or `poor`. The docs say so: "The functions in this module
   are highly optimized and are expected to either execute faster or consume less memory,
   or both, compared to equivalent implementations written in pure Erlang"
   (https://www.erlang.org/doc/apps/stdlib/binary.html).
2. **The cost Elixir pays is per-element term creation, not scanning.** On a 2M-row
   1BRC-style input, scanning every byte for `;` with binary matching ran at ~500 MB/s and
   `:binary.split` by newline at ~620 MB/s, but the full split-parse-`Map.update`
   aggregate ran at ~45 MB/s. The 13× gap is sub-binary creation, `Map.update` and tuple
   rebuilding per row. That is the gap a kernel removes, and only when it also *consumes*
   the fields: hashes the key, parses the number, updates a packed table. The 1BRC
   community numbers (60 s to 25 s for 13 GB, below) are this gap on all cores.
3. **Codecs and hashes are where hand-written NIFs cluster.** `fast64` (541k downloads)
   and `b64fast` (272k) are hand-written C base64 with `enif_consume_timeslice` chunking;
   `siphash` (224k) is a 108-line C NIF next to an Elixir fallback; `evil_crc32c`,
   `spirit_fingers`, `trigram` are hand-written loops. `crc32cer` (48.5M) wraps Google's
   SIMD crc32c. Two popular hashes stayed pure Elixir and say so: `murmur` (2.4M) and
   `xxhash` (205k, whose README says "You should consider creating a NIF of xxHash if you
   require a high performance version"). These are defk's shape: `[u8]` in, number or
   fixed-length `[u8]` out, no terms per element.
4. **Parsers that return terms are out of reach, and their authors already minimise
   term cost.** `rusty_csv` (7,861 lines of Rust) scans with SIMD then has the main thread
   build sub-binary terms, "Env is not thread-safe, so term construction is serial";
   `jsont` and `jaxon` return `enif_make_sub_binary` slices; `ecsv` copies each field with
   `enif_make_new_binary`. A kernel cannot make a sub-binary or a map, so full CSV/JSON
   parsing, tokenisation to lists, and sort/dedup that returns binaries are out of scope.
   The scanning half (offsets out as `[i64]`) is expressible but only pays when the
   consumer is also a kernel (finding 1).
5. **Every text workload needs the same four additions, in the same order**: bitwise
   operators (`defk-w38`), then constants (`defk-ivt` / `defk-n4r.5`), word loads with
   wrapping u64 arithmetic (`defk-n4r.2`), and writable array parameters in helper kernels
   (`defk-n4r.4`). Sub-array views (`defk-n4r.3`) are needed by 1BRC alone among the top
   three. No workload below needs a map type, a string type, or Unicode semantics.
6. **The yield story is as strong as in the numeric survey.** `fast64` and `b64fast`
   hand-roll `enif_consume_timeslice` + `enif_schedule_nif` chunking; `ecsv` cuts input
   into 20 kB blocks sized to "10-15% of timeslice"; `rusty_csv`, `jsont`, `jsonrs`,
   `fuzler` and `trigram` batch calls mark everything `DirtyCpu`; `crc32cer` ships `nif`
   and `nif_d` twins; `siphash`, `ex_base58`, `evil_crc32c`, `bandit_native`, `xxh3` run
   unbounded on normal schedulers. defk's automatic yielding replaces all of these.

## Categories

Download counts are Hex all-time totals on 2026-10-09. "Elixir baseline" is what the
BEAM offers without a NIF, with this survey's single-run measurement where one was taken.

### A. 1BRC-style parse-and-aggregate (no package; the community did it by hand)

The challenge: ~13 GB of `<station>;<temperature>\n`, one billion rows, station names
"UTF-8 strings ranging from 1 to 100 bytes maximum, excluding semicolons and newline
characters", temperatures "between -99.9 and 99.9 (inclusive), always displaying exactly
one decimal place", "Maximum of 10,000 unique station names"; output min/mean/max per
station sorted by name (https://github.com/gunnarmorling/1brc, README). The reference
machine is "eight cores of a Hetzner AX161 dedicated server (32 core AMD EPYC 7502P)";
the top Java entry took 1.535 s with a GraalVM native image and `Unsafe`.

Elixir Forum numbers, all quoted (https://forum.elixirforum.com/t/60974 and /t/69585):

| Who | Quoted | Technique |
|---|---|---|
| blubparadox (rrcook/brc) | no time posted; README: `File.stream` "only used 8 of 16 processors", so switched to `prim_file` block reads with `read_line` to finish a cut line, and a worker pool | `prim_file`, worker pool, maps |
| stevensonmt | "130 seconds for 50M lines" → "around 95 seconds for 50M lines" (ETS `set` instead of `ordered_set`) → "consistently under 50sec for the 50M rows" by matching lines "as binaries based on the expected length of the city name"; "14yo i5 4 core machine" | ETS, binary patterns by name length, `Float.parse` |
| garazdawi | "an Erlang implementation that does 1B lines in 60 seconds on my slow laptop" (jesperes/erlang_1brc PR 1) | Erlang, binary matching |
| tj0 | Explorer: "Lazy (f32): 53575.23ms" for 1B lines (eager f64 675 s) | Polars via Explorer (native) |
| Raj Rajhans, Code BEAM Europe 2024 | "code that initially took over 10 minutes ... went down to just 25 seconds" (talk title: "From 12 Minutes to 25 Seconds"; no hardware in the thread) | profiling, concurrency modelling |

- **Shape:** `[u8]` chunk in (Elixir splits the file by byte offset and aligns to `\n`);
  out: a tuple of packed arrays, the open-addressing table (`[i64]` slots, `[u8]` key
  arena, `[i64]` min/max/sum/count columns). Elixir merges per-chunk tables and formats.
- **Realistic size:** 1B rows / 13 GB for the verdict; 100M rows for development
  (`defk-n4r`). One kernel call per 8–64 MB chunk.
- **Elixir baseline (measured, 2M rows, 32 MB, one core):** byte scan for `;` via binary
  matching 505 MB/s; `:binary.split(bin, "\n", [:global])` 621 MB/s;
  split + fixed-point parse + `Map.update` 45 MB/s (2.8M rows/s). At that rate 13 GB is
  ~290 s on one core, ~36 s on 8, consistent with the quoted 25–60 s. The optimized
  baseline is `defk-n4r.1`'s job.
- **Needs:** `defk-w38` (bitwise for hashing and SWAR delimiter finding); `defk-n4r.2`
  (word loads + wrapping u64: FNV/xxh-style name hash, 8-byte-at-a-time `;` search);
  `defk-n4r.3` (sub-array view for the name range, to compare against the arena and pass
  to a helper); `defk-n4r.4` (an `insert(table, arena, stats, ...)` helper that writes
  its caller's `alloc`'d arrays); `defk-n4r.5` or `defk-ivt` only for literal names in
  tests (`?;` and `?\n` already work as integer literals). A byte-range compare is a loop
  over two slices; no new builtin. The hash table is three `alloc`'d arrays; no new type.

### B. Base64, hex and base58 codecs (hand-written, chunked by hand)

| Package | Downloads | What | Native code |
|---|---|---|---|
| [fast64](https://github.com/bancolombia/fast64_elixir) | 541k | base64 encode/decode | 580 lines of C; `encode64_chunk`/`decode64_chunk` re-scheduled with `enif_consume_timeslice` + `enif_schedule_nif`; README: "20x faster than Elixir default implementation" (quoted) |
| [b64fast](https://github.com/zuckschwerdt/b64fast) | 272k | base64 for Erlang | 222 lines of C, same chunking ("won't block the Erlang scheduler. It also doesn't need a dirty scheduler by breaking large amounts of data into chunks") |
| [ex_base58](https://github.com/ayrat555/ex_base58) | 156k | base58 with Bitcoin/Ripple/Monero/Flickr alphabets, optional checksum | 148 lines of Rust over the `bs58` crate; normal scheduler, no size limit; alphabet passed as a `String` |
| [erl_base58](https://github.com/helium/erl-base58), [b58](https://github.com/dwyl/base58), [base58](https://github.com/jrdnull/base58) | 416k / 307k / 32k | base58 | pure Erlang / Elixir (no native code in the tarballs) |
| [base64url](https://github.com/dvv/base64url), [base16](https://github.com/esl/base16) | 43.1M / 3.4M | URL-safe base64, hex | pure (wrap `Base` / `binary`) |

- **Shape:** `[u8]` in, `[u8]` out of a length known up front: base64 `4 * ceil(n / 3)`,
  hex `2n`, base58 at most `ceil(n * 138 / 100) + 1` (so `alloc` the bound and return
  `{out, len}`; Elixir takes `binary_part`). Decode raises on a bad byte.
- **Realistic size:** bytes to tens of MB (file uploads, JWT, data URLs); base58 inputs are
  20–64-byte keys and hashes.
- **Elixir baseline (measured, 16 MiB random):** `Base.encode64` 764 MB/s,
  `Base.decode64!` 551 MB/s, `Base.encode16` 475 MB/s, `:binary.encode_hex` 1,091 MB/s.
  A table-driven C encoder is a few GB/s, so a 2× bar is plausible for base64 and hex and
  likely for base58, whose pure implementations are bignum arithmetic.
- **Needs:** `defk-w38` (`bsr`/`band` to split 24-bit groups into 6-bit indices; a bit of
  masked arithmetic for decode); an alphabet constant via `defk-ivt` (a module attribute
  holding a binary) or `defk-n4r.5` (a `"ABC..."` literal); base58's long-division loop
  writes an `alloc`'d digit array in place, which works today in a single kernel body and
  needs `defk-n4r.4` only if split into helpers. Decode's "invalid byte" error maps onto
  `ArgumentError`, as `Base.decode64!` raises. Nothing growable: output is bounded.

### C. Non-cryptographic hashing of binaries (hand-written, or pure Elixir asking for a NIF)

| Package | Downloads | What | Native code |
|---|---|---|---|
| [crc32cer](https://github.com/kafka4beam/crc32cer) | 48.5M | CRC32C of iodata (Kafka) | wraps Google `crc32c` (SSE4.2 / ARM64); `nif` and `nif_d` (`ERL_NIF_DIRTY_JOB_CPU_BOUND`) twins |
| [murmur](https://github.com/preciz/murmur) | 2.4M | Murmur3 x86_32 / x86_128 / x64_128 | pure Elixir |
| [jchash](https://github.com/cabol/jchash) | 672k | jump consistent hash | NIF; `jumper` (18.7M) is the pure Elixir equivalent |
| [siphash](https://github.com/whitfin/siphash-elixir) | 224k | SipHash-c-d of a binary with a 16-byte key | 108-line hand-written C (`U8TO64_LE`, rotate, compress) next to an Elixir fallback (`disable_nifs: true`); README: "roughly 200x the speed of the initial implementations" (quoted) |
| [xxhash](https://github.com/ttvd/elixir-xxhash) | 205k | xxHash32/64 | pure Elixir; README recommends a NIF "if you require a high performance version" |
| [evil_crc32c](https://github.com/ayrat555/evil_crc32c) | 38.8k | CRC32C / CRC16 | 66 lines of hand-written Rust, bit-at-a-time |
| [spirit_fingers](https://github.com/holsee/spirit_fingers) | 6.8k | SimHash of a text + Hamming distance | ~200 lines of hand-written Rust over `siphasher`; README: "400-900x faster" (quoted) |
| [xxh3](https://github.com/farhadi/xxh3) | 4.4k | XXH3 64/128, streaming | wraps `xxhash-rust`; streaming state in a resource |

- **Shape:** `[u8]` (and a key or seed) in, `i64`/u64 or 16-byte `[u8]` out. SimHash
  tokenises first (whitespace split, hash per token), then a 64-counter vote.
- **Realistic size:** 16 B to a few MB (keys, messages, Kafka batches, documents).
- **Elixir baseline:** `murmur` and `xxhash` pure Elixir (sizes not benchmarked here);
  `:erlang.phash2` 2.6 GB/s and `:erlang.crc32` ~39 GB/s measured on 16 MiB, both BIFs
  (https://www.erlang.org/doc/apps/erts/erlang.html#phash2/2). A kernel is for a *specific*
  hash (Murmur3, xxh, SipHash, FNV) that must match other systems; `phash2` is not portable
  across OTP versions and `crc32` is one polynomial.
- **Needs:** `defk-w38` with masked arithmetic (CONTEXT.md: "how hashes and checksums
  wrap"), `defk-n4r.2` (`u64_le(bytes, i)`, wrapping `*`, `+`, rotates from `Defk.Bits`),
  `defk-ivt` for the constants. Table-driven CRC32C needs a 256-entry `alloc`'d table
  built in the kernel (works today) and reaches plain-C speed (~1–2 GB/s), not `crc32cer`'s
  SIMD speed; report that beside the verdict. SimHash's per-token vote is one more loop.

### D. UTF-8 validation and byte-class scanning (wrapped SIMD, or a BIF)

| Package | Downloads | What | Native code |
|---|---|---|---|
| [bandit](https://github.com/mtrudel/bandit) | 15.6M | validates text frames with `String.valid?(frame.data)` (`lib/bandit/websocket/connection.ex:67`), masks with `Bitwise.bxor` over `<<h::32, rest::binary>>` | pure Elixir; `primitive_ops_module` is pluggable |
| [bandit_native](https://github.com/moogle19/bandit_native) | 3.7k | `valid_utf8` and `mask` for Bandit | 28 lines: mask hand-written, `valid_utf8` wraps `simdutf8` (NEON build) |
| [jsont](https://github.com/devsnek/jsont) | 140k | `decode(bin, validate_unicode)` | `simdutf8` in the encoder; decoder hand-rolled from `serde_json` |

- **Shape:** `[u8]` in, `bool` out (or the first invalid offset as `i64`).
- **Realistic size:** WebSocket frames (bytes to 64 KB), JSON documents (KB to MB).
- **Elixir baseline (measured, 15.9 MB mixed ASCII/Latin text):** `String.valid?`
  463 MB/s; `:unicode.characters_to_binary/1` (also validates) 2,057 MB/s. A branchy
  byte-state-machine kernel runs at about 1 GB/s; a SIMD validator (`simdutf8`) at
  10+ GB/s. So the honest expectation is `marginal` against the BIF and `poor` against the
  crate, unless validation is fused into a kernel that is scanning anyway (1BRC names,
  JSON strings).
- **Needs:** `defk-w38` only (`band` for lead-byte classes). Listed for completeness and
  as a likely "Elixir is the right choice" entry.

### E. CSV and JSON structural scanning (hand-written, output is terms)

| Package | Downloads | What | Native code |
|---|---|---|---|
| [csv](https://github.com/beatrichartz/csv), [nimble_csv](https://github.com/dashbitco/nimble_csv) | 58.4M / 19.2M | CSV | pure Elixir; NimbleCSV compiles binary patterns per separator and uses `:binary.split(prefix, separator, [:global])` on unquoted runs |
| [rusty_csv](https://github.com/jeffhuen/rustycsv) | 2.3k | "drop-in replacement for NimbleCSV" | 7,861 lines of hand-written Rust: simdjson-style prefix-XOR quote detection over 16/32/64-byte chunks, then sub-binary terms for unquoted fields; all parse NIFs `DirtyCpu`; README quotes "3.5x faster" (simple) and "18.6x faster" (quote-heavy) vs NimbleCSV on an M1 Pro, and "~20ms" vs "~233ms" for a 7 MB file |
| [ecsv](https://github.com/erpuno/ecsv) | 3.8k | streaming CSV for Erlang | 589 lines of hand-written C; `enif_make_new_binary` + `memcpy` per field, tuple per row; Erlang side chops input into 20 kB blocks that "should take 10-15% of timeslice" |
| [jason](https://github.com/michalmuskala/jason), poison, thoas | 212.8M / 122M / 12M | JSON | pure Elixir / Erlang; Jason's string scanner is a byte-case loop counting `len` then `binary_part(original, skip, len)` |
| [jaxon](https://github.com/boudra/jaxon) | 1.29M | event-based JSON | 821 lines of hand-written C; every string is `enif_make_sub_binary` over the input |
| [jsonrs](https://github.com/benhaney/jsonrs), [simdjsone](https://github.com/saleyn/simdjsone), [simdjson](https://github.com/ChomperT/simdjson_erlang) | 337k / 4k / 0.8k | JSON | wrap `serde_json` / `simdjson`; `DirtyCpu` or `enif_schedule_nif(..., ERL_NIF_DIRTY_JOB_CPU_BOUND, ...)`; simdjsone README: "about 2.5 times faster than jiffy" (quoted) |

- **Shape:** binary in, lists of rows of sub-binaries (CSV) or nested maps/lists (JSON).
  The only kernel-expressible half is the structural index: an `[i64]` (or `[i32]`,
  `defk-4ai`) of field starts/ends with a quote flag, which is what `rusty_csv`'s
  `StructuralIndex` is before term building.
- **Realistic size:** 1 KB to hundreds of MB (`rusty_csv` guards 4 GiB).
- **Elixir baseline (measured):** `:binary.split` by newline 621 MB/s; `String.split` on
  lines then `;` 87 MB/s (the term half). NimbleCSV's path is in between.
- **Needs:** an offsets array whose length is unknown up front: either a two-pass kernel
  (count, then fill an `alloc`), or a growable `[i64]` (a new need; `defk-cmr`'s bitstring
  accumulator builds bits, not an indexable array). Plus `defk-w38` for the quote-parity
  (prefix-XOR) trick. **Verdict risk:** Elixir still has to build every sub-binary from
  the offsets, which is the ~45 MB/s half, so a scan-only kernel buys little. It pays when
  the kernel also converts fields: numeric columns straight into `[f64]`/`[i64]` (a
  "CSV to packed columns" loader, Explorer's territory), or 1BRC-style aggregation.

### F. Substring and multi-pattern search (wrapped automata; the BEAM has them)

| Package | Downloads | What | Native code |
|---|---|---|---|
| `:binary.match/matches/split/replace` | stdlib | Boyer-Moore for one pattern, Aho-Corasick for many; `compile_pattern/1` | ERTS C |
| [re2](https://github.com/dukesoferl/re2) | 524k | regex | wraps RE2 |
| [aho_corasearch](https://github.com/pejrich/AhoCorasearch), [aho_corasick_nif](https://github.com/morgahl/aho_corasick_nif) | 51k / 34k | many patterns with values; leftmost-longest / overlapping | wrap `daachorse` / `aho-corasick`; automaton in a resource; return `Vec<(start, end, value)>` |
| [trigram](https://github.com/EnaiaInc/trigram) | 0.3k | pg_trgm-compatible similarity, `best_match`, `score_all` | 450 lines of hand-written Rust (trigram sets in `FxHashSet`, CRC32 for non-ASCII), `DirtyCpu` batches, pure Elixir fallback |

- **Shape:** haystack + patterns in, list of `{start, len}` (or `{start, end, value}`)
  out; a count or first offset in the simple case.
- **Elixir baseline (measured, 15.9 MB):** `:binary.match` miss 10.3 GB/s;
  `:binary.matches` one pattern 880 MB/s; five patterns 527 MB/s; `String.split(" ")`
  into words 249 MB/s.
- **Needs:** nothing new for a single-pattern or byte-class count (works today); offsets
  out needs the growable `[i64]` of E; an Aho-Corasick table over `alloc`'d arrays needs
  `defk-n4r.4` to build in a helper. **Not a target:** the BIFs already run in C and
  return the sub-binaries the caller wants. Trigram-style *batch scoring* (one needle, N
  packed haystacks, `[f64]` scores out) is the fuzzy_search shape and fits today.

### G. Tokenisation (library wrappers; the simple case is a split)

`tokenizers` (744k) wraps Hugging Face's crate, `tiktoken` (83k) wraps OpenAI's; both out
of scope. The "simple whitespace/byte tokeniser" returns a list of sub-binaries (`String.split`,
249 MB/s measured), which a kernel cannot build; its kernel form is "token offsets as
`[i64]`" (category E) or a fused consumer (hash each token: SimHash in C). No anchor
package writes this by hand; not a target.

### H. String distance (crate wrappers over short algorithms; already a target)

`ex_strsim` (236), `strsim` (608), `fuzler` (544; `triple_accel`, Unicode normalisation,
`DirtyCpu`), against pure Elixir `the_fuzz` (433k), `simetric` (554k), `akin` (265k),
`levenshtein` (148k), `seqfuzz` (55k). Two `[u8]` in, `i64`/`f64` out; the per-pair call
pattern is the trap, the batch form is the win. This is the existing fuzzy_search target
(`examples/fuzzy_search`, 4.2× with the early cut-off on both sides), and Myers bit-parallel
waits on `defk-w38` (`defk-l2g`). Measured here: a naive Enum-based DP over 600×700 bytes
took 9.3 ms (~45M cells/s). Nothing new for the subset.

### I. Sorting and dedup of byte keys (no NIF found)

The Hex search for "sort nif" returns only `sorted_set_nif` (308k), a persistent structure,
category E of the numeric survey. Measured here on 200k 9-byte binaries: `Enum.sort` 40 ms,
`Enum.uniq` 17 ms, `Enum.frequencies` 40 ms. These return lists of binaries, which a kernel
cannot build; a kernel could sort a packed `[i64]` of hashes or fixed-width keys in a `[u8]`
(a swap loop works today), but no package shows demand. Out of scope until a workload
needs sorted packed keys as an intermediate (1BRC's output sort stays in Elixir: 10k names).

## Ranked candidates for the catalog

Ranked by (fits defk's model) × (evidence that people need it) × (an Elixir baseline to
measure against), as in the numeric survey.

| Rank | Workload | Evidence | Elixir baseline | What defk needs |
|---|---|---|---|---|
| 1 | **1BRC parse-and-aggregate**: `[u8]` chunk → packed per-station table | community 25–60 s vs 1.5 s Java; measured 13× gap between scanning (600 MB/s) and aggregating (45 MB/s) in Elixir; the ticketed north star (`defk-n4r`) | `defk-n4r.1`'s optimized Elixir (binary matching, `prim_file`, maps per worker) | `defk-w38`, `defk-n4r.2`, `defk-n4r.3`, `defk-n4r.4` (`defk-n4r.5` for tests) |
| 2 | **Base64 / hex / base58 codecs** | `fast64` 541k and `b64fast` 272k hand-written with timeslice chunking; `ex_base58` 156k; three pure base58s | `Base.encode64/decode64` (764 / 551 MB/s measured), `Base.encode16`, `b58` | `defk-w38`, `defk-ivt` or `defk-n4r.5` (alphabet constant); base58 helpers want `defk-n4r.4` |
| 3 | **Non-cryptographic hashes**: xxHash/Murmur3/SipHash/FNV/CRC32C over binaries | `siphash` 224k (C + Elixir fallback), `murmur` 2.4M and `xxhash` 205k pure and asking for a NIF, `crc32cer` 48.5M, `evil_crc32c`, SimHash | `murmur`, `xxhash`, `siphash`'s fallback | `defk-w38` with masked arithmetic, `defk-n4r.2`, `defk-ivt` |
| 4 | **Batch string distance / trigram scoring** (one needle, N packed candidates) | existing fuzzy_search target; `trigram`, `fuzler`, `spirit_fingers` batch APIs | `examples/fuzzy_search` Elixir | works today; `defk-w38` for Myers |
| 5 | **CSV/JSON structural index → packed numeric columns** | `rusty_csv` 3.5–18.6× quoted; `ecsv`, `jaxon` | NimbleCSV + `String.to_float` into a binary | growable `[i64]` or two-pass; `defk-w38`; `defk-4ai` for `[i32]` offsets; only as a fused loader, never scan-only |
| 6 | **UTF-8 validation / byte-class scan** | `bandit_native`, `jsont` option; Bandit uses `String.valid?` | `String.valid?` 463 MB/s, `:unicode.characters_to_binary` 2 GB/s | `defk-w38`; expected `marginal`: keep as a "BIF wins" entry |
| — | **Out of scope**: full CSV/JSON parse to terms (E), tokenisers and `String.split` to lists (G), sort/dedup returning binaries (I), single/multi-pattern search that returns sub-binaries (F: `:binary` BIFs), regex, Unicode case/graphemes/normalisation (`String.downcase` measured 16.6 MB/s but needs Unicode tables and must keep Elixir's answer: Elixir's job), anything per-element-call (`ex_strsim` pairs, `scenic_math`-style) | | | |

What is **not** needed by any of these: a map type, a string type, Unicode semantics,
resource-backed state between calls, or a sub-binary return (Elixir slices with
`binary_part` from `{out, len}` or an offsets array).

## The minimal ordered set of subset additions for the top three

Ordered by dependency and by how many of the three each unlocks.

1. **`defk-w38` bitwise operators with masked arithmetic** (`band`/`bor`/`bxor`/`bnot`/
   `bsl`/`bsr`, `band(expr, 2^k - 1)` computed wrapping). Unlocks codecs (rank 2) and the
   whole of hashing (rank 3), and is the prerequisite of every other item. Nothing in
   this survey compiles without it.
2. **Constants: `defk-ivt` module attributes, then `defk-n4r.5` binary literals as
   `[u8]`.** Codecs need an alphabet table (`@alphabet "ABC..."`, read as `alphabet[i]`),
   hashes need their primes and seeds, 1BRC tests need station-name literals. `defk-ivt`
   covers integers today; a binary-valued attribute lowered as a static `[u8]` view gives
   both tickets in one step.
3. **`defk-n4r.2` word loads and wrapping u64** (`u64_le(bytes, i)`, `u32_le`, rotates
   and `clz`/`popcount` via `Defk.Bits`). Hashes read 8 bytes per round; 1BRC hashes names
   and can find `;` eight bytes at a time. Blocked by 1.
4. **`defk-n4r.4` writable array parameters in helper kernels** (blocked by `defk-auo`,
   value semantics). 1BRC's `insert(table, arena, stats, ...)` and base58's digit loop
   are helpers that write their caller's `alloc`'d arrays; without this both must be
   written inline in one kernel body.
5. **`defk-n4r.3` sub-array views** (`slice(a, start, len)`; blocked by `defk-gqk` for the
   return path only). Needed by 1BRC alone among the top three: naming the station bytes
   to compare against the arena and to pass to the insert helper. A byte-range compare is
   a loop over two slices, so no separate builtin.

Rank 2 ships after steps 1–2 (base58 helpers after 4); rank 3 after 1–3; rank 1 after all
five, as `defk-n4r`'s sequencing already says. Two further needs appear only below the
top three and are not ticketed: a **growable `[i64]` output** (offset lists, category E/F;
the alternative is a two-pass kernel) and **`[i32]`/`[u32]` offsets** (`defk-4ai`) to halve
index memory. The bitstring accumulator (`defk-cmr`) is not needed by any text workload
here; it stays a Gorilla need.

## Sources

- Hex.pm API: `https://hex.pm/api/packages/<name>` for every package named above (read
  2026-10-09); searches `https://hex.pm/api/packages?search=<q>&sort=downloads`.
- Package tarballs `https://repo.hex.pm/tarballs/<name>-<version>.tar`, key files read:
  - `fast64-0.1.3/src/fast64_nif.c` (`enif_consume_timeslice`, `enif_schedule_nif`), `README.md`
  - `b64fast-0.2.3/c_src/b64fast.c`, `README.md`
  - `ex_base58-0.6.5/native/ex_base58/src/lib.rs`, `Cargo.toml` (`bs58`)
  - `siphash-3.2.0/c_src/siphash.c`, `lib/siphash/digest.ex`, `README.md`
  - `xxhash-0.3.1/README.md`, `murmur-2.0.2/README.md` (pure Elixir)
  - `crc32cer-1.1.4/c_src/crc32c_nif.c` (`ERL_NIF_DIRTY_JOB_CPU_BOUND` twins), `external/crc32c/`
  - `evil_crc32c-0.2.10/native/evil_crc32c/src/lib.rs`
  - `spirit_fingers-0.5.1/native/simhash/src/simhash_algo.rs`, `README.md`
  - `xxh3-0.3.6/native/xxh3/src/lib.rs`
  - `bandit_native-0.1.2/native/bandit_native/src/lib.rs`; `bandit-1.12.5/lib/bandit/websocket/connection.ex`, `lib/bandit/primitive_ops/websocket.ex`
  - `rusty_csv-0.4.6/native/rustycsv/src/lib.rs`, `src/term.rs`, `src/core/simd_scanner.rs`, `README.md`
  - `ecsv-1.4.2/c_src/ecsv_parser.c`, `src/ecsv.erl` (`BLOCK_SIZE`, "10-15% of timeslice")
  - `nimble_csv-1.3.0/lib/nimble_csv.ex`
  - `jason-1.4.5/lib/decoder.ex` (`string/6`), `jsont-0.2.0/native/jsont_nif/src/{lib,decoder,encoder}.rs`, `jaxon-2.0.8/c_src/decoder_nif.c`, `jsonrs-0.3.4/native/jsonrs/src/lib.rs`, `simdjsone-0.5.0/c_src/simdjson_nif.cpp`, `README.md`
  - `aho_corasearch-0.3.0/native/aho_corasearch_nif/src/lib.rs`, `trigram-0.6.0/native/trigram_nif/src/lib.rs`, `fuzler-0.1.3/native/fuzler/src/lib.rs`, `ex_strsim-0.1.0/native/ex_strsim_nif/src/lib.rs`
- Erlang docs: `binary` https://www.erlang.org/doc/apps/stdlib/binary.html; `erl_nif`
  https://www.erlang.org/doc/apps/erts/erl_nif.html ("return to its caller within 1
  millisecond", `enif_make_sub_binary` "no copy of data is made", `enif_consume_timeslice`,
  `enif_schedule_nif`); `erlang:phash2/2`, `crc32/1`
  https://www.erlang.org/doc/apps/erts/erlang.html#phash2/2
- 1BRC: https://github.com/gunnarmorling/1brc (README: rules, input ranges, hardware);
  Elixir Forum https://forum.elixirforum.com/t/my-elixir-implementation-of-the-1-billion-row-challenge/60974
  (posts 1, 4, 9, 12, 13, 14) and
  https://forum.elixirforum.com/t/the-one-billion-row-challenge-in-elixir-from-12-minutes-to-25-seconds-raj-rajhans-code-beam/69585;
  https://github.com/rrcook/brc; https://github.com/jesperes/erlang_1brc
- This repo: `CONTEXT.md` (one rule, masked arithmetic, bitstring accumulator, target
  workload, anchor package), `README.md` ("What it is", "Known limitations"),
  `examples/README.md`, `lib/defk/compiler.ex` (`inline/4` binds callee arrays
  `owned: false`), tickets via `bw show`.

## Limits

- Download counts are all-time totals and favour old packages; `recent` (90-day) counts
  were read but not tabulated.
- The Elixir baselines are single runs of a 40-line script on a noisy laptop, meant to
  rank workloads, not to be quoted as results; each catalog entry must re-measure.
- The Raj Rajhans numbers come from the talk abstract; the code and hardware were not
  found (his blog index lists no 1BRC post). stevensonmt's times are for 50M rows on a
  "14yo i5", and garazdawi's 60 s is Erlang on a "slow laptop": none is comparable to the
  Java leaderboard's machine.
- Private and in-house text NIFs are invisible; GitHub code search was not used.
- `simdutf8`, `xxhash-rust`, `bs58`, `daachorse`, `triple_accel` and `crc32c` were classed
  as wrappers from `Cargo.toml`/vendored sources without reading the crates themselves.
