# ADR-0004: Test fixtures may exercise the constructs the linters forbid

- Date: 2026-10-09
- Status: accepted
- Source: `bw show defk-x15.5`, commit `0581e4a`

## Context

`mix credo --strict` flagged code whose entire purpose is to prove defk
compiles a construct Credo would rather you not use:

- `test/select_test.exs` and `test/early_exit_test.exs` contain kernels whose
  body is a `cond` with exactly one condition before `true` — `cond_square`
  deliberately only passes through when `keep`, and the overflow it tests is
  in the `true` branch, so the one-branch form is the fixture. Credo's
  `CondStatements` reads it as prose and suggests `if`.
- `test/elixir_mode_test.exs` contains a `defk debug` kernel calling `dbg/1`
  and `IO.inspect/2` — those calls are the test: they prove the constructs are
  available in Elixir mode and their tracing output works.

These are not production code and not sloppy production code; rewriting them
to satisfy the linter would turn each test into a different test.

## Decision

Site suppressions with a reason comment immediately above the construct, each
naming the exact check disabled:

- `# credo:disable-for-next-line Credo.Check.Refactor.CondStatements`
- `# credo:disable-for-next-line Credo.Check.Warning.Dbg`
- `# credo:disable-for-next-line Credo.Check.Warning.IoInspect`

The scope is one line; no file-wide or check-wide disabling was added for
these (the single exception is `resume_test.exs`, ADR-0003, where the flagged
function is quoted fixture data Credo cannot see as data).

## Consequences

- The cond fixtures stay honest: a `cond` with one condition is exactly what
  the compile-under-test handles, and converting to `if` would couple the
  fixture to the very transformation the compiler already performs.
- `mix credo --strict` in `mix ci` passes; the suppressions are visible in
  review and each carries its reason inline.
- Cost of revisited policy: these three comment kinds are the search surface
  if the team ever decides test fixtures must be lint-clean.

## How to revisit

If a fixture can exercise the same kernel shape without the flagged construct
(an equivalent `if` form that still hits the same compile path), prefer the
change over the suppression. Re-check after any credo upgrade: the three
checks may gain a config to ignore test directories, at which point these
comments become redundant.