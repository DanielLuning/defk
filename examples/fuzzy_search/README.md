# fuzzy_search: a typo-tolerant search service

A search box that tolerates typos ("elixr" finds "elixir") is a classic point
where Elixir teams reach for a Rust or C NIF. It has three properties that make
it a good test for defk:

- **Hot integer loops.** Levenshtein distance is a tight loop over bytes, integer and bitwise operations.
- **Not tensor-shaped.** The work is branchy and data-dependent, so Nx doesn't fit.
- **Runs inside a web server.** A blocking NIF there hurts every other request.

This app serves top-k Levenshtein matches over the 234k words in
`/usr/share/dict/words` through Plug + Bandit. Every request picks one of three
backends:

| Backend | What it is |
|---|---|
| `elixir` | Pure Elixir: Myers bit-parallel distance by tail recursion over binary words, early cut-off, bounded top-k ([`elixir_backend.ex`](lib/fuzzy_search/elixir_backend.ex)) |
| `defk` | The same algorithm as a defk kernel that yields like Elixir code ([`kernels.ex`](lib/fuzzy_search/kernels.ex)) |
| `blocking` | The identical kernel compiled with `yield: false`. It behaves like a typical hand-written NIF and holds its scheduler until it finishes. |

All three return identical results; `bench/verify.exs` and `mix test` check this.

### The algorithm

**Myers/Hyyrö bit-parallel Levenshtein** for queries of 1 to 62 bytes: the
query becomes a table of bit masks (bit j of `peq[ch]` is set when byte j of
the query is `ch`), and each byte of the candidate word is one step of about
twenty bitwise operations on two bit vectors. Up to 62 bits, every value
stays a small integer in Elixir and fits an `i64` in the kernel. An empty
query and queries of 63 bytes or more take the classic DP, one row per byte
of the word.

A bounded top-k list and an **early cut-off**: once the top k is full, a word
stops as soon as a lower bound on its distance reaches the k-th best distance
found so far. Two lower bounds: `|n - m|` (the length difference) before the
word starts, and `score - (n - i)` after `i` of its `n` bytes, because each
remaining byte lowers the distance by at most one. The DP path cuts on the row
minimum. Words are scanned in index order and ties go to the lower index, so
a word that can only tie the k-th best is cut too. Results are exactly those
of a full scan: `test/fuzzy_search_test.exs` compares every backend with one.

Both sides use the same algorithm, the same bounds and the same score step.
The kernel writes the cut-off as `Enum.reduce_while` over the word's bytes
(`{:halt, ...}` once the bound is reached); the Elixir backend as a
tail-recursive walk over the binary word that returns `:cut`.

## Run it

```bash
mix deps.get
mix test                                  # every backend vs a full scan
NO_SERVER=1 mix run bench/verify.exs      # correctness + single-query timing
NO_SERVER=1 mix run bench/elixir_variants.exs  # the Elixir variants that were tried
NO_SERVER=1 mix run bench/yield_cost.exs  # yielding vs `yield: false`, query by query
PORT=4040 mix run --no-halt               # the service
curl 'localhost:4040/search?q=elixr&backend=defk&k=5'

# in another terminal: a separate VM, so it doesn't compete for the server's schedulers
elixir --erl "+S 2" bench/loadgen.exs 4040 8
```

`GET /search?q=<word>&backend=elixir|defk|blocking&k=1..100` returns the matches plus
the server-side compute time. `GET /health` is a liveness probe.

## Results

Measured on 2026-10-15. M-series Mac, 12 cores, OTP 29, Elixir 1.20.
**Provisional:** other sessions ran on the machine (load average 4–7 before
the runs, up to 26 during the load test). Re-check on a quiet machine.

Single query, in-process (`bench/verify.exs`, 40 typo'd queries, k = 10,
three runs):

