# BEAM/NIF reference

What a kernel actually depends on in the Erlang runtime: how a NIF executes,
what its arguments and memory mean, how it raises, how it loads and survives a
hot code upgrade, and when a job should not be a NIF at all.

The facts below are grounded in the OTP documentation, in this repo's generated
code and runtime header, and in the design decisions in docs/project.md; file and line are
given where practical. Where something is defk's reasoning rather than an OTP
requirement, it says so. Where a fact is not settled, it says that too.

Code references in this document cite symbols by name rather than line number,
so they survive refactors; where a line range conveys essential context, it is
kept as "around `symbol`".

Vocabulary is `CONTEXT.md`'s: a **kernel** is a function written in the kernel
subset and compiled to native code (a kernel is compiled to one NIF library,
but a NIF is any native function); the **runtime contract** is what a kernel
promises the BEAM while it runs.

## 1. Execution model

A NIF runs *on the scheduler thread that called it*, as a direct extension of
the VM's native code. From the `erl_nif` manual page:

> Execution is not made in a safe environment. The VM _cannot_ provide the
> same services as provided when executing Erlang code, such as pre-emptive
> scheduling or memory protection. If the native function does not behave
> well, the whole VM will misbehave.
>
> - A native function that crashes will crash the whole VM.

and, on duration:

> A native function doing lengthy work before returning degrades
> responsiveness of the VM, and can cause miscellaneous strange behaviors.

and, on how long is too long:

> It is difficult to give an exact maximum amount of time that a native
> function is allowed to work, but usually a well-behaving native function is
> to return to its caller within 1 millisecond.

(In the local OTP 29 install, `erts-17.0.3/include/erl_nif.h` carries
declarations and a version history only; this prose lives in the `erl_nif`
manual page for that header. See §8 for the URL.)

**Scheduling knobs.** OTP offers three answers to a long call, in the order
its documentation prefers them: split the work and yield with
`enif_schedule_nif`, hand it to another thread, or run it as a dirty NIF. The
documentation calls yielding "always preferred over the other alternatives".

- **`enif_schedule_nif` is defk's yield.** It schedules a new NIF call; the
  calling NIF "must use the return value of `enif_schedule_nif` as its own
  return value", and it "only schedules the NIF for future execution" — the
  current call returns immediately, the scheduler runs other processes, then
  the continuation runs. defk uses it in both wrappers: once to hand off a
  first call that yielded (`promote/2` in lib/defk/compiler.ex) and once per resumed
  step (`step_fn/3` in lib/defk/compiler.ex).
- **`enif_consume_timeslice` is return-time accounting only.** It reports how
  much of the process's timeslice the call has used and returns `1` when the
  slice is exhausted, at which point "the NIF is to return as soon as
  possible". It is a hint the runtime may act on when the NIF returns; it
  cannot stop a loop that is already running. A kernel that only called it
  would still block its scheduler for the whole loop. defk therefore decides
  *to* yield from its own wall-clock safepoints and uses
  `enif_consume_timeslice` to *charge* the time: every loop back-edge counts
  against a budget, `defk_tick` reads `enif_monotonic_time` and adapts that
  budget so the clock is read every `DEFK_SLICE_US/10` … `/4`
  (around `defk_tick` in priv/defk_runtime.h), and a spent budget returns `0`, which makes
  the loop return `DEFK_YIELD`. `DEFK_SLICE_US` is 250 µs
  (`DEFK_SLICE_US` in priv/defk_runtime.h); the safepoint macro is
  `sp_macro/2` in lib/defk/compiler.ex. `bench/tick_gap.exs` measures the worst
  scheduler gap and `bench/yield_cost.exs` the throughput cost.

**Dirty schedulers are not used.** OTP defines a dirty NIF as one that
"cannot be split and cannot execute in a millisecond or less", run on a
separate pool with "not the same duration restriction as a normal NIF". Two
properties make it the wrong tool for the runtime contract; this is defk's
reading rather than an OTP rule:

1. Dirty scheduling relaxes the *duration* limit; it does not change the
   warning above — a crashing kernel still crashes the node. The runtime
   contract asks for preemption, isolation, cleanup and hot code upgrade
   together (`CONTEXT.md`), and preemption has to be at the granularity defk
   measures — a scheduler gap in line with a busy Elixir process
   (`bench/tick_gap.exs`) — not "whenever the dirty job finishes".
