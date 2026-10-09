# ADR-0005: Compile-time priv resolution stays source-relative

- Date: 2026-10-09
- Status: accepted
- Source: `bw show defk-x15.5`, commit `0581e4a`; dialyzer notes from
  `bw show defk-x15.1`, commit `e893192`

## Context

Credo's ExSlop `PathExpandPriv` warns against `Path.expand("...priv...",
__DIR__)` in `lib/defk.ex:19` (`@runtime_h`) and `lib/defk/build.ex:5`
(`@priv`) and suggests `Application.app_dir/2`, which "works in dev, test,
and releases".

Both sites are module attributes evaluated at `mix compile` time. At that
moment the `:defk` application is not loaded, so `:code.priv_dir(:defk)`
(which `Application.app_dir/2` reads) returns `{:error, :bad_name}`. The
happy-path recommendation is a runtime concern; these paths are
compile-time inputs to C generation.

## Decision

Keep `Path.expand(..., __DIR__)`, suppressed inline with
`# credo:disable-for-next-line ExSlop.Check.Warning.PathExpandPriv` and a
comment stating why the replacement cannot answer at compile time. The
same rationale covers a sibling scan: dialyzer originally reported
`Mix.*` as unknown functions (the `:mix` app isn't in the PLT), and we
resolved that honestly too — `plt_add_apps [:ex_unit, :mix]` plus
`@spec ... :: no_return()` on the 14 rejection helpers that genuinely
never return. **No `@dialyzer nowarn_function` was used anywhere**: a
helper that returns is a spec violation and dialyzer will say so, which is
the desired tripwire.

## Consequences

- The header path is correct in releases and from a build directory other
  than the source tree, because it is anchored to the file, not to the
  loaded app or the `MIX_ENV`.
- Two one-line credo suppressions exist, each naming the check and the
  reason; this ADR records the underlying justification.
- If defk ever computes these paths at runtime (e.g. the C cache is found
  at runtime rather than dialed at compile time), `Application.app_dir/2`
  becomes the right call and both suppressions should be deleted.

## How to revisit

Trigger: a compiled module needs the runtime header or the build cache path
when the application is unloaded. Resolution: move the attribute into a
runtime function and switch to `Application.app_dir/2`, removing the two
suppressions. The dialyzer approach stays as-is: prefer a truthful spec and
PLT coverage over `nowarn_function` unless a specific finding cannot be
stated as a spec.