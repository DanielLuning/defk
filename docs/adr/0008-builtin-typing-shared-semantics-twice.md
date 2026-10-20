# ADR-0008: Builtin typing is shared data; builtin semantics are written twice on purpose

- Date: 2026-10-12
- Status: accepted (2026-10-12, maintainer, architecture review grilling);
  extended 2026-10-20 (the rest of the typing, below)
- Source: /improve-codebase-architecture session 2026-10-12; evidence in the
  review of `Defk.Compiler.builtin/4` and `Defk.ElixirMode.builtin/4`

## Context

A builtin exists in two emitters: the compiler lowers it to C, Elixir mode
translates it to `Defk.ElixirMode.Ops` / `Defk.Bits` calls. Today both
emitters also repeat the builtin's *typing* — which operand types it
accepts, its result type, which operands coerce — as two hand-maintained
pattern tables that must agree (adding `crc32c` touched six code places).
The obvious deduplication is to drive both emitters, typing and behaviour,
from one table.

## Decision

`Defk.Builtins` grows into the single signature table: name × operand type
patterns → result type + coercions, consumed by both emitters, with
irregular builtins marked `typing: :bespoke` so the table stays total. The
table generates agreement kernels: one tiny kernel per concrete type
combination, compiled in both modes and checked with `assert_agrees`.

The *semantics* stay written twice, independently: C in
`priv/defk_runtime.h`, Elixir in `Ops`/`Defk.Bits`. This is deliberate and
must not be "fixed". Under the one rule, Elixir mode is the oracle that
defines what a kernel must return; if its emissions were generated from
the same table as the C lowering, a table error would propagate to both
sides and the agreement tests could no longer catch it. Typing gains
nothing from this independence — a typing drift surfaces only as a
confusing mode-specific "unsupported" — which is why typing is shared and
semantics are not.

(Message *text* is different again: runtime error messages may be
single-sourced between `defk_runtime.h` and `Ops`, because identical
wording is a rendering concern and carries no semantic weight; agreement
remains defined as same exception module for the same reason.)

## Consequences

- A new builtin adds one table row, one C implementation, one Elixir
  implementation; the generated agreement kernels enforce that all three
  exist and agree.
- Anyone proposing to generate the Elixir emissions (or `Ops` bodies) from
  the table should be pointed here: it would silently retire the oracle.

## Extension (2026-10-20): the rest of the typing also stays twice

- Status: accepted (2026-10-20, maintainer)
- Source: the spike `defk-rt2.11` (its ticket comment has the numbers)

Beyond the builtins, Elixir mode types every node again: `expr/2`
returns `{quoted, type}`, and the u64 accumulator inference
(`settle_accs/3`, `note_u64_mix/3`) is a hand copy of the compiler's
`u64_accs/2`. The spike asked whether the compiler could hand Elixir mode
its node types, so that Elixir mode only emits.

The seam exists. The compiler runs first, on the same desugared kernels,
and a unique id stamped into each node's meta keys a node (a line and a
column do not: a kernel built by a macro has no columns). The stamp left
the C of every test and example module byte-identical, and 99.2% of
Elixir mode's 58,361 keyed node typings equalled the compiler's own. The
rest are four special cases: `bitstring` and `[u8]` naming, nodes the
compiler types twice (u64 retries, `in` guards), float trees that do not
pass `lower_expr`, and helpers that are only inlined.

Decision: Elixir mode keeps its own typing. Two reasons:

- The u64 accumulator inference is semantics, not typing: it decides the
  result. `3 - 5` on a u64 accumulator raises, on an i64 one it is `-2`.
  Shared, an inference error in the compiler would pass every agreement
  test, which is what the decision above forbids.
- Without that part the gain is about 20 lines (`body_type/3`, the
  `leaf_types` look ahead). `expr/2`'s types and `trial/1` stay in any
  case, as the emission and the write discovery use them. The cost is a
  stamping step, type records in several lowering paths, the four special
  cases, and an Elixir mode that depends on the compiler's lowering
  instead of the AST.

## How to revisit

A proposal to share node types with Elixir mode answers both reasons: an
independent check of the u64 accumulator inference, and a gain larger than
the four special cases and the coupling.