2. While a process runs a dirty NIF, OTP documents that "suspend or garbage
   collection of a process executing a dirty NIF cannot be done until the
   dirty NIF has returned", so a process in a long dirty call is not
   suspendable — which `test/upgrade_test.exs` needs in order to recompile a
   module under a running kernel.

Every generated NIF is registered with flag `0` (a normal NIF)
(`emit_init/3` in lib/defk/compiler.ex); no source in this repo schedules a dirty job.

## 2. Lifecycles

**`ErlNifEnv` and `argv` live exactly one call long.** OTP: "The environment
is only valid in the thread where it was supplied as argument until the NIF
returns. It is thus useless and dangerous to store pointers to process bound
environments between NIF calls." All arguments belong to that environment, and
the return value must belong to it too.

A yield ends the call, so a suspended kernel holds no `env` and no `argv`
pointers across a yield: it re-enters through `enif_schedule_nif` with a fresh
environment and a fresh `argv`.

**Heap binaries move, so every entry rebinds.** Binaries of at most 64 bytes
live on the calling process's heap, and GC between two steps can move them.
The comment above `defk_bind` in priv/defk_runtime.h states the rule:
bind on *every* entry — the first call and each resume — because "heap
binaries can move during GC between yields". The generated entry does exactly
that for each array argument (`bind_params/2` in lib/defk/compiler.ex), and
`test/heap_binary_yield_test.exs` forces a GC mid-kernel to prove a resume
reads the moved binary rather than the address the previous step held.
A misaligned input (a sub-binary at an odd offset) is copied once into an
owned binary and that copy slot is remembered across resumes
(around `defk_bind` in priv/defk_runtime.h, `F->copy`).

The kernel body builds no terms: it computes on off-heap memory in
`ctx->owned`, and terms are made at the boundary from the current environment
— the result at return, the exception on a raise, the frame resource on a
first yield.

**Process death frees the frame.** A kernel starts on a C stack frame and is
copied into a resource only on its first yield (docs/project.md design decision 4;
around `defk_promote` in priv/defk_runtime.h). If the process dies while
suspended, the resource destructor runs: `defk_frame_dtor` calls
`defk_finish`, releasing every owned buffer, and decrements `frames_live`
(around `defk_frame_dtor` in priv/defk_runtime.h).

**Resource keep/release rules** (OTP): a resource is destructed when the last
reference is removed; each `enif_alloc_resource` or `enif_keep_resource` must
be balanced by an `enif_release_resource`; references made by
`enif_make_resource` are removed only by the garbage collector; and "there
are no guarantees exactly when the destructor of an unreferenced resource is
called". defk's `defk_promote` releases its allocation reference immediately
after making the term, so only the term keeps the frame alive
(`defk_promote` in priv/defk_runtime.h).

## 3. Memory constructs

| Construct | Ownership | Good for | Bad for | defk's stance |
|---|---|---|---|---|
| `enif_alloc` / `enif_free` | Caller owns the raw block; nothing frees it if you forget | Scratch memory with one obvious owner and one free site | Anything that must be cleaned up when a process dies or a raise happens | Used only for the `ctx->owned` table itself (`enif_realloc` in `defk_own`, `enif_free` in `defk_release_owned`); never for kernel data |
| `enif_alloc_binary` + `enif_make_binary` | Owned until `enif_make_binary` transfers it to a term (or `enif_release_binary`) | Output buffers whose size is known before the term exists; can be kept between NIF calls | Small one-shot outputs (heap allocation is cheaper); leaks if neither release nor transfer happens | The output path for every array: `defk_own` allocates and `defk_make_arr` transfers (both in priv/defk_runtime.h). docs/project.md design decision 1 |
| `enif_make_new_binary` | Creates the owning term in one step; the data is mutable only until the NIF returns | Small outputs and error messages, when you do not need to reallocate or outlive the call | Cannot be kept between NIF calls, cannot be reallocated — so no growable buffers | The message binary in `defk_raise` and the empty-array edge case in `defk_make_arr` |
| `enif_alloc_resource` | Refcounted object with a destructor; a term handle via `enif_make_resource` | Long-lived native state that must be cleaned up by the GC on any exit path | Per-call values: refcounting, destructor rules, and hot-upgrade complexity | Used only for the suspended frame (around `defk_promote` in priv/defk_runtime.h), with a resource type per loaded library (§6). Not for kernel state — see ADR-0001 |

