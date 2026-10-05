# defk examples

Real use cases, each implemented in plain Elixir and in defk, checked for
agreement and measured. The catalog exists to answer two questions honestly,
and keeps answering them as it grows:

1. **Is defk getting better at the jobs people write NIFs for?**
2. **Where should you not use it?**

The format follows [mix_install_examples](https://github.com/wojtekmach/mix_install_examples):
one self-contained script per use case.

```bash
elixir examples/geo_nearest.exs     # one example
elixir examples/run_all.exs         # all of them + scoreboard (exit 1 if any claim fails)
```

## Use defk for

Loops over numbers or bytes, where the data is already packed, or is packed once and reused.

| Example | Real-world job | defk vs Elixir |
|---|---|---|
| [`rolling_stats.exs`](rolling_stats.exs) | Moving mean/stddev over 1M sensor readings | **165–177×** (≈30× on arithmetic alone; the rest is Elixir materialising 2M floats as lists) |
| [`geo_nearest.exs`](geo_nearest.exs) | 10 nearest of 500k locations (haversine) | **43–46×** |
| [`image_blur.exs`](image_blur.exs) | Grayscale + 3×3 box blur on a raw 1080p frame | **28–29×** |
| [`fuzzy_search/`](fuzzy_search) (app) | Typo-tolerant search service: Levenshtein over 234k words behind Plug + Bandit | **4.3× req/s, 3.9× lower p99**, `/health` latency stays at Elixir levels (a blocking NIF pushes it to ~80 ms p99) |

## Don't use defk for

| Example | The trap | defk vs Elixir |
|---|---|---|
| [`poor_list_data.exs`](poor_list_data.exs) | Data arrives as a list (Ecto rows, JSON); packing it costs more than Elixir's whole `Enum.sum` | **0.23–0.25×** (4× slower) |
| [`poor_tiny_calls.exs`](poor_tiny_calls.exs) | One kernel call per element inside `Enum.map`; the call overhead exceeds the work | **0.49–0.56×** |
| [`out_of_scope_word_count.exs`](out_of_scope_word_count.exs) | Strings in, a map out; kernels can't build BEAM terms, and the compiler refuses | not expressible |

Also not what defk is for (no script needed):

- **Wrapping an existing native library** (codecs, crypto, databases): use Rustler, Zigler or an existing binding.
- **Tensor and ML work**: use Nx, which compiles to XLA or LibTorch. Ticket `defk-9p6.2` will measure where the boundary lies.
- **I/O-bound work**: native code doesn't make the network faster.

Numbers are from an M-series Mac (OTP 29, Elixir 1.20); ranges cover the runs so far.
The scoreboard, not this table, is the source of truth: rerun `run_all.exs`.

## How verdicts work

Every script ends with `Defk.Bench.report/1`, which:

- checks that the Elixir and defk results agree,
- takes the best of several timed runs for each side, measured **end to end**, including any conversion a real caller would pay for,
- prints a `DEFK_RESULT` JSON line.

The verdict comes from the measurement:

| Verdict | Rule |
|---|---|
| `good` | defk ≥ 2× faster |
| `marginal` | between 1× and 2× |
| `poor` | defk slower |
| `out_of_scope` | can't be written as a kernel |

Each example also declares the verdict it **expects**. `run_all.exs` fails if an
example is incorrect, crashes, or measures a different verdict than it claims.
That's deliberate: if a defk change turns a `poor` example into a `good` one,
the catalog has to be updated, which is exactly the progress we want to see.

## Adding an example

1. Copy [`_template.exs`](_template.exs) to `examples/<use_case>.exs` (files starting with `_` are skipped by the runner).
2. Describe the real job and why people reach for a NIF, in the header.
3. Write the Elixir version the way a careful Elixir developer would; a strawman baseline proves nothing.
4. Give both versions the same input, in the form a real caller would have.
5. Call `Defk.Bench.report/1` with the `expected` verdict and a one-sentence `reason`.
6. Run `elixir examples/run_all.exs` and add a row to the right table above.

Planned examples are tracked as children of epic `defk-9p6` (`bw show defk-9p6`).
