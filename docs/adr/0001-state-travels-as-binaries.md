# ADR-0001: State travels as binaries

- Date: 2026-10-05
- Status: accepted
- Source: `bw show defk-dtw.9` (resolution, 2026-10-05)

## Context

Two of the six target workloads keep native state between kernel calls: HLL
keeps its registers, and Gorilla keeps the previous chunk's encoder state
(previous value, previous leading/trailing zero counts, …). The choice was
between the kernel owning that state as a resource mutated in place, and the
caller passing packed state back in on every call.

The one rule constrains this: a kernel is Elixir over numbers and binaries, so
whatever a kernel does, Elixir mode must be able to do the same way. A
kernel-owned mutable resource has no Elixir meaning — Elixir mode could only
fake it with ETS or the process dictionary — and mutating an input binary in
place would change the caller's binary, which is a divergence.

## Decision

State travels as values: binaries and scalars in, a new binary or tuple out.
`defk upd(regs :: [u8], items :: [i64]) :: {[u8], i64}` compiles and returns
`{new_regs, n}`. (Amended by `defk-dtw.10`: HLL is
`update_many(regs :: [u8], hashes :: [u64]) :: [u8]`.)

- A kernel never mutates an input binary in place.
- Kernel-owned mutable state is not part of the kernel subset.

## Consequences

- **One rule holds in Elixir mode.** State is an ordinary value, so the Elixir
  version computes the same result from the same inputs with nothing faked.
- **The per-call copy is accepted.** HLL is 16 KiB of registers per call (at
  100 items it likely dominates the update itself). BEAM binaries are
  immutable, so the Elixir version and almost certainly a hand-written NIF pay
  the same copy; the catalog measures it rather than assuming it.
- **Kernel-owned resources stay an expansion candidate** ("persistent mutable
  structures via kernel-owned resources"), listed in the verdict's *Where
  defk could grow* and not built. See `CONTEXT.md` for what an *expansion
  candidate* means.
- Suspended-kernel frames are unaffected: they are runtime-owned bookkeeping
  (README design decision 4), not state a kernel can see.
