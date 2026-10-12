# How compilers are written in Elixir, and where idiomatic Elixir is defined

Research note. Nothing here was measured: every claim cites a primary source
(Elixir and Erlang/OTP source and docs, Nx/EXLA, Zigler, NimbleParsec, Ecto,
Rustler and LFE source, elixir-lang.org and Dashbit posts, publisher pages for
books). Statements marked *inference* are my reading of the sources, not
something a source says outright.

Versions read (2026-10-12):

- Elixir **v1.20.2** (the version installed here, `elixir --version`), tag
  [`v1.20.2`](https://github.com/elixir-lang/elixir/tree/v1.20.2) =
  `545dddf`. Below, `elixir:` paths are relative to that tag. The guides
  (anti-patterns, meta-programming, references) are the Markdown sources under
  `lib/elixir/pages/`, which hexdocs renders at
  `https://hexdocs.pm/elixir/<page>.html` (now redirected to
  `elixir.hexdocs.pm`).
- Erlang/OTP **29.1.1** (compiler 10.0.6, syntax_tools 4.1.1): erlang.org docs
  and [`compile.erl` at `OTP-29.1.1`](https://github.com/erlang/otp/blob/OTP-29.1.1/lib/compiler/src/compile.erl).
- `nx`/`exla` **1.0.0**, tag [`v1.0.0`](https://github.com/elixir-nx/nx/tree/v1.0.0)
  = `33d7867` (`nx:`/`exla:` paths). The sibling note
  `docs/research/nx-boundary.md` read the same release at main `87e923e`.
- Zigler main [`3e0f869`](https://github.com/E-xyza/zigler/tree/3e0f869cfcfbede52ce9ca7cba9039900f799b3e)
  (`mix.exs` version 0.16.0), NimbleParsec main
  [`6f00961`](https://github.com/dashbitco/nimble_parsec/tree/6f00961cfc4875cbbdf03edfdf2e9210c4f4e1e7)
  (1.4.2), Ecto main [`94d6927`](https://github.com/elixir-ecto/ecto/tree/94d69279c517347ff0962b138f4ccd0556486ae2)
  (3.15.0-dev), Rustler main
  [`7436cac`](https://github.com/rusterlium/rustler/tree/7436cac727ecf2fc626361200c3731adc97c83a6),
  LFE master [`0aa820e`](https://github.com/lfe/lfe/tree/0aa820e93bb592a821fe0a50b1db7e8926e56b30).
- Credo **1.7.19** (defk's locked version, `deps/credo`).

## Bottom line

1. **The canonical shape of an Elixir compiler pass is a recursive function
   that pattern-matches AST nodes in its clause heads and threads explicit
   state through the walk, returning `{node, state}`.** Elixir's own expander
   (`expand(Expr, S, E) -> {EExpr, SE, EE}`), its Erlang backend
   (`translate(Expr, Ann, S) -> {TExpr, TS}`), its type checker
   (`of_expr(..., stack, context)`), Nx's `defn` normaliser
   (`normalize(ast, state) -> {ast, state}`), EXLA's lowering
   (`recur_operator(expr, state, cache) -> {res, cache}`) and Ecto's query
   builder (`escape(expr, type, {params, acc}, vars, env)`) all do this.
   `Macro.prewalk/postwalk/traverse` are the library form of the same idea.
2. **The process dictionary is used by these compilers, but only for a few
   compile-wide side channels, always saved and restored around a dynamic
   extent.** Elixir keeps its diagnostics sink, compiler PID, current file and
   produced binaries under pdict keys (`elixir_code_diagnostics`,
   `elixir_compiler_info`, `elixir_compiler_file`, `elixir_module_binaries`);
   `Code.with_diagnostics/2` and `elixir_compiler:quoted/3` save the previous
   value and restore it in `after`. Nx keeps "which compiler is tracing" and
   "the current backend" in the pdict the same way. Neither puts per-pass
   working state (variables, types, warnings) there: that is threaded.
3. **Errors are accumulated, not raised at first sight, and a failure flag
   stops cascades.** Since v1.15 Elixir reports many errors per file: an error
   inside a module "taints" it, compilation continues, and the module raises
   one `CompileError` at fixed checkpoints. The type checker accumulates
   warnings in its threaded context and sets `failed: true` so one error does
   not produce a cascade. Code marked `generated: true` in its metadata is not
   warned about.
4. **Pass structure in the BEAM world is a list of passes as data, with dumps
   and linters between them.** OTP's `compile.erl` and LFE's `lfe_comp.erl`
   both describe the pipeline as a list of `{pass, ...}`/`{iff, Flag, ...}`
   commands, with a listing option after every IR (`dcore`, `dssa`, ...)
   and optional IR linters (`core_lint_module`, `beam_ssa_lint`). Elixir's
   pipeline is tokenizer → yecc parser → expansion → ETS-stored definitions →
   type inference → Erlang abstract format → Core Erlang → BEAM.
5. **Nx `defn` is the closest prior art, and it is mostly not a
   compile-time compiler.** At compile time `defn` only normalises and
   validates the AST and emits ordinary Elixir functions. The real
   compilation happens at call time: the function is *run* with
   `Nx.Defn.Expr` as the tensor backend, which records an expression DAG
   (`%Expr{id, op, args, context}`, ids are refs), and a pluggable
   `Nx.Defn.Compiler` (Evaluator, EXLA) lowers that DAG. defk lowers at
   compile time to C, so its closest structural relatives are Zigler and
   Rustler (native build from `__before_compile__`/`use`, tracked with
   `@external_resource`), not Nx's tracing.
6. **On idioms, the highest-trust sources are the Elixir team's own guides,**
   especially the four anti-pattern pages, the meta-programming guide
   ("data > functions > macros", "macros should only be used as a last
   resort", keep `quote` small and delegate to functions), naming
   conventions and the library guidelines. Credo (which defk gates on) turns
   several of these into checks. Community style guides are older and mostly
   superseded by `mix format`.

## Part 1: compilers in Elixir

### The building blocks Elixir gives a compiler author

- **Quoted AST.** "Macros are compile-time constructs that receive Elixir's
  AST as input and return Elixir's AST as output", and the `Macro` module
  exists "to traverse, query, and transform it"
  ([`elixir:lib/elixir/lib/macro.ex`](https://github.com/elixir-lang/elixir/blob/v1.20.2/lib/elixir/lib/macro.ex) L8-L15).
  Evaluating code from macros "is often an anti-pattern" (same, L63-L67).
- **Metadata for diagnostics.** AST metadata is a keyword list; "the AST
  received by a macro will always include the `:line` annotation". Public
  keys include `:line`, `:column` (via `Code.string_to_quoted/2`),
  `:counter` (hygiene), `:keep` (`quote location: :keep`) and `:generated`:
  "Whether the code should be considered as generated by the compiler or not.
  This means the compiler and tools like Dialyzer may not emit certain
  warnings" (`macro.ex` L100-L137). `Macro.update_meta/2` rewrites it
  (L381).
- **Traversal.** `Macro.prewalk/2,3`, `postwalk/2,3` and `traverse/4`
  (pre and post functions threading one accumulator, `{t, acc}` results)
  are the stock walkers (`macro.ex` L620, L692, L721, L730, L739);
  `Macro.prewalker/1` and `postwalker/1` (since 1.13) are lazy enumerables
  over the tree (L1049, L1107).
- **The environment.** `__ENV__`/`__CALLER__` give a `Macro.Env` with module,
  file, line, variables, imports and requires; "many of the functions in the
  `Macro` module expect a `Macro.Env`"
  ([macros guide](https://github.com/elixir-lang/elixir/blob/v1.20.2/lib/elixir/pages/meta-programming/macros.md) L205-L224,
  [hexdocs](https://hexdocs.pm/elixir/macros.html)).
- **Collect, then generate.** The DSL guide's canonical pattern: `__using__`
  registers an accumulating attribute and `@before_compile`; each DSL macro
  only appends to the attribute; `__before_compile__/1` reads it and
  generates the functions
  ([DSL guide](https://github.com/elixir-lang/elixir/blob/v1.20.2/lib/elixir/pages/meta-programming/domain-specific-languages.md) L126-L200).
  This is exactly the shape of Nx `defn` (`nx:lib/nx/defn.ex` L828-L836,
  L900-L903), Zigler (`lib/zig.ex` L331, `lib/zig/compiler.ex` L20) and
  Rustler (`rustler_mix/lib/rustler.ex` L98-L114).
- **Compile-time dependencies and recompilation.** Elixir tracks compile,
  export and runtime dependencies; a compile-time dependency "has to be
  recompiled whenever the callee changes (or any dependency of the callee
  changes)", and macros and module-body calls are what create them
  ([`elixir:lib/mix/lib/mix/tasks/xref.ex`](https://github.com/elixir-lang/elixir/blob/v1.20.2/lib/mix/lib/mix/tasks/xref.ex)
  L110-L150). Non-Elixir inputs are declared with `@external_resource`, and
  `__mix_recompile__?/0` adds custom staleness rules but is called for every
  module, so it must be cheap
  ([`compile.elixir.ex`](https://github.com/elixir-lang/elixir/blob/v1.20.2/lib/mix/lib/mix/tasks/compile.elixir.ex)
  L31-L58). Zigler registers each Zig source and its transitive imports as
  `@external_resource` (`lib/zig/compiler.ex` L71-L73, L166-L178); Rustler
  does the same for the crate's files (`rustler.ex` L100-L101).
- **Diagnostics.**
  - `Code.with_diagnostics/2` (since 1.15) "capture[s] all diagnostics";
    "if using `mix compile` or `Kernel.ParallelCompiler`, note they already
    capture and return diagnostics"
    ([`code.ex`](https://github.com/elixir-lang/elixir/blob/v1.20.2/lib/elixir/lib/code.ex) L659-L709).
  - `Mix.Task.Compiler.Diagnostic` carries `file`, `source`, `severity`
    (`:error`/`:warning`/`:hint`/`:information`), `message`, `position`,
    `span`, `stacktrace`, `details`; "The file and position relate to where
    the diagnostic should be shown ... you can use the given file and
    position for generating snippets, IDEs annotations"
    ([`task.compiler.ex`](https://github.com/elixir-lang/elixir/blob/v1.20.2/lib/mix/lib/mix/task.compiler.ex) L96-L136).
  - The public way for library code to emit a *warning* diagnostic is
    `IO.warn/2` with a `Macro.Env` or `[file:, line:, column:]` (since 1.14),
    which goes through `:elixir_errors.emit_diagnostic/6`
    ([`io.ex`](https://github.com/elixir-lang/elixir/blob/v1.20.2/lib/elixir/lib/io.ex) L336-L411).
    There is no public API to emit an *error* diagnostic; errors are
    `raise CompileError, file:, line:, description:` (`CompileError` has only
    those three public fields, [`exception.ex`](https://github.com/elixir-lang/elixir/blob/v1.20.2/lib/elixir/lib/exception.ex) L1377-L1405).
  - v1.15 release post: "The Elixir compiler can now emit many errors for a
    single file, making sure more feedback is reported to developers before
    compilation is aborted", and `Code.with_diagnostics/2` lets editors
    "point to several errors at once"
    ([Elixir v1.15 released](https://elixir-lang.org/blog/2023/06/19/elixir-v1-15-0-released/), 2023-06-19).

### Elixir's own compiler pipeline

Read from `elixir:lib/elixir/src/`:

| Stage | Where | Representation |
|---|---|---|
| Tokenise | `elixir_tokenizer.erl` (hand-written) | tokens |
| Parse | `elixir_parser.yrl` (a **yecc** grammar) | quoted AST |
| Per-file driver | `elixir_compiler:string/3`, `quoted/3` (L10-L30) | AST |
| Expand macros, resolve aliases/imports, check variables | `elixir_expand:expand/3` (`expand(Expr, S, E) -> {EExpr, SE, EE}`, L13-L20) | expanded AST |
| Store definitions | `elixir_def:store_definition` (L123-L192) into the module's ETS tables | clauses |
| Infer and check types | `Module.Types.infer/7` called from `elixir_module` (L200-L206) | set-theoretic types |
| To Erlang | `elixir_erl:compile/2` (L152-L175), `elixir_erl_pass:translate/3` (L5-L20: "Translate Elixir quoted expressions to Erlang Abstract Format") | Erlang abstract format |
| To Core, to BEAM | `elixir_erl_compiler:erl_to_core/2` calls `v3_core:module/2`, then `compile:noenv_forms(Core, [from_core, ...])` (L61-L90) | Core Erlang → BEAM |

What it shows about pass structure (all source facts; the "lessons" are
*inference*):

- **Two kinds of state, kept apart.** Expansion threads `S`, an
  `#elixir_ex{}` record of per-expansion mutable facts (variables, unused
  vars, prematch, version counter), and `E`, the `Macro.Env` map
  (`elixir.hrl` L13-L52). The Erlang backend threads its own `#elixir_erl{}`
  record (L54-L71). The type checker splits a read-only `stack` (file,
  module, function, mode, handlers) from a threaded `context` (warnings,
  vars, `failed`, local signatures) (`elixir:lib/elixir/lib/module/types.ex`
  L607-L668), with explicit `fresh_context`/`restore_context` around each
  function. *Inference:* these are records/maps passed as arguments, never
  pdict entries.
- **Errors taint, then raise at checkpoints.** `module_error/4`: "A module
  error is one where it can continue if there is a module being compiled";
  it prints the error and marks the module tainted (`elixir_errors.erl`
  L271-L289); `elixir_module:taint/1` writes `{elixir, taint}` to the
  module's ETS table (`elixir_module.erl` L73-L80), and
  `compile_error_if_tainted` raises before type inference and again before
  code generation (L197, L231, L271-L275).
- **The type checker's error discipline.** `warn/5` prepends to
  `context.warnings` unless the node's meta has `generated: true`;
  `error/5` is "a warning that halts other errors from being collected": once
  `context.failed` is true further errors are dropped
  (`module/types/helpers.ex` L538-L571).
- **Where the process dictionary *is* used.** Diagnostics:
  `emit_diagnostic/6` reads `elixir_compiler_file` and appends to
  `elixir_code_diagnostics`, or sends to the parallel compiler's PID from
  `elixir_compiler_info` (`elixir_errors.erl` L60-L95). Produced binaries:
  `elixir_module_binaries` (`elixir_compiler.erl` L15-L29,
  `elixir_module.erl` L610-L612). The parallel compiler spawns one process
  per file and sets `elixir_compiler_info` and `elixir_compiler_file` in it
  ([`kernel/parallel_compiler.ex`](https://github.com/elixir-lang/elixir/blob/v1.20.2/lib/elixir/lib/kernel/parallel_compiler.ex) L540-L545).
  Every write is bracketed: `Previous = get(K), try put(K, New), ... after
  put(K, Previous)` (`elixir_compiler.erl` L15-L29; `Code.with_diagnostics`
  L693-L709 erases the key if it was undefined). When work moves to another
  process the keys are copied in and the results copied back
  (`elixir_erl_compiler:spawn/1`, L9-L47).
- **Module data lives in ETS, not the pdict.** Each module being compiled
  has a set and a bag ETS table (`elixir_module:data_tables/1`), deleted in
  `after` (`elixir_module.erl` L262-L266, the `after` clause of `compile`).

### OTP's compiler: the pass list as data

- `compile:forms/2` takes "a list of forms (in either Erlang abstract or
  Core Erlang format representation)"; `from_core`, `from_abstr`, `binary`,
  `return` and `'S'` (assembler listing) select entry and exit points
  ([`compile` docs, OTP 29.1.1](https://www.erlang.org/doc/apps/compiler/compile.html)).
- The pipeline is a list of commands interpreted by the driver:
  `{pass,Mod}` calls `Mod:module(Code, Options)` which "must transform the
  code and return `{ok,NewCode}` or `{ok,NewCode,Warnings}`";
  `{listing,Ext}` dumps the current IR and stops
  ([`compile.erl`](https://github.com/erlang/otp/blob/OTP-29.1.1/lib/compiler/src/compile.erl) L1585-L1615).
  `standard_passes/0` → `abstr_passes` → `core_passes` → `kernel_passes`
  → `asm_passes` runs lint, record expansion, `v3_core`, `sys_core_fold`,
  inlining, `sys_core_bsm`, `core_to_ssa`, `beam_ssa_opt`,
  `beam_ssa_codegen`, with a `{iff, dX, {listing, ...}}` after nearly every
  pass and optional IR linters (`core_lint_module`, `beam_ssa_lint`)
  (L1745-L1870).
- LFE copies the shape: `passes()` is a list of
  `{do,Fun}`/`{when_flag,Flag,Cmd}`/`{done,Fun}` entries (split, export
  macros, expand macros, lint, codegen "to Erlang AST", then the Erlang
  compiler), each with a `to_X` flag that stops and prints
  ([`lfe_comp.erl`](https://github.com/lfe/lfe/blob/0aa820e93bb592a821fe0a50b1db7e8926e56b30/src/lfe_comp.erl)
  L213-L295; `lfe_codegen.erl` header: "code generator (to Erlang AST)").
- Representations for generated Erlang: `erl_syntax` is an abstract datatype
  for Erlang syntax trees, backwards compatible with `erl_parse` trees
  ([erl_syntax](https://www.erlang.org/doc/apps/syntax_tools/erl_syntax.html));
  `cerl` is the same for Core Erlang but "an internal part of the compiler"
  whose API "is not guaranteed to remain compatible between releases"
  ([cerl](https://www.erlang.org/doc/apps/compiler/cerl.html)).
- Lexer/parser generators: [`leex`](https://www.erlang.org/doc/apps/parsetools/leex.html)
  and [`yecc`](https://www.erlang.org/doc/apps/parsetools/yecc.html)
  (parsetools). Elixir's own parser is a yecc grammar
  (`elixir_parser.yrl`) with a hand-written tokenizer.

*Inference:* the transferable lesson from both OTP and LFE is not any
particular IR, but (a) naming each pass and listing them in one place,
(b) being able to dump the IR after any pass, and (c) cheap invariant checkers
between passes that are off by default.

### Nx `defn`: the closest prior art

All paths `nx:` at v1.0.0.

- **Compile time does little.** `defn` records each definition in a
  `@__defn_exports__` attribute and registers `@before_compile Nx.Defn`
  (`nx/lib/nx/defn.ex` L828-L836); `__before_compile__/1` calls
  `Nx.Defn.Compiler.__compile__/2` (L900-L903), which walks the AST with
  `normalize(ast, state) -> {ast, state}` clauses (rejecting anything
  outside the subset with "invalid numerical expression", rewriting `case`,
  `cond`, maps, remote calls) and emits two plain Elixir functions per
  `defn`: an entry point and an implementation
  (`nx/lib/nx/defn/compiler.ex` L271-L293, L323-L361, L420-L726). The state
  is a plain map (`module`, `file`, `line`, `function`, `defns`,
  `transforms`), threaded explicitly.
- **Compilation is tracing at call time.** The entry point checks
  `Process.get(Nx.Defn.Compiler)`: outside a trace it calls
  `Nx.Defn.jit_apply/2`, inside one it calls the implementation directly
  (L340-L351). `runtime_fun/3` puts `Nx.Defn.Expr` as the process's backend
  and the chosen compiler under `Nx.Defn.Compiler`, applies the function,
  and restores both keys in `after` (L184-L205). Every `Nx` call then builds
  an `%Nx.Defn.Expr{id, op, args, context}` node whose `id` is a
  `make_ref()` (`nx/lib/nx/defn/expr.ex` L1-L60, L434, L1354). "Given
  numerical definition first build a representation of your code, it is not
  possible to write recursive ... code inside `defn`" (`defn.ex` L206-L211).
- **Pluggable backends behind a behaviour.** `Nx.Defn.Compiler` defines
  `__jit__/5` and `__compile__/4` callbacks that receive the vars and a
  function that builds the expression (`compiler.ex` L1-L58); the default is
  `Nx.Defn.Evaluator`. EXLA lowers the DAG to MLIR by recursion over the
  nodes with a memo map keyed by expression id
  (`recur_operator(expr, state, cache) -> {res, cache}`,
  `exla/lib/exla/defn.ex` L575-L583). `Nx.Defn.Tree` provides the
  traversals (`apply_args/4`, `scope_ids/2`, `nx/lib/nx/defn/tree.ex`).
- **Escape hatch.** `deftransform`/`deftransformp` run arbitrary Elixir on
  the expression at trace time (`defn.ex` L91-L127).
- **Errors.** Nx raises `CompileError` at the first invalid expression
  (`compile_error!/3`, `compiler.ex` L1073-L1076); it does not accumulate.
- **Process dictionary use** is limited to "is a trace running and with which
  compiler", the current backend, and per-process default options, which
  its docs say "must be used only for scripting and testing"
  (`defn.ex` L222-L270; `compiler.ex` L125-L136).
- José Valim's v0.1 announcement: "Inside `defn` we can use Elixir regular
  operators and they are all translated to their equivalent tensor
  operations"; compilation is driven by "the types and shapes of the
  arguments"
  ([Nx v0.1 released](https://dashbit.co/blog/elixir-and-machine-learning-nx-v0.1), 2022-01-06).

*Inference:* Nx gets shapes and types for free by running the code; defk has
no runtime values at compile time, so it must infer them from the AST, which
is why its compiler looks more like Elixir's expander and type checker than
like Nx.

### Other compiler-ish projects

- **Zigler** (inline Zig NIFs). `use Zig` registers `@before_compile
  Zig.Compiler`; `~Z` sigils accumulate source in `@zig_code_parts`
  (`lib/zig.ex` L331, L570). `__before_compile__/1` runs one pipeline over a
  `%Zig.Module{}` struct: write code, stage build, **run Zig's own semantic
  analysis** (`Sema.run_sema!`, a `zig build -Dzigler-mode=sema` step that
  reports function types), parse, analyse, verify NIFs, compile, render
  Elixir (`lib/zig/compiler.ex` L134-L160; `lib/zig/command.ex` L37-L53).
  Errors are raised as `CompileError` with file/line, first error wins
  (L44-L58, L227-L232). *Inference:* Zigler delegates typing to the target
  compiler; defk cannot, because its source is Elixir, so it owns its type
  checking.
- **Rustler** (Rust NIFs). `use Rustler` calls `Rustler.Compiler.compile_crate/3`
  at compile time, which shells out to `cargo rustc
  --message-format=json-render-diagnostics`, registers the crate's files as
  `@external_resource`, and adds an `@on_load` that calls
  `:erlang.load_nif/2` (`rustler_mix/lib/rustler.ex` L98-L166,
  `rustler_mix/lib/rustler/compiler.ex` L7-L98).
- **NimbleParsec** (compile-time code generator). Combinators are plain data;
  "this library does not rely on macros for building and composing parsers
  ... The only macros are `defparsec/3` and `defparsecp/3` which emit the
  compiled clauses with binary matching", and the output has "no runtime
  dependency" on NimbleParsec (README, the moduledoc). *Inference:* the
  textbook case of the guide's "data > functions > macros": build an IR as
  data with functions, use one macro only to emit.
- **Ecto's query compiler.** `Ecto.Query.Builder.escape/5` "smart escapes a
  query expression and extracts interpolated values", threading a
  `{params, acc}` accumulator and returning `{Macro.t(), {list, acc}}`
  (`lib/ecto/query/builder.ex` L68-L84). Query expressions are structs that
  carry `file` and `line` for errors (e.g. `%BooleanExpr{... file:, line:}`,
  `lib/ecto/query/planner.ex`). The planner normalises at run time.
- **Gleam** was not read: it is a Rust compiler that emits Erlang source,
  so its implementation does not bear on writing passes in Elixir.

### Passes in Elixir: what the sources do, summarised

| Concern | Elixir compiler | Module.Types | Nx defn | EXLA lowering | Ecto builder | Zigler |
|---|---|---|---|---|---|---|
| Node dispatch | clause heads per AST shape | clause heads | clause heads | clause heads per `op` | clause heads | struct pipeline |
| Working state | records `S`/`E`, threaded | `stack` (read-only) + `context` (threaded) | map, threaded | `state` + `cache` map, threaded | `{params, acc}`, threaded | one struct through `|>` |
| Module-wide store | ETS tables per module | n/a | module attribute | n/a | n/a | module attributes |
| Process dictionary | diagnostics sink, compiler PID/file, binaries; save/restore | none | trace flag, backend; save/restore | none | none | none |
| Errors | taint + raise at checkpoints, many per file | accumulate; `failed` stops cascade | raise first | raise | raise first | raise first |
| IR nodes | quoted AST, Erlang forms | type descriptors | `%Expr{}` structs, ref ids | MLIR values | `%QueryExpr{}` etc. | `%Zig.Nif{}` etc. |

## Part 2: sources for idiomatic Elixir, ranked by trust

### 1. Official (Elixir team, shipped with the language)

| Source | URL | What it is good for |
|---|---|---|
| Anti-patterns (4 pages + intro) | [what-anti-patterns](https://hexdocs.pm/elixir/what-anti-patterns.html), [code](https://hexdocs.pm/elixir/code-anti-patterns.html), [design](https://hexdocs.pm/elixir/design-anti-patterns.html), [process](https://hexdocs.pm/elixir/process-anti-patterns.html), [meta-programming](https://hexdocs.pm/elixir/macro-anti-patterns.html) | named smells with problem/example/refactoring |
| Meta-programming guide | [quote and unquote](https://hexdocs.pm/elixir/quote-and-unquote.html), [macros](https://hexdocs.pm/elixir/macros.html), [DSLs](https://hexdocs.pm/elixir/domain-specific-languages.html) | macro hygiene, `Macro.Env`, `@before_compile`, when not to use macros |
| References | [naming conventions](https://hexdocs.pm/elixir/naming-conventions.html), [library guidelines](https://hexdocs.pm/elixir/library-guidelines.html), [typespecs](https://hexdocs.pm/elixir/typespecs.html), [gradual set-theoretic types](https://hexdocs.pm/elixir/gradual-set-theoretic-types.html) | `foo!`/`foo?`/`is_foo`, `size` vs `length`, `get`/`fetch`; publishing and deps |
| Getting started | [writing documentation](https://hexdocs.pm/elixir/writing-documentation.html) and the other chapters | `@moduledoc false` vs `__name__` for hidden APIs |
| Module docs | `Macro`, `Macro.Env`, `Code`, `Module`, `Kernel.SpecialForms`, `mix xref`, `mix compile.elixir`, `Mix.Task.Compiler` | the APIs above |
| `mix format` | [`Code.format_string!/2` docs](https://hexdocs.pm/elixir/Code.html#format_string!/2) | "the formatter never changes the semantics of the code by default"; "as little configuration as possible" (`code.ex` L795-L813) |
| Elixir blog | [elixir-lang.org/blog](https://elixir-lang.org/blog/) | release posts explain the why of compiler changes |

Owner: the Elixir core team; the pages carry `SPDX-FileCopyrightText: 2021
The Elixir Team`. The anti-patterns intro says matching one "does not mean
your code must be rewritten ... No codebase is free of anti-patterns"
(`what-anti-patterns.md` L12-L18).

**Meta-programming anti-patterns, in detail** (`macro-anti-patterns.md`):

1. **Compile-time dependencies.** Macro *arguments* used in a module body
   become compile-time dependencies (the `plug MyApp.Authentication`
   example), causing large recompilation graphs. Fix: `Macro.expand_literals/2`
   with the env of the function where the module will be used, so it becomes
   a runtime dependency, but "only ... if your macros do not attempt to invoke
   any function, access any struct, or any other metadata of the module at
   compile-time". Diagnose with `mix xref trace` (L10-L79).
2. **Large code generation.** Each macro call expands and compiles its whole
   `quote`; "the developer should simplify the macro, delegating part of its
   work to other functions", e.g. `quote do: Routes.__define__(__MODULE__,
   ...)` with the validation in a plain function (L81-L136).
3. **Unnecessary macros.** "Macros ... should only be used when absolutely
   necessary"; replace with functions where possible (L138-L184).
4. **`use` instead of `import`.** `use` can inject anything; prefer
   `import`/`alias`, and when `use` is needed, document its effect in an
   admonition block in `@moduledoc` ("a 'Nutrition facts label' for code
   generation", listing only public API changes) (L186-L289).
5. **Untracked compile-time dependencies.** Building module names with
   `Module.concat` or atom literals hides dependencies from the compiler and
   leads to stale builds; use full aliases (L291-L380).

The macros guide adds: macros are "harder to write than ordinary Elixir
functions ... Macros should only be used as a last resort. Remember that
**explicit is better than implicit**", and "macros are not your API. Keep
your macro definitions short, including their quoted contents", moving work
to a function that can be tested directly (`macros.md` L8-L10, L240-L290).
The DSL guide: "data > functions > macros" (`domain-specific-languages.md`
L44).

**Other anti-patterns relevant to a compiler codebase**
(`code-anti-patterns.md`):

- *Long parameter list*: group related arguments into maps or structs; for
  private functions "split the arguments in two maps (or tuples): one map
  keeps the data that may change, and the other keeps the data that won't
  change (read-only)" (L238-L274).
- *Structs with 32 fields or more*: above 32 keys a map stops being a flat
  map and loses key sharing; nest rarely used fields in a sub-struct
  (L589-L640). Credo enforces this by default
  (`Credo.Check.Warning.StructFieldAmount`, `max_fields: 31`).
- *Dynamic atom creation*, *non-assertive map access*, *complex extractions
  in clauses* (L105, L143, L315).

**What the official docs do not say.** None of the Elixir guides (grep of
`lib/elixir/pages/` for "process dictionary": no hits) gives a policy on the
process dictionary; `Process.put/2`'s doc only describes the API
(`process.ex` L163-L180). The Erlang reference manual likewise only lists the
BIFs ([Processes](https://www.erlang.org/doc/system/ref_man_processes.html)).

What the Erlang side does say:

- **Ericsson's *Programming Rules and Conventions*** (Klas Eriksson, Mike
  Williams, Joe Armstrong; EPK/NP 95:035), rule 6.5 "Use the process
  dictionary with extreme care". The original at
  `http://www.erlang.se/doc/programming_rules.shtml` could not be read on
  2026-10-12: `www.erlang.se` does not resolve (DNS), web.archive.org
  returned "Temporarily Offline" (HTTP 503), and the FreeBSD mirror of the
  R13 PDF (`mirror.its.dal.ca/.../programming_rules.pdf`) does not resolve.
  The resolvable copy is the LFE project's adaptation, which says it "was
  copied from the [Erlang original](http://www.erlang.se/doc/programming_rules.shtml)
  and modified for use with LFE", crediting the three authors, with the code
  examples converted to LFE
  ([lfe/docs `prog-rules/1.html`](https://github.com/lfe/docs/blob/dfbe59e51416bd06b8c68046414722d05ef2e263/docs/current/prog-rules/1.html),
  last changed 2017-03-16). Its rule 6.5, prose quoted as given there
  ([`prog-rules/6.html`](https://github.com/lfe/docs/blob/dfbe59e51416bd06b8c68046414722d05ef2e263/docs/current/prog-rules/6.html)):

  > Do not use get and put etc. unless you know exactly what you are doing!
  > Use get and put etc., as little as possible.
  >
  > A function that uses the process dictionary can be rewritten by
  > introducing a new argument.
  >
  > [...] The use of get and put will cause a function to behave differently
  > when called with the same input at different occasions. This makes the
  > code hard to read since it is non-deterministic. Debugging will be more
  > complicated since a function using get and put is a function of not only
  > of its argument, but also of the process dictionary. Many of the run time
  > errors in LFE (for example bad_match) include the arguments to a function,
  > but never the process dictionary.

  The example is a `tokenize` that reads `(get 'device)`, rewritten to take
  `device` as an argument. The neighbouring rule 6.4 ("Use catch and throw
  with extreme care") names a compiler as a legitimate case for catch/throw.
  Caveat: this is an adaptation, so "LFE" in the last sentence stands for
  "Erlang" in the original; the wording of the original was not compared.
- **OTP's secure coding guide** (OTP 29.1.1) makes the same point for one
  API: `rand:uniform/1` and `crypto:rand_seed/0` keep their state in the
  process dictionary, where "This state could be modified to select another
  generator by other functionality called interleaved with calls retrieving
  random numbers. A better solution is to use the functional API, which will
  pass the state between calls instead of storing it in the process
  dictionary"
  ([`system/doc/design_principles/secure_coding.md`](https://github.com/erlang/otp/blob/OTP-29.1.1/system/doc/design_principles/secure_coding.md)
  L306-L314).
- The OTP efficiency guide's processes chapter says nothing about it
  ([eff_guide_processes](https://www.erlang.org/doc/system/eff_guide_processes.html)).

No statement by the Elixir core team was found (a search of elixirforum.com
turned up only community posts). The Elixir-side evidence is therefore the
code itself (Part 1).

### 2. Tools that encode the official guidance

- **`mix format`** (Elixir team): the formatter is the style authority for
  layout; the community style guide itself says "The formatter should be
  preferred for all new projects and source code"
  ([christopheradams/elixir_style_guide](https://github.com/christopheradams/elixir_style_guide) README L71-L72).
- **Credo** (René Föhring, [rrrene/credo](https://github.com/rrrene/credo),
  [hexdocs](https://hexdocs.pm/credo/)): "a static code analysis tool for the
  Elixir language with a focus on teaching and code consistency" (README).
  defk runs it under `--strict` and overrides only two thresholds
  (ADR-0003). Default-enabled checks that map onto the official
  anti-patterns include `Refactor.LongQuoteBlocks` (max 150 lines in a
  `quote`), `Warning.StructFieldAmount` (cites the 32-field anti-pattern by
  URL), `Refactor.CyclomaticComplexity` and `Refactor.Nesting`;
  `Refactor.ModuleDependencies` and `Warning.UnsafeToAtom` are opt-in
  (`deps/credo/.credo.exs` L120-L215).
- **`mix xref`** (Elixir team): `trace`, `graph --label compile`, cycles
  (`xref.ex`).

### 3. Community, authoritative by author

| Source | Owner | URL | Good for | Caveat |
|---|---|---|---|---|
| Dashbit blog | José Valim and Dashbit | [dashbit.co/blog](https://dashbit.co/blog) | design rationale for Nx, Elixir releases | posts are dated; check against current docs |
| Type system paper and talks | Castagna, Duboc, Valim | ["The Design Principles of the Elixir Type System"](https://arxiv.org/abs/2306.06391); talks ["The foundations of the Elixir type system"](https://youtu.be/giYbq4HmfGA), ["Precision in type system design"](https://youtu.be/Ay-gnCqDw9o?t=102) (all linked from `gradual-set-theoretic-types.md` L16, L286-L288) | the theory behind `Module.Types` | relevant only if defk's typing pass wants set-theoretic types |
| *Metaprogramming Elixir* (book, Pragmatic, 2015) | Chris McCord | [pragprog.com/titles/cmelixir](https://pragprog.com/titles/cmelixir/metaprogramming-elixir/) | the classic macro book | predates 1.15 diagnostics and many `Macro` APIs |
| *Elixir in Action*, 3rd ed. (Manning, 2024) | Saša Jurić | [manning.com](https://www.manning.com/books/elixir-in-action-third-edition) | language and OTP fundamentals (updated for Elixir 1.15) | not about compilers |
| *Designing Elixir Systems with OTP* (Pragmatic, 2019) | James Edward Gray II, Bruce Tate | [pragprog.com/titles/jgotp](https://pragprog.com/titles/jgotp/designing-elixir-systems-with-otp/) | layering: functional core vs processes | not about compilers |
| Elixir Style Guide (community) | Christopher Adams | [christopheradams/elixir_style_guide](https://github.com/christopheradams/elixir_style_guide) | naming, structs, exceptions beyond what the formatter does | last commit 2024-05-06; largely superseded by `mix format` |
| Elixir Style Guide | Aleksei Magusev | [lexmag/elixir-style-guide](https://github.com/lexmag/elixir-style-guide) | concise linting rules | last commit 2018-04-03 |
| Elixir Forum | community, with core team posts | [elixirforum.com](https://elixirforum.com) | context on decisions | cite only posts by the owner of the code in question |

The publication facts for the three books come from the publishers' pages
and listings (Pragmatic and Manning); the books' contents were not read for
this note.

## What this means for defk (*inference throughout*)

This section connects the sources to defk's code as of `d203a5b` plus the
then-uncommitted `defk-euu` work (`lib/defk/compiler.ex`,
`lib/defk/compiler/ctx.ex`), since merged as `f78bf4c`. The audit section
after it reads `lib/defk.ex` at `f78bf4c` (unchanged in the working tree).

1. **defk already has the canonical outer shape.** `defk` accumulates kernel
   ASTs in attributes and `__before_compile__` hands them to
   `Defk.Compiler.compile/4` (compiler-map), the DSL guide's pattern and the
   one Nx, Zigler and Rustler use. The runtime header is an
   `@external_resource` (`lib/defk.ex` L197), as Zigler and Rustler do for
   their native sources.
2. **The `:defk_ctx` key is closer to Elixir's practice than to its
   anti-patterns, with two gaps.** One key holding one struct, snapshot and
   restore as one value (`ctx_swap/1`) mirrors how Elixir brackets
   `elixir_code_diagnostics` and how `Module.Types` restores context fields.
   The gaps against what Elixir and Nx do:
   - *No bracketing.* Elixir and Nx restore the previous value in `after`;
     `compile/4` overwrites `:defk_ctx` on entry and leaves it set afterwards
     ("the compile's ctx stays in the process", `ctx.ex`), and
     `Defk.ElixirMode` relies on that. Since the parallel compiler runs one
     process per file, a stale ctx can leak between modules in the same file.
     Wrapping `compile/4` in save/restore, and passing what ElixirMode needs
     explicitly, would match the sources.
   - *Working state in the pdict.* Elixir, `Module.Types`, Nx and EXLA keep
     per-pass working state (variables, facts, counters, warnings) in
     threaded values and reserve the pdict for cross-cutting sinks. defk's
     `Ctx.lowering` (fresh-name counters, decls, safepoints, the strip
     record, now the copy-analysis state) is that working state. The
     sources' shape would be: compile-wide read-only facts (`file`,
     `module`, `lines`) in a "stack"-like value, the mutable part (`diags`,
     `broken`, `lowering`) in a threaded "context", as the long-parameter
     anti-pattern and `Module.Types.stack/7` + `context/0` both describe. The
     pdict could then keep only the diagnostics sink, as Elixir does. This
     is a large refactor of a 6,500-line module and the sources do not say
     the pdict version is wrong; they show that nobody else uses it for this.
3. **Struct size.** `Ctx` has 11 fields and `Ctx.Lowering` 14; both are under
   the 32-field threshold. Credo's `StructFieldAmount` will flag growth past
   31. Nesting `Lowering` inside `Ctx` is the refactoring the anti-pattern
   recommends.
4. **Diagnostics.** defk's model (collect every rejection, poison the
   kernel, raise one `CompileError` at the end, `Defk.Errors.compile_error/3`)
   is the same discipline as Elixir's taint-and-checkpoint and
   `Module.Types`' `failed` flag. Two things the sources offer that defk does
   not use: (a) `IO.warn/2` with `file:`/`line:`/`column:` produces a real
   `Mix.Task.Compiler.Diagnostic` with position, which editors show inline;
   defk's `Defk.InlineSize` already uses `IO.warn`, the fast-path report
   could too; (b) for errors there is no public diagnostic API, so one
   `CompileError` with `line: 0` and the per-kernel positions in the
   description is the available option. Emitting one `IO.warn` per rejection
   before raising would give editors positions; whether that duplicates
   output needs a check. The `:generated` meta key is the standard way to
   mark compiler-generated AST so tools stay quiet.
5. **Pass structure.** `compiler.ex` is one module ordered by section
   dividers. OTP and LFE suggest a cheap next step that needs no rewrite: a
   named list of passes, an option to dump each IR (defk already has the
   strip record and fast-path report as structured outputs), and
   off-by-default invariant checks between passes (defk's cross-check of the
   strip record against the text classifier in `defk-ch4` was exactly an
   IR linter).
6. **Macro hygiene for defk's generated code.** Audited below ("defk against
   the meta-programming anti-patterns"): four of the five don't apply or
   apply only in part, and the one concrete gap is that `use Defk` takes the
   module's `@on_load` without saying so.
7. **Nx is a model for the backend seam, not for the front end.** Nx's
   `Nx.Defn.Compiler` behaviour (Evaluator vs EXLA) parallels defk's native
   vs Elixir mode. Nx's tracing front end does not transfer: it needs runtime
   values, and defk compiles before any exist.

## defk against the meta-programming anti-patterns

The five anti-patterns are those of
[`macro-anti-patterns.md` at v1.20.2](https://github.com/elixir-lang/elixir/blob/v1.20.2/lib/elixir/pages/anti-patterns/macro-anti-patterns.md).
The code read is `lib/defk.ex` at `f78bf4c`: `__using__/1` (L174-L200),
`defk/1` (L230), `defk/3` (L277-L281), `kernel/4` (L283-L296),
`take_impl/1` (L304-L308), `__before_compile__/1` (L338-L424), `lib_defs/1`
(L432-L456), and the stub, wrapper and dispatch generators (L497-L584). Also
read: `Defk.Attributes.capture/1` (`lib/defk/attributes.ex` L20-L36),
`Defk.Raise.module!/3` (`lib/defk/raise.ex` L45-L58), and the two other
macros in `lib/` (`err!/4` and `attempt_err!/5`, private to
`lib/defk/compiler.ex` L65-L76). The facts below come from the code, from
`mix xref`, and from one toy module; each verdict is *inference*.

`mix xref` evidence: `MIX_ENV=test mix xref graph --no-compile` on the
existing `_build/test` manifest. The manifest includes the uncommitted
`lib/defk/errors/` work that was in the tree when this was read, which
changes no kernel-module edges. It reports 35 files, 8 compile edges, 1
export edge, 45 runtime edges and 0 cycles. `--label compile-connected`
lists exactly two sources. One is `test/support/examples.ex` →
`lib/defk.ex (compile)`, the one kernel module in that environment. The other
is `lib/defk/compiler.ex` → `lib/defk/errors.ex (compile)`, from the
`err!` macros.

| Anti-pattern | Verdict | Evidence |
|---|---|---|
| Compile-time dependencies | **doesn't apply** | A kernel module's only compile edge is to `lib/defk.ex`, from `use Defk` and the `defk` macros. `--source test/support/examples.ex` shows the rest of defk reached through `lib/defk.ex`'s runtime edges, which makes the module compile-connected to the compiler. That is intended: a compiler change must recompile kernels. A macro argument never becomes a module reference. `kernel/4` stores the kernel's head, options and body as `Macro.escape`d data in `@defk_kernels` (L290-L295). The only calls it adds to the user's module body are to defk's own `Defk.Attributes.value/2` and `Defk.take_impl/1`, plus `Application.compile_env/3` in `__using__` (L196), which Mix tracks. Kernels cannot call other user modules ("Calls into other modules are not in the kernel subset", `lib/defk/errors.ex` L438), so a kernel body cannot pull in a compile dependency on user code. |
| Large code generation | **doesn't apply**, with one note on size | Each `defk` call expands to one attribute write that calls functions for the work (L289-L295). That is the guide's own refactoring: a small `quote` plus `__define__`-style functions. `__before_compile__/1` runs once per module, and the C compile, build and Elixir-mode translation are function calls (L338-L406). Per kernel it generates an `@spec` and one `def`, plus a native stub and a wrapper or dispatcher when the NIF is renamed (L497-L584); the loader is two or three tiny functions (`lib_defs/1`, L432-L456). The note: the module also embeds the C source, the report and the signatures as literals (L412-L418). `Examples.Kernels` (15 kernels, test env with Elixir mode) has a 71,229-byte `__defk_c_source__/0` string and a 129,160-byte `.beam`. That is beam size, not repeated expansion, and the functions are documented as unstable debugging aids (moduledoc "Generated functions"). |
| Unnecessary macros | **doesn't apply** | `defk/1,3` must see the body as AST, so they must be macros. `__using__` must register an attribute and `@before_compile`. Everything else is functions: `Defk.Test.assert_agrees/3` is a `def` (`lib/defk/test.ex` L79), and the generated module API is plain `def`s. The two private macros `err!`/`attempt_err!` exist to check a rejection's code against the registry when defk itself compiles (comment at `compiler.ex` L61-L63), and their `quote` is one call to a function (L65-L76). Moving a check to compile time is a reason the guide accepts. |
| `use` instead of `import` | **partly** | `use Defk` is justified: it sets five `@defk_*` attributes, registers `@defk_kernels`, adds `@external_resource` and `@before_compile`, and imports only `defk: 1, 2, 3` (L189-L199). The moduledoc's "`use Defk`" and "Generated functions" sections describe the import, the options, the reserved `@defk_` attributes and every generated function with its stability. That is the "nutrition facts" content, though not in the recommended `{: .info}` admonition. **Not documented:** `__before_compile__` sets `@on_load :__defk_load__` (L409). A toy module (not defk) showed that a module with its own `@on_load` and a `__before_compile__` that sets another one fails with Elixir's `ArgumentError` "the @on_load attribute can only be set once per module", raised from `Module.put_attribute/7` (`elixir:lib/elixir/lib/module.ex` L2139-L2162). **Reproduced with `use Defk`** (2026-10-12, Elixir 1.20.2, `MIX_ENV=test mix run`): a module with `use Defk`, its own `@on_load :init` and one `defk` kernel fails with `** (ArgumentError) the @on_load attribute can only be set once per module`, raised from `Module.put_attribute/7` with `Defk.__before_compile__/1` on the stack. There is no defk diagnostic, and `Defk`'s moduledoc doesn't mention it. `docs/language.md` L263 mentions the hook, but in the compile-time behaviour list, not as a restriction. |
| Untracked compile-time dependencies | **alias form doesn't apply; broader form partly** | No module names are built for dispatch. The one `Module.concat` (`raise.ex` L46) turns a `raise` alias into an atom only to compare it with the fixed list `[ArgumentError, ArithmeticError, RuntimeError]` (L8), which needs no dependency. A side effect, outside the anti-pattern: aliases in kernel bodies are matched unexpanded (`{:__aliases__, _, [:Enum]}`, `[:Defk, :Bits]` in `compiler.ex` and `elixir_mode.ex`), so `alias Defk.Bits` then `Bits.clz(x)` would not be recognised. That is a lexical-scope difference from a `def`, not a recompilation bug. The non-Elixir inputs are handled unevenly. The runtime header is tracked (`@external_resource`, L197). `config :defk, :mode` goes through `Application.compile_env` (L196), which Mix tracks. But `CC` and `ERTS_INCLUDE_DIR` are read from the environment at compile time (`lib/defk/build.ex` at `f78bf4c` L45, L252, L290, L346) and feed the build-cache key, and nothing (no `__mix_recompile__?/0`, grep of `lib/`) tells Mix to recompile when they change. Changing `CC` therefore leaves already-compiled kernel modules built with the old compiler until something else recompiles them. `mix compile.elixir`'s `__mix_recompile__?/0` is the documented hook for such inputs, but it is called for every module, so it must be cheap (`compile.elixir.ex` L31-L58). |

## Gaps and open questions

- **Erlang Programming Rules:** the 1996 Ericsson original is still
  unreadable from here (DNS failure for `www.erlang.se` and the FreeBSD
  mirror; the Internet Archive was offline). The rule is quoted from LFE's
  adaptation, so its exact Erlang wording is unconfirmed.
- **Books:** not read; their entries rest on publisher listings. Reading
  them is out of scope for a source-code note.
- **Elixir core team on the process dictionary:** no primary statement found.
  The Erlang-side statements are above; the Elixir-side claims rest on what
  the code does.
- **The `@on_load` collision:** reproduced (see the audit table); the fix
  (a defk diagnostic or a moduledoc line) is a ticket, not part of this note.
- **Untracked `CC`/`ERTS_INCLUDE_DIR`:** read from the code, not
  reproduced by changing `CC` and running `mix compile`.
