# ADR-0003: Credo complexity and nesting thresholds for a compiler codebase

- Date: 2026-10-09
- Status: accepted
- Source: `bw show defk-x15.3`, `bw show defk-x15.4`, commits
  `7382db2`, `e842a0e`

## Context

`mix credo --strict` (part of the `mix ci` gate, `defk-x15`) reported the
compiler's decision-table functions far over Credo's defaults
(`CyclomaticComplexity` max 9, `Nesting` max 2). Before raising anything we
decomposed every function that could be honestly split (`defk-x15.3`): the
comparison lowering, the `case_arms`/`emit_entry` emitters, `__before_compile__`,
`builtin_arguments!`, `parse_kernel`, `elixir_mode`'s `finish`, and the
`lower_expr` comparison clause — ten helpers, each one `if(yields?)` branch
wide. That work also fixed a real duplicate-clause bug in the Elixir-mode
dispatch (`native_stubs`/`dispatch_defs` split).

After the extractions the worst surviving function is a single decision table
at complexity 14 (`compare_numeric_c`, `byte_fields`, elixir_mode `finish`);
the worst nesting is depth 3 in AST-lowering idioms (`errors.ex` `span`,
elixir_mode `tail_expr`/`cond_form`, compiler `argument_fix`, `compile`,
`byte_fields`). These are many-way patterns over one value, or builder
functions whose bodies walk a syntax tree one level deeper than prose — they
are the compiler's shape, not accidental growth.

## Decision

Calibrate, do not bless:

- `.credo.exs`: `CyclomaticComplexity [max_complexity: 15]` — the single-table
  ceiling is 14, so 15 passes the current truth with one point of margin and a
  growing table trips the check again.
- `.credo.exs`: `Nesting [max_nesting: 3]` — same ceiling reasoning for the
  depth-3 AST idiom; depth 4 is still caught.
- The check stays on `--strict`; these are the only two `Refactor` settings
  overridden, everything else uses Credo's defaults.

`test/resume_test.exs` `shapes` (complexity 20, depth 4) is the one function we
did not keep: it is fixture data quoted inside a macro, so Credo counts the
kernel bodies' nested `for`s as one function. Its file carries a file-scoped
`credo:disable-for-this-file` with a comment explaining the artifact (ADR-0004
covers the fixture policy).

## Consequences

- A future contributor who adds a 16th branch to a decision table, or nests a
  builder one level deeper, gets a failing `mix credo --strict` — the threshold
  still functions as a tripwire, just at the compiler's real ceiling.
- `mix ci` no longer stops at credo; the gate continues to dialyzer, ex_dna,
  and reach.
- The `# credo:disable-for-this-file` on `resume_test.exs` is the only
  file-scoped credo suppression in the repo; it names its reason in the
  adjacent comment.

## How to revisit

Re-evaluate either threshold if a real refactor changes the ceiling: every
option is still the compiler's floor, and a future plain-Elixir rewrite of a
pass (the project's stated preference, `AGENTS.md`) should make the
extractions moot and let the thresholds come back down.