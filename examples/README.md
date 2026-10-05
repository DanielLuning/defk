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
| [`image_blur.exs`](image_blur.exs) | Grayscale + 3×3 box blur on a raw 1080p frame | 26–29× | first pass: **provisional** |
| [`fuzzy_search/`](fuzzy_search) (app) | Typo-tolerant search service: Levenshtein over 234k words behind Plug + Bandit | 4.3× req/s, 3.9× lower p99; `/health` latency stays at Elixir levels (a blocking NIF pushes it to ~80 ms p99) | first pass: **provisional** |

These numbers will shrink as the Elixir baselines are optimised; that's
expected and is the point. Each example's header lists what hasn't been
tried yet.

## Where Elixir is the right choice

| Example | The trap | defk vs Elixir | Elixir baseline |
|---|---|---|---|
| [`poor_list_data.exs`](poor_list_data.exs) | Data arrives as a list (Ecto rows, JSON); packing it costs more than Elixir's whole `Enum.sum` | 0.35–0.37× (≈3× slower) | optimised |
| [`poor_tiny_calls.exs`](poor_tiny_calls.exs) | One kernel call per element inside `Enum.map`; the call overhead exceeds the work | 0.38–0.43× | optimised |
| [`out_of_scope_word_count.exs`](out_of_scope_word_count.exs) | Strings in, a map out; kernels can't build BEAM terms, and the compiler refuses | not expressible | n/a |

Also not what defk is for (no script needed):

- **Wrapping an existing native library** (codecs, crypto, databases): use Rustler, Zigler or an existing binding.
- **Tensor and ML work**: use Nx, which compiles to XLA or LibTorch. Ticket `defk-9p6.3` will measure where the boundary lies.
- **I/O-bound work**: native code doesn't make the network faster.

Numbers are from an M-series Mac (OTP 29, Elixir 1.20); ranges cover the runs so far.
The scoreboard, not these tables, is the source of truth: rerun `run_all.exs`.

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
