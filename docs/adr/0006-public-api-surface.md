# ADR-0006: The public API surface

- Date: 2026-10-11
- Status: accepted (2026-10-11: the maintainer accepted every recommendation under "Questions decided")
- Source: `bw show defk-djy.2` (this audit), parent epic `bw show defk-djy`;
  followed by `defk-djy.3` (API docs)

## Context

defk has never decided what a user may depend on. The code says one thing
(`@moduledoc false` on `Defk.Test`, `@doc` strings on generated functions),
the docs say another (README, `docs/language.md`, `docs/scope.md`,
`docs/performance.md`, `examples/README.md` tell users to call
`Defk.Test.assert_agrees/3`, `Mod.__defk_elixir__/2`,
`Defk.Errors.scope/1`, ...), and `mix.exs` groups modules for HexDocs that
ex_doc then hides (`Defk.Test`, `Defk.Case`). `defk-djy.3` writes the API
docs and needs a list to document.

Rule used here: anything a user-facing doc tells people to call is de facto
public today, whatever its `@doc` says.

Tiers:

- **Public**: documented, stable intent. Changing it needs a deprecation.
- **Unstable**: documented, but its shape or output may change in any
  release; the docs say so.
- **Hidden**: `@moduledoc false` / `@doc false`; may change or go at any time.
  Some hidden functions must stay `def` because generated code or
  `@before_compile`/`@on_load` call them.

"Who uses it" counts files that mention the name, as of commit `ead50e0`:
`test/` (incl. `test/support`), `examples/` (incl. `fuzzy_search`,
`one_brc`, `release_debian`), `bench/`, `demo.exs`, and the user docs named
above.

## Decision

### Modules

| Module | Current state | Who uses it | Proposed | Reason |
|---|---|---|---|---|
| `Defk` | documented (short moduledoc) | every kernel module | **public** | the entry point: `use Defk`, `defk` |
| `Defk.Test` | `@moduledoc false`; `@doc` on both functions | tests 30, `language.md`, `verdict.md` | **public** | `language.md` §10 tells users to call `assert_agrees/3`; agreement is the core testing story |
| `Defk.Case` (`lib/defk/ex_unit/case.ex`) | `@moduledoc false` | 4 tests | **hidden** | thin sugar over `with_mode/2`, in no user doc; see open question 4 |
| `Defk.ElixirMode` | documented; grouped as "Internals" in `mix.exs` | tests 6, `hashes.exs`, README, `language.md` | **public** (only `with_mode/2`) | its moduledoc is the Elixir mode reference; regroup under Testing |
| `Defk.ElixirMode.Ops` | `@moduledoc false` | generated Elixir mode code | **hidden** | runtime of generated code; must stay `def` |
| `Defk.Bits` | documented, specs, doctests | tests 5, 1 example, `language.md` | **public** | defines the Elixir meaning of the bit builtins; the docs say "as `Defk.Bits.wrap64/1`" |
| `Defk.Report` | documented, types | tests, 1 example, README, `performance.md` | **public** (`print/1`, `format/1`, types) | the fast-path report entry point; the facts inside are unstable (below) |
| `Defk.Errors` | documented | tests, README, `language.md`, `scope.md` | **public facade** (`codes/0`, `explain!/1`) | error codes are a stable contract ("codes are never renamed"); the rest is internal (`defk-euu` will split it) |
| `Defk.Bench` | documented | 28 examples, `examples/README.md`, `performance.md` | **unstable** (`report/1` only) | catalog tooling: its verdicts and `DEFK_RESULT` line serve `mix defk.examples`, not users |
| `Defk.Bench.TickGap` | documented | `bench/tick_gap.exs`, `one_brc/rustler.exs`, `Defk.Bench` | **unstable** | measurement helper for the catalog and benches |
| `Defk.Attributes`, `Defk.BinaryLiteral`, `Defk.Bitstring`, `Defk.Build`, `Defk.Builtins`, `Defk.Clauses`, `Defk.Compiler`, `Defk.GuardIn`, `Defk.Masked`, `Defk.Raise` | `@moduledoc false` (some functions carry `@doc` text anyway) | compiler, tests (`Defk.Build.cache_key/1` in 14 tests) | **hidden** | compiler internals |

### Functions and macros of defk's own modules

