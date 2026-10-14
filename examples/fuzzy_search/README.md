# fuzzy_search: a typo-tolerant search service

A search box that tolerates typos ("elixr" finds "elixir") is a classic point
where Elixir teams reach for a Rust or C NIF. It has three properties that make
it a good test for defk:

- **Hot integer loops.** Levenshtein distance is a dynamic-programming loop over bytes.
- **Not tensor-shaped.** The work is branchy and data-dependent, so Nx doesn't fit.
- **Runs inside a web server.** A blocking NIF there hurts every other request.

This app serves top-k Levenshtein matches over the 234k words in
`/usr/share/dict/words` through Plug + Bandit. Every request picks one of three
backends:

| Backend | What it is |
|---|---|
| `elixir` | Pure Elixir: charlist rows built by tail recursion, early cut-off, bounded top-k ([`elixir_backend.ex`](lib/fuzzy_search/elixir_backend.ex)) |
| `defk` | The same algorithm as a defk kernel that yields like Elixir code ([`kernels.ex`](lib/fuzzy_search/kernels.ex)) |
| `blocking` | The identical kernel compiled with `yield: false`. It behaves like a typical hand-written NIF and holds its scheduler until it finishes. |

All three return identical results; `bench/verify.exs` and `mix test` check this.

### The algorithm

Classic Levenshtein DP, one row per character of the candidate word, with a
bounded top-k list and an **early cut-off**: a row's minimum never
decreases from one row to the next, and the final distance is at least that
minimum. So once the top k is full, a word stops as soon as its row minimum
reaches the k-th best distance found so far. Words are scanned in index order
and ties go to the lower index, so a word that can only tie the k-th best is
cut too. Results are exactly those of a full scan: `test/fuzzy_search_test.exs`
compares every backend with one.

Both sides use the same cut-off. The kernel writes it as `Enum.reduce_while`
over the rows (`{:halt, true}` once the row minimum reaches the bound); the
Elixir backend as a tail-recursive row loop that returns `:cut`.

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

### With the early cut-off

Measured on 2026-10-13 on a quiet machine (no builds or other
agents; load average 3–6 before each run). M-series Mac, 12 cores, OTP 29,
Elixir 1.20.

