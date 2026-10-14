# The runtime contract

A hand-written NIF runs inside the BEAM with no protection: a long one
blocks its scheduler, and a crash takes down the node. The **runtime
contract** is what a kernel promises the BEAM instead, while it runs. Its
purpose is that a kernel can never starve or crash the BEAM: for any
arguments it returns or raises, other processes keep running, and a crashing
process takes only itself down. A kernel that couldn't keep this would be
worse than a port, however fast it is.

This page says what each promise means for you, how defk keeps it, and where
it stops today. What each means inside a kernel is in
[Yielding and the runtime contract in practice](../language.md#9-yielding-and-the-runtime-contract-in-practice);
the BEAM side (scheduling, `enif_schedule_nif`, resources, upgrade) is in the
[BEAM/NIF reference](https://github.com/DanielLuning/defk/blob/main/docs/beam-nifs.md).
The four promises are part of [the stability promise](stability.md): later
releases keep them, while the numbers that tune them may change.

## 1. Preemption: a long kernel yields

You don't have to do anything for a kernel to share its scheduler:

- Every loop back-edge is a safepoint. A kernel reads the clock every 25 to
  60 µs of work, charges the time to its process, and after about 250 µs
  yields to its scheduler, then resumes where it stopped. Yielding never
  changes a result.
- Loops in kernels it calls yield too, because calls between kernels are
  inlined.
- A kernel with no loops never yields; it does a bounded amount of work.
- Kernels run on the normal schedulers, not dirty ones.

Measured on one scheduler with a 1 ms ticker, the worst gap beside a
yielding kernel was 2.3 to 2.5 ms, against 2.0 to 2.2 ms beside a busy Elixir
process (the
[results snapshot](https://github.com/DanielLuning/defk/blob/main/docs/project.md#results-snapshot), [`bench/tick_gap.exs`](https://github.com/DanielLuning/defk/blob/main/bench/tick_gap.exs)).

`yield: false` after the return type compiles a kernel without safepoints.
Use it only for kernels that always finish in well under a millisecond: the
same loop without safepoints left an 867 ms gap.

A kernel charges its process a whole timeslice per slice, far fewer
reductions per millisecond than Elixir code, and the BEAM wakes idle
schedulers by the reductions run on a crowded run queue. So that short calls
fanned out from one process (`Task.async_stream/3`) still spread, a
yielding kernel's function checks whether any processes are waiting
(`:erlang.statistics(:total_run_queue_lengths)`, about 9 ns a call) and, if
so, yields every 50 µs instead of 250 µs for the call's first millisecond.
A lone call is unchanged. 48 calls of 0.65 ms under `Task.async_stream/3`
went from 3 schedulers and 13.6 ms to 10-11 schedulers and 5.6-5.7 ms
(`defk-04y`; see
[Parallelism and schedulers](../performance.md#4-parallelism-and-schedulers)).
`use Defk, adaptive_slice: false` turns this off. `+swt very_low` spreads
such calls further.

## 2. Isolation: an error is an exception in the caller

A kernel touches only its own arguments and the arrays it allocates:

- Every array read and write is bounds-checked. The compiler leaves a check
  out only where it proves the index in range; there is no way to turn the
  checks off.
- Inputs are never changed. Arrays are values, as in Elixir: a write to an
  input array writes a copy, and the caller's binary stays as it was.
- Every runtime error (`ArithmeticError` for overflow or a float that would
  be inf or NaN, `ArgumentError` for a bad argument,
  `Enum.OutOfBoundsError`, `CaseClauseError`, a kernel's own `raise`) is an
  ordinary exception in the calling process, raised after the kernel's
  buffers are freed. Rescue it like any other.

```elixir
defk bump(a :: [i64], i :: i64) :: [i64] do
  a[i] = a[i] + 1
  a
end
```

```elixir
iex> a = <<1::signed-64-native, 2::signed-64-native>>
iex> M.bump(a, 1)
<<1::signed-64-native, 3::signed-64-native>>
iex> a
<<1::signed-64-native, 2::signed-64-native>>
iex> M.bump(a, 2)
** (Enum.OutOfBoundsError) index 2 out of bounds for array of length 2
```

What a kernel cannot do to the VM, because the kernel subset has no way to
say it: build or read BEAM terms other than its arguments and result, send
or receive messages, call Elixir or Erlang functions, do I/O, or keep native
state between calls. State travels as values, binaries in and new binaries
out ([ADR 0001](https://github.com/DanielLuning/defk/blob/main/docs/adr/0001-state-travels-as-binaries.md));
kernel-owned state is being explored in ticket `defk-sve`.

**A fault in kernel code is an exception too.** A crash in a kernel's
native code, such as a segmentation fault, would be a bug in defk's compiler
or runtime, not in your kernel: defk prevents it by construction (checked
accesses, no pointers in the subset) and tests for it (agreement properties,
forced yields, hostile arguments, sanitizers, fuzzing). If one happens
anyway, the runtime turns it into a `RuntimeError` in the calling process
whose message starts with "defk bug" and names the signal and the address,
after the kernel's buffers are freed; the node keeps running. File it, do
not rescue it.

**Where isolation stops.** The runtime contains a fault only inside the
kernel's own code while the kernel runs. A fault in the C library or in the
VM itself (also when a kernel called into them), a wild write that happens
not to fault, or a corrupted C stack still takes the whole node down, as any
NIF crash does; so does a fault on Windows, where the mechanism does not
exist.

## 3. Cleanup: a dead process frees its kernel's memory

A kernel starts on the C stack. Only when it first yields is its state moved
into a frame that the BEAM owns, and that frame's destructor frees the
kernel's arrays and bitstring buffers. So if a process is killed while its
kernel is suspended, nothing leaks: `Mod.__defk_stats__().frames_live` goes
back down. `alloc/2` raises `ArgumentError` for a length over 2^48 bytes or
one the allocator cannot provide, instead of failing later.

A kernel's arrays live until it returns, so an `alloc` or a copy in a loop
body keeps one per iteration. On an operating system that overcommits
memory, the node would be killed long before the allocator failed, so each
call has a budget: an allocation that would take the bytes it holds past
`use Defk, max_owned_bytes: n` (by default half of physical memory) raises
`ArgumentError` "out of memory" in the caller, and frees what the call held
([the owned-buffer budget](../language.md#the-owned-buffer-budget)). It
bounds one call, not the node: many concurrent calls near their budgets can
still exhaust memory, as many Elixir processes can.

## 4. Hot code upgrade: a suspended kernel finishes in its own code

Recompiling a module builds a new native library next to the old one. A
kernel suspended across the reload finishes in the library it started in,
and the old library stays loaded until it does. A second reload (or
`:code.purge/1`) before it finishes kills the process, like any process
still running old Erlang code.

## How it is checked

- Agreement of every kernel with its Elixir mode, on edge values and
  generated inputs, and with a forced yield at every safepoint (see
  [Testing kernels](testing.md)).
- `test/resume_test.exs`, `test/upgrade_test.exs`,
  `test/fault_containment_test.exs` (faults injected into a kernel, in the
  VM and in a child VM) and the `bench/tick_gap.exs` and
  `bench/yield_cost.exs` measurements, described in the
  [design decisions](https://github.com/DanielLuning/defk/blob/main/docs/project.md#design-decisions-the-benchmarks-validated).