**Ideas layer.** A review of four general NIF memory patterns against defk is
recorded as a breadcrumb comment on `defk-dtw` dated **2026-10-08**
(`bw show defk-dtw`, "external NIF memory-pattern review"):

1. **Arena / bump allocation** — *not adopted*; it does not apply to today's
   kernel subset (no recursion, no per-node `malloc`; locals live in
   registers). The goal it exists for — one owner, bulk free on any exit — is
   already built: `ctx->owned` plus `defk_finish` releases on raise, on
   completion and on process death. The recipe belongs to expansion
   candidates that grow trees or graphs.
2. **`enif_resource` for long-lived state** — *decided against* for kernel
   state (ADR-0001, `defk-dtw.9`); *adopted* only for yield frames, with a
   resource type per `.so` (docs/project.md design decision 8, §6).
3. **Yield-state context struct** — *adopted*: the frame resource, resume
   through loop headers, hot upgrade. The pattern's usual reliance on
   `enif_consume_timeslice` alone is deliberately rejected — it reports at
   return only and cannot preempt a mid-loop kernel (§1).
4. **Zero-copy `enif_alloc_binary` output** — *adopted* as docs/project.md design decision 1; defk allocates at the `alloc/2` site, which also handles
   early-exit sizes.

Forward hook from the same breadcrumb: the bitstring accumulator
(`defk-cmr`) already specs a doubling growable buffer, and arena/resource
recipes belong in the verdict's *Where defk could grow*.

## 4. Errors

**Raising.** `enif_raise_exception(env, reason)` creates the exception "to be
returned from a NIF"; OTP guarantees it is raised when the NIF returns "even
if the NIF attempts to return a non-exception term instead". defk builds the
Elixir exception struct as a map and returns it
(`defk_raise` in priv/defk_runtime.h): `ArithmeticError`,
`Enum.OutOfBoundsError`, `CaseClauseError`, `ArgumentError`, `RuntimeError`.

**`sigsetjmp` discipline.** An error inside a kernel does not unwind through
the generated frames; it `siglongjmp`s to a `setjmp` taken at the NIF
boundary.
`defk_ctx.jb` is the jump buffer (the `defk_ctx` typedef in priv/defk_runtime.h), and docs/project.md design decision 6 records why `sigsetjmp(jb, 0)` and not `setjmp`: plain `setjmp`
saves the signal mask on macOS, a syscall costing 160 ns per call. The jump
target lives in a separate `noinline` function so the `setjmp` frame does not
pessimise the kernel body (in `guard_fn/2`):
`guard_<n>` takes the jump and calls `run_<n>`, which contains no `setjmp`.

**Release owned on every error path.** Anything the call allocated is in
`ctx->owned` and must be released before the NIF returns, on success and on
failure alike — `defk_finish` in priv/defk_runtime.h. It runs in both
wrappers immediately before a raise is constructed: `step_` for a resumed
kernel (`step_fn/3` in lib/defk/compiler.ex) and `nif_` for a first call
(`nif_fn/3` in lib/defk/compiler.ex). Process death is covered by the frame
destructor (§2). `test/raise_cleanup_test.exs` checks both frames, including
that the bytes are gone from `:erlang.memory(:binary)`.

**Nothing unwinds across the NIF boundary.** A raise is a value built and
returned from the boundary, not a C unwind leaving the library: `defk_fail`
jumps to `guard_` *inside* the same call (in `defk_fail`),
`guard_` returns `DEFK_ERR`, the wrapper releases and raises. The order is
release, then raise — never the reverse.

## 5. Signals and fault containment

**Today, a kernel fault is a node crash.** `erl_nif`: "A native function that
crashes will crash the whole VM." defk's runtime and its generated code
install no signal handlers: `priv/defk_runtime.h` and the emitted C use
`sigsetjmp`/`siglongjmp` only for in-call errors (§4).
Containment is currently prevention-by-construction plus evidence (the threat
list `defk-5fc`, the alloc overflow `defk-gtv`, differential checks
`defk-63k`).

**OTP's contract for NIF-local signal use.** From PR #7174 ("jit: Refactor
`sigaltstack(2)` handling", merged for OTP-27):

