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
bounded top-k list and an **early cut-off** (`defk-8i4`): a row's minimum never
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

### With the early cut-off (provisional, noisy machine)

> **Provisional.** Measured while other agents were building on the same
> machine (load average 5–90 during the session). Each number is one of two
> alternating before/after runs, which agreed within ~5%. The quiet-machine
> re-measure, including the load test below, belongs to `defk-klw`.

Single query, in-process (`bench/verify.exs`, 40 typo'd queries, k = 10), M-series Mac, 12 cores, OTP 29, Elixir 1.20:

| Backend | before (no cut-off) | after (cut-off) | gain |
|---|---|---|---|
| `elixir` | 112 ms | 60 ms | 1.9× |
| `defk` | 20.4–20.8 ms | 14.1–14.2 ms | 1.5× |
| `blocking` | 20.6 ms | 13.1–13.7 ms | 1.5× |
| defk vs Elixir | 5.4× | **4.2×** | |

`bench/yield_cost.exs` (20 queries × 5, interleaved): yielding 12.6–12.8 ms vs
blocking 12.0–12.4 ms (+4.7–4.9%, 55 yields/query); before the cut-off it was
20.9–21.4 vs 21.7 ms (−2%, 77 yields/query). Whether that ~5% is real or code
layout noise (`defk-9vl` saw ±3% from layout alone) is for the quiet re-measure.

The cut-off helps Elixir more than defk. A likely reason (not yet profiled):
it removes the same DP cells on both sides, but the per-word cost it can't
remove (row setup, the reduce over rows, the top-k check) is a larger share of
the kernel's time.

### Before the cut-off: under load

Measured on an M-series Mac with 12 cores, OTP 29 and Elixir 1.20; two runs agreed within a few percent.
These predate the cut-off and have not been re-run with it.

**Under load:** 24 concurrent clients saturating the server, while a prober hits
`GET /health` every 5 ms.

| Backend | 1 client p50 | req/s | search p50 | search p99 | health p50 | health p99 |
|---|---|---|---|---|---|---|
| `elixir` | 124–126 ms | 68–69 | 345–348 ms | 615–633 ms | 0.3 ms | 6–9 ms |
| `defk` | 21 ms | 426–429 | 54 ms | 115–117 ms | 1.1 ms | 8–10 ms |
| `blocking` | 22 ms | 433–443 | 52–53 ms | 111–116 ms | **33 ms** | **77–90 ms** |

### What the numbers say

1. **defk gives 6.2× the throughput of pure Elixir and cuts p99 latency by 5.4×**, from the same code shape. The speedup is smaller than the 10–15× seen on float arrays, because the BEAM JIT handles small-integer DP loops well.
2. **The blocking NIF is barely faster, and it slows every other request.** `/health`, which does nothing, takes a median of 33 ms and up to 90 ms at p99. Processes queued on a scheduler that is busy in a NIF wait until the NIF finishes. In an earlier run with only 4 clients (8 of 12 cores idle), its `/health` p99 was 26 ms, against 2 ms for defk.
3. **defk keeps `/health` in the same range as pure Elixir** (p99 8–10 ms against 6–9 ms) while serving 6.2× the traffic. This is the BEAM promise the example exists to test.
4. **defk is within ~2% of the blocking build** under load. One query at a time, the two take the same time (~21 ms). An earlier version of defk was ~30% slower. That gap closed for several reasons: bounds checks are now elided (`defk-88q`), the short inner DP loops no longer check a safepoint per cell (`defk-5s3`), and a resumed kernel re-enters its loops through their headers instead of jumping into the middle of them, which had made the loops irreducible for LLVM (`defk-nua`).
5. **Yielding more often cost nothing measurable here.** Kernels now yield after 250 µs instead of 1 ms (`defk-j3h`), ~78 yields per query instead of 18. Throughput stayed within run-to-run noise, and defk's `/health` median fell from 3 ms to 1.1 ms. `bench/yield_cost.exs` compares `search/4` with its `yield: false` twin, query by query.

## Elixir baseline: first pass

The Elixir backend is careful (a precomputed charlist catalog in
`:persistent_term`, tail-recursive rows, the early cut-off, bounded top-k),
and its row layout has now been measured against the alternatives. It stays
**first pass**, so the 4.2× is **provisional**, because a better algorithm
exists that the kernel can't use yet (Myers, below).

What was tried for `defk-8i4` (`bench/elixir_variants.exs`: 20 queries × 3
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
  kernels have bitwise operators (`defk-w38`); then both sides should use it
  and be re-measured. Until then the 4.2× is a DP-vs-DP comparison only.
- **The length pre-filter** is cheap on both sides; adding it to both is a follow-up.

Not yet tried: processing the catalog in parallel chunks per request (it
doesn't raise throughput under load, where every scheduler is already busy).

## Not modelled

Real fuzzy search adds things none of the three backends do:

- a length pre-filter, or a tighter cut-off bound that adds the remaining length difference to each cell,
- prefix or n-gram indexes, so most words are never scored,
- Unicode grapheme handling (this compares ASCII bytes).

Each of these speeds up all backends.
