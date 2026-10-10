# defk

> defk explores one question: **can a typed subset of Elixir compile
> to native code that runs at C speed, with a cheap boundary, while keeping the
> BEAM's promises (preemption, isolation, cleanup)?**

```bash
mix run demo.exs              # correctness, throughput vs Elixir and plain C, boundary cost,
                              # preemption on one scheduler, failure isolation
mix run bench/tick_gap.exs    # worst scheduler gap: idle vs Elixir vs kernel
mix run bench/yield_cost.exs  # throughput cost of yielding
mix test                      # resumed kernels match yield: false, incl. a forced yield at every clock read;
                              # reloading a module while a kernel is suspended
```

Needs Elixir ≥ 1.20 (OTP 29 tested) and a C compiler (`cc`, or set `CC`; set `ERTS_INCLUDE_DIR` to build against another ERTS's headers, as with elixir_make).

## Purpose: help Elixir, not compete with it

The goal of defk is not to beat Elixir. It is to find the jobs where Elixir
today pushes people towards a hand-written NIF, and to offer something
better there.

Elixir stays the default. When an Elixir solution is as good or as fast, it
is the right choice. So before claiming defk should be used anywhere, we
optimise the Elixir solution as far as we can, and we keep the cases where
Elixir wins as part of the record.

## Examples: where defk helps, and where Elixir is the right choice

[`examples/`](examples) is a growing catalog of real use cases, each written in
Elixir and in defk, checked for agreement and measured end to end.
`elixir examples/run_all.exs` prints the scoreboard. The measurement rules are
in [`examples/README.md`](examples/README.md).

So far:

- **Where defk looks like it helps.** These are provisional: the Elixir baselines are first passes and still need optimising.
  - rolling sensor statistics
  - nearest of 500k locations
  - 1080p image blur
  - FFT and convolution over audio-sized f64 signals (63–91× an optimised Elixir baseline)
  - a fuzzy-search web service, where `/health` latency stays at Elixir levels while a blocking NIF pushes it to ~80 ms p99
  - 1080p image resize, YUV420 conversion and Floyd-Steinberg dithering on raw frames (12–26× an optimised Elixir baseline, bit-exact; libvips not compared)
  - Monte Carlo slot RTP simulation, the kernel running `:rand`'s exsss generator bit for bit (3.2–3.3× an optimised Elixir baseline at 100M spins on all schedulers; totals equal exactly)
- **Where Elixir is the right choice:**
  - data that arrives as lists (defk ≈3× slower)
  - one kernel call per element (defk ≈2.5× slower)
  - maps and string building (not expressible; a string literal is a read-only `[u8]`)

## What it is

The full reference for kernel authors (every construct, its exact semantics, the limits, and every compile error code) is [`docs/language.md`](docs/language.md); this section is the overview.

```elixir
defmodule Stats do
  use Defk

  defk dot(a :: [f64], b :: [f64]) :: f64 do
    for i <- 0..(len(a) - 1)//1, reduce: 0.0 do
      acc -> acc + a[i] * b[i]
    end
  end
end

Stats.dot(bin_a, bin_b)   # [f64] = a binary of packed native-endian floats
```

A construct outside the kernel subset is a compile error in Elixir's
diagnostic format, with why it's rejected, a rewrite where one exists, and a
stable code (`Defk.Errors.codes/0`). Every rejection in the module is reported
at once, up to 10.

At `mix compile`, `defk` type-checks the body, emits C
(`_build/dev/defk/*.c`; also `Mod.__defk_source__/0`), builds a NIF with
`cc -O3`, and generates the Elixir stubs plus `@spec`s.

| Piece | File |
|---|---|
| `defk` macro and stub generation | `lib/defk.ex` |
| Module attributes read in kernel bodies, inlined as constants | `lib/defk/attributes.ex` |
| Type checker and C codegen | `lib/defk/compiler.ex` |
| Compile error codes and format | `lib/defk/errors.ex` |
| C build, cached by source hash | `lib/defk/build.ex` |
| Fast-path report: margin notes, clang's vectorisation remarks | `lib/defk/report.ex` |
| Elixir mode: kernel bodies as plain Elixir | `lib/defk/elixir_mode.ex`, `lib/defk/elixir_mode/ops.ex` |
| Measurement and the DEFK_RESULT line for examples | `lib/defk/bench.ex` |
| The builtin list shared by the compiler, Elixir mode and the error registry | `lib/defk/builtins.ex` |
| Agreement helpers for tests | `lib/defk/test.ex`, `lib/defk/ex_unit/case.ex` |
| StreamData generators by kernel type | `test/support/generators.ex` |
| Runtime: arrays, checks, safepoints, frames, exceptions | `priv/defk_runtime.h` |
| BEAM/NIF reference (execution model, lifecycles, errors, upgrade) | `docs/beam-nifs.md` |
| Example kernels | `lib/examples.ex` |
| Plain C baseline | `bench/native.c` |

**Language:**
- Types: `i64`, `f64`, `bool`, `[f64]`, `[f32]`, `[i64]`, `[i32]`, `[i16]`, `[u8]`, and tuples for return values. The narrow element types exist only in arrays: a read widens to `i64`/`f64`, a write that does not fit raises.
- Constructs: `=`, `if`/`else`, `cond`, `case`, `for` with ranges, array generators, filters and `reduce:` (including tuple accumulators, owned arrays threaded in place, and the bitstring accumulator).
- Early exit: `Enum.reduce_while(enumerable, acc, fn x, acc -> {:cont, acc} | {:halt, acc} end)`, and `Enum.all?/2` / `Enum.any?/2` with a `fn`. The enumerable is a range or an array, as in a `for` generator.
- `case` on an `i64` or `bool`: integer literals, `true`/`false`, `^pinned`, `_` or a variable, each with an optional guard. Used as a value or a statement.
- `raise ArgumentError, "message"`, `raise ArithmeticError` (the module's default message), `raise "message"` (`RuntimeError`): a statement, anywhere a statement goes (`if not ok, do: raise(...)` before the value), with a string-literal message; it raises the same exception, message and all, natively and in Elixir mode.
- Operators: `a[i]`, `out[i] = v` (only on `alloc/2` arrays), `+ - * /`, `div`, `rem`, comparisons, `and`/`or`/`not`, and bitwise on `i64`: `band`/`bor`/`bxor`/`bnot`/`bsl`/`bsr` (also as `&&& ||| ^^^ ~~~ <<< >>>` or `Bitwise.band/2` and so on, no `import Bitwise` needed).
- Builtins: `len`, `min`, `max`, `abs`, `float`, `trunc`, `round`, `sqrt`, `exp`, `log`, `sin`, `cos`, `pow` (also as `:math.*`), plus calls to other kernels (inlined).
- `u64` scalars and `[u64]` arrays: exact unsigned 64-bit integers, checked like `i64` (docs/language.md "u64").
- Masked arithmetic: `+ - * band bor bxor bnot bsl` directly inside `band(expr, 2^k - 1)`, k <= 64, wrap like machine arithmetic and give Elixir's exact masked result without raising (the 64-bit mask gives a `u64`); `wrap64(expr)` wraps the same tree to the low 64 bits as a signed i64, as `Defk.Bits.wrap64/1` does in Elixir (for hashes such as FNV-1a and MurmurHash3).
- Bit builtins: `mulhi(a, b)` (high 64 bits of the unsigned 128-bit product), `clz`, `ctz`, `popcount` and `rotl64`/`rotr64` on the u64 bit pattern of an `i64`, `clz/2`, `ctz/2`, `rotl/3`, `rotr/3` on a w-bit value, and `f64_to_u64/1`; each is a plain function in `Defk.Bits` that Elixir mode calls (for hashing and bit-reader kernels).
- Word loads: `u64_le(bytes, i)`, `u32_le`, `u16_le` and the `_be` variants read an unsigned word at a byte offset of a `[u8]` (one unaligned load; `u64` comes back as its signed i64 bit pattern).
- Binary literals: `"abc"` and `<<1, 2, 3>>` (integer segments 0..255) are a read-only `[u8]` in static storage, like a binary attribute: index it, `len` it, `for x <- "abc"`, pass it to a helper, compare it byte by byte; `"0123456789abcdef"[band(x, 15)]` has no bounds check. Not writable or returnable; no interpolation or charlists.
- Module attributes as constants: `@name` holding an integer, float or boolean is inlined as that literal (also as a `case` pattern, in a guard, as a range bound, or a `band` mask that elides bounds checks); one holding a binary is a read-only `[u8]`. The value is the one where the kernel is defined, as in a `def`.

**Elixir mode** (tests and debugging only): each kernel body is also compiled to
plain Elixir with the kernel's limits applied, so the two can be checked for
agreement. `Mod.__defk_elixir__(:fun, args)` runs one call that way;
`config :defk, mode: :elixir` (only in `:dev`/`:test`) runs every call that
way, and `Defk.ElixirMode.with_mode/2` switches one process. It is always
compiled in `:test`. `dbg/1` and `IO.inspect/1,2` work inside a kernel body
there (native code ignores them), and `Mod.__defk_elixir_source__/0` shows the
generated code.

**Fast-path report** (a tool for explaining measurements): `Defk.Report.print(Mod)`
prints each kernel's source with margin notes on what the compiler did to the
hot path. It shows each bounds check dropped or kept (a kept one names the fact
that would drop it), each `if`/`cond`/`case` as a select or a branch and why,
each loop's safepoints (per iteration, strips of `DEFK_STRIP`, or none) and
why, inlined calls, copies and flagged float checks. `Mod.__defk_report__/0`
returns the same facts as data, so a test can assert that a hot loop stays
tight. `use Defk, report: :full` adds clang's vectorisation verdict for each
loop, at the cost of one extra compiler pass. See
[`docs/fast-path-report.md`](docs/fast-path-report.md).

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

## Results (M-series Mac, OTP 29, Elixir 1.20; noisy, single runs)

The float rows predate the inf/NaN checks (defk-i00). Since defk-6tt they cost `dot` nothing measurable (see Known limitations).

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

## Known limitations

These are deliberate, to keep defk small for now.

- No recursion (rejected at compile time). Kernel calls are inlined, so the generated code grows with the number of call sites along each call chain.
- A float operation whose result would be inf or NaN raises `ArithmeticError` at that operation, as Elixir does (`1.0e308 * 10.0`, `x / 0.0`, `0.0 / 0.0`, `sqrt(-1.0)`, `log(0.0)`, `exp(1000.0)`, `:math.pow(10.0, 400.0)`), also when the value would never be returned. An `[f64]` input element whose bits are inf or NaN raises `ArgumentError` when it is read, as Elixir mode's binary match does; an element never read does not. Underflow to 0.0 or a subnormal does not raise. A select whose untaken arm would give inf or NaN (`if y != 0.0, do: x / y, else: 0.0`) does not raise: float arms are speculated with a flag, like i64 overflow (defk-i00).
  This is Elixir's behaviour, not a limit, but it costs time. A float expression over variables, literals and in-range reads is computed with plain C operators and checked once (`+ - *` keep an inf or NaN operand non-finite, so the result shows it; a divisor that may be inf is checked too); a failed check replays the expression one operation at a time, so it raises the error Elixir would. Other float operations are checked one by one. Measured with the checks and with them compiled out (`mix run bench/float_checks.exs`, 1M elements, 3 runs of 11 interleaved rounds, best of 5 per round, on a shared machine): `dot` +24% (run medians 23.5-24.1%, single rounds 20-28%), cosine similarity +17% (17.4-17.5%, 13-20%), rolling_stats `mean_std` +23% (22.0-23.3%, 19-44%), and an element-wise map (`scale`, `out[i] = a[i] * k`) +87-91% (75-118%), because a check per element stops clang from vectorising the loop. Checking every operation and read on its own cost `dot` 30%, cosine 82%, `mean_std` 48% and `scale` 150%.
  A flat loop (design decision 3) whose only checks are these float checks now runs each strip with a flag instead (defk-6tt): every float result and `[f64]` input read ORs "inf or NaN" into a flag with no branch, and the flag is tested once at the strip's end, before its safepoint. A reduce accumulator built with `+ - *` (`acc + a[i] * b[i]`) keeps an inf or NaN, so it is tested once at the strip's end instead of on every iteration. A set flag replays the strip from a snapshot of its locals taken at its start, with the raising checks, so the error is the one Elixir raises, at the same element. The flat loop's body is emitted three times instead of twice (the 4 benchmark kernels: 12.9 KB to 14.9 KB of code). Measured the same way (3 runs of 11 rounds, same machine and noise): `dot` 0.0-0.2% (run medians; single rounds -7..14%), cosine -0.3-0.2% (-8..12%), `scale` 0.5-3.6% (-5..19%); clang now vectorises `scale` 16 elements per iteration with the flag as an OR of compare masks (`fmul.2d`, `fabs.2d`, `fcmge.2d`, `orr.16b`). `mean_std` is unchanged at 29-33% (main measured 31% in the same session): its strip can also fail by bounds checks and i64 overflow on its index arithmetic, which would raise before an earlier flagged float error, so it keeps one check per expression. Testing the flag before each of those other checks instead measured worse (41%).
  A strip with float checks now also runs flagged when it has i64/u64 overflow checks, bounds checks, narrow-write range checks and float-to-integer conversions (defk-hki): each sets the same flag and the strip replays from its start on any failure, so the first error in program order still wins. A flagged element access out of bounds reads a static zero or writes a strip-local sink instead (the address is selected, never formed from the bad index), and a strip whose unchecked accesses use an index assigned in the strip stays checked, so a wrong value computed after a failure never reaches memory. Branchless flags alone did not pay for `mean_std`: its loop does not vectorise, and they measured 6-15% slower than the predicted branches with the checks on. What pays is what the flag allows: a check whose inf or NaN always reaches a later checked float expression is left out of the flagged strip (the `[f64]` reads of the window sums and `mean`, which flows into the variance), `sqrt(max(x, 0.0))` needs no check at all, and `sqrt` is one instruction (`__builtin_sqrt`, correctly rounded like libm's) instead of a libm call. Measured provisionally under load (other agents' builds and tests running, load average 5-7.5; 3 runs of 11 interleaved rounds, best of 5 per round): `mean_std` +8.2%, +7.1%, +8.5% (run medians; min/min 8.2-9.7%, single rounds 3-12%), so within 10% of the unchecked loop on the medians but not in every round. It is also faster outright: checks on 1937-1956 us against main's 2621-2637 us in the same session (main's cost 37-39%), checks off 1788-1816 us against main's 1893-1899 us. `dot` and cosine stay within noise (run medians -1.8..0.9%); `scale` (unchanged C) swung 7.7-14.8% in these runs and main measured 4.3-14.9% in the same session, noise under load.
- An array may be returned if the kernel created it with `alloc/2` or wrote it (a written input array is a copy, the caller's binary is never changed); returning an input array the kernel never writes is not supported yet (defk-gqk). Arrays can't flow through `if`/`cond` branches.
- No maps, lists or strings (a string literal, `<<1, 2, 3>>` or a binary module attribute is a `[u8]`; a write copies it first).
- Early exit only through `Enum.reduce_while` and `Enum.all?/any?`. Every tail of the `fn` must be a literal `{:cont, acc}` or `{:halt, acc}` (through `if`/`cond`/`case`). There is no `while`/`break`, and `{:halt, acc}` in a `for ..., reduce:` is not early exit, as in Elixir. No `Enum.find`/`find_index` (no `nil`).
- `case` matches only `i64`/`bool` subjects against literals, variables and pins (no floats, tuples or ranges). An error inside a guard (overflow, `rem` by zero) raises, where Elixir would fail that clause. Kernel calls are rejected in guards, as Elixir rejects them.
- Arrays are values, as in Elixir: after `b = a`, a write `a[i] = x` leaves `b` as it was. The compiler copies the buffer once, before the write (or before the loop or branch holding it), when the array is an input or another variable reading the same buffer is used later; otherwise the write is in place. The test is static and conservative, and every copy lives until the kernel returns (docs/language.md, "Copies"). An array variable bound again inside a loop body and read after the loop is a compile error, since the binding does not leave the loop.
- `alloc/2` raises `ArgumentError` for a length over 2^48 bytes ("length too large", the user address space of 64-bit platforms) and for one the allocator cannot provide ("out of memory"). A range whose last element is within one step of the i64 limit (`0..9223372036854775807`) raises `ArithmeticError` before its loop starts, also when a halt would end it earlier: stepping past that element would overflow the loop counter.
- Float arithmetic is evaluated as written, so results match Elixir bit for bit: kernels build with `-ffp-contract=off` and never `-ffast-math` or reassociation. A float reduction (`acc + a[i] * b[i]`) therefore stays in order and is not vectorised across lanes. Measured with and without the flag (5M elements): `dot` ~0.56 ns/elem, `sum` 0.50-0.53, `mean_var` 3.8-4.3 either way, so the flag costs nothing measurable here (defk-jlk). libm calls (sin, cos, exp, log, pow, sqrt) are not fused or substituted either (`-fno-builtin`: no sincos, no `pow(x, 2.0)` to `x*x`), so they match `:math` bit for bit (defk-6g6).
- `bsl`/`<<<` (and `bsr` by a negative shift) raises `ArithmeticError` when the exact result does not fit in i64, where Elixir would return a bignum; there is no wrapping shift yet (masked arithmetic, defk-n4r.2).
- A kernel survives one reload of its module; a second reload before it finishes purges its code and kills it (standard BEAM old-code semantics).
- The C compiler runs at compile time on the build machine (no Cranelift JIT path).

## Roadmap

The larger steps, grouped by goal. Each item names its beadwork ticket (`bw show <id>`); ticked items are closed.

**0. Verdict** (plan in `bw show defk-sgw`)
- [ ] Draft docs/verdict.md with the pre-registered go/no-go rule (defk-sgw.2)
- [ ] Write docs/language.md, the kernel subset reference (defk-sgw.1)
- [ ] Devex cold test: a new kernel from the docs alone (defk-sgw.3)
- [ ] Freeze the workload-results snapshot on a quiet machine (defk-sgw.4)
- [ ] Write the verdict: guide, runtime contract, devex, limitations (defk-sgw.5)
- [ ] Final verdict session (defk-sgw.6)

**1. Honest measurement: show where defk helps Elixir**
- [x] Record the purpose: Elixir first, defk only where it helps (defk-9p6.5)
- [x] Example catalog with a scoreboard (defk-9p6.1)
- [x] fuzzy_search example app (defk-nv1)
- [ ] Optimise the Elixir baselines, so the `good` verdicts are no longer provisional: rolling_stats (defk-9p6.6), geo_nearest (defk-9p6.7), image_blur (defk-9p6.8), fuzzy_search (defk-9p6.9)
- [ ] Re-measure fuzzy_search, yielding against blocking, on a quiet machine (defk-klw)
- [ ] Refresh the results table and demo numbers on a quiet machine (defk-yzw)
- [ ] Separate code-layout noise (±3%) from real effects (defk-wnu)

**2. Language: express the algorithms people write NIFs for**
- [x] Early exit: `Enum.reduce_while`, `Enum.all?/any?` (defk-9vl)
- [x] `case` on `i64`/`bool` (defk-9vl)
- [x] Calls between kernels that yield (defk-jaj)
- [ ] Bitwise operators (`band`/`bor`/`bxor`/`bsl`/`bsr`) for hashing and checksums (defk-w38)
- [ ] Arrays through `if`/`cond` branches, and returning input arrays (defk-gqk)
- [ ] `Enum.reduce/3`, and a `find_index` that keeps Elixir semantics without `nil` (defk-nii)
- [ ] More `case` patterns: `x in [1, 2, 3]` and ranges (defk-gid)
- [ ] Module attributes as constants (defk-ivt)
- [x] Multi-clause kernels with a typed function head (defk-u9c)
- [ ] Signed integer segments in the bitstring accumulator (defk-dki)
- [ ] Pass the bitstring accumulator through helper kernels (defk-ooq)

**3. Semantics: behave like Elixir where it matters**
- [x] Array value semantics: copy on aliased write (defk-i2e, defk-auo)
- [x] inf/NaN inside kernels: raise like Elixir (defk-q1c, defk-i00)
- [ ] An error inside a guard fails the clause instead of raising (defk-7a6)

**4. Performance: plain-C speed from Elixir-shaped code**
- [x] Bounds-check elimination for provably in-range `a[i]` (defk-88q)
- [x] count_primes at C speed: `if`/`cond` arms compiled as selects (defk-jp3, defk-7q5)
- [ ] Guard against code-size blowup from inlined calls (defk-6ag)
- [ ] No C compiler warnings in generated code (defk-5dd)

**5. Runtime: be a good BEAM citizen**
- [x] Safepoints cost ~0% in hot loops (defk-5s3, defk-nua)
- [x] Worst scheduler gap in line with a busy Elixir process (defk-j3h)
- [x] Resume correctness under forced yields (defk-h8a)
- [x] Hot code upgrade with suspended kernels (defk-nbl)
- [x] Resume tests fail instead of hanging on a resume bug (defk-juw)
- [x] Show an early-exit kernel in the preemption demo and `tick_gap` (defk-tfh)
- [ ] `__defk_stats__` semantics across reloads (defk-9qv)
- [ ] Layout version tag on frames, as defence in depth (defk-ls8)

**6. Catalog: map the boundary of defk's niche**
- [ ] Checksum/hash over binaries, compared with `:erlang.crc32` (defk-9p6.2, needs defk-w38)
- [ ] Matrix multiply against Nx (expected verdict: use Nx) (defk-9p6.3)
- [ ] n-body step with state kept packed between calls (defk-9p6.4)
- [x] Fair early-exit cutoff for fuzzy_search's Levenshtein, in both backends (defk-8i4)

**7. Later**
- [ ] Cranelift JIT backend for kernels specialised at runtime (defk-o1w)
