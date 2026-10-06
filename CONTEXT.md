# defk

defk explores whether a typed subset of Elixir can compile to native code at C speed while keeping the BEAM's promises, and where that helps Elixir developers who would otherwise write a NIF.

## Language

**Kernel**:
A function written in the kernel subset with `defk`, compiled to native code and called from Elixir.
_Avoid_: NIF (a kernel is compiled to one, but a NIF is any native function), native function

**Kernel subset**:
The part of Elixir a kernel may use: its types, constructs, convenience constructs, and the semantics they keep.
_Avoid_: defk language, DSL

**Runtime contract**:
What a kernel promises the BEAM while it runs: preemption, isolation, cleanup on process death, and hot code upgrade. Its purpose is that a kernel can never starve or crash the BEAM: for any arguments it returns or raises, other processes keep running, and a crashing process takes only itself down. A kernel that can't keep this is worse than a port, however fast it is.

**Convenience construct**:
An idiomatic Elixir form in the kernel subset that exists because a developer would write it first, and that costs nothing over the equivalent loop.

**The one rule**:
A kernel is Elixir over numbers and binaries: it gives the result Elixir would, or raises where its types can't hold that result, or doesn't compile. It never gives a different answer.

**Agreement**:
A kernel and its Elixir mode agree on an input when both return values that are identical (`===`, bit-exact for floats), or both raise the same exception module for the same reason.
_Avoid_: equivalence, matching results

**Limit**:
A documented case where a kernel raises or refuses to compile where Elixir would have succeeded, such as i64 overflow. Allowed by the one rule.

**Divergence**:
A case where a kernel gives a different value or behaviour from Elixir mode without raising. Not allowed by the one rule: each is a bug to remove or turn into a limit.
_Avoid_: difference (alone)

**Masked arithmetic**:
Integer arithmetic written inside `band(expr, 2^k - 1)`, which a kernel computes with wrapping machine arithmetic and which still gives Elixir's exact result. It is how hashes and checksums wrap.
_Avoid_: wrapping mode, unchecked arithmetic

**Array**:
A kernel value holding elements of one element type, which is a binary to the caller. Like any Elixir value it never changes: a write gives that variable a new array, and every other variable keeps what it had.
_Avoid_: buffer, view

**Element type**:
The type of each value in a kernel array, which is a binary of native-endian values of that type. Narrow element types (`u8`, `i16`, `i32`, `f32`) exist only inside arrays: reading one gives an `i64` or `f64`, and a write must fit the element type or raise.
_Avoid_: array type, dtype

**Bitstring accumulator**:
A kernel local built only by appending integer segments, `acc = <<acc::bitstring, v::size(n)>>`, starting from `<<>>`, and returned to the caller as a bitstring. It is how a kernel produces output whose length depends on the data. Like an array write, a segment value that doesn't fit its width raises.
_Avoid_: bit buffer, bit writer, growable output

**Elixir mode**:
A kernel compiled to plain Elixir instead of native code, for tests and debugging only. Its results define what the same code gives in Elixir, with the kernel subset's limits applied (a value that doesn't fit its type raises there too). It is never a fallback in production and never a baseline.
_Avoid_: fallback, interpreter, pure mode

## Measurement

**Target workload**:
A job that people write hand-written NIFs for today, reproduced from a named package and measured against that package's Elixir version and its NIF. The target workloads are the yardstick for what the kernel subset must express.
_Avoid_: use case, benchmark

**Anchor package**:
The real Hex package a target workload reproduces. Its pure-Elixir version is the first baseline and its NIF is the native comparison.

**Realistic size**:
The input size a target workload's anchor package is typically called with, declared before anything is measured. The workload verdict is measured at this size; other sizes and the crossover are reported beside it.

**Supporting example**:
A catalog entry that isn't tied to a real NIF package. It illustrates defk but doesn't count towards the verdict.

**Expansion candidate**:
A job that could become defk territory after research or a language or runtime addition, listed in the verdict but not a target workload.

**Catalog**:
The target workloads and supporting examples, each written in Elixir and as a kernel, checked for agreement and measured end to end.
_Avoid_: examples, benchmark suite

**Baseline**:
The Elixir solution a kernel is measured against, marked first-pass or optimized. A win over a first-pass baseline is provisional.

**Fast-path report**:
For one kernel, what the compiler did to its hot path: which bounds checks stayed, which branches became selects, where safepoints and copies went, and which loops vectorised. A tool for explaining measurements, not part of the kernel subset: a kernel's meaning never depends on it.
_Avoid_: optimisation report, profile

**Workload verdict**:
The outcome for one target workload, measured as defk against an optimized baseline: `good` (defk helps), `marginal`, `poor` or `out_of_scope` (Elixir is the right choice). Comparisons with an existing NIF and responsiveness are reported beside it and never change it.
_Avoid_: verdict (alone), score

**Verdict**:
The written conclusion of the whole effort (`docs/verdict.md`): whether and where defk helps Elixir, and whether it warrants growing into a library.