| Function | Current state | Who uses it | Proposed | Reason |
|---|---|---|---|---|
| `use Defk` (`Defk.__using__/1`) | moduledoc example | every kernel module | **public** | |
| `Defk.defk/3` (`defk head do ... end`, `defk head, opts do ... end`) | no `@doc` | every kernel module | **public** | the macro |
| `Defk.defk/2` (`defk head, opts` without body) | no `@doc` | multi-clause kernels | **public** | head of a multi-clause kernel with options (`language.md`) |
| `Defk.defk/1` (`defk head`) | no `@doc` | multi-clause kernels | **public** | head of a multi-clause kernel |
| `Defk.__before_compile__/1` | no `@doc` | `@before_compile` | **hidden** | must stay public; add `@doc false` |
| `Defk.arg_vars/1` | moved to `Defk.Args.vars/1` | `Defk.Args` | **hidden** | internal helper; moved out of `Defk` in defk-djy.16 |
| `Defk.Test.assert_agrees/3` | `@doc` in hidden module | tests 29, `language.md`, `verdict.md` | **public** | the agreement check |
| `Defk.Test.reason/1` | `@doc` in hidden module | tests 9 | **public** | what "same reason" means in agreement; users need it to assert a raise. Rename candidate |
| `Defk.Case.in_both_modes/1` (macro) | hidden module | tests 2 | **hidden** | see open question 4 |
| `Defk.ElixirMode.with_mode/2` | `@doc` | tests 6, 1 example, README, `language.md` | **public** | the documented per-process switch |
| `Defk.ElixirMode.setup!/4`, `native_name/1`, `process_mode_key/0`, `definitions/3`, `fun_name/1` | `@doc false` | `Defk` at compile time | **hidden** | |
| `Defk.Bits.wrap64/1`, `mulhi/2`, `clz/1`, `ctz/1`, `popcount/1`, `rotl64/2`, `rotr64/2`, `clz/2`, `ctz/2`, `rotl/3`, `rotr/3`, `f64_to_u64/1` (12) | `@doc`, `@spec`, doctests | Elixir mode, tests, `language.md` | **public** | each is a kernel builtin's meaning; renaming one is a language change |
| `Defk.Report.print/1` | `@doc`, `@spec` | 1 test, 1 example, README, `performance.md`, `fast-path-report.md` | **public** | the way to read the report |
| `Defk.Report.format/1` | `@doc`, `@spec` | `print/1` | **public** | the same text as a string (for tests and tools) |
| `Defk.Report.t/0`, `kernel/0`, `fact/0` (types) | `@type` | | **unstable** | fact topics and texts grow with the compiler |
| `Defk.Report.full/3` | `@doc false` | `Defk` | **hidden** | |
| `Defk.Errors.codes/0` | `@doc` | tests 10 uses, README, `language.md` | **public** | lists the stable codes; the entry map's keys are unstable |
| `Defk.Errors.explain!/1` | `@doc`, `@spec` | tests, `language.md`, error footers | **public** | printed in every compile error footer without `language.md` |
| `Defk.Errors.fetch!/1` | `@doc` | tests 3 | **unstable** | entry shape will change with `defk-euu` |
| `Defk.Errors.docs/1` | `@doc` | the error footer | **hidden** | link format changes with `defk-djy.6` |
| `Defk.Errors.reference/0`, `scope/1` | `@doc`, `@spec` | doc-sync tests; `language.md` and `scope.md` tell maintainers to run them | **hidden** | they regenerate this repo's docs; see open question 5 |
| `Defk.Errors.compile_error/3`, `no_compiler/3`, `render/1`, `locate/3`, `unsupported/2`, `unsupported_local/2`, `fill_rewrites/4`, `collect_rewrites/4` | `@doc false` | compiler | **hidden** | |
| `Defk.Bench.report/1` | `@doc` with options | 28 examples | **unstable** | catalog API; options were added per workload and will be again |
| `Defk.Bench.compare/2`, `native_speedup/2`, `sweep_row/3`, `verdict/1`, `crossover/1` | `@doc` | `report/1`, `bench_test.exs` (`native_speedup` also in 3 examples' prose) | **hidden** | pure helpers exposed for tests |
| `Defk.Bench.TickGap.measure/1`, `with_one_scheduler/1`, `run/2`, `percentile/2` | `@doc` | `bench/tick_gap.exs`, `one_brc/rustler.exs`, `Defk.Bench` | **unstable** | used by scripts outside `lib` |
| `Defk.Bench.TickGap.summary/1` | `@doc` | `Defk.Bench`, 1 test | **hidden** | internal helper |

### `use Defk` and `defk` options, configuration and environment

| Option / setting | Current state | Who uses it | Proposed | Reason |
|---|---|---|---|---|
| `use Defk, elixir_mode: true \| false` | documented (README, `language.md`, `ElixirMode`) | 8 examples, tests | **public** | how scripts get `__defk_elixir__/2` |
| `use Defk, report: :full` | documented (README, `Defk.Report`, `performance.md`) | 1 example, tests | **public** (the option) / **unstable** (what it adds) | output is clang's remarks, `unknown` with another `CC` |
| `use Defk, max_owned: bytes` (added by `defk-4b2`, after this ADR) | documented (`Defk`, `language.md`, `runtime-contract.md`) | tests | **public** | the per-call owned-buffer budget; its default (half of physical memory) may be tuned |
| `use Defk, adaptive_slice: true \| false` (added by `defk-04y`, after this ADR) | documented (`Defk`, `runtime-contract.md`, `performance.md`) | tests, `bench/adaptive_slice*.exs` | **unstable** | an opt-out for a scheduling heuristic that is new and may be retuned, replaced or dropped as the runtime learns more (`+swt very_low` still does better) |
| `defk ..., yield: false` (per kernel, not a `use Defk` option) | documented (`language.md` "one option exists") | 5 examples, tests, bench | **public** | the one kernel option; runtime-contract escape hatch |
| `config :defk, mode: :native \| :elixir` | documented (README, `language.md`, `ElixirMode`) | 12 examples' docs, tests | **public** | `:dev`/`:test` only, read at compile time |
| `CC` environment variable | documented (README, `language.md`, compile error hint) | builds | **public** | the elixir_make convention |
| `ERTS_INCLUDE_DIR` environment variable | documented (README, `language.md`) | cross builds | **public** | the elixir_make convention |
| Build output `_build/<env>/defk/<Module>-<key>.{c,so}`, and an app module's copy in `ebin/<Module>-<key>.so` (added by `defk-n8f`, after this ADR) | documented (`language.md`, `deploying.md`) | `release_debian` | **unstable** | an app module loads its library from its app's `ebin/` (ships in `mix release`); the paths may move |
| `DEFK_SLICE_US`, `DEFK_STRIP` (C macros) | named in `language.md`, `Defk.Report` | runtime header | **hidden** | names for explanation, not settings a user can change |
| Module attributes `@defk_kernels`, `@defk_mode`, `@defk_elixir_mode`, `@defk_report` | undocumented | `use Defk` | **hidden** (reserved prefix) | a user `@defk_*` attribute can clash; document the prefix as reserved |

### Functions `use Defk` generates in a kernel module

| Function | Current state | Who uses it | Proposed | Reason |
|---|---|---|---|---|
| `name/arity` per kernel, with `@spec` | documented (`language.md`) | everyone | **public** | the user's own API |
| `__defk_elixir__/2` (only where Elixir mode is compiled) | generated `@doc`; `language.md`, README | tests 8, examples 12, `verdict.md` | **public** | the documented way to run one call in Elixir mode |
| `__defk_elixir_source__/0` (same condition) | generated `@doc`; `language.md`, README | 1 test | **unstable** | debugging output; the text changes with the emitter |
| `__defk_source__/0` | generated `@doc`; `language.md`, README | tests 18 | **unstable** | debugging output (C text). Rename candidate |
| `__defk_report__/0` | generated `@doc`; README, `fast-path-report.md`, `Defk.Report`; **missing from `language.md`'s table** | tests 3 | **unstable** | fact list grows; `Defk.Report.print/1` is the stable way in |
| `__defk_lib__/0` | generated `@doc`; `language.md` | tests 8, `demo.exs`, `release_debian` | **unstable** | path moves with `defk-n8f` |
| `__defk_kernels__/0` | generated `@doc`; `language.md` | `test/support/properties.ex`, 1 test | **unstable** | signature maps; keys (`ret`, type atoms) not settled |
| `__defk_stats__/0` | generated `@doc`; `language.md`, README | tests 15, `demo.exs`, 2 benches, 2 examples | **unstable** | semantics across reloads still open (`defk-9qv`) |
| `__defk_force_yields__/1` | generated `@doc`; `language.md` | tests 19 | **public** (testing) | the documented way to test every resume path; note it is module-wide, not per process |
| `__defk_corrupt_tags__/1` | `@doc false` | `test/frame_tag_test.exs` | **hidden**, and generate only under `:test` | a fault-injection hook compiled into every production library; see open question 2 |
| `__defk_load__/0` | `@doc false`, `@on_load` | `release_debian` README (prose) | **hidden** | loader; `@impl true` before a `defk` lands on it (`defk-ltt`) |
| `__defk_native_<name>__/N` (Elixir mode compiled, or a bitstring-returning kernel) | `@doc false`; named in `language.md` | 1 test | **hidden** | implementation detail of dispatch; docs may explain it but not invite calls |
| `__defk_elixir_<name>__/N` | `defp` | generated code | **hidden** (not callable) | private per-kernel Elixir mode function |

### Counts

- Modules: 6 public (`Defk`, `Defk.Test`, `Defk.ElixirMode`, `Defk.Bits`,
  `Defk.Report`, `Defk.Errors` as a facade), 2 unstable (`Defk.Bench`,
  `Defk.Bench.TickGap`), 12 hidden.
- Functions and macros of defk's modules: 23 public (`use Defk`, 3 `defk`
  arities, `assert_agrees/3`, `reason/1`, `with_mode/2`, 12 `Defk.Bits`,
  `Report.print/1`, `Report.format/1`, `Errors.codes/0`, `Errors.explain!/1`),
  6 unstable (`Bench.report/1`, `Errors.fetch!/1`, 4 `TickGap`) plus the
  `Defk.Report` types, everything else hidden.
