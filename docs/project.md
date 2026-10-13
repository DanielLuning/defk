# Working on defk itself

This page is for people inside the repository: how to run the demo and the
benchmarks, which file does what, the design decisions the benchmarks
validated, a results snapshot and the roadmap with its ticket ids. It is
linked from the [README](../README.md) and is not part of HexDocs. What defk is
and how to use it is in the README and the guides in `docs/guides/`.

## Running things

```bash
mix run demo.exs              # correctness, throughput vs Elixir and plain C, boundary cost,
                              # preemption on one scheduler, failure isolation
mix run bench/tick_gap.exs    # worst scheduler gap: idle vs Elixir vs kernel
mix run bench/yield_cost.exs  # throughput cost of yielding
mix test                      # resumed kernels match yield: false, incl. a forced yield at every clock read;
                              # reloading a module while a kernel is suspended
elixir examples/run_all.exs   # the example catalog's scoreboard
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
| Example kernels | `lib/examples.ex` |
| Plain C baseline | `bench/native.c` |

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
   - bounds failures raise `Enum.OutOfBoundsError` in the caller. The check is dropped when the compiler can prove the index is in range, e.g. `i <- 0..(n - 1)//1` with `n = min(len(a), len(b))`, or a `[u8]` value indexing a 256-element `alloc`
3. **Automatic yielding.** Every loop back-edge is a safepoint. Locals live in registers and are spilled to a frame struct only when the kernel actually yields. Resume re-enters each loop through its header, so loops keep a single entry and clang optimises them like ordinary loops.
   A call to another kernel is inlined, so the callee's loops (however many calls deep) are loops of the kernel called from Elixir and yield like its own. `yield: false` applies to the kernel called from Elixir, including what it calls.
   A `{:halt, acc}` jumps to the end of its loop. Jumping out of loops keeps their single entry, so it needs no change to resume.
   A flat inner loop (no nested loop, also none in an inlined call, so each iteration costs a bounded amount) skips the per-iteration check, which would stop clang from vectorising it. If it has fewer than `DEFK_STRIP` (2048) trips, it runs as a plain loop, its trips are charged to the budget, and the enclosing loop's safepoint does the check. A longer loop runs in strips of 2048 with one safepoint per strip.
4. **Pay for yielding only when you yield.** A kernel starts on a C stack frame. Only on its first yield is the frame copied into a resource, whose destructor frees owned buffers if the process dies.
5. **Adaptive safepoint budget.** The clock is read every ~25–60 µs regardless of how expensive one loop iteration is.
6. **`sigsetjmp(jb, 0)` for errors.** Plain `setjmp` saves the signal mask on macOS (a syscall), which cost 160 ns per call.
7. **Never take the address of an array view in kernel code.** If it escapes, clang reloads `data`/`len` on every iteration.
8. **Hot code upgrade: a suspended kernel finishes in the code it started in.** Recompiling a module builds a new `.so` (its path carries a hash of the C source and runtime). A yielded kernel reschedules its own library's step function, and ERTS keeps that library mapped until the continuation returns. Each loaded library has its own frame resource type and is never taken over by a newer library, so the old library destroys its own frames with the frame layout it was built with, and stays loaded while any exist. Purging the old code (`:code.purge/1`, or loading a third version while the kernel is still running) kills processes still running it, as for any old Erlang code, and the old library frees their frames. `__defk_stats__/0` counts the current library's frames only. Earlier, the new library took over a shared frame type: its destructor and `frames_live` counter were applied to old frames, which is unsafe once the frame layout changes. `test/upgrade_test.exs` covers all of this.

## Results snapshot (M-series Mac, OTP 29, Elixir 1.20; noisy, single runs)

The float rows predate the inf/NaN checks (defk-i00). Since defk-6tt they cost `dot` nothing measurable (see [`performance.md`](performance.md) 6.5 and [`language.md`](language.md) section 12).

| | Elixir | defk | plain C |
|---|---|---|---|
| sum of 5M f64 (ns/elem) | 8.5 (list), 16.7 (binary comprehension) | 0.58 | 0.64 |
| dot of 5M f64 via `a[i]` (ns/elem) | 12.2 (list) | 0.50 | 0.50 |
| count_primes(1M), trial division (ms) | 1400 | 180 | 186 |
| count_primes_early(1M), trial division to the first divisor (ms) | 236 (`Enum.all?`), 140 (tail recursion, fastest tried) | 33 | 32 |
| call overhead (ns/call) | 1.6 | 12 | — |
| worst 1 ms-ticker gap on one scheduler (ms) | 2.0–2.2 (busy Elixir process) | 2.3–2.5 (yielding), 2.3 (loop in a called kernel), 867 (`yield: false`) | — |

