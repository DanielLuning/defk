# ADR-0011: The measurement harness ships; the scoreboard cache does not

- Date: 2026-10-19
- Status: accepted (2026-10-19: the maintainer accepted the recommendation
  in the architecture-review grilling)
- Source: /improve-codebase-architecture session 2026-10-19, candidate 1;
  ticket `defk-x3a.1` in epic `defk-x3a`

## Context

`lib/` is what a Hex user installs. Before this decision it held, beside
the compiler and the runtime, the whole measurement tooling of the example
catalog: `Defk.Bench` (the harness: `report/1`, timing, verdict bands, the
`DEFK_RESULT` line), `Defk.Bench.Cache` (a result cache keyed by the
kernels' `.beam` files, the build inputs, the script, the CPU model and
more; the quiet test over a `ps` walk of the process tree; stamps) and
`Defk.Bench.TickGap`. A user who reads `lib/` to learn what the library is
finds a scoreboard runner next to the compiler.

The obvious move, all three modules to `dev/` (compiled in `:dev` and
`:test`, never packaged), breaks two things a user and the catalog depend
on:

- `docs/guides/measuring.md`, a shipped guide, tells users to call
  `Defk.Bench.report/1` to measure their own kernel.
- Every example script loads defk with `Mix.install([{:defk, path: ...}])`,
  and `mix defk.examples` runs each script as a child `elixir` process. A
  path dependency compiles `lib/` only, so a module in `dev/` is not there
  in that child.

## Decision

The seam goes through `Defk.Bench.Cache`, not around `Defk.Bench`.

- `Defk.Bench` stays in `lib/` as the user harness. It absorbs the
  measurement hygiene that every `report/1` under the runner needs:
  `wait_quiet/0`, `other_cpu/0`, `quiet?/1`, `quiet_limit/0`. The
  `DEFK_RESULT` line stays with it: it is one `IO.puts`, check-only runs
  print it too, and it is the protocol the runner parses.
- The result cache (`lookup/1`, `store/3`, `cpu_model/0`, the key parts,
  the file format) is the runner's adapter and lives in
  `dev/defk/bench/cache.ex`, never packaged. `mix defk.examples --bench`
  loads it into each example's process with `elixir -r` before the
  script's `Mix.install` brings defk. `Defk.Bench.report/1` asks the cache
  only when `Code.ensure_loaded?/1` says it is there, through a dynamic
  call, so `lib/` compiles without it.
- Two adapters make the seam real: none for a user running
  `elixir examples/x.exs` or their own script (every report measures, as
  before), the cache for the catalog runner.

## Consequences

- `lib/` loses the cache and the CPU-model and process-tree code; what
  stays measures a kernel and says whether the machine was quiet.
- A future review must not propose moving `Defk.Bench` out of `lib/`
  while the measuring guide documents it and the examples load defk as a
  path dependency; nor merging the cache back in for convenience.
- `Defk.Bench` stays "unstable public" (ADR-0006). Moving the cache is a
  documented change (`CHANGELOG.md`), not a promise break.
