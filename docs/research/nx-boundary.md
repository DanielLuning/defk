# Where Nx already covers native-speed numerics, and where it doesn't

Research for ticket **defk-dtw.2**. Nothing here was measured: every claim cites
a primary source (Nx/EXLA/Torchx/EMLX/Explorer source and moduledocs, ERTS docs,
José Valim's posts and issues). Statements marked *inference* are my reading of
the sources, not something a source says outright.

Versions read (2026-10-05): `nx`, `exla`, `torchx` **1.0.0** (latest stable on
hex.pm), from the `elixir-nx/nx` repo at commit
[`87e923e`](https://github.com/elixir-nx/nx/tree/87e923e4664fc303555c89ed4f3a3b71b4f677d1);
`emlx` main at [`10ddda6`](https://github.com/elixir-nx/emlx/tree/10ddda6c1bf58d1f3b19f4e50d126dafe76db6d4)
(0.5.0 on hex); `explorer` main at
[`5e75adb`](https://github.com/elixir-explorer/explorer/tree/5e75adb6a763b14b0e26d8cd3136562fb368b91d).
Below, `nx:` / `exla:` / `torchx:` paths are relative to that Nx commit.

## Bottom line

Nx is the right tool when the work is **whole-tensor, shape-static, and big
enough to amortise a compile and a dirty-scheduler round trip**: elementwise
maps, reductions, windows, cumulative sums, sort/argsort, linear algebra,
convolutions, anything with gradients, anything that should run on a GPU. defk
should not compete there (the catalog's planned matmul-vs-Nx entry, defk-9p6.3,
expects "use Nx", and the sources agree).

The jobs Nx leaves open, and that people therefore still solve with hand-written
NIFs or slow Elixir, are the ones defk's kernel subset is shaped for:

1. **Sequential scalar loops with data dependencies between iterations and early
   exit** (scans that aren't associative, state machines, trial division, edit
   distance with cutoff). Nx can express them with `while`, but its own docs say
   to avoid hand-written loops, and the loop then runs either through the
   pure-Elixir Evaluator (tensor ops per iteration) or as one uninterruptible
   XLA call on a dirty scheduler.
2. **Variable-length inputs, small inputs and high call rates.** defn
   compiles per input shape, the jit cache lookup "may take milliseconds", EXLA
   calls go through a GenServer lock per device, and empty tensors cannot exist.
3. **Byte/binary and integer-exact work.** Nx has `u8` and bitwise ops, but
   integers wrap silently, integer division by zero "may trigger undefined
   behaviour", masking/filtering (data-dependent output shapes) is unsupported,
   and Torchx emulates unsigned types with signed ones.
4. **Scheduler behaviour.** Every native Nx path (EXLA, Torchx) runs on dirty
   schedulers; EMLX on its own worker threads. None yields, and per ERTS a
   killed process does not stop a running dirty NIF. The only path that stays
   on normal schedulers is the pure-Elixir Evaluator + BinaryBackend, which is
   not native speed. defk's automatic yielding on normal schedulers is the
   property no Nx backend offers.

## What Nx does well

- **Tensor programming as an Elixir subset.** "A numerical function is a subset
  of Elixir tailored for numerical computations ... will work with scalars,
  vector, matrices, and n-dimensional tensors ... JIT-compiled and run either on
  the CPU or GPU" (`nx/lib/nx/defn.ex` moduledoc, L1-L18). The v0.1 announcement
  frames the project as bringing "Elixir to the world of numerical computing and
  machine learning" (José Valim,
  [Nx v0.1 released](https://dashbit.co/blog/elixir-and-machine-learning-nx-v0.1),
  2022-01-06).
- **Rich type set:** `u2`..`u64`, `s2`..`s64`, `f16`/`f32`/`f64`, `bf16`, `f8`
  variants, `c64`/`c128` (`nx/lib/nx.ex` L56-L63). Bitwise ops
  (`bitwise_and`, `left_shift`, `population_count`, `count_leading_zeros`) exist
  (`nx/lib/nx.ex` L6940, L7099, L9052, L9118).
- **Built-in vectorised kernels** that cover most "loop over an array" jobs:
  `window_sum/mean/max/min/product/reduce`, `cumulative_sum`, `argmax`,
  `argsort`, `take`, `select`, linear algebra (`nx/lib/nx.ex` L11244-L11837,
  L10826, L15980, L14763, L7813; `Nx.LinAlg`).
- **XLA compilation to CPU/GPU/TPU** via EXLA, with fusion, sharding
  (`EXLA.shard_jit/3`), buffer donation, and a compile cache keyed by shapes
  and types (`exla/lib/exla.ex` moduledoc L1-L60, `jit/2` options L270-L318).
  Torchx (libtorch) and EMLX (Apple MLX, with its own defn compiler) are
  alternative backends.
- **Batching for services.** `Nx.Serving` "encapsulates client and server work
  to perform batched requests" and batches "until a given size or timeout is
  reached" (`nx/lib/nx/serving.ex` L1-L12). This is the Nx answer to
  per-call overhead: amortise it over a batch.
- **Ahead-of-shape compilation.** `Nx.Defn.compile/3` "precompiles the given
  anonymous function based on the input shapes ... beneficial for large
  numerical definitions, where the cache mechanism in `jit/2` may take
  milliseconds" (`nx/lib/nx/defn.ex` L284-L291).

## Where Nx doesn't fit

### Scalar loops, `while`, early exit, data dependencies

- **Loops are discouraged.** `while` docs: "you must prefer to use the
  operations in the `Nx` module, whenever available, instead of writing your
  own loops" (`nx/lib/nx/defn/kernel.ex` L1052-L1053, repeated L1104-L1106).
  `Nx.reduce/4` with a function: "may not be available or efficient on all Nx
  backends. Therefore, you should avoid using `reduce/4` whenever possible"
  (`nx/lib/nx.ex` L12350-L12358).
- **No recursion, so `while` is the only general loop.** "Given numerical
  definition first build a representation of your code, it is not possible to
  write recursive (nor tail recursive) code inside `defn`. Instead, one must use
  `Nx.Defn.Kernel.while/4`" (`nx/lib/nx/defn.ex` L206-L211).
- **`while` is expressive enough for early exit:** its condition is evaluated
  every iteration and the loop state is a tuple of tensors
  (`nx/lib/nx/defn/kernel.ex` L1033-L1089). There is no `break`; early exit
  means folding the stop flag into the condition. Every variable used inside
  must be threaded through the loop state explicitly (L1063-L1077).
- **XLA loops are sequential.** José Valim, opening the issue that introduced
  `while`: "the only form of loops we have in XLA are while loops which are
  sequential", and he preferred higher-level tensor functions (`map`, `reduce`)
  instead ([elixir-nx/nx#122](https://github.com/elixir-nx/nx/issues/122),
  2021-01-02). EXLA lowers `while` to `stablehlo.while`
  (`exla/lib/exla/mlir/value.ex` L761-L767). The v0.1 post presents `while` as
  "handy in recurrent models" ([Nx v0.1](https://dashbit.co/blog/elixir-and-machine-learning-nx-v0.1)),
  i.e. a loop over large tensor steps, not over scalars.
- **Cost of `while` depends on the compiler.**
  - Evaluator (the default compiler): "evaluates the expression tree against
    the tensor backend" (`nx/lib/nx/defn/evaluator.ex` L1-L5); `while` is
    interpreted iteration by iteration (`evaluator.ex` L330-L333). With the
    default `Nx.BinaryBackend`, "written in pure Elixir that stores the data in
    Elixir's binaries" (`nx/lib/nx/binary_backend.ex` L2-L9), each scalar step
    is a tensor op in Elixir. *Inference:* slower than plain Elixir for scalar
    loops, never native speed.
  - With Torchx as the backend, defn still runs through the Evaluator (Torchx
    is a backend, not a `Nx.Defn.Compiler`: `torchx/lib/torchx/backend.ex` L1-L2, and no `Nx.Defn.Compiler` in `torchx/lib`), and each tensor op is a separate
    dirty NIF call (`torchx/lib/torchx.ex` L27-L39, `torchx/c_src/torchx.cpp`
    L45-L49). *Inference:* a scalar loop pays a NIF round trip per op per
    iteration.
  - EXLA: the whole loop compiles into one executable and runs inside one NIF
    call (see "Scheduler behaviour"). Fast per iteration, but uninterruptible
    for the whole loop.

### Small inputs, per-call overhead, compile time

- **Compile per shape.** "`defn` functions are compiled when they are invoked,
  based on the type and shapes of the tensors given as arguments. Therefore
  compilation may be quite time consuming on the first invocation. The
  compilation is then cached based on the tensors shapes and types"
  (`nx/lib/nx/defn.ex` L81-L87). *Inference:* a job whose input length varies
  per call (strings, packets, rows of a CSV) compiles once per distinct length,
  unless the caller pads to fixed buckets.
- **Each eager op on `EXLA.Backend` is itself jit-compiled** (`EXLA.jit_apply`
  per op, `exla/lib/exla/backend.ex` L427-L431). Compile time is reported via
  telemetry `[:exla, :compilation]` with `:eval_time`/`:compile_time`
  (`exla/lib/exla.ex` L242-L256); XLA compilation itself runs as a dirty-CPU NIF
  (`mlir_compile`, `exla/c_src/exla/exla.cc` L324).
- **Cache lookup is not free:** "the cache mechanism in `jit/2` may take
  milliseconds" for large definitions (`nx/lib/nx/defn.ex` L289-L291). EMLX
  documents the same: `jit` "still retrace[s] through Nx on every call", and
  for a hot loop recommends `Nx.Defn.compile/3` (`emlx/lib/emlx.ex` L147-L160).
- **Per-call locking on EXLA.** Every call to a compiled EXLA function takes
  `EXLA.Defn.Lock.lock(run_key(executable))` before running and unlocks after
  (`exla/lib/exla/defn.ex` L66-L70, L206-L220). The lock is a GenServer call
  that queues callers per key (`exla/lib/exla/defn/lock.ex` L16-L18, L63-L77),
  and on the host the key is `[:host | device_id]` (`defn.ex` L223). The host
  client is created with `asynchronous = false`
  (`exla/c_src/exla/exla_client.cc` L545-L549), and XLA's CPU device count
  defaults to `--xla_force_host_platform_device_count`
  ([`cpu_client_options.h`](https://github.com/openxla/xla/blob/main/xla/pjrt/plugin/xla_cpu/cpu_client_options.h)).
  *Inference:* with the default single host device, concurrent EXLA-CPU calls
  from many BEAM processes run one at a time, each paying two GenServer calls
  plus the dirty-NIF hop. That suits batched work (`Nx.Serving`), not many
  small independent calls.
- **No empty tensors:** `Nx.from_binary/2` raises "cannot build an empty
  tensor" (`nx/lib/nx.ex` L2056-L2058). Zero-length input needs a guard in
  Elixir.

### Byte/binary processing and integer-heavy work

- `u8` and bitwise ops exist (above), and `Nx.from_binary/2` accepts a packed
  binary. But:
- **No data-dependent shapes:** "Boolean masking requires dynamic shape
  behavior, which is not supported in Nx because Nx compiles all operations
  ahead-of-time ... tensors must have static shapes"
  (`nx/guides/cheatsheets/numpy_nx.cheatmd` L250-L252). Filtering, tokenising,
  "find all matches" and variable-length output need `select`+padding or Elixir.
- **Integer overflow wraps silently:** "Integers and floats bigger than the
  given size overflow", e.g. `300` as `s8` becomes `44` (`nx/lib/nx.ex`
  L522-L528). Integer literals default to `s32` (`nx/lib/nx/type.ex` L173).
  defk raises `ArithmeticError` on i64 overflow, as Elixir would (README).
- **Integer division by zero:** `quotient/2` "Division by zero raises, but it
  may trigger undefined behaviour on some compilers" (`nx/lib/nx.ex`
  L6592-L6594; `divide/2` carries the same caveat, L6504-L6506).
- **Torchx unsigned types are emulated:** "u64 actually overflows at u32", and
  Torchx rounds half-to-even where Elixir rounds half-away-from-zero
  (`torchx/lib/torchx/backend.ex` L5-L22).
- **EMLX has no f64:** "Metal does not support 64-bit floats, so neither MLX nor
  EMLX do either" (`emlx/README.md` L21).
- No strings or maps of variable size inside `defn`; maps are containers of
  tensors (`nx/lib/nx/defn.ex` L126-L200). Same limitation as defk's subset.

### Scheduler behaviour

| Path | Where it runs | Preemptible? | Source |
|---|---|---|---|
| `Nx.Defn.Evaluator` + `Nx.BinaryBackend` | normal schedulers, pure Elixir | yes (ordinary reductions) | `evaluator.ex` L1-L5, `binary_backend.ex` L2-L9 |
| EXLA, host (CPU) | `run_cpu`, **dirty CPU** NIF, whole executable in one call | no | `exla.cc` L620-L628, `executable.ex` L151-L154 |
| EXLA, GPU/TPU | `run_io`, **dirty IO** NIF | no | `exla.cc` L630-L637; moduledoc: "GPU Executions run in dirty IO threads" (`exla.ex` L185-L193) |
| EXLA compile | `mlir_compile`, dirty CPU | no | `exla.cc` L324 |
| Torchx | every op `_cpu` (dirty CPU) or `_io` (dirty IO) variant | no | `torchx.cpp` L45-L49, `torchx.ex` L34-L37 |
| EMLX | "dedicated threads instead of BEAM dirty schedulers"; caller awaits a reply | the caller waits on a message | `emlx/README.md` L17, `emlx/lib/emlx.ex` L31-L34 |
| Explorer (Polars) | 194 `DirtyCpu` + 25 `DirtyIo` Rustler NIFs | no | `grep 'schedule = "Dirty'` over `explorer/native` |

What ERTS says about these paths:
- A regular NIF should "return to its caller within 1 millisecond"; long work
  should use `enif_schedule_nif`/`enif_consume_timeslice`
  ([erl_nif](https://www.erlang.org/doc/apps/erts/erl_nif.html)).
- When a process running a dirty NIF is killed, "The execution of the NIF is,
  however, *not* stopped" (erl_nif, dirty NIFs). *Inference:* a long EXLA
  `while` or a big Torchx op keeps burning a dirty CPU thread (and, for EXLA,
  holds the device lock) after its caller is gone.
- Dirty CPU schedulers default to one per normal scheduler; dirty IO
  schedulers default to 10 ([erl `+SDcpu`/`+SDio`](https://www.erlang.org/doc/apps/erts/erl_cmd.html)).
  *Inference:* dirty scheduling keeps normal schedulers responsive, which is
  why Nx's design works for its niche, but it caps concurrent native work at
  the dirty pool size and gives no fairness between long and short jobs in it.

So Nx's answer to "don't block the scheduler" is **dirty schedulers (or worker
threads), not yielding**. That is a sound choice for big batched tensor calls.
It is a poor fit for (a) work that should be cancellable when its process dies,
(b) many concurrent medium-length calls competing for a small dirty pool or a
single EXLA host lock, and (c) code that wants to run as an ordinary,
preemptible BEAM citizen. defk's runtime contract (yield at loop back-edges on
normal schedulers, free the frame on process death) targets exactly that gap.

## The boundary

| Job shape | Use | Why (source) |
|---|---|---|
| Elementwise/reduction/window/scan over large fixed-shape arrays, linear algebra, convolutions, gradients, GPU | **Nx** (EXLA/EMLX) | built-in ops + XLA fusion; Nx docs steer away from hand loops (kernel.ex L1052) |
| Many requests of the same shape (model inference, scoring) | **Nx.Serving** | batching amortises per-call cost (serving.ex L1-L12) |
| Sequential scalar loop with data dependencies (recurrence, state machine, DP row) | **defk** | `while` is sequential (nx#122), interpreted per op on Evaluator, uninterruptible on EXLA |
| Loop with early exit (search, trial division, cutoff) | **defk** | Nx: stop flag in `while` condition; no `break`; same cost profile as above |
| Variable-length input per call (strings as bytes, packets, rows) | **defk**, or Elixir | defn compiles per shape (defn.ex L81-L87); no empty tensors (nx.ex L2057) |
| Small inputs, high call rate, many concurrent callers | **defk**, or Elixir | jit lookup cost (defn.ex L289), EXLA per-device GenServer lock (defn.ex L66, lock.ex) |
| Byte processing with filtering/variable output (parse, tokenize, find) | **defk** (as its subset grows), or Elixir binaries | no dynamic shapes (numpy_nx.cheatmd L250) |
| Integer-exact arithmetic (checksums, hashing) | **defk** once bitwise ops land (defk-w38); `:erlang.crc32`/`:crypto` where they exist | Nx ints wrap silently (nx.ex L522), div-by-zero UB (nx.ex L6593) |
| Work that must stay preemptible / be cancelled with its process | **defk** | all native Nx paths are dirty NIFs or worker threads; killed dirty NIFs keep running (erl_nif) |
| Maps, strings, lists as data | **Elixir** | neither Nx defn nor defk express them |

## Gaps and open questions

- **Measured since** (`examples/threshold_cross.exs`, `defk-9p6.29`,
  2026-10-20, Nx and EXLA 0.13.1 on the CPU, provisional): one early-exit
  job (the first index where a running sum of i64 passes a budget) in
  Elixir, defk, `defn` with `while` and `defn` with `Nx.cumulative_sum`.
  These inferences above are now numbers:
  - Per-call cost: EXLA-CPU takes 37-48 us a call on a 16-element tensor
    (compiled with `Nx.Defn.compile/3`, tensors resident), against 0.05 us
    for the kernel and 0.14 us for Elixir.
  - `while` iteration cost on EXLA: about 1.0 ns a step at 16M elements
    (4.3 ms for 4.2M steps), 3x the kernel's 0.35; the `cumulative_sum` form
    costs 1.5 ns an element and loses to plain Elixir at every size.
  - The per-device lock: 48 concurrent callers raised EXLA's throughput
    only 1.6-1.9x over one caller (the kernel 7x).
  - Compile per shape: about 6.4 ms per new input length; padding to 8
    power-of-two buckets cut 300 variable-length calls from 1.9 s to
    0.25 s cold, at 2x the warm cost.
  - Responsiveness: a 1 ms ticker on one normal scheduler saw the same gap
    (about 2 ms, the floor under load) for all three: EXLA's dirty NIF does
    not hold a normal scheduler.
  Still not measured: Evaluator and Torchx `while` costs.
  GPU, one data point (`defk-w8r.2`; the handwired research note and its
  scripts were deleted on 2026-10-20 and are not restored): for pattern
  search over 100k JSON documents, the best CPU times here (7 to 15 ms in
  12 chunks, Elixir anchor-and-verify and a defk NFA kernel) are in the range
  of handwired's WebGPU search (4.5 to 5.2 ms on its author's machine), an
  order of magnitude only. The scope line stays: GPU is Nx's.
- Whether XLA CPU parallelises a single executable across threads internally
  (intra-op thread pool) was not traced in source; it affects how much one
  EXLA call occupies the machine beyond its one dirty scheduler.
- EMLX's worker-thread model avoids dirty-scheduler starvation but was not
  checked for cancellation on caller exit.