- Options and settings: 6 public (`elixir_mode:`, `report: :full`,
  `yield: false`, `config :defk, mode:`, `CC`, `ERTS_INCLUDE_DIR`), 1
  unstable (build path), the rest hidden.
- Generated functions: 3 public (each kernel, `__defk_elixir__/2`,
  `__defk_force_yields__/1`), 6 unstable (`__defk_elixir_source__/0`,
  `__defk_source__/0`, `__defk_report__/0`, `__defk_lib__/0`,
  `__defk_kernels__/0`, `__defk_stats__/0`), 4 hidden.

## Naming inconsistencies and rename candidates

Before people depend on these names (no tickets yet; the maintainer decides):

1. **`__defk_source__/0` is the C source**, next to `__defk_elixir_source__/0`.
   The pair reads as if the first were the kernel source. Candidate:
   `__defk_c_source__/0` (18 test files, `language.md`, README).
2. **`Defk.Test.reason/1`** says nothing about what it is a reason of.
   Candidate: `Defk.Test.agreement_reason/1` (or `error_reason/1`), since it
   defines "the same reason" in the glossary's **Agreement** (9 test files).
3. **Generated functions document themselves in the user's module.** The
   `__defk_*__` functions carry `@doc` strings, so they appear in the HexDocs
   of every module that writes `use Defk`. Elixir's reflection convention
   (`__schema__/1` in Ecto, `__info__/1`) is `@doc false` in the generated
   module and one description in the library's docs. Candidate: generate
   them with `@doc false` and document them in the `Defk` moduledoc. See open
   question 1.
