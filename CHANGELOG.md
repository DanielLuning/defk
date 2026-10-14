# Changelog

defk is a research project that may grow into a library (the decision is
the verdict in `docs/verdict.md`). It is not on Hex yet.

## Version policy

- `0.0.x` while the project is a research result: anything may change
  between versions, including the kernel subset, the generated functions and
  the build paths. The published docs say what is stable (`docs/scope.md`)
  and what is not (ADR-0006 in the repository).
- `0.1.0` is the first version published to Hex, cut when the verdict is
  accepted. From then on a minor version may add constructs and builtins and
  may change what `docs/scope.md` lists as unstable; it never changes a
  kernel's result, removes a construct, or renames a compile error code.
- Compile error codes are never renamed or reused; a retired code stays in
  the catalogue as retired.

## Unreleased

Everything so far: the kernel subset (`docs/language.md`), Elixir mode,
the runtime contract (preemption, isolation with fault containment, cleanup
on process death, hot code upgrade), the compile error catalogue, the
example catalog and its scoreboard, and the verdict.
