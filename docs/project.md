# Working on defk itself

This page is for people inside the repository: how to run the demo and the
benchmarks, which file does what, the design decisions the benchmarks
validated, a results snapshot and where the roadmap lives. It is
linked from the [README](../README.md) and is not part of HexDocs. What defk is
and how to use it is in the README and the guides in `docs/guides/`.

## Running things

```bash
mix run bench/demo.exs        # correctness, throughput vs Elixir and plain C, boundary cost,
                              # preemption on one scheduler, failure isolation
mix run bench/tick_gap.exs    # worst scheduler gap: idle vs Elixir vs kernel
mix run bench/yield_cost.exs  # throughput cost of yielding
mix run bench/port_roundtrip.exs  # a port program's round trip vs a kernel call, by size (the out-of-process floor)
mix test                      # resumed kernels match yield: false, incl. a forced yield at every clock read;
                              # reloading a module while a kernel is suspended
mix defk.examples            # every example outside mix test, check-only (not in mix ci); --bench for the scoreboard
mix ci                        # what must be green before a merge
DEFK_DUMP_C=<dir> mix dump_c  # the byte-identical gate for compiler refactors (dev/dump_c.exs)
verify/fuzz/run.sh            # libFuzzer over the decoder kernels, outside the VM (verify/fuzz/README.md)
verify/valgrind/run.sh        # the test suite under Valgrind memcheck, in a container (verify/valgrind/README.md)
```

Work is tracked with beadwork (`bw`, on the `beadwork` branch); see
[`docs/agents/issue-tracker.md`](agents/issue-tracker.md) and `AGENTS.md`.
Run `bw prime` first; `bw show <id>` shows a ticket. The conventions for
agents (Elixir first, how to measure) are in `AGENTS.md`, and the vocabulary
in `CONTEXT.md`.

## Where things are

