# ADR-0007: Range facts are symbolic bounds over ranked atoms

- Date: 2026-10-12
- Status: proposed
- Source: `bw show defk-2mz` (design); the research and walk-throughs are in
  [`docs/research/relational-facts.md`](../research/relational-facts.md).
  Unblocks `defk-pic`, `defk-siy`, `defk-n7k`, `defk-9za`.

## Context

A bounds check is dropped when the compiler's range facts prove the index
in range. Today a fact relates one value to constants (`lo`, `hi`) and to
array lengths (`lb`, `ub`, `len_lo`, `len_lb`, and defk-upc's scaled forms
`q * v <= p * len(a) + k`). Nothing relates two scalars, and nothing is
learned from a condition. Four tickets keep checks for that reason:
`len(out) == n` after `alloc(e, n)` (pic), `base + i < len(b)` from a bound
with three terms (siy), `r * dim + j < len(m)` from `n = div(len(m), dim)`
(n7k), and `i - w >= 0` inside `if i >= w` after a raise when `w < 1` (9za).
A fact kind per ticket would multiply cases in every place facts are made,
merged, carried and reported, and difference bounds (`x <= y + c`) leave
siy and n7k out.

## Decision (proposed)

Replace the fact model with one representation:

- **Atoms** are the C variables of i64 bindings and the lengths of array
  bindings, ranked by binding order (`fresh/2`'s counter; parameters
  first).
- **Facts** are `q * x <= P` and `q * x >= P` for an atom or a product of
  two atoms `x`, with `q >= 1` and `P` a polynomial of degree at most 2 over
  atoms ranked below `x`, plus the constant `lo`/`hi` kept as they are.
  Values carry their exact form and bounds; the env carries the facts of
  atoms in scope.
- **One prover** decides `D <= 0` by replacing the newest atom by one of its
  bounds until a constant is left, with a step budget; an unproven query
  keeps the check.
- **Sources:** exact checked arithmetic, `min`/`max`, `div`, range loop
  bounds and non-emptiness, alloc and copy lengths, and conditions: `if`,
  `cond`, `for` filters, `and`, and raising guards (`if c, do: raise ...`).
- Today's facts are special cases and are migrated, not kept beside the new
  ones.

## Consequences

- **The four tickets become sources of facts**, not new kinds; each later
  addition is a rule that records facts, and `in_bounds?/3`, the
  accumulator carry and the report stay one code path.
- **Soundness rules the compiler must keep:** facts describe exact integers
  (no forms from masked or u64 arithmetic; each operation keeps or drops its
  own overflow check); facts are lexically scoped and mention only older
  atoms; an arm that used its own condition to drop a check is never a
  select; a condition narrows only from operands computed without a check
  that a flagged strip could run on past. The proof's support is visible to
  the flagged-strip classifier (`fixed_indices?/3`).
- **Cost:** a bounded search per query; estimated 1-2% of the compiler's
  own time on the test suite, about 10% if every query exhausted its budget
  (provisional, from a prototype prover; clang not included).
- **Raising guards become the way to state facts about arguments** in a
  kernel, which the language docs would describe.
- **Out of scope:** degree 3 and nested products, facts across loop
  iterations for scalar accumulators, facts about array contents,
  disjunctions and `!=`.
- **Migration risk:** the first step must leave the generated C of every
  test kernel and example byte-identical.

## Alternatives considered

- **A fact kind per ticket:** rejected, see Context.
- **Difference bounds (ABCD-style shortest paths):** covers pic and 9za,
  not siy loop 1 (three terms) or n7k (a product).
- **A general solver (Fourier-Motzkin, Presburger, SMT):** decides more, at
  a less predictable compile-time cost and, for SMT, a dependency.