4. **`Defk.ElixirMode` is grouped as "Internals"** in `mix.exs` while its
   `with_mode/2` and moduledoc are user-facing; **`Defk.Test` and `Defk.Case`
   are grouped under Testing but hidden**, so the group renders empty or
   partial. Fix the groups in `defk-djy.3`.
5. **`Defk.Case` lives in `lib/defk/ex_unit/case.ex`**: the path suggests
   `Defk.ExUnit.Case`. Either rename the module or move the file (or fold the
   macro into `Defk.Test`, open question 4).
6. **`Defk.arg_vars/1`** is a public internal helper on the user-facing
   module. Move it to `Defk.ElixirMode` or a hidden helper module.
   Done in defk-djy.16: moved to `Defk.Args.vars/1`.
7. **Three spellings of one switch**: `use Defk, elixir_mode: true`
   (compile Elixir mode in), `config :defk, mode: :elixir` (default call path)
   and `with_mode(:elixir, fun)` (per process). They mean different things,
   which the docs explain, but `mode:` alone is generic in an app's config.
   Candidate: none now; if renamed, `config :defk, default_mode:`. Low value.
8. **`Defk.Bits` arity naming**: `clz/1`, `ctz/1`, `popcount/1` work on the
   64-bit pattern without a suffix, while `rotl64/2`, `rotr64/2` carry one
   (`rotl/3` takes a width). These are kernel builtin names too, so renaming
   is a language change. Candidate: keep, and state the rule in the moduledoc.
