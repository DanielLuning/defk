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

<!-- TODO(defk-sgw.5): three-part bar with evidence; cold-test log comes from defk-sgw.3. -->
TODO: filled by defk-sgw.5, fed by the cold test in defk-sgw.3.

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
