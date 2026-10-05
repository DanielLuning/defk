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
What a kernel promises the BEAM while it runs: preemption, isolation, cleanup on process death, and hot code upgrade.

**Convenience construct**:
An idiomatic Elixir form in the kernel subset that exists because a developer would write it first, and that costs nothing over the equivalent loop.

**The one rule**:
A kernel is Elixir over numbers and binaries: it gives the result Elixir would, or raises where its types can't hold that result, or doesn't compile. It never gives a different answer.

**Limit**:
A documented case where a kernel raises or refuses to compile where Elixir would have succeeded, such as i64 overflow. Allowed by the one rule.

**Divergence**:
A case where a kernel gives a different value or behaviour from Elixir mode without raising. Not allowed by the one rule: each is a bug to remove or turn into a limit.
_Avoid_: difference (alone)

**Elixir mode**:
A kernel compiled to plain Elixir instead of native code, for tests and debugging only. Its results define what the same code gives in Elixir. It is never a fallback in production and never a baseline.
_Avoid_: fallback, interpreter, pure mode

## Measurement

**Target workload**:
A job that people write hand-written NIFs for today, reproduced from a named package and measured against that package's Elixir version and its NIF. The target workloads are the yardstick for what the kernel subset must express.
_Avoid_: use case, benchmark

**Supporting example**:
A catalog entry that isn't tied to a real NIF package. It illustrates defk but doesn't count towards the verdict.

**Expansion candidate**:
A job that could become defk territory after research or a language or runtime addition, listed in the verdict but not a target workload.

**Catalog**:
The target workloads and supporting examples, each written in Elixir and as a kernel, checked for agreement and measured end to end.
_Avoid_: examples, benchmark suite

**Baseline**:
The Elixir solution a kernel is measured against, marked first-pass or optimized. A win over a first-pass baseline is provisional.

**Workload verdict**:
The outcome for one target workload, measured as defk against an optimized baseline: `good` (defk helps), `marginal`, `poor` or `out_of_scope` (Elixir is the right choice). Comparisons with an existing NIF and responsiveness are reported beside it and never change it.
_Avoid_: verdict (alone), score

**Verdict**:
The written conclusion of the whole effort (`docs/verdict.md`): whether and where defk helps Elixir, and whether it warrants growing into a library.