9. **`Defk.Errors` name and contents**: the module is both the public code
   registry and ~1100 lines of compiler internals (`defk-euu`). Keep the name
   for the facade (`codes/0`, `explain!/1`) and move the internals out in
   `defk-euu`; its moduledoc still says "once that file exists" about
   `docs/language.md` (stale).
10. **Ticket wording**: `defk-djy.2` lists `yield` as a `use Defk` option; it
    is a per-kernel `defk` option. `use Defk` accepts only `elixir_mode:` and
    `report:`.

Doc gaps found on the way (for `defk-djy.3`, not renames): `language.md`'s
table of generated functions lacks `__defk_report__/0`; the `defk` macro and
`__using__/1` have no `@doc`; `Defk.Bench` and `TickGap` have no `@spec`.

## Questions decided

The maintainer accepted the recommendation on all ten (2026-10-11).

1. **Generated reflection functions: `@doc false` in the user's module,
   documented once in `Defk`?** Recommendation: **yes**. Keep the
   `__defk_*__` names (the Elixir convention for generated reflection), stop
   them cluttering every kernel module's HexDocs, and do not add wrapper
   functions (`Defk.source(mod)`, ...) before the verdict.
2. **Generate `__defk_corrupt_tags__/1` only under `MIX_ENV=test`?**
   Recommendation: **yes**. It deliberately breaks frame-tag checks and today
   ships in every production library. `__defk_force_yields__/1` stays
   everywhere (scripts without a Mix env use it, and it only costs speed).
3. **Keep `Defk.Bench` and `Defk.Bench.TickGap` in `lib/` as documented
   but unstable "catalog tooling"?** Options: (a) keep, unstable; (b) hide
   with `@moduledoc false`; (c) move out of the package. Recommendation:
   **(a)**. The `Mix.install` examples need them in `lib/`, and
   `examples/README.md` documents them; revisit at Hex release
   (`defk-djy.8`).
4. **`Defk.Case` / `in_both_modes/1`: hide, fold into `Defk.Test`, or
   publish?** Recommendation: **hide** (keep `@moduledoc false`, drop it from
   the `mix.exs` group). It runs a block twice without comparing; the
   public testing story is `assert_agrees/3`.
5. **`Defk.Errors.reference/0` and `scope/1`: hidden?** They regenerate this
   repo's docs, but `scope.md` (a HexDocs page) tells readers to run them.
   Recommendation: **hide them, and move the regeneration instructions to a
   contributor note or a mix task under `defk-djy.7`**.
6. **Is the fast-path report public or unstable?** Recommendation:
   **`Defk.Report.print/1`, `format/1` and the `report: :full` option public;
   the facts (`__defk_report__/0`, the `t/0` types, the text) unstable**, as
   CONTEXT.md says the report is "a tool, not part of the kernel subset".
7. **Rename `__defk_source__/0` to `__defk_c_source__/0`?** Recommendation:
   **yes**, now, while only this repo calls it.
8. **Rename `Defk.Test.reason/1` to `Defk.Test.agreement_reason/1`?**
   Recommendation: **yes** (cheap, and the name then says what it defines).
9. **Make `__defk_force_yields__/1` public, or unstable?** Recommendation:
   **public (testing)**, with a doc note that it is module-wide (affects every
   process calling that module), since `language.md` already offers it as the
   way to test resume paths.
10. **Make `Defk.Errors.codes/0`'s entry maps part of the contract?**
    Recommendation: **no**: the codes (strings) are stable; the map keys are
    unstable until `defk-euu` settles them.

## Consequences

- `defk-djy.3` documents exactly the public and unstable rows, marks the
  unstable ones as such in their docs, and adds `@doc false` to the hidden
  rows that lack it.
- Accepted renames become tickets after the decision; none is done here.
- Hidden functions that generated code calls (`Defk.ElixirMode.Ops`,
  `Defk.ElixirMode.process_mode_key/0`, `__before_compile__/1`,
  `__defk_load__/0`, `__defk_native_<name>__`) stay `def`.

## How to revisit

Trigger: a Hex release (`defk-djy.8`, gated on the verdict `defk-sgw.5`), the
`defk-euu` split of `Defk.Errors`, or `defk-9qv` settling `__defk_stats__/0`.
Then move rows between tiers in this table and record the change here.
