---
modules: [Defk, Defk.Compiler, Defk.ElixirMode]
---

## Purpose

The kernel subset is one of the four surfaces of the stability promise
(`docs/guides/stability.md`, "The kernel subset"): the language of `defk`,
described by `docs/language.md`. Within a major version a valid kernel keeps
compiling and keeps its meaning. Each release freezes the valid kernels it
shipped, with the results they gave, as data under
`test/stability/<version>/kernels/` (written by `mix
defk.stability.freeze`).

The one rule is part of the promise: a kernel gives the result Elixir would,
or raises where its types cannot hold that result, or does not compile.
Elixir mode is the Elixir side of that comparison.

Not promised, and so not obligations here: speed, the fast-path report, the
generated C, the text of an exception's message (its module and its
agreement reason are promised).

### defk.kernel_subset.I1 — A frozen kernel keeps compiling and keeps its results
- **scope:** every file under `test/stability/<version>/kernels/`
- **must:** the example compiles, natively and in Elixir mode, and each recorded call gives the recorded result in both; or the file is listed under `fixed` in `test/stability/exceptions.exs` with words the `CHANGELOG.md` contains, and then the example keeps failing
- **why:** a kernel a release accepted is code someone ships; a later release that rejects it or changes its result breaks them
- **kind:** functional
- **record:** frozen-kernels-are-data
- **status:** active

### defk.kernel_subset.I2 — A kernel agrees with Elixir
- **scope:** kernels over the core of the subset: integer and float arithmetic, arrays, loops with early exit, `case` and `cond`, bitwise builtins
- **must:** for generated arguments, edge values included, a kernel's native call returns exactly the value its Elixir mode returns, or both raise the same exception module with the same agreement reason, also with a forced yield at every safepoint
- **why:** the one rule: a kernel is Elixir, faster; where it cannot hold Elixir's result it raises, it never returns a different value
- **kind:** functional
- **status:** active