> if a NIF or driver uses signals in a creative manner locally during a call,
> then that's fine as long as they restore them before returning to Erlang
> code.
>
> A NIF or driver that doesn't do this is misbehaving to begin with and we
> can't shield ourselves against that.

The same change records why `SA_ONSTACK` matters: ERTS's own native-code
stacks are small, so ERTS adds `SA_ONSTACK` to its uses of `sigaction(2)` to
run handlers on an alternate signal stack — a NIF-local handler that wants
the same protection must set `SA_ONSTACK` itself, and must save and restore
the previous `sigaction` (chaining if it was not `SIG_DFL`).

**The defk spike is not decided.** `defk-7dm` proposes installing
`sigaction` for `SIGSEGV`/`SIGBUS`/`SIGILL`/`SIGFPE` around kernel execution,
with a fault whose PC is inside a loaded defk `.so` turned into a raise for
the calling process, and any other fault re-raised so the node dies as today.
**Placeholder: `defk-7dm` is open and blocked; its accept/reject decision
lands here when it closes (ADR-0003 is created then).** Treat everything
above as the current state, not a plan.

**Debugging a fault.** OTP's *Debugging NIFs and Port Drivers* page is the
reference: a debug emulator build, Address Sanitizer, Valgrind, and `rr`
record-and-replay — including hardware watchpoints on the corrupted address
with `reverse-continue` to stop at the write. The page's framing is the same
one this doc opens with: NIF code runs inside the VM OS process with full
access to its memory, so a buggy NIF can corrupt state that no later trace
will explain. URL in §8.

## 6. Loading and hot code upgrade

**One `.so` per source hash.** `Defk.Build.build!/3` hashes the C flags, the
generated C and `priv/defk_runtime.h`, and names the artifact
`<Module>-<first 10 hex>` under `_build/<env>/defk/`
(in `build!/3` in lib/defk/build.ex); an existing file is not rebuilt
(in `build!/3` in lib/defk/build.ex), so the library is content-addressed and a
reload of identical source maps to the same image. The compiler is the system
`cc` or `$CC` (ADR-0002; around `build!/3` in lib/defk/build.ex).

**Loading.** The stub module declares `@on_load :__defk_load__` and calls
`:erlang.load_nif(lib, 0)` with that absolute build path
(around `__defk_load__` in lib/defk.ex); `Mod.__defk_lib__/0` returns it (`__defk_lib__` in lib/defk.ex).
Known limitation: a `mix release` does not copy `_build/<env>/defk`, so a
release is not relocatable until the `.so` ships in `priv/` — see
`examples/release_debian/README.md` and ticket `defk-n8f`.

**ERTS keeps a library mapped while a suspended kernel runs.** docs/project.md design decision 8: recompiling a module builds a new `.so`; a yielded kernel
reschedules *its own* library's step function, and ERTS keeps that library
mapped until the continuation returns. The comment above `defk_open_rt`
(around `defk_open_rt` in priv/defk_runtime.h) spells out the mechanism:

- Each loaded library image opens its **own frame resource type**, named after
  the address of one of its statics (around `defk_open_rt` in priv/defk_runtime.h), in
  `defk_load` / `defk_upgrade` (registered in priv/defk_runtime.h through `ERL_NIF_INIT`
  in `emit_init/3` in lib/defk/compiler.ex).
- A newer library therefore never takes over an older library's frames: each
  destroys its own frames with the `defk_ctx` layout it was built with, and
  stays loaded while any exist.
- The alternative — one shared `defk_frame` type — was the earlier design and
  is called out as unsafe: the new destructor and `frames_live` counter would
  be applied to old frames once the layout changes.

**Purge semantics** are ordinary BEAM old-code semantics: purging the old
module (`:code.purge/1`, or loading a third version while the kernel is still
running) kills processes still running that code, and the old library frees
their frames. A kernel survives one reload of its module; a second reload
before it finishes purges its code and kills it (`docs/language.md` section 12).
`__defk_stats__/0` counts the current library's frames only.
`test/upgrade_test.exs` covers all of this.

## 7. When not to use a NIF

The `erl_nif` warnings, condensed:

- No memory protection and no pre-emptive scheduling: a native function runs
  as a direct extension of the VM, so "a native function that crashes will
  crash the whole VM", and an erroneous one can leave the VM in an
  inconsistent state that misbehaves later.
- Lengthy work degrades responsiveness; return within about a millisecond.

