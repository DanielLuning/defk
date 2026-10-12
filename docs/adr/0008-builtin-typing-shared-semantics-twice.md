# ADR-0008: Builtin typing is shared data; builtin semantics are written twice on purpose

- Date: 2026-10-12
- Status: accepted (2026-10-12, maintainer, architecture review grilling)
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
