# ADR-0010: A stability promise stricter than SemVer 0.x

- Date: 2026-10-14
- Status: accepted (2026-10-14: the maintainer approved the guide's text)
- Source: the map 'Wayfinder: defk ready for a first Hex release'
  (`defk-wfi`), its rename review (`defk-wfi.3`) and `defk-wfi.4`; the
  text is `docs/guides/stability.md`

From `0.1.0`, defk promises that within a major version a valid kernel
keeps compiling and keeps its meaning, and that a change to the kernel
subset, the runtime contract, the public API or the error codes needs a
deprecation. `0` counts as a major version, so `0.y` releases are
compatible with each other, which SemVer does not ask of `0.x`.

We chose this because a kernel is code a user writes in our language and
ships in their app: a minor release that stops it compiling, or changes
what it computes, breaks their build or, worse, their results. The one rule
already makes "same result as Elixir" the standard, so meaning cannot drift
without a bug. The cost is that names and constructs are frozen early: a
mistake made in `0.1.0` stays, deprecated, until `1.0`. That is why the
names were reviewed and renamed just before the promise.

## Considered options

- **Plain SemVer 0.x** (anything may break in a minor release until `1.0`):
  rejected; users would have to pin exact versions of a compiler for their
  own code.
- **Wait for `1.0` to promise anything**: rejected for the same reason, and
  because the verdict asked for a stability promise before the first Hex
  release.

## Consequences

- New constructs are allowed in a minor release: a compile error may become
  a valid kernel, and its error code is then retired, not removed.
- Two narrow exceptions, both named in `CHANGELOG.md`: a fix that makes a
  kernel agree with Elixir changes its result, and a fix may reject a
  kernel the compiler accepted but cannot compile correctly.
- Not promised: speed, the fast-path report's facts, the generated C and
  the build, message texts, the order of compile errors, the unstable and
  hidden tiers (ADR-0006), and the supported Elixir, OTP and C compiler
  versions.
