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
| array values | ownership, value semantics; the copy analysis's rules and tracking state live in `Defk.Copies` | `owned`, `before_write`, `hoist` |
| expressions | arithmetic, comparisons, overflow checks; operands in Elixir's order (`lower_expr/2` wraps every `lower_node/2` clause) | `i64_arith`, `lower_ops/3`, `in_order/3` |
| calls | kernel-to-kernel inlining, builtins | (inline size: `Defk.InlineSize.check/3`) |
| loops | `for`, reduce accumulators, safepoints; recovery inside a rejected `for`, reduce or pipe | `lower_quals`, `with_acc_facts/2`, `for_collect!/6`, `recover_for/4`, `recover_reduce/5`, `recover_pipe/2` |
| case | clause dispatch (multi-clause kernels) | |
| range facts | `Defk.Facts` holds ADR-0007's representation: forms over atoms (array lengths and i64 bindings), values' exact forms (`eq`), bounds `{q, form}`, one prover with a step budget; this file states facts through the module's sources (`len_value`, `len_from`, `len_like`, `between`, `bound`, the derivations), keeps i64 bindings' facts by C variable in `env.atoms` (`put_var/3`), and asks the proofs with the env as scope | `Facts.check`, `Facts.fits_i64?`, `range_limit` |
| element types | narrow loads/stores | |
| emitting | C text: entries, init, frames, resume | `emit_entry`, `resume_block/3`, `view_term/3` |
| report | fast-path notes; one of `compile/4`'s results | `note/4`, `note_bounds/4` |

The compiler's state is one process-dictionary key, `:defk_ctx`, holding a
`Defk.Compiler.Ctx` (defk-euu): compile-wide fields (file, diags, report,
...) plus a `lowering` sub-struct replaced wholesale per kernel in
`lower_kernel`. Probing and backtracking (`probe/1`, `with_acc_facts/2`,
`u64_accs/2`) snapshot and restore that one value. The flagged-strip
classifier decides from the strip record (`lowering.strip`, rows the
lowering declares as it emits; defk-ch4), not from the C text.

## The other modules

- `lib/defk.ex`: the `defk` macro, options (`max_owned_bytes`, `yield`,
  `adaptive_slice`), `@impl` handling, `lib_defs/1`.
- `lib/defk/build.ex`: C compiler invocation, cache key, where the `.so`
  lives (`placement!/3`: app ebin vs absolute path), `mix_project?/0`, the
  sanitizer build mode (`sanitize/0`, `DEFK_SANITIZE`; its C side is
  `defk_poison_slack` in the runtime header).
- `lib/defk/errors.ex`: the error registry (code, why, fix); `reference/0`
  and `scope/1` feed the generated docs — after changing it, follow
  `docs/agents/generated-docs.md`. Rendering and location live in
  `Defk.Errors.Diagnostics`, the rewrite-suggestion engine in
  `Defk.Errors.Rewrites` (defk-vlf); a literal code passed to `err!` is
  checked against the registry when the compiler compiles.
- `lib/defk/messages.ex`: the runtime error messages as templates, the one
  source of `priv/defk_messages.h` (generated: `mix defk.messages`), Elixir
  mode's raise texts (`text/2`) and the agreement reasons (`reason/1`);
  see `docs/agents/generated-docs.md`.
- `lib/defk/facts.ex`: the range-facts lattice (one opaque value under
  `v.facts`; assert/derive in, `check`/`prove_i64`/`fits_i64?` with
  support out). ADR-0007's representation lives here; its soundness nets
  are `test/facts_test.exs`, `test/scaled_facts_test.exs`,
  `test/linear_facts_test.exs`, `test/condition_facts_test.exs` and
  `test/product_facts_test.exs`.
- `lib/defk/copies.ex`: the copy analysis — what counts as a read after a
  write, and the pure tracking state (writes log, buffer carrying, alias
  classes) the compiler keeps at `ctx.lowering.copies`.
- `lib/defk/compiler/ctx.ex`: the ctx struct itself.
- `lib/defk/clauses.ex`: multi-clause heads and patterns.
- `lib/defk/elixir_mode.ex`: the Elixir compilation of kernels (tests only).
  Its translation state (binding counter, writes log, look-ahead leaf
  types, u64 candidates and hits) is one process-dictionary key, `:defk_em`,
  holding one `Defk.ElixirMode.State`, fresh per kernel and deleted when
  `definitions/3` returns; the `env` map (vars, sigs) is threaded
  explicitly. `lib/defk/elixir_mode/guard.ex` evaluates a case guard that
  can fail.
- `lib/defk/inline_size.ex`: the code-size warning (defk-6ag).
- `lib/defk/bench.ex`: measurement (`report/1`, `settle/0`); rules in
  `examples/README.md` and AGENTS.md.
- `lib/defk/report.ex`, `lib/defk/bits.ex`, `lib/defk/test.ex`
  (`assert_agrees`): user-facing helpers.
- `lib/defk/deprecations.ex`: the deprecation table and the renames it
  drives (a builtin in `__before_compile__`, a `use Defk` option, a config
  key), warning once per use site. How to add an entry:
  `docs/agents/deprecations.md`.

## priv/defk_runtime.h (~1,900 lines)

The C runtime included in every generated file: the `defk_ctx` (owned
buffers, `owned_bytes` budget, stats), frames and safepoints (yield,
resume, forced yields), input binding on every entry (binaries move across
GC), `defk_make_arr` / `defk_make_arr_view`, strips
(`DEFK_ZERO_STRIP`/`DEFK_COPY_STRIP`), range copies, crc32c. The
"Responsibilities" comment at the top is the index. Its raise sites use the
`DEFK_MSG_` defines of the generated `priv/defk_messages.h`, never a
literal message (`Defk.Messages`).

## Tests

One file per feature area, named after it (`test/<area>_test.exs`); shared
kernels and helpers in `test/support/` (`examples.ex` is the catalog's
kernels, `language_doc.ex` checks doc examples). The promises of
`docs/guides/stability.md` are checked elsewhere, by the contract tests
under `test/contracts/` (frozen per release); a unit test checks how a
section of the compiler does its job, and that is where a change to a
section gets its test. Conventions that matter:

- Agreement with Elixir mode (`Defk.Test.assert_agrees`) and forced yields
  (`__defk_force_yields__/1`) are the backbone: cover every resume path.
- A test that sets OS env or compiles with warnings captured is
  `async: false`.
- Slow/flaky-under-load tags are excluded by default (`test/test_helper.exs`).
- While iterating, `mix test <file>` and `mix test --stale`; one full
  `mix test` before you finish. A timeout under load is rerun alone before
  it counts as a failure.
