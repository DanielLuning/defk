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
| `elixir` | Pure Elixir: charlist rows built by tail recursion, bounded top-k ([`elixir_backend.ex`](lib/fuzzy_search/elixir_backend.ex)) |
| `defk` | The same algorithm as a defk kernel that yields like Elixir code ([`kernels.ex`](lib/fuzzy_search/kernels.ex)) |
| `blocking` | The identical kernel compiled with `yield: false`. It behaves like a typical hand-written NIF and holds its scheduler until it finishes. |

All three return identical results; `bench/verify.exs` checks this.

## Run it

```bash
mix deps.get
NO_SERVER=1 mix run bench/verify.exs      # correctness + single-query timing
NO_SERVER=1 mix run bench/yield_cost.exs  # yielding vs `yield: false`, query by query
PORT=4040 mix run --no-halt               # the service
curl 'localhost:4040/search?q=elixr&backend=defk&k=5'

# in another terminal: a separate VM, so it doesn't compete for the server's schedulers
elixir --erl "+S 2" bench/loadgen.exs 4040 8
```

`GET /search?q=<word>&backend=elixir|defk|blocking&k=1..100` returns the matches plus
the server-side compute time. `GET /health` is a liveness probe.

## Results

Measured on an M-series Mac with 12 cores, OTP 29 and Elixir 1.20; two runs agreed within a few percent.

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
`:persistent_term`, tail-recursive rows, bounded top-k) but not yet
optimised, so the 6.2× is **provisional**. Not yet tried:

- a tuple or `:array` row instead of rebuilding lists,
- processing the catalog in parallel chunks per request,
- the early cut-off below, applied to the Elixir side too.

## Not modelled

Real fuzzy search adds things none of the three backends do:

- an early cut-off (stop a word once its row minimum exceeds the current k-th best),
- prefix or n-gram indexes, so most words are never scored,
- Unicode grapheme handling (this compares ASCII bytes).

Each of these speeds up all backends. The cut-off needs early loop exit in defk (ticket `defk-9vl`).
