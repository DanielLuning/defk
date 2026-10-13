# ADR-0009: A fault inside kernel code is an exception, not a node crash

- Date: 2026-10-13
- Status: accepted
- Source: `bw show defk-7dm` (feasibility note and decision, 2026-10-13)

## Context

A kernel never faults by construction: every array access is checked or
proven in range, integer arithmetic is checked, and the kernel subset has no
pointers. So a hardware fault (`SIGSEGV`, `SIGBUS`, `SIGILL`, `SIGFPE`)
inside a kernel's native code is a defk bug. Before this decision such a
fault killed the node, as any NIF crash does, and the runtime contract's
isolation promise ("a crashing process takes only itself down") rested on
prevention and evidence alone: the threat list, the differential checks, the
sanitizer and Valgrind runs, the fuzzing of the decoder kernels.

The from-scratch decoders (`defk-52v`: LZ4, Snappy, later inflate and
JPEG) parse attacker-controlled bytes, and each of their catalog entries
claims "raises, never crashes the VM". That claim needed a second line of
defence behind the checks.

Two designs were weighed:

1. **Contain the fault in the VM.** A signal handler installed by each
   kernel library turns a fault inside that library's code, while one of its
   kernels runs on the faulting thread, into a `RuntimeError` for the
   calling process, and chains every other fault to the handler that was
   there before.
2. **Run kernels outside the VM.** A port program or an `erl_interface` C
   node gives real OS-process isolation: a fault, or a wild write that never
   faults, kills only that process. The price is two pipe transfers per call
   before any term encoding or work.

## Decision

Design 1. The runtime header installs the handler (`defk_fault_handler` in
`priv/defk_runtime.h`); the generated guard function marks the running call
in a thread-local (`defk_cur_ctx`). A fault is contained when, and only
when, it is synchronous (`si_code > 0`), a kernel of that library runs on
the thread, and the faulting PC is inside the library's own executable
segment. Then the handler records the fault and `siglongjmp`s to the guard,
exactly as a bounds check raises: the NIF frees the call's owned buffers and
raises `RuntimeError` with the signal, the code, the address and the PC
offset, and the words "defk bug".

Everything else chains to the previous handler and kills the node as
before: a fault in ERTS, in libc called from a kernel (`memcpy`, libm: a
longjmp out of an allocator or a lock would corrupt it), in another NIF, or
in a kernel library while no kernel runs. A wild write that happens not to
fault is not a fault and cannot be contained; the verification tooling
(`verify/`, `DEFK_SANITIZE`) is what finds those.

ERTS coexistence follows OTP PR #7174: `SA_ONSTACK` (ERTS runs handlers on
an alternate stack on its scheduler threads), `SA_SIGINFO`, `SA_NODEFER`
(the guard's `sigsetjmp(jb, 0)` saves no mask, so the signal must not be
blocked when the handler longjmps out), the previous `sigaction` saved and
chained. An image leaves the chain or stays mapped, never both: at unload it
restores the previous handler if its own is still the installed one, else it
pins itself (`dlopen` with `RTLD_NODELETE`); at upgrade the new image pins
the old one through the `priv_data` ERTS hands over, because ERTS never
calls an upgraded image's unload and its suspended kernels keep running
until the purge. An image that is still in the chain is never installed a
second time: the same `.so` loaded again (a module reloaded with unchanged
code gets the same image and the same statics from `dlopen`) would
otherwise save its own handler as the previous one, and the first fault
would spin forever inside the handler. That hang was found by the test
suite, which reloads unchanged modules often; a thread-local re-entry
guard now also turns any fault inside the handler itself into the default
action, so a handler bug can crash the node but never hang it.

Design 2 stays available as a choice for a caller, not as defk's design: a
kernel's C can be linked into a port program, and the measured floor of that
boundary is recorded in `docs/performance.md` (7.10) so the verdict can say
when it pays.

## Consequences

- **The isolation promise now has a mechanism, not only evidence.** A fault
  in kernel code is an ordinary exception; `test/fault_containment_test.exs`
  injects a segmentation fault, an illegal instruction and (on x86-64) a
  division by zero at a clock read, on the C stack and in a promoted frame,
  and checks the caller gets the exception, the buffers are freed, the frame
  count goes back down, a concurrent kernel in another process is unaffected,
  and the chain holds across a hot upgrade and across unloads. Three cases
  that must still kill the node (a fault in libc called from a kernel, a
  fault in the library outside a call, and the last fault after the chain
  tests) run in a child VM.
- **Cost: one thread-local lookup and two stores per call.** `inc/1` (a
  scalar kernel) 12.5-12.7 ns per call on `main` against 12.7-13.2 ns with
  the handler, interleaved, load 3.9-4.0 on 12 cores; `spin(10)` 42-44 ns on
  both. A first version with two thread-local lookups cost 2.5 ns more,
  because `__thread` in a dylib on macOS arm64 is a call per access; the
  guard now takes the address once.
- **On macOS, kernel libraries are never unmapped any more.** dyld never
  unloads an image that has thread-local storage, so a purged kernel library
  stays mapped (its `.so` size, typically 50-500 KB) for the life of the
  node, pin or no pin. On Linux (glibc) the image is unmapped unless the
  chain rule pins it. A `pthread_key` instead of `__thread` would give the
  unmapping back on macOS at a cost per call not yet measured; revisit if
  hot reloads in a long-lived node ever make it matter.
- **Not covered, and documented as such:** Windows (no `sigaction`); a
  fault inside libc or ERTS called from a kernel; a wild write that does not
  fault; a corrupted C stack (`-fstack-protector-strong` aborts, which is
  `SIGABRT` from libc and not contained). The runtime contract guide names
  these.
- **Reporting:** the message names the signal, `si_code`, the faulting
  address and the PC offset into the library, so a report can be matched to
  the generated C (`mix dump_c`). It says "defk bug": a user who sees it
  should file it, not catch it.
- **Elixir mode is unaffected.** A fault has no Elixir meaning; the raise is
  a divergence by definition and a bug to fix, never a limit to document.