Single query, in-process (`bench/verify.exs`, 40 typo'd queries, k = 10, three runs):

| Backend | before (no cut-off) | after (cut-off) | gain |
|---|---|---|---|
| `elixir` | 112 ms | 59.9–61.4 ms | 1.9× |
| `defk` | 20.4–20.8 ms | 13.6–13.8 ms | 1.5× |
| `blocking` | 20.6 ms | 13.1–13.3 ms | 1.6× |
| defk vs Elixir | 5.4× | **4.4×** | |

The "before" column was measured under load (load average 5–90); the first
measurement of the cut-off read 60 ms and 14.1–14.2 ms under the same load, so load
moved those numbers by less than 5%.

**Yielding vs blocking.** `bench/yield_cost.exs` (20 queries × 5, interleaved,
five runs): yielding 12.25–12.75 ms vs blocking 11.7–12.0 ms, **+3.5–4.5%**,
54–56 yields/query. The gap is real and comes from the kernel's shape, not from
the yields or from a compiler regression:

- Built with `DEFK_SLICE_US=10000000` (0.2–0.4 yields/query), the gap stays
  (+3.6–4.7%). The yields cost nothing measurable.
- The kernel from before the cut-off (`d3bc3cd^`), on today's compiler, gives
  yielding −1.6% to −3.4% against blocking, as it did when it was first measured. So no
  compiler commit since then made yielding slower.
- What the yielding build adds is per-row bookkeeping in the `Enum.reduce_while`
  over rows: a safepoint every row (the row loop holds the DP loop, so it can't
  run in strips), a resume check, and the strip copy of the DP loop. The
  cut-off made rows short work, so this costs a larger share. This is a
  known class of cost, tracked separately.

The 27–28 ms vs ~21 ms that an earlier run saw at load average 30+ was load noise.

The cut-off helps Elixir more than defk. A likely reason (not yet profiled):
it removes the same DP cells on both sides, but the per-word cost it can't
remove (row setup, the reduce over rows, the top-k check) is a larger share of
the kernel's time.

### Under load

**Under load:** 24 concurrent clients saturating the server, while a prober hits
`GET /health` every 5 ms (`elixir --erl "+S 2" bench/loadgen.exs 4047 8`).

With the cut-off (quiet machine): three runs that agreed within
~3%. Four earlier runs overlapped another session's test suite and scattered
(defk 499–629 req/s, blocking 499–681); they are not used.

| Backend | 1 client p50 | req/s | search p50 | search p99 | health p50 | health p99 |
|---|---|---|---|---|---|---|
| `elixir` | 54 ms | 126–130 | 163–167 ms | 507–544 ms | 0.4 ms | 9.6–12.1 ms |
| `defk` | 11.6–11.9 ms | 652–663 | 32–33 ms | 99–105 ms | 1.0–1.1 ms | 9.8–11.7 ms |
| `blocking` | 11.5–11.8 ms | 676–693 | 32 ms | 85–100 ms | **18–22 ms** | **75–82 ms** |

Before the cut-off (two runs agreed within a few percent; load not recorded):

| Backend | 1 client p50 | req/s | search p50 | search p99 | health p50 | health p99 |
|---|---|---|---|---|---|---|
| `elixir` | 124–126 ms | 68–69 | 345–348 ms | 615–633 ms | 0.3 ms | 6–9 ms |
| `defk` | 21 ms | 426–429 | 54 ms | 115–117 ms | 1.1 ms | 8–10 ms |
| `blocking` | 22 ms | 433–443 | 52–53 ms | 111–116 ms | **33 ms** | **77–90 ms** |

### What the numbers say

1. **defk gives 5.1–5.2× the throughput of pure Elixir and cuts p99 latency by 5.1–5.3×**, from the same code shape (6.2× and 5.4× before the cut-off). The speedup is smaller than the 10–15× seen on float arrays, because the BEAM JIT handles small-integer DP loops well.
2. **The blocking NIF is a little faster, and it slows every other request.** `/health`, which does nothing, takes a median of 18–22 ms and up to 75–82 ms at p99 (33 ms and 90 ms before the cut-off). Processes queued on a scheduler that is busy in a NIF wait until the NIF finishes. In an earlier run with only 4 clients (8 of 12 cores idle), its `/health` p99 was 26 ms, against 2 ms for defk.
3. **defk keeps `/health` in the same range as pure Elixir** (p99 9.8–11.7 ms against 9.6–12.1 ms) while serving 5.1–5.2× the traffic. This is the BEAM promise the example exists to test.
4. **defk gives 2–6% less throughput than the blocking build under load** (652–663 vs 676–693 req/s), and is 3.5–4.5% slower one query at a time. Before the cut-off the two were within ~2%. The single-query gap comes from per-row bookkeeping in the cut-off's `Enum.reduce_while`, not from yielding (see above). An earlier version of defk was ~30% slower. That gap closed for several reasons: bounds checks are now elided, the short inner DP loops no longer check a safepoint per cell, and a resumed kernel re-enters its loops through their headers instead of jumping into the middle of them, which had made the loops irreducible for LLVM.
5. **Yielding more often cost nothing measurable here.** Kernels now yield after 250 µs instead of 1 ms, ~78 yields per query instead of 18 before the cut-off (~55 with it). Throughput stayed within run-to-run noise, and defk's `/health` median fell from 3 ms to 1.1 ms. With the cut-off, a build that almost never yields is no faster than the one that yields every 250 µs. `bench/yield_cost.exs` compares `search/4` with its `yield: false` twin, query by query.

## Elixir baseline: first pass

The Elixir backend is careful (a precomputed charlist catalog in
`:persistent_term`, tail-recursive rows, the early cut-off, bounded top-k),
and its row layout has now been measured against the alternatives. It stays
**first pass**, so the 4.4× is **provisional**, because a better algorithm
exists that the kernel can't use yet (Myers, below).

What was tried while adding the cut-off (`bench/elixir_variants.exs`: 20 queries × 3
rounds, k = 10, each query in a fresh process, catalog in `:persistent_term`;
median ms/query, noisy machine, the two runs agreed within ~10%):

| Variant | ms/query |
|---|---|
| first pass, no cut-off | 124–128 |
| list rows + cut-off, `Enum.reduce_while` over the word | 66–69 |
| **list rows + cut-off, tail recursion (shipped)** | **60–62** |
| = shipped, but words as binaries (`<<ch, rest::binary>>`) | 66–67 |
| = shipped, tail-recursive catalog walk instead of `Enum.reduce` | 59–62 (same) |
| = shipped, row minimum via `:lists.min/1` | 69–70 |
| = shipped, rows as tuples (`elem`, `List.to_tuple`) | 79–82 |
| = shipped, rows as `:array` | 287–288 |
| = shipped, rows as `u16` binaries built by appending | 322–330 |
| = shipped + length pre-filter (`abs(len(w) - len(q)) >= bound`)\* | 53–54 |
| Myers/Hyyrö bit-parallel distance, no cut-off\* | **18–19** |

\* Not used as the baseline, because the kernel doesn't have the same trick:

- **Myers bit-parallel** replaces each row with a few bitwise operations on one
  integer (queries up to 58 characters fit a small integer). In Elixir it is
  **3.3× faster than the shipped DP and within ~1.3× of the defk DP kernel**,
  which would make this example `marginal`. A defk kernel can't write it until
  kernels have bitwise operators; then both sides should use it
  and be re-measured. Until then the 4.4× is a DP-vs-DP comparison only.
- **The length pre-filter** is cheap on both sides; adding it to both is a follow-up.

The Elixir backend now processes the catalog in parallel chunks across schedulers
for a single request (parallel chunking per request). Under server load where
all schedulers are busy, this doesn't add much; for a single-query latency test
with spare cores it can help. The defk kernel remains single-threaded per call.

## Not modelled

Real fuzzy search adds things none of the three backends do:

- a length pre-filter, or a tighter cut-off bound that adds the remaining length difference to each cell,
- prefix or n-gram indexes, so most words are never scored,
- Unicode grapheme handling (this compares ASCII bytes).

Each of these speeds up all backends.
