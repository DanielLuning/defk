# defk

> defk explores one question: **can a typed subset of Elixir compile
> to native code that runs at C speed, with a cheap boundary, while keeping the
> BEAM's promises (preemption, isolation, cleanup)?**

```bash
mix run demo.exs        # correctness, throughput vs Elixir and plain C, boundary cost,
                        # preemption on one scheduler, failure isolation
```

Needs Elixir ≥ 1.18 and a C compiler (`cc`, or set `CC`).

## Real-world example

[`examples/fuzzy_search`](examples/fuzzy_search) is a typo-tolerant search
service (Levenshtein top-k over 234k words, Plug + Bandit), the kind of code
teams usually write a NIF for. Under saturating load, defk serves 4.3× the
requests of pure Elixir while keeping `/health` latency at Elixir levels. An
equivalent blocking NIF is faster but pushes `/health` p99 to ~80 ms.

## What it is

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

At `mix compile`, `defk` type-checks the body, emits C
(`_build/dev/defk/*.c`; also `Mod.__defk_source__/0`), builds a NIF with
`cc -O3`, and generates the Elixir stubs plus `@spec`s.

| Piece | File |
|---|---|
| `defk` macro and stub generation | `lib/defk.ex` |
| Type checker and C codegen | `lib/defk/compiler.ex` |
| C build, cached by source hash | `lib/defk/build.ex` |
| Runtime: arrays, checks, safepoints, frames, exceptions | `priv/defk_runtime.h` |
| Example kernels | `lib/examples.ex` |
| Plain C baseline | `bench/native.c` |

**Language:**
- Types: `i64`, `f64`, `bool`, `[f64]`, `[i64]`, `[u8]`, and tuples for return values.
- Constructs: `=`, `if`/`else`, `cond`, `for` with ranges, array generators, filters and `reduce:` (including tuple accumulators).
- Operators: `a[i]`, `out[i] = v` (only on `alloc/2` arrays), `+ - * /`, `div`, `rem`, comparisons, `and`/`or`/`not`.
- Builtins: `len`, `min`, `max`, `abs`, `float`, `trunc`, `round`, `sqrt`, `exp`, `log`, `sin`, `cos`, `pow` (also as `:math.*`), plus calls to other kernels.

## Design decisions the benchmarks validated

1. **Arrays are views over binaries.** Inputs are zero-copy. Outputs are `enif_alloc_binary` buffers handed over with `enif_make_binary`. Unaligned sub-binaries are copied once.
2. **Elixir semantics where they're cheap:**
   - checked i64 overflow raises `ArithmeticError`
   - `/` always returns a float and raises on division by zero
   - `div`/`rem` follow Elixir rounding
   - `a..b` counts down when `a > b`
   - bounds failures raise `Enum.OutOfBoundsError` in the caller
3. **Automatic yielding.** Every loop back-edge is a safepoint. Locals live in registers and are spilled to a frame struct only when the kernel actually yields; resume jumps back to the label.
4. **Pay for yielding only when you yield.** A kernel starts on a C stack frame. Only on its first yield is the frame copied into a resource, whose destructor frees owned buffers if the process dies.
5. **Adaptive safepoint budget.** The clock is read every ~100–250 µs regardless of how expensive one loop iteration is.
6. **`sigsetjmp(jb, 0)` for errors.** Plain `setjmp` saves the signal mask on macOS (a syscall), which cost 160 ns per call.
7. **Never take the address of an array view in kernel code.** If it escapes, clang reloads `data`/`len` on every iteration.

## Results (M-series Mac, OTP 29, Elixir 1.20; noisy, single runs)

| | Elixir | defk | plain C |
|---|---|---|---|
| sum of 5M f64 (ns/elem) | 8.5 (list), 16.7 (binary comprehension) | 0.58 | 0.64 |
| dot of 5M f64 with bounds-checked `a[i]` (ns/elem) | 12.2 (list) | 0.79 | 0.62 |
| count_primes(1M), trial division (ms) | 1490 | 317 | 188 |
| call overhead (ns/call) | 1.6 | 12 | — |
| worst 1 ms-ticker gap on one scheduler (ms) | 2.2 (busy Elixir process) | 3.5 (yielding), 939 (`yield: false`) | — |

- Safepoint overhead: ~0% (within noise).
- Killing a process mid-kernel frees its frame (`frames_live` 1 → 0).

**Still open:**
- `count_primes` is 1.7× slower than C. It isn't the `rem` checks (C with the same checks is the same speed), and switching the loop shape didn't change it.
- `dot` pays ~25% for bounds checks, because the compiler doesn't yet prove `i < len`.

## Known limitations

These are deliberate, to keep defk small for now.

- Kernels called from other kernels can't yield; only the entry kernel's loops yield.
- No recursion (rejected at compile time, so native stack depth stays bounded).
- inf/NaN are allowed inside a kernel; a non-finite *returned* float raises.
- An array may be returned only if it was created with `alloc/2`. Arrays can't flow through `if`/`cond` branches.
- No `while`/early exit, no `case`, no maps, lists or strings.
- Array writes alias: `b = a` then `a[i] = x` is visible through `b`.
- Hot code upgrade has an `upgrade` callback that takes over the resource type, but it hasn't been tested.
- The C compiler runs at compile time on the build machine (no Cranelift JIT path).
