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
[results snapshot](https://github.com/DanielLuning/defk/blob/main/docs/project.md#results-snapshot-m-series-mac-otp-29-elixir-120-noisy-single-runs), [`bench/tick_gap.exs`](https://github.com/DanielLuning/defk/blob/main/bench/tick_gap.exs)).

`yield: false` after the return type compiles a kernel without safepoints.
Use it only for kernels that always finish in well under a millisecond: the
same loop without safepoints left an 867 ms gap.

What preemption does not fix: short kernel calls charge the scheduler less
than Elixir code of the same length does, so many sub-millisecond kernel
calls from `Task.async_stream/3` stay on a few schedulers instead of
spreading (ticket `defk-6lr`; see
[Parallelism and schedulers](../performance.md#4-parallelism-and-schedulers)).

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

**Where isolation stops today.** A crash in a kernel's native code, such as a
segmentation fault, would be a bug in defk's compiler or runtime, not in your
kernel. Like any NIF crash, it takes the whole node down. defk prevents
crashes by construction (checked accesses, no pointers in the subset) and
tests for them (agreement properties, forced yields, hostile arguments), but
does not yet contain one. Turning such a crash into an exception in the
calling process is ticket `defk-7dm`, still open; the
[scope page](../scope.md#not-yet-planned) lists it.

## 3. Cleanup: a dead process frees its kernel's memory

A kernel starts on the C stack. Only when it first yields is its state moved
into a frame that the BEAM owns, and that frame's destructor frees the
kernel's arrays and bitstring buffers. So if a process is killed while its
kernel is suspended, nothing leaks: `Mod.__defk_stats__().frames_live` goes
back down. `alloc/2` raises `ArgumentError` for a length over 2^48 bytes or
one the allocator cannot provide, instead of failing later.

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
- `test/resume_test.exs`, `test/upgrade_test.exs` and the
  `bench/tick_gap.exs` and `bench/yield_cost.exs` measurements, described in
  the [design decisions](https://github.com/DanielLuning/defk/blob/main/docs/project.md#design-decisions-the-benchmarks-validated).
