# ADR-0002: The C compiler runs at build time

- Date: 2026-10-05 (stack review reaffirmed 2026-10-08)
- Status: accepted
- Source: `bw show defk-dtw.11` (resolution, 2026-10-05) and
  `bw show defk-dtw.19` (resolution, 2026-10-08)

## Context

defk's codegen target had to be settled before the verdict: is a C toolchain
at build time an acceptable requirement for a defk library, as for
`elixir_make` packages, or does a library need a named way out — precompiled
artifacts, a bundled compiler, or a Cranelift JIT path (`defk-o1w`)?

A rewrite of the implementation was reviewed as part of the same question
(`defk-dtw.19`): Zig, Rust and Odin compile via LLVM and V compiles via C, so
against current clang parity no codegen-quality gain is possible; and the
frontend (macro, type checker, error format, Elixir mode) runs at
`mix compile` over Elixir AST and cannot move off it.

## Decision

C, compiled by the system `cc` (or `$CC`) on the build machine
(`lib/defk/build.ex`), stated per audience:

- **App developers writing their own kernels:** acceptable, the same
  requirement as `elixir_make` packages (bcrypt_elixir, exqlite); a limit, not
  a blocker for go/no-go.
- **Hex library authors shipping kernels:** the named way out is precompiled
  artifacts in the `cc_precompiler` / `rustler_precompiled` style — built per
  target in CI, downloaded and checked by hash, which defk's hash-keyed build
  cache fits. Named in the verdict; nothing built in this map.
- **Livebook users:** need Xcode CLT / build-essential, stated in the guide.

A bundled compiler (Zigler-style) is rejected. Cranelift JIT (`defk-o1w`)
stays a P4 exploration under *Where defk could grow*, not the way out. No
rewrite of defk in another language (`defk-dtw.19`): node-crash isolation
comes from prevention-by-construction and evidence, not from the
implementation language.

## Consequences

- **A C compiler is needed at build time.** Evidence owed: an actionable
  missing-compiler error in the agreed format that honours `ERTS_INCLUDE_DIR`
  (`defk-lb8`), plus one recorded `mix release` build in a stock Debian
  Elixir image (`defk-ds0`, `examples/release_debian/`).
- **Cross-compiling is a limitation**, out of scope for building and listed in
  the verdict's Limitations as untested (Nerves, macOS → Linux).
- **C warnings are a defect class of their own**: generated code must compile
  warning-free (`defk-5dd`).
- The verdict's Limitations gets three lines: C toolchain at build time (as
  `elixir_make`), library authors would need a precompilation step that
  doesn't exist yet, cross-compiling and untested architectures unverified.
