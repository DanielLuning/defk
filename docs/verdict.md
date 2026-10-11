# Verdict

## Conclusion

<!-- TODO(defk-sgw.5): 3-5 sentences including the go/no-go outcome. -->
TODO: filled by defk-sgw.5.

## "Should I use defk for X?" guide

<!-- TODO(defk-sgw.5): guide by job type (Elixir / defk / Nx / Rustler) plus the traps list. -->
TODO: filled by defk-sgw.5.

## Workload results

<!-- TODO(defk-sgw.4): frozen snapshot tied to a commit, one row per target workload. -->
TODO: filled by defk-sgw.4 (frozen snapshot on a quiet machine).

## Runtime contract

<!-- TODO(defk-sgw.5): one row per promise with linked test/bench, measured figure, known gaps. -->
TODO: filled by defk-sgw.5.

## Developer experience

<!-- TODO(defk-sgw.5): three-part bar with evidence. -->
TODO: the rest of this section is filled by defk-sgw.5.

### Cold test (defk-sgw.3)

A fresh agent session, given only README.md, docs/language.md and the
compiler's output (no lib/ source, no prior context), wrote a count-min
sketch `update_many` over `[u64]` hashes, a job not in the catalog. Full log:
[docs/cold-tests/count-min.md](cold-tests/count-min.md).

- Result: the first kernel it wrote compiled and agreed with a plain Elixir
  reference and with Elixir mode (`Mod.__defk_elixir__/2`, and
  `Defk.Test.assert_agrees/3` over random sketch shapes, empty batches and
  hashes with the top bit set). One attempt, no compile error.
- Compile errors: none were hit, so this run gives no evidence on whether
  the errors' hints get an author unstuck. That half of the bar needs a run
  on a job that meets the subset's limits (defk-dig).
- Doc gaps it reported, fixed: no example combined a hash-to-bucket index
  with a counter bump in a `[u64]` table (the kernel is now the third example
  under docs/language.md "Writing", checked by the docs example test), and
  README did not say that a `mix run` script needs
  `use Defk, elixir_mode: true` for `__defk_elixir__/2`.

### Second cold test (defk-dig)

The same setup on a job chosen to meet the subset's limits: a batch decoder
for packed LEB128 varints (raising on a truncated one) and a streaming top-k
over `[f64]` with a small sorted buffer and early exit. The prompt did not
mention any limit. Full log:
[docs/cold-tests/leb128-topk.md](cold-tests/leb128-topk.md).

- Result: both kernels compiled and agreed with plain Elixir references
  (fixed cases and 200 random inputs each) and with Elixir mode after four
  attempts, from the docs alone.
- Compile errors: four were hit, all with the full why/hint/code frame.
  Rated by the author: unknown-type (`binary` -> `[u8]`) helped,
  array-in-branch ("do the array work inside each branch") helped,
  clause-head helped for its line but hid the real blocker (binary patterns
  in clause heads, ticketed defk-x4o), unsupported-list helped for inputs
  and only partly for a result. The redesign (array in, `{array, count}`
  out) came from docs/language.md; the error catalogue was never needed.
- One runtime error, an `i64` overflow in `bsl(1, 63)`, named its cause; the
  `u64` masking fix was in the docs but spread over two places.
- Fixed after the run: unsupported-list's hint and a docs row for results of
  unknown length; a bug the bitstring recipe exposed (`u64` segment values
  of 2^63 and up raised natively, not in Elixir mode); a docs note that a
  mask drops high bits silently; README instructions for depending on defk.

### Third cold test, from the built HexDocs (defk-djy.9)

A fresh session that could read only the built HexDocs (no repo source)
installed defk as a dependency of a new project and wrote a kernel for the
Shannon entropy of each 4096-byte window of a binary, then tested, measured
and deployed it, and answered scope and "defk or Elixir?" questions from the
docs. Full log, with the resolution of each point:
[docs/cold-tests/hexdocs-entropy.md](cold-tests/hexdocs-entropy.md).

- Result: the second attempt compiled and passed unit tests, an agreement
  property and a forced-yield test on the first run; ~25 minutes of reading.
  Measured by the tester on a loaded machine (provisional): ~16x an
  optimised Elixir baseline, one process against one call.
- Compile errors: 2 hit (unknown-function helped, for-collect partly), and 7
  deliberate probes (2 helped, 5 partly). The weak spots were generic hints
  for data-shape errors and a footer that pointed at a local path.
- 15 confusing points, all fixed in the docs or the messages or ticketed:
  footers are URLs outside the repo; the Markdown copies of the pages had
  dead links, now rewritten and checked by `mix docs`; new hints and
  rewrites for `:math.log2`, lists, `String.t()` and counter maps; guides now
  cover alloc in loops, errors in rounds, comparing over all schedulers,
  `[u8]` properties and the release workaround. Ticketed: log2 builtins
  (defk-ngj), errors inside rejected constructs (defk-uw9), a for-collect
  rewrite (defk-djy.13), a byte-histogram catalog entry (defk-9p6.28), the
  HexDocs main page (defk-djy.14, for a human), and a report note for alloc
  in a loop (defk-djy.15).

## Limitations

<!-- TODO(defk-sgw.5): limitations and what would change the verdict. -->
TODO: filled by defk-sgw.5.

## Method

Pre-registered: this section was committed before any workload row was filled (commit date is the pre-registration).

The workload-results table is generated from `examples/run_all.exs` output once defk-9p6.10 lands. See `examples/README.md` for the measurement details.

<!-- Source: defk-dtw.4 resolution comment (2026-10-05T19:30:53Z), quoted verbatim below. -->

Evidence bar per row:

> Evidence bar per row: baseline :optimized (no provisional verdict counts), quiet-machine run_all.exs, best of N with spread, machine/OTP/Elixir/commit, Elixir attempts linked from the example header. One machine; other architectures go under Limitations.

<!-- Source: defk-dtw.4 resolution comment (2026-10-05T19:30:53Z). -->

Go/no-go rule:

> Pre-registered go/no-go (recorded in Method before rows are filled): grow into a library only if (a) >= half the target workloads are good on optimised baselines, spanning >= 2 NIF-survey categories; (b) no open safety gap in the runtime contract (performance gaps OK); (c) devex bar met and the cold test completed a kernel from the docs alone; (d) the C-compiler-at-build-time stance is settled. Otherwise: a research result, not a library. The conclusion may argue against the rule's outcome only explicitly.

<!-- Source: defk-dtw.4 amendment comment (2026-10-05T21:21:53Z), by defk-dtw.15. -->

Amendment:

> Amended by 'Plan the catalog build for the six target workloads' (defk-dtw.15): each workload verdict is measured at a realistic size declared in the script before any numbers (recorded in Method beside the go/no-go rule); the other size and the crossover are reported beside it.