| Backend | DP + cut-off (2026-10-13) | Myers + cut-off | gain |
|---|---|---|---|
| `elixir` | 59.9–61.4 ms | 10.9–11.1 ms | 5.5× |
| `defk` | 13.6–13.8 ms | 4.6–4.7 ms | 3.0× |
| `blocking` | 13.1–13.3 ms | 3.9 ms | 3.4× |
| defk vs Elixir | 4.4× | **2.3–2.4×** | |

Myers helps Elixir more than defk: in Elixir it replaces a list of row cells
per byte with a few operations on one small integer, where the kernel's DP
row was already a tight loop over an array. The verdict stays **good**
(at least 1.9×), but by a smaller margin than the DP comparison showed.

**Yielding vs blocking.** `bench/yield_cost.exs` (20 queries × 5, interleaved,
three runs): yielding 4.91–4.99 ms vs blocking 4.11–4.20 ms, **+19%**, at 17
yields per query. With the DP it was +3.5–4.5%. A build with
`DEFK_SLICE_US=10000000` keeps the same gap, so the yields themselves cost
little. The fast-path report (`Defk.Report.print(FuzzySearch.Kernels)`) names
the cause: the word loop holds the inner loop over the word's bytes, so it
checks a safepoint on every word. Myers made each word a few nanoseconds of
work, so this per-word bookkeeping is now a large share. This is a known cost
in the compiler, tracked separately.

### Under load

24 concurrent clients saturating the server, while a prober hits
`GET /health` every 5 ms (`elixir --erl "+S 2" bench/loadgen.exs 4047 8`).
Two runs; a third run, during a load spike, gave defk 1376 req/s and a
`/health` p99 of 29 ms and is not used.

| Backend | 1 client p50 | req/s | search p50 | search p99 | health p50 | health p99 |
|---|---|---|---|---|---|---|
| `elixir` | 10.7 ms | 698–741 | 31–33 ms | 75–76 ms | 0.3–0.4 ms | 12.4–13.5 ms |
| `defk` | 4.7–4.8 ms | 1791–1839 | 12.0–12.4 ms | 31–33 ms | 0.8 ms | 12.3–13.2 ms |
| `blocking` | 4.0–4.1 ms | 2264–2367 | 9.4–9.8 ms | 24–25 ms | **5.9–6.2 ms** | **17.7–19.9 ms** |

### What the numbers say

1. **defk gives 2.4–2.6× the throughput of pure Elixir and cuts p99 latency
   by 2.3–2.5×**, with the same algorithm on both sides. With the DP on both
   sides it was 5×: a better algorithm narrowed the gap, as it should when
   the baseline improves.
2. **The blocking NIF is faster, and it still slows every other request.**
   `/health`, which does nothing, takes a median of ~6 ms and up to 18–20 ms
   at p99, against 12–13 ms for defk and Elixir. A query now blocks its
   scheduler for ~4 ms instead of ~13 ms, so the harm is smaller than with
   the DP (75–82 ms p99), but processes queued on a scheduler that is busy in
   a NIF still wait until the NIF finishes.
3. **defk keeps `/health` in the same range as pure Elixir** (p99 12.3–13.2
   ms against 12.4–13.5 ms) while serving 2.4–2.6× the traffic. This is the BEAM
   promise the example exists to test.
4. **defk gives ~21% less throughput than the blocking build under load**
   (1791–1839 vs 2264–2367 req/s), the same share as its single-query yield
   cost (+19%, above).

### Earlier results: the DP on both sides

Before Myers, both sides ran the row DP with the row-minimum cut-off. On a
quiet machine (2026-10-13): single query Elixir 59.9–61.4 ms, defk 13.6–13.8
ms, blocking 13.1–13.3 ms (4.4×); yielding +3.5–4.5% over blocking, from
per-row bookkeeping in the `Enum.reduce_while` over rows. Under load:

