# Changelog

## Version policy

- `0.0.x` was the research project: anything could change between versions.
- From `0.1.0`, the first version published to Hex, the
  [stability promise](docs/guides/stability.md) holds: within a major
  version (`0` counts as one) a valid kernel keeps compiling and keeps its
  meaning, and a change to the kernel subset, the runtime contract, the
  public API or the compile error codes needs a deprecation first. A minor
  version may add constructs, builtins and options. Each release lists here
  its bug fixes that change a result or reject a kernel, its deprecations,
  and any rise in the minimum Elixir or OTP version.

## Unreleased

- Fixed: a `@doc` written before a `defk` was lost, and moved to the next
  `def` of the module. It now documents the kernel's function, as `@impl`
  already did.

## 0.1.0

The first release on Hex, after the project's verdict (go) and the release
readiness work.

- The kernel subset, described in `docs/language.md`, with Elixir mode: every
  kernel also compiles to plain Elixir, so tests can check the two agree.
- The runtime contract: preemption, isolation with fault containment,
  cleanup on process death, hot code upgrade.
- The compile error catalogue: every rejection has a stable code, why, a
  hint and a rewrite where one exists.
- The [stability promise](docs/guides/stability.md) for the kernel subset,
  the runtime contract, the public API and the error codes.
- Tested on every change on Linux x86-64 (clang and gcc), Linux arm64
  (clang) and macOS arm64 (Apple clang), with OTP 29 and Elixir 1.20.
- Fixed before the release: the operands of an operation are evaluated in
  Elixir's order, so the first error is Elixir's on every C compiler (gcc on
  x86-64 evaluated call arguments right to left); the `address` sanitizer
  mode builds with gcc; the sanitizer modes load with clang on Linux.

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