Ports and separate processes exist precisely for work that does not fit those
rules, and `CONTEXT.md`'s runtime contract states the bar in one line: "A
kernel that can't keep this is worse than a port, however fast it is." So:

- **Do not use a kernel for work that cannot keep the runtime contract** —
  preemption, isolation, cleanup on process death, hot code upgrade. Blocking
  a scheduler for the duration of the call, or risking the node, is a fail
  regardless of throughput.
- **Do not use a kernel to wrap an existing native library** (codecs, crypto,
  databases): use Rustler, Zigler or an existing binding — `examples/README.md`.
- **Do not use a kernel for I/O-bound work**, and not for tensor/ML work (use
  Nx) — `examples/README.md`.

The catalog already records the fits that fail. In `examples/README.md`,
*Where Elixir is the right choice*:

| Example | Why | Verdict |
|---|---|---|
| `poor_list_data.exs` | Data arrives as lists; packing costs more than Elixir's whole `Enum.sum` (0.35–0.37×, ≈3× slower) | `poor` |
| `poor_tiny_calls.exs` | One kernel call per element; call overhead exceeds the work (0.38–0.43×) | `poor` |
| `out_of_scope_word_count.exs` | Strings in, a map out: not expressible in the kernel subset | `out_of_scope` |

`out_of_scope` means "can't be written as a kernel → use Elixir" (the verdict
table in `examples/README.md`), and the kernel subset's answer to that is a
compile error with a rewrite, not a slow kernel. Keep the poor fits: they are
part of the record (`AGENTS.md`, *Purpose and measurement*).

## 8. Sources

- `erl_nif` manual page (the documentation for `erl_nif.h`):
  <https://www.erlang.org/doc/man/erl_nif.html> — the warning text quoted in
  §1 and §7, the *Long-running NIFs* section (yielding, threaded, dirty
  NIFs), `enif_consume_timeslice`, `enif_schedule_nif`, `enif_raise_exception`,
  `ErlNifEnv` / process-bound environments, and the `enif_alloc*`,
  `enif_make_*`, `enif_alloc_resource` ownership rules in §2–§3. Doc source in
  OTP: `erts/doc/references/erl_nif.md`.
- *Debugging NIFs and Port Drivers*:
  <https://www.erlang.org/doc/system/debugging.html> — debug emulator,
  Address Sanitizer, Valgrind, `rr` with watchpoints (§5).
- OTP PR #7174, *jit: Refactor sigaltstack(2) handling* (merged for OTP-27):
  <https://github.com/erlang/otp/pull/7174> — the contract for NIF-local
  signal use and `SA_ONSTACK` (§5).
- docs/project.md, *Design decisions the benchmarks validated*:
  1 arrays as views over binaries (§3), 4 pay for yielding only when you
  yield (§2), 5 adaptive safepoint budget (§1), 6 `sigsetjmp(jb, 0)` (§4),
  8 hot code upgrade (§6).
- `CONTEXT.md`: *runtime contract*, *the one rule*, *divergence*, *limit*,
  *expansion candidate*.
- Wayfinder tickets: `defk-dtw` (breadcrumb comments dated 2026-10-08, §3),
  `defk-dtw.9` (state travels as binaries → ADR-0001), `defk-dtw.11` +
  `defk-dtw.19` (C at build time, no stack rewrite → ADR-0002), `defk-7dm`
  (fault containment, §5 placeholder), `defk-5dd` (C warnings), `defk-5fc`
  (threat list), `defk-gtv` (alloc overflow), `defk-63k` (differential
  checks), `defk-nbl` (upgrade), `defk-j3h` / `defk-5s3` (safepoints and tick
  gap), `defk-juw` (resume), `defk-lb8` + `defk-ds0` (compiler-at-build-time
  evidence), `defk-o1w` (Cranelift exploration), `defk-n8f` (ship `.so` in
  releases), `defk-7w2` (this document).
- In-repo evidence: `priv/defk_runtime.h`, `lib/defk/build.ex`,
  `lib/defk/compiler.ex`, `lib/defk.ex`, `docs/project.md`, `CONTEXT.md`,
  `examples/README.md`, `examples/release_debian/README.md`,
  `test/heap_binary_yield_test.exs`, `test/raise_cleanup_test.exs`,
  `test/upgrade_test.exs`, `bench/tick_gap.exs`, `bench/yield_cost.exs`.