- Safepoint overhead: ~0% (within noise), including branchy nested loops such as the fuzzy_search Levenshtein kernel (20 ms yielding vs 20 ms `yield: false`).
- A kernel yields after 250 µs of wall time (`DEFK_SLICE_US`). At 1 ms, the limit ERTS allows a NIF, the ticker's worst gap was 3.5 ms. A busy Elixir process yields every few µs. Each yield costs a few µs of scheduler work (mostly its I/O poll): 2–3% on `count_primes`, which yields ~3,300 times a second, and nothing measurable on fuzzy_search. `bench/tick_gap.exs` and `bench/yield_cost.exs` measure both sides.
- Kernel calls are inlined, so a loop in a callee yields too: `count_primes_via_call` (all its work two calls deep) has the yielding kernel's worst tick gap (2.3 ms). Inlining costs `count_primes` nothing measurable: `prime?`'s trial division (up to 1000 trips at 1M) is a flat loop, and since `DEFK_STRIP` went from 512 to 2048 it runs as one plain loop (at 512 it ran in two strips, 6% slower than `yield: false`).
- `count_primes_early` is `count_primes` with `prime?` written as `Enum.all?(2..limit//1, fn d -> rem(x, d) != 0 end)`, so trial division stops at the first divisor. Elixir and C get the same algorithm (`Enum.all?` or tail recursion; a `return` in C). It is a separate kernel, so `count_primes` stays the long-running yield and preemption workload. With early exit, defk is 4.3× faster than the fastest Elixir version, against 8× when both sides scan the whole range: Elixir gains more from early exit, because each of its iterations costs more. The yielding and `yield: false` forms run within 1–2% of each other.
- Killing a process mid-kernel frees its frame (`frames_live` 1 → 0).
- `count_primes` used to be 1.7× slower than C because of the overflow check in `if prime?(i), do: count + 1, else: count`. A check that can raise inside one arm keeps clang from turning the `if` into a select. Clang then threads the branch into `prime?`'s inner loop, and that loop ran 1.7× slower. Now an `if` or `cond` whose arms are pure arithmetic is compiled as a select: every arm is computed with overflow flags, and only an overflow in the taken arm raises, with the same error. A `cond` gets the select only when its conditions after the first are pure arithmetic too, since those run only when the earlier ones are false.


## Roadmap

The larger steps, grouped by goal. Each item names its beadwork ticket (`bw show <id>`); ticked items are closed.

**0. Verdict** (plan in `bw show defk-sgw`)
- [x] Draft docs/verdict.md with the pre-registered go/no-go rule (defk-sgw.2)
- [x] Write docs/language.md, the kernel subset reference (defk-sgw.1)
- [x] Devex cold test: a new kernel from the docs alone (defk-sgw.3)
- [ ] Freeze the workload-results snapshot on a quiet machine (defk-sgw.4)
- [ ] Write the verdict: guide, runtime contract, devex, limitations (defk-sgw.5)
- [ ] Final verdict session (defk-sgw.6)

**1. Honest measurement: show where defk helps Elixir**
- [x] Record the purpose: Elixir first, defk only where it helps (defk-9p6.5)
- [x] Example catalog with a scoreboard (defk-9p6.1)
- [x] fuzzy_search example app (defk-nv1)
- [x] Optimise the Elixir baselines, so the `good` verdicts are no longer provisional: rolling_stats (defk-9p6.6), geo_nearest (defk-9p6.7), image_blur (defk-9p6.8), fuzzy_search (defk-9p6.9)
- [ ] Re-measure fuzzy_search, yielding against blocking, on a quiet machine (defk-klw)
- [ ] Refresh the results table and demo numbers on a quiet machine (defk-yzw)
- [ ] Separate code-layout noise (±3%) from real effects (defk-wnu)

**2. Language: express the algorithms people write NIFs for**
- [x] Early exit: `Enum.reduce_while`, `Enum.all?/any?` (defk-9vl)
- [x] `case` on `i64`/`bool` (defk-9vl)
- [x] Calls between kernels that yield (defk-jaj)
- [x] Bitwise operators (`band`/`bor`/`bxor`/`bsl`/`bsr`) for hashing and checksums (defk-w38)
- [ ] Arrays through `if`/`cond` branches, and returning input arrays (defk-gqk)
- [ ] `Enum.reduce/3`, and a `find_index` that keeps Elixir semantics without `nil` (defk-nii)
- [x] More `case` patterns: `x in [1, 2, 3]` and ranges (defk-gid)
- [x] Module attributes as constants (defk-ivt)
- [x] Multi-clause kernels with a typed function head (defk-u9c)
- [x] Signed integer segments in the bitstring accumulator (defk-dki)
- [x] Pass the bitstring accumulator through helper kernels (defk-ooq)

**3. Semantics: behave like Elixir where it matters**
- [x] Array value semantics: copy on aliased write (defk-i2e, defk-auo)
- [x] inf/NaN inside kernels: raise like Elixir (defk-q1c, defk-i00)
- [x] An error inside a guard fails the clause instead of raising (defk-7a6)

**4. Performance: plain-C speed from Elixir-shaped code**
- [x] Bounds-check elimination for provably in-range `a[i]` (defk-88q)
- [x] count_primes at C speed: `if`/`cond` arms compiled as selects (defk-jp3, defk-7q5)
- [ ] Guard against code-size blowup from inlined calls (defk-6ag)
- [x] No C compiler warnings in generated code (defk-5dd)

**5. Runtime: be a good BEAM citizen**
- [x] Safepoints cost ~0% in hot loops (defk-5s3, defk-nua)
- [x] Worst scheduler gap in line with a busy Elixir process (defk-j3h)
- [x] Resume correctness under forced yields (defk-h8a)
- [x] Hot code upgrade with suspended kernels (defk-nbl)
- [x] Resume tests fail instead of hanging on a resume bug (defk-juw)
- [x] Show an early-exit kernel in the preemption demo and `tick_gap` (defk-tfh)
- [ ] `__defk_stats__` semantics across reloads (defk-9qv)
- [x] Layout version tag on frames, as defence in depth (defk-ls8)

**6. Catalog: map the boundary of defk's niche**
- [ ] Checksum/hash over binaries, compared with `:erlang.crc32` (defk-9p6.2, needs defk-w38)
- [x] Matrix multiply against Nx (expected verdict: use Nx) (defk-9p6.3)
- [x] n-body step with state kept packed between calls (defk-9p6.4)
- [x] Fair early-exit cutoff for fuzzy_search's Levenshtein, in both backends (defk-8i4)

**7. Later**
- [ ] Cranelift JIT backend for kernels specialised at runtime (defk-o1w)
