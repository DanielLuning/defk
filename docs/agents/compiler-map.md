# Compiler map: orientation before you read code

Where things live, so you open the right file at the right place instead of
reading 9,000 lines. Function names are stable; line numbers are not, so
navigate by grep. `sb map/digest/show/implements/search/deps/reverse-deps`
work on Elixir, and kernels defined with `defk` appear in maps (if `sb map
lib/defk.ex` says "0 parseable file(s)", the machine has the upstream
ast-bro without the Elixir adapter: fall back to grep and `mix xref`).
`sb callers`/`callees` do not work for Elixir: for call questions use
`mix xref callers <Module>` (module granularity).

## The flow of one kernel

`defk` (a macro in `lib/defk.ex`) collects each kernel's AST into module
attributes; `__before_compile__` hands them to `Defk.Compiler.compile/4`,
which type-checks and lowers every kernel to C, calls the C compiler through
`Defk.Build`, and generates the Elixir functions that load and call the NIF
(`lib_defs/1` in `lib/defk.ex`: `__defk_load__`, `__defk_lib__`, stats and
test hooks). Compile errors are collected as diagnostics and raised in one
`CompileError` by `Defk.Errors.compile_error/3`.

## lib/defk/compiler.ex (~6,500 lines)

One module, ordered by section dividers you can grep for
(`grep -n '# ---' lib/defk/compiler.ex`):

| Divider | What it holds | Names worth knowing |
|---|---|---|
| entry | `compile/4`, per-kernel orchestration | `compile/4` |
| rejections | recording and de-duplicating errors, poisoning | `err!/4`, `record/1`, `poison/2` |
| parsing | heads, types, options | |
| kernels | lowering one kernel, return handling | `lower_kernel`, `coerce_return`, `emit_result` |
| blocks / statements | statement lowering, bindings | `lower_block`, `lower_stmts` |
| array values | ownership, the copy analysis, value semantics | `owned`, alias groups (`:defk_alias`) |
| expressions | arithmetic, comparisons, overflow checks | `i64_arith` |
| calls | kernel-to-kernel inlining, builtins | (inline size: `Defk.InlineSize.check/3`) |
| loops | `for`, reduce accumulators, safepoints | `lower_quals`, `with_acc_facts/2`, `for_collect!/6`, `recover_for/4` |
| case | clause dispatch (multi-clause kernels) | |
| range facts | bounds proofs (ADR-0007 moves this to symbolic bounds) | `in_bounds?/3`, `range_limit` |
| element types | narrow loads/stores | |
| emitting | C text: entries, init, frames, resume | `emit_entry`, `resume_block/3`, `view_term/3` |
| report | fast-path notes | `note/4`, `note_bounds/4`, `fixed_indices?/3` |

State during one kernel's lowering is in the process dictionary
(`:defk_decls`, `:defk_sp`, `:defk_writes`, `:defk_alias`, ...), reset per
kernel in `lower_kernel`; defk-euu plans to replace this with a context.

## The other modules

- `lib/defk.ex`: the `defk` macro, options (`max_owned`, `yield`,
  `adaptive_slice`), `@impl` handling, `lib_defs/1`.
- `lib/defk/build.ex`: C compiler invocation, cache key, where the `.so`
  lives (`placement!/3`: app ebin vs absolute path), `mix_project?/0`.
- `lib/defk/errors.ex`: the error registry (code, why, fix), `reference/0`
  and `scope/1` feed the generated docs — after changing it, follow
  `docs/agents/generated-docs.md`.
- `lib/defk/clauses.ex`: multi-clause heads and patterns.
- `lib/defk/elixir_mode.ex`: the Elixir compilation of kernels (tests only).
- `lib/defk/inline_size.ex`: the code-size warning (defk-6ag).
- `lib/defk/bench.ex`: measurement (`report/1`, `settle/0`); rules in
  `examples/README.md` and AGENTS.md.
- `lib/defk/report.ex`, `lib/defk/bits.ex`, `lib/defk/test.ex`
  (`assert_agrees`): user-facing helpers.

## priv/defk_runtime.h (~1,900 lines)

The C runtime included in every generated file: the `defk_ctx` (owned
buffers, `owned_bytes` budget, stats), frames and safepoints (yield,
resume, forced yields), input binding on every entry (binaries move across
GC), `defk_make_arr` / `defk_make_arr_view`, strips
(`DEFK_ZERO_STRIP`/`DEFK_COPY_STRIP`), range copies, crc32c. The
"Responsibilities" comment at the top is the index.

## Tests

One file per feature area, named after it (`test/<area>_test.exs`); shared
kernels and helpers in `test/support/` (`examples.ex` is the catalog's
kernels, `language_doc.ex` checks doc examples). Conventions that matter:

- Agreement with Elixir mode (`Defk.Test.assert_agrees`) and forced yields
  (`__defk_force_yields__/1`) are the backbone: cover every resume path.
- A test that sets OS env or compiles with warnings captured is
  `async: false`.
- Slow/flaky-under-load tags are excluded by default (`test/test_helper.exs`).
- While iterating, `mix test <file>` and `mix test --stale`; one full
  `mix test` before you finish. A timeout under load is rerun alone before
  it counts as a failure.
