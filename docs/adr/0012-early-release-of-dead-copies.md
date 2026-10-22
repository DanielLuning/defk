# ADR-0012: A dead copy is released early; an alloc lives until return

- Date: 2026-10-22
- Status: accepted (2026-10-22: the maintainer chose "copies only" from
  the design proposal on the ticket)
- Source: ticket `defk-c1e` in epic `defk-w8r`, follow-up to `defk-4b2`
  (the owned-buffer budget)

## Context

Every buffer a kernel call owns (`alloc/2`, a value-semantics copy, a
bitstring accumulator, an aligned copy of a misaligned input) is a slot in
`ctx->owned` and lives until the kernel returns. `defk-4b2` bounded the
total with `max_owned_bytes`, so a copy or an alloc inside a loop raises
"out of memory" instead of taking the node down, but the buffers still
accumulate: `b = a; a[i] = x; ... b[0]` in a loop body copies `a` every
iteration (docs/language.md, Copies), and each copy is kept until return
although only the latest two are ever read again. Elixir would
garbage-collect the rest.

Two facts of the compiler decide what can be released safely:

- The copy analysis (`Defk.Copies`) already tracks which bindings *may*
  share a buffer: alias classes for the arrays an `if`, `cond` or `case`
  gives, and `{id, buf}` pairs for what is live after a statement and after
  a block. A buffer no live pair may share is dead.
- The analysis gives a loop accumulator a fresh buffer ref whether or not
  its initial value was copied, so one physical buffer can carry two refs
  (the dead outer binding's and the accumulator's). That is harmless for
  the copy decision (the outer binding is dead, or a copy was made) but
  unsound for a release: a buffer could be released through one ref while
  the other is live.

Elixir mode enforces the same `max_owned_bytes` on the bytes `alloc/2`
asks for, and docs/language.md promises that native code's total is never
below Elixir mode's, so an `alloc/2` in a loop raises at the same iteration
in both modes. Releasing a dead `alloc/2` buffer natively would invert
that: native code would succeed where Elixir mode raises.

## Decision

1. **Only copies are released early.** A buffer is released where the last
   binding of the block that holds it dies (after a statement nothing
   later reads it, or after the block's last statement with the block's
   value bound to locals first), when the buffer was made by a copy and no
   live holder may be the same buffer. `alloc/2` buffers, bitstring
   accumulators and aligned input copies live until return, as before, so
   the budget agreement with Elixir mode stays as written.
2. **One physical buffer, one "may be the same" class.** `Defk.Copies`
   records, beside the alias classes, which buffers are physically one
   (`phys`: an accumulator and its source when no copy was made, the
   accumulator and its body binding and its result, a merged value and
   each arm's buffer) and which were made by a copy (`origin`). The release
   test asks `may_same?/3` over both. An accumulator's buffer counts as a
   copy only when its initial value was copied (or was a copy) and every
   new value the body gives is a copy: the body is lowered under that
   assumption and lowered again without it when a new value breaks it,
   through the same backtracking as the accumulator facts.
3. **The runtime keeps the slot.** `defk_disown(ctx, data)` releases the
   binary, subtracts its bytes from the budget and puts the slot on a free
   list threaded through the empty slots, which `defk_own_raw` fills before
   taking a new one, so a loop's table stays small. The array value stays
   two words (data, length); the slot is found by a backward scan, since
   the buffer that dies is usually a recent one. A slot index inside every
   array value was rejected: it would touch every array operation.
4. **A stale pair does not hold a buffer.** A `{id, buf}` pair live after a
   block whose binding was since copied in place (the same id with a
   buffer that is not physically `buf`) names a buffer the binding no
   longer holds. An accumulator binding stands in for the outer binding it
   took its buffer from without a copy (`take_over/3`), so the loop
   statement's reads of that name, resolved before the body bound it
   again, do not keep the old buffer alive.

Two calls the implementation made beyond the owner's "copies only":

- The release point is every block whose bindings die with it (an arm, a
  loop body, an inlined callee's body), as the proposal recommended, and
  also the kernel's own body, which the proposal said needed nothing:
  there a dead copy is released before the next statement instead of at
  return (`copy_kept` in `test/owned_budget_test.exs` releases the hoisted
  copy of its input after the loop). One rule, one code path.
- A plain nested block (`x = (a; b)`) releases nothing: its bindings live
  on in the block around it.

## Consequences

- A per-iteration copy whose binding dies holds at most two buffers at a
  time instead of one per iteration; `test/owned_budget_test.exs` runs
  1000 iterations of a 1 KiB copy under an 8 KiB budget, natively and in
  Elixir mode, also under forced yields and as a property.
- The release is static and conservative: a buffer an `if`/`cond`/`case`
  value may hold, or one a loop accumulator may hold when not every value
  is a copy, is never released early (`copy_kept` in the same test still
  raises past the budget).
- A released binding's C local is stale at the next spill; a spill is a
  store, never a dereference, and the binding is bound again before any
  read. The generated C of a kernel without a dying copy is unchanged but
  for `free1 = 0` in the entry.
- The report says where each copy is released; a copy in a loop that is
  not released is still noted as kept per iteration.
