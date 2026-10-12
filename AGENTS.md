## Work Management

This project tracks work with `bw` (beadwork), which persists to git — plans, progress, and decisions survive compaction, session boundaries, and context
loss.

ALWAYS run `bw prime` before starting work. Without it, you're missing workflow context, current state, and repo hygiene warnings. Work done without priming
often conflicts with in-progress changes.

Committing, closing issues, and syncing are part of completing a task — not separate actions requiring additional permission.

## Purpose and measurement

defk exists to help Elixir, not to beat it. We are looking for the jobs where
Elixir today pushes people towards a hand-written NIF.

- **Elixir is the default.** If an Elixir solution is as good or as fast, it is the right choice, and that is a valid result to record.
- **Optimise the Elixir side before claiming defk.** Try the stdlib, Erlang BIFs and modules, established libraries, and a better data layout or algorithm. Measure the alternatives instead of assuming which is fastest, and write down what you tried.
- **Mark baselines honestly** (`baseline: :first_pass` / `:optimized` in `Defk.Bench.report/1`). A defk win over a first-pass baseline is provisional.
- **Keep comparisons fair.** Give both sides the same algorithmic tricks. Measure end to end from the data a real caller has, kept where a real app keeps it (shared indexes in `:persistent_term`/ETS, not on the benchmark process's heap, where GC skews the timing).
- **Treat Elixir wins as results, not failures.** Poor fits stay in the catalog.
- **Record what you learned about speed.** When a workload, example or ticket teaches you something about performance, add or update the entries in `docs/performance.md`, including what didn't help: numbers, conditions (mark loaded runs provisional) and the source.

Details: `examples/README.md`.

## Agent skills

### Issue tracker

Issues live in beadwork (`bw`), on the `beadwork` branch of this repo. See `docs/agents/issue-tracker.md`.

### Triage labels

The five default triage labels (`needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`), applied with `bw label`. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: one `CONTEXT.md` and `docs/adr/` at the repo root. See `docs/agents/domain.md`.

### Compiler map

Orientation before reading code: where each concern lives in the compiler,
the runtime header and the tests, and how to navigate (AST tools don't parse
Elixir; use grep and `mix xref`). See `docs/agents/compiler-map.md`.

### Generated docs

After changing the `Defk.Errors` registry, regenerate `docs/compile-errors.md` and parts of `docs/scope.md`. See `docs/agents/generated-docs.md`.
