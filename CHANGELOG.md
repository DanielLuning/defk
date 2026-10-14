# Changelog

defk is a research project that may grow into a library (the decision is
the verdict in `docs/verdict.md`). It is not on Hex yet.

## Version policy

- `0.0.x` while the project is a research result: anything may change
  between versions, including the kernel subset, the generated functions and
  the build paths. The published docs say what is stable (`docs/scope.md`)
  and what is not (ADR-0006 in the repository).
- From `0.1.0`, the first version published to Hex, the
  [stability promise](docs/guides/stability.md) holds: within a major
  version (`0` counts as one) a valid kernel keeps compiling and keeps its
  meaning, and a change to the kernel subset, the runtime contract, the
  public API or the compile error codes needs a deprecation first. A minor
  version may add constructs, builtins and options. Each release lists here
  its bug fixes that change a result or reject a kernel, its deprecations,
  and any rise in the minimum Elixir or OTP version.

## Unreleased

Everything so far: the kernel subset (`docs/language.md`), Elixir mode,
the runtime contract (preemption, isolation with fault containment, cleanup
on process death, hot code upgrade), the compile error catalogue, the
example catalog and its scoreboard, and the verdict.

### Renamed before 0.1.0

The last renames before the stability promise freezes the names. There are
no deprecated aliases: the old names are gone.

| Old name | New name |
|---|---|
| builtin `len/1` | `length/1` |
| builtins `rotl64/2`, `rotr64/2`, and `Defk.Bits.rotl64/2`, `Defk.Bits.rotr64/2` | `rotl/2`, `rotr/2` |
| builtin `f64_to_u64/1`, and `Defk.Bits.f64_to_u64/1` | `f64_bits/1` |
| `use Defk, max_owned: n` (and the `__defk_stats__/0` key `max_owned`) | `max_owned_bytes: n` (`max_owned_bytes`) |
| `Defk.Errors.codes/0` | `Defk.Errors.entries/0` |
| compile error code `unknown-function` | `undefined-function` |
| compile error code `u64-mix` | `u64-with-i64` |