| Piece | File |
|---|---|
| `defk` macro and stub generation | `lib/defk.ex` |
| Module attributes read in kernel bodies, inlined as constants | `lib/defk/attributes.ex` |
| Type checker and C codegen | `lib/defk/compiler.ex` |
| Compile error codes and format | `lib/defk/errors.ex` |
| C build, cached by source hash | `lib/defk/build.ex` |
| Fast-path report: margin notes, clang's vectorisation remarks | `lib/defk/report.ex` |
| Elixir mode: kernel bodies as plain Elixir | `lib/defk/elixir_mode.ex`, `lib/defk/elixir_mode/ops.ex`, `lib/defk/elixir_mode/guard.ex` (case guards) |
| Measurement and the DEFK_RESULT line for examples | `lib/defk/bench.ex` |
| The builtin list shared by the compiler, Elixir mode and the error registry | `lib/defk/builtins.ex` |
| Agreement helpers for tests | `lib/defk/test.ex`, `lib/defk/ex_unit/case.ex` |
| StreamData generators by kernel type | `test/support/generators.ex` |
| Runtime: arrays, checks, safepoints, frames, exceptions | `priv/defk_runtime.h` |
| BEAM/NIF reference (execution model, lifecycles, errors, upgrade) | `docs/beam-nifs.md` |
| Performance guide: what is fast on the BEAM, what isn't, and how to fix it | `docs/performance.md` |
| Example kernels (compiled in `:dev` and `:test` only) | `test/support/examples.ex` |
| The catalog's kernels that `mix test` compiles | `test/support/catalog.ex` |
| Demo and benchmark scripts | `bench/` (`demo.exs`, `tick_gap.exs`, `yield_cost.exs`, ...) |
| Plain C baseline | `bench/native.c` |
| Repo-only Mix tasks and dev scripts (never in a dependent's build or the Hex package) | `dev/` (`mix defk.examples`, `dump_c.exs`) |
| Verification tooling that is not part of `mix ci`: fuzzing, Valgrind | `verify/fuzz/`, `verify/valgrind/` |
| Use-case catalog, measured against optimised Elixir | `examples/` (`examples/README.md`) |
| Research notes, one per research ticket | `docs/research/` |
| Design decisions | `docs/adr/`, vocabulary in `CONTEXT.md` |

How a kernel is compiled, Elixir mode and the fast-path report are described in [`language.md`](language.md) (sections 2 and 10) and [`fast-path-report.md`](fast-path-report.md).

## Design decisions the benchmarks validated

1. **Arrays are views over binaries.** Inputs are zero-copy. Outputs are `enif_alloc_binary` buffers handed over with `enif_make_binary`. Unaligned sub-binaries are copied once.
2. **Elixir semantics where they're cheap:**
   - checked i64 overflow raises `ArithmeticError`
   - `/` always returns a float and raises on division by zero
   - `div`/`rem` follow Elixir rounding
   - `a..b` counts down when `a > b`
   - a `case` that no clause matches raises `CaseClauseError`, so a catch-all is optional
   - a `{:halt, acc}` ends only the `Enum.reduce_while` it belongs to, also inside nested loops and inlined calls
   - bounds failures raise `Enum.OutOfBoundsError` in the caller. The check is dropped when the compiler can prove the index is in range, e.g. `i <- 0..(n - 1)//1` with `n = min(length(a), length(b))`, or a `[u8]` value indexing a 256-element `alloc`
3. **Automatic yielding.** Every loop back-edge is a safepoint. Locals live in registers and are spilled to a frame struct only when the kernel actually yields. Resume re-enters each loop through its header, so loops keep a single entry and clang optimises them like ordinary loops.
   A call to another kernel is inlined, so the callee's loops (however many calls deep) are loops of the kernel called from Elixir and yield like its own. `yield: false` applies to the kernel called from Elixir, including what it calls.
   A `{:halt, acc}` jumps to the end of its loop. Jumping out of loops keeps their single entry, so it needs no change to resume.
   A flat inner loop (no nested loop, also none in an inlined call, so each iteration costs a bounded amount) skips the per-iteration check, which would stop clang from vectorising it. If it has fewer than `DEFK_STRIP` (2048) trips, it runs as a plain loop, its trips are charged to the budget, and the enclosing loop's safepoint does the check. A longer loop runs in strips of 2048 with one safepoint per strip.
4. **Pay for yielding only when you yield.** A kernel starts on a C stack frame. Only on its first yield is the frame copied into a resource, whose destructor frees owned buffers if the process dies.
5. **Adaptive safepoint budget.** The clock is read every ~25–60 µs regardless of how expensive one loop iteration is.
6. **`sigsetjmp(jb, 0)` for errors.** Plain `setjmp` saves the signal mask on macOS (a syscall), which cost 160 ns per call.
7. **Never take the address of an array view in kernel code.** If it escapes, clang reloads `data`/`len` on every iteration.
8. **Hot code upgrade: a suspended kernel finishes in the code it started in.** Recompiling a module builds a new `.so` (its path carries a hash of the C source and runtime). A yielded kernel reschedules its own library's step function, and ERTS keeps that library mapped until the continuation returns. Each loaded library has its own frame resource type and is never taken over by a newer library, so the old library destroys its own frames with the frame layout it was built with, and stays loaded while any exist. Purging the old code (`:code.purge/1`, or loading a third version while the kernel is still running) kills processes still running it, as for any old Erlang code, and the old library frees their frames. `__defk_stats__/0` counts the current library's frames only. Earlier, the new library took over a shared frame type: its destructor and `frames_live` counter were applied to old frames, which is unsafe once the frame layout changes. `test/upgrade_test.exs` covers all of this.
9. **A fault inside kernel code is an exception, not a node crash** ([ADR-0009](adr/0009-fault-containment.md)). Each library installs a chained `sigaction` handler at load; a synchronous fault with its PC inside the library's own code, while one of its kernels runs on that thread, `siglongjmp`s to the guard like a bounds check and raises `RuntimeError` "defk bug: ..." after the owned buffers are freed. Any other fault chains on and kills the node as before. The running call is one thread-local set by the guard: 12.5-12.7 ns to 12.7-13.2 ns per scalar call. An image never leaves a dangling handler (restore at unload if it is the head, else pin the image; the upgrader pins the image it replaces). `test/fault_containment_test.exs` covers it, with the cases that must still kill the node in a child VM.

## Results snapshot

Apple M4 Pro, OTP 29.0.3, Elixir 1.20.2, commit f064e33, 2026-10-13: `bench/demo.exs`, `bench/tick_gap.exs` and `bench/yield_cost.exs`, run one after the other with nothing else on the machine (load average 3.1-3.3; defk-sgw.4 and defk-yzw). The catalog's snapshot from the same session is in [`verdict.md`](verdict.md).

| | Elixir | defk | plain C |
|---|---|---|---|
| sum of 5M f64 (ns/elem) | 8.0 (list), 12.1 (binary comprehension) | 0.55 | 0.54 |
| dot of 5M f64 via `a[i]` (ns/elem) | 16.7 (list) | 0.57 | 0.56 |
| count_primes(1M), trial division (ms) | 1504 | 206 (yielding), 201 (`yield: false`) | 204 |
| count_primes_early(1M), trial division to the first divisor (ms) | 239 (`Enum.all?`), 167 (tail recursion, fastest tried) | 38 | 37 |
| call overhead (ns/call) | 1.8 | 13.1 (11.3 ns over the Elixir call; one thread-local store pair of it is fault containment, ADR-0009) | — |
| worst 1 ms-ticker gap on one scheduler (ms) | 2.0–2.5 (busy Elixir process; idle 2.0–2.4) | 2.25–2.3 (yielding), 2.3 (loop in a called kernel), 2.3 (early exit), 554 (`yield: false`) | — |

- Safepoint overhead: 2.4-2.7% on `count_primes` (2,065 yields per run, 6.5 µs per yield, `bench/yield_cost.exs` on the idle machine), ~0% on branchy nested loops such as the fuzzy_search Levenshtein kernel (20 ms yielding vs 20 ms `yield: false`).
- A kernel yields after 250 µs of wall time (`DEFK_SLICE_US`). At 1 ms, the limit ERTS allows a NIF, the ticker's worst gap was 3.5 ms. A busy Elixir process yields every few µs. Each yield costs a few µs of scheduler work (mostly its I/O poll): 2–3% on `count_primes`, which yields ~3,300 times a second, and nothing measurable on fuzzy_search. `bench/tick_gap.exs` and `bench/yield_cost.exs` measure both sides.
- Kernel calls are inlined, so a loop in a callee yields too: `count_primes_via_call` (all its work two calls deep) has the yielding kernel's worst tick gap (2.3 ms). Inlining costs `count_primes` nothing measurable: `prime?`'s trial division (up to 1000 trips at 1M) is a flat loop, and since `DEFK_STRIP` went from 512 to 2048 it runs as one plain loop (at 512 it ran in two strips, 6% slower than `yield: false`).
- `count_primes_early` is `count_primes` with `prime?` written as `Enum.all?(2..limit//1, fn d -> rem(x, d) != 0 end)`, so trial division stops at the first divisor. Elixir and C get the same algorithm (`Enum.all?` or tail recursion; a `return` in C). It is a separate kernel, so `count_primes` stays the long-running yield and preemption workload. With early exit, defk is 4.3× faster than the fastest Elixir version, against 8× when both sides scan the whole range: Elixir gains more from early exit, because each of its iterations costs more. The yielding and `yield: false` forms run within 1–2% of each other.
- Killing a process mid-kernel frees its frame (`frames_live` 1 → 0).
- `count_primes` used to be 1.7× slower than C because of the overflow check in `if prime?(i), do: count + 1, else: count`. A check that can raise inside one arm keeps clang from turning the `if` into a select. Clang then threads the branch into `prime?`'s inner loop, and that loop ran 1.7× slower. Now an `if` or `cond` whose arms are pure arithmetic is compiled as a select: every arm is computed with overflow flags, and only an overflow in the taken arm raises, with the same error. A `cond` gets the select only when its conditions after the first are pure arithmetic too, since those run only when the earlier ones are false.


## Roadmap

The roadmap lives in beadwork and nowhere else: `bw prime` shows the current
state, `bw ready` the next unblocked steps, `bw show <epic>` an epic's goal,
children and order. This page does not repeat it, because a copy goes stale
within days (the checklist that used to be here did).

The verdict in [`verdict.md`](verdict.md) was accepted on 2026-10-14
(`defk-sgw.6`): the go/no-go rule's outcome is go, and the decision taken on
it is to keep developing and improving defk without publishing on Hex yet.
The map that held the decisions behind it (`defk-dtw`) and the build to it
(`defk-sgw`) are closed. The next destination is the map `defk-wfi`: defk
ready for a first Hex release, gated on Linux evidence (`defk-a1p`, its
first ticket) and a stability promise for the subset and the runtime
contract. Until that map is designed, the other epics stay as they were:

| Epic | What it holds | State |
|---|---|---|
| `defk-wfi` | the map to a first Hex release; a stub until its own design session | open |
| `defk-9p6` | the example catalog: new entries and baseline work | open |
| `defk-djy` | documentation: API docs, guides, HexDocs | open |
| `defk-o08` | symbolic bounds: prove more indices in range (ADR-0007) | open |
| `defk-w8r` | measurement and per-call cost | open |
| `defk-vcx` | kernel subset and devex gaps | open |
| `defk-52v` | from-scratch kernels where people wrap a library today | deferred |
| `defk-n4r` | 1BRC: parse and aggregate a 1-billion-row file | deferred |
| `defk-sve` | kernel-owned state across calls | deferred |
| `defk-ulk` | SIMD and target-specific builds | deferred |
| `defk-96f` | verification of the generated C: sanitizers, Valgrind, fuzzing, bounded proofs | deferred |

A deferred epic is hidden from `bw ready`; `bw list --all` shows it. The
expansion candidates are listed in the verdict under "Where defk could
grow"; `defk-wfi` triages them, and none reopens automatically
([`scope.md`](scope.md) says what is planned, under exploration and out by
design).