| Backend | 1 client p50 | req/s | search p50 | search p99 | health p50 | health p99 |
|---|---|---|---|---|---|---|
| `elixir` | 54 ms | 126–130 | 163–167 ms | 507–544 ms | 0.4 ms | 9.6–12.1 ms |
| `defk` | 11.6–11.9 ms | 652–663 | 32–33 ms | 99–105 ms | 1.0–1.1 ms | 9.8–11.7 ms |
| `blocking` | 11.5–11.8 ms | 676–693 | 32 ms | 85–100 ms | **18–22 ms** | **75–82 ms** |

Without any cut-off (load not recorded) the DP was 112 ms in Elixir and
20.4–20.8 ms in defk (5.4×), and the blocking build's `/health` p99 was
77–90 ms. An earlier version of defk was ~30% slower than the blocking
build. That gap closed for several reasons: bounds checks are now elided, the
short inner DP loops no longer check a safepoint per cell, and a resumed
kernel re-enters its loops through their headers instead of jumping into the
middle of them, which had made the loops irreducible for LLVM. Kernels now
yield after 250 µs instead of 1 ms; that cost nothing measurable, and
defk's `/health` median fell from 3 ms to 1.1 ms.

## Elixir baseline: optimized

The Elixir side is measured against the alternatives
(`bench/elixir_variants.exs`: 20 queries × 3 rounds, k = 10, each query in a
fresh process, catalog in `:persistent_term`; median ms/query; two runs on
2026-10-15, four runs at load average 4–14, provisional; the shipped row
comes from the last two runs, at load 4–6):

| Variant | ms/query |
|---|---|
| DP, first pass, no cut-off | 126–128 |
| DP, list rows + cut-off, `Enum.reduce_while` over the word | 68 |
| DP, list rows + cut-off, tail recursion | 61–63 |
| = DP tail recursion, but words as binaries (`<<ch, rest::binary>>`) | 67 |
| = DP tail recursion, tail-recursive catalog walk instead of `Enum.reduce` | 60–61 (same) |
| = DP tail recursion, row minimum via `:lists.min/1` | 69–70 |
| = DP tail recursion, rows as tuples (`elem`, `List.to_tuple`) | 79 |
| = DP tail recursion, rows as `:array` | 277–281 |
| = DP tail recursion, rows as `u16` binaries built by appending | 324–325 |
| = DP tail recursion + length pre-filter | 54 |
| Myers over charlists, no cut-off | 18.6–19.0 |
| Myers over charlists + length pre-filter | 22.4–23.0 |
| = Myers + length pre-filter + score cut-off | 12.7–13.6 |
| = Myers + both bounds, binary words | 11.9–12.2 |
| **= Myers + both bounds, binary words, branch-free score step (shipped)** | **11.5–11.6** |

What this shows:

- **Myers is 3–5× the best DP.** One small-integer step per byte replaces a
  row of list cells.
- **The length pre-filter alone slows Myers down over charlists** (22–23 vs
  19 ms): `length/1` walks the whole word, while Myers without a cut-off has
  to walk it anyway. With binary words `byte_size/1` costs nothing, so binary
  words win once the cut-off makes most words stop early (12 vs 13 ms). Over
  a full scan with no cut-off, charlists are the faster walk.
- **The branch-free score step** (`score + (ph >>> top &&& 1) - (mh >>> top
  &&& 1)` instead of a `cond`) gains ~4% in Elixir. The kernel gets the same
  step; there it measured the same as the `cond`, which the C compiler
  already turns into a select.
- In the kernel, `wrap64/1` around the one checked addition (to drop its
  overflow check) measured no faster, so the kernel keeps plain `+`.

`ElixirBackend.search/3` can also split the catalog into one chunk per
scheduler (`parallel: true`). The service does not use it: under load every
scheduler is busy, and the defk kernel is single-threaded per call too.

## Not modelled

Real fuzzy search adds things none of the three backends do:

- prefix or n-gram indexes, so most words are never scored,
- multi-word Myers for queries longer than 62 bytes (they take the DP here),
- Unicode grapheme handling (this compares bytes).

Each of these speeds up, or changes, all backends alike.
