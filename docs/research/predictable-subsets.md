# How comparable native subsets keep their rules predictable

Research for **defk-dtw.3**. Date: 2026-10-05.

Question: how do Numba, Nx `defn`, Cython, Pythran, Mojo, Julia, Taichi,
Futhark and Terra define their compiled subset, document it, and report
constructs they don't support? Which of them can also run the same code in
the host language, and what does that cost or gain?

Method: official docs and compiler source. Where the question asked for real
error messages, the snippets were made by running the tool locally
(Numba 0.68.0, Cython 3.x, Pythran 0.19.0, Nx 0.13.1 on Elixir 1.20). Scratch
paths are shortened to the file name. Messages for Futhark and Taichi are
taken from their compiler source. Julia, Mojo and Terra are covered from
their docs only.

---

## 1. How each system defines and explains its subset

| System | How the boundary is drawn | Where it is documented |
|---|---|---|
| Numba (nopython) | Whatever type inference can type. Constructs are listed as supported, partially supported or unsupported, and a separate page lists semantic deviations. | [Supported Python features](https://numba.readthedocs.io/en/stable/reference/pysupported.html), [Deviations from Python semantics](https://numba.readthedocs.io/en/stable/reference/pysemantics.html), [Troubleshooting](https://numba.readthedocs.io/en/stable/user/troubleshoot.html) |
| Nx `defn` | `Kernel` is replaced by `Nx.Defn.Kernel`. The body is traced into an expression graph. Calls go only to other `defn`s or to an allow-list. `deftransform` is the escape hatch to plain Elixir. | [Nx.Defn](https://nx.hexdocs.pm/Nx.Defn.html), [Nx.Defn.Kernel](https://nx.hexdocs.pm/Nx.Defn.Kernel.html) |
| Cython | All of Python compiles. Adding C types narrows semantics, and *compiler directives* (`boundscheck`, `wraparound`, `cdivision`, `overflowcheck`) say which Python checks are kept. | [Pure Python mode](https://cython.readthedocs.io/en/latest/src/tutorial/pure.html), [compilation and directives](https://cython.readthedocs.io/en/latest/src/userguide/source_files_and_compilation.html) |
| Pythran | A `#pythran export f(float list)` comment gives the entry types. The manual has a "say bye bye to" list (classes, polymorphic variables, heterogeneous containers, BigInt). | [Pythran manual](https://pythran.readthedocs.io/en/latest/MANUAL.html) |
| Taichi | Split into a *Python scope* and a *Taichi scope*. The language reference states rules per construct ("The return statement may only occur once…", "Break statement is not allowed when the nearest enclosing loop is a parallel … for loop"). `ti.static` is the compile-time escape hatch. | [Language reference](https://docs.taichi-lang.org/docs/language_reference), [Debugging](https://docs.taichi-lang.org/docs/debugging) |
| Futhark | A separate language with a specification. Errors link to an **error index**: one entry per error, each with a failing program, an explanation and the fix. | [Error index](https://futhark.readthedocs.io/en/latest/error-index.html) |
| Julia | No subset: every function compiles. "Type-stable" is a performance property, not a legality rule. Tools show where code falls off the fast path: `@code_warntype`, and JET's `@report_opt` and `@test_opt`. | [Performance tips](https://docs.julialang.org/en/v1/manual/performance-tips/), [JET optimization analysis](https://aviatesk.github.io/JET.jl/stable/optanalysis/) |
| Mojo | The subset is now the language itself. `def` requires argument and return types and is "non-raising by default" unless marked `raises`. Earlier, Mojo had two dialects: Python-like `def` and strict `fn`. | [Functions](https://mojolang.org/docs/manual/functions) |
| Terra | Separated by syntax: Lua is the meta-language, and functions written with `terra` are the compiled subset. Lua values enter through `[escape]`. "Functions are typechecked when they are defined." | [Getting started](https://terralang.org/getting-started.html) |

Patterns:

- **A list for each status.** Numba's reference has three lists per area:
  *supported*, *partially supported* (with the restriction stated, e.g.
  "`raise` is only supported in the forms `raise SomeException` /
  `raise SomeException(<args>)`") and *unsupported*. A reader can check a
  construct without reading the compiler.
- **Deviations on their own page.** Numba keeps "where we differ from Python"
  ([pysemantics](https://numba.readthedocs.io/en/stable/reference/pysemantics.html))
  apart from "what we accept". Its list: no bounds checking, fixed-width
  integers that wrap, `~` on booleans, globals frozen at compile time,
  variables zero-initialised, and memory leaked when an exception is raised.
  This is the same idea as defk's **Divergence** term.
- **The reference can fall behind the compiler.** Numba's reference lists
  "set, dict and generator comprehensions" as unsupported, yet in Numba 0.68.0
  `@njit def f(n): return {i: i for i in range(n)}` compiles and runs. A
  hand-written reference drifts unless it is tested.
- **Named escape hatches.** Nx has `deftransform`, Taichi has `ti.static`,
  Numba has `objmode`, Terra has `[...]`. Each subset names the way out to
  the host language, so "not allowed" can always end with "do this instead".
- **Rule-shaped reference text.** Taichi words its reference as rules with
  the condition stated, e.g. "Break statement is not allowed when the nearest
  enclosing loop is a parallel range/ndrange for loop… write
  `ti.loop_config(serialize=True)` … then it can be terminated by `break`".
  Each rule comes with its workaround.

## 2. How unsupported constructs are reported (real messages)

### Numba 0.68.0: location, a caret, the inferred types and the candidates

```
numba.core.errors.TypingError
Failed in nopython mode pipeline (step: nopython frontend)
Can't unify return type from the following types: UniTuple(int64 x 1), int64
Return of: IR name '$22return_value.2', type 'UniTuple(int64 x 1)', location:
File "nb1.py", line 8:
def bad_unify(x):
    <source elided>
    if x > 0:
        return (x,)
        ^
Return of: IR name '$26return_value.1', type 'int64', location:
File "nb1.py", line 9:
...
    return x
    ^
During: Pass nopython_type_inference
```

```
No implementation of function Function(<built-in function sqrt>) found for signature:
 >>> sqrt(float64, Literal[int](2))
There are 2 candidate implementations:
 - Of which 2 did not match due to:
 Type Restricted Function in function 'sqrt': ...
   With argument(s): '(float64, int64)':
  No match for registered cases:
   * (int64,) -> float64
   * (uint64,) -> float64
   * (float32,) -> float32
   * (float64,) -> float64
During: typing of call at nb3.py (7)
File "nb3.py", line 7:
    return math.sqrt(x, 2)
    ^
```

What works: every conflicting site is shown with a caret, and the accepted
signatures are listed, which tells the developer what to change. What doesn't:
compiler internals leak into the message ("IR name '$22return_value.2'",
"Pass nopython_type_inference"). Some constructs are rejected in bytecode
terms rather than source terms:

```
UnsupportedBytecodeError: Use of unsupported opcode (IMPORT_NAME) found. Raised from nb3.py (12)
UnsupportedBytecodeError: Exception object cannot be stored into variable (e).. Raised from nb1.py (26)
```

`IMPORT_NAME` is the bytecode for `import os`. The user has to translate it
back to the source line, and no alternative is suggested.

### Cython: source excerpt, a caret, and `file:line:col`

```
Error compiling Cython file:
------------------------------------------------------------
...
    for i in range(a.shape[0]):
        s += a[i]
    cdef int j = "hello"
                 ^
------------------------------------------------------------
cy1.pyx:6:17: Only single-character string literals can be coerced into ints.
```

The `file:line:col:` prefix is the gcc/clang format, so editors and CI turn
it into a link.

### Pythran 0.19.0: a short rejection, and a gap that drifts silently

```
CRITICAL: I am in trouble. Your input file does not seem to match Pythran's constraints...
py1.py: error: Classes not supported
```

This message has no line number. Worse, a type-unstable function that the
manual rules out ("polymorphic variables") was **accepted**:

```python
#pythran export g(int)
def g(n):
    x = 1
    if n > 0:
        x = "s"
    return x + 1
```

CPython raises `TypeError: can only concatenate str (not "int") to str`, but
the compiled `g(1)` returned `68`. A subset is only predictable if the
compiler enforces every rule the manual states.

### Nx 0.13.1 (`defn`): `CompileError` with the line, or a trace-time `RuntimeError`

```
RuntimeError: cannot invoke Enum.map/2 inside defn because it was not defined with defn
RuntimeError: cannot invoke String.length/1 inside defn because it was not defined with defn
CompileError: nofile:4: undefined function receive/1 (there is no such import)
Protocol.UndefinedError: protocol Nx.LazyContainer not implemented for BitString, data-structures
given to defn/Nx must implement either Nx.LazyContainer or Nx.Container. ...
```

Other messages in the source
([`nx/lib/nx/defn/compiler.ex`](https://github.com/elixir-nx/nx/blob/main/nx/lib/nx/defn/compiler.ex)):

- "only variables, tuples, maps, and structs are allowed as patterns in defn, got: …"
- "case/2 in defn does not allow matching on keys of maps and structs in patterns. Got: …"
- "`Nx.runtime_call` inside defn requires a named capture (e.g. &my_callback/2), anonymous functions are not allowed. Use a defp or def function and pass it as &name/2"

They follow one template: *what is not allowed, why, and the alternative to
write*. Nx also **warns** when something is legal but likely to surprise:
`Nx.tensor(opts[:key])` warns "As that will JIT compile a different function
for each different key".

Gap: the docs say recursion is "not possible" in `defn`, but a recursive
`defn` gave no error. Calling it ran for more than 15 s and was killed. The
rule is documented but not enforced at compile time.

### Futhark: an error code and a versioned link to an error index

From
[`TypeChecker/Monad.hs`](https://github.com/diku-dk/futhark/blob/master/src/Language/Futhark/TypeChecker/Monad.hs)
(`withIndexLink`) and
[`Consumption.hs`](https://github.com/diku-dk/futhark/blob/master/src/Language/Futhark/TypeChecker/Consumption.hs),
an error renders roughly as below. This was reconstructed from the source,
not captured from a run, so the locations and version are placeholders:

```
Error at prog.fut:<line:col>:
Using "x", but this was consumed at <line:col>.  (Possibly through aliases.)

For more information, see:
  https://futhark.readthedocs.io/en/v<compiler version>/error-index.html#use-after-consume
```

The URL points to the documentation of the **compiler's own version**
(`latest/` only for development builds). Each index entry has a minimal
failing program, an explanation and the fix, e.g. "use `copy` to break
aliasing", or "define one or more *monomorphic* entry points" for
`polymorphic-entry`.

### Taichi: a caret under the whole range, with messages that name the fix

[`ast_transformer_utils.get_pos_info`](https://github.com/taichi-dev/taichi/blob/master/python/taichi/lang/ast/ast_transformer_utils.py)
prints `File "...", line N, in kernel_name:`, then the source line, then
`^^^^` under the whole node (from `col_offset` to `end_col_offset`). Messages from
[`ast_transformer.py`](https://github.com/taichi-dev/taichi/blob/master/python/taichi/lang/ast/ast_transformer.py):

- "Return inside non-static if/for is not supported"
- "'else' clause for 'for' not supported in Taichi kernels"
- `"{op}" is only supported inside ti.static.`, as distinct from `"{op}" is not supported in Taichi kernels.`
  The first message names a workaround, the second says there is none.
- "Using conditional expression for element-wise select operation on Taichi
  vectors/matrices is deprecated and removed starting from Taichi v1.5.0
  Please use "ti.select" instead."

### Julia: no error, just annotations

`@code_warntype` prints the typed IR, with non-concrete types in red
(`y::Union{Float64, Int64}`) and the return type as `Body::Float64`.
Unions with `Nothing` or `Missing` are yellow, because they are often
harmless. JET's `@report_opt` prints `runtime dispatch detected:
fill_twos!(a::Vector)::Any` with the call frame. `@test_opt f(x)` makes
"stays on the fast path" a **test assertion**. This fits properties that are
not legality rules, such as "this loop will vectorise" or "this check was
removed".

## 3. Dual execution: running the same code in the host language

| System | Mechanism | What actually runs |
|---|---|---|
| Numba | `NUMBA_DISABLE_JIT=1` ([env var docs](https://numba.readthedocs.io/en/stable/reference/envvars.html)) | The original Python function. "Useful if you want to run the Python debugger over your code." `vectorize`/`guvectorize` still compile, because they have no pure-Python form. |
| Cython (pure Python mode) | The same `.py` file is either imported by CPython or compiled. `cython.compiled` tells the code which. The `Cython.Shadow` module makes the annotations no-ops. | The original Python. |
| Pythran | `#pythran export` is a comment, so CPython runs the file unchanged ("100% Python compatible"). | The original Python. |
| Nx `defn` | `Nx.Defn.Evaluator`, the default compiler. EXLA and others can be chosen per call (`Nx.Defn.jit(f, compiler: EXLA)`). | **Not** the original Elixir. The Evaluator "evaluates the expression tree against the tensor backend" ([docs](https://nx.hexdocs.pm/Nx.Defn.Evaluator.html)): the same traced graph, interpreted. |
| Taichi | No pure-Python mode was found in the docs. Debugging uses `ti.init(debug=True)` (bounds checks and `assert`, "performance may worsen"), `arch=ti.cpu, cpu_max_num_threads=1` to serialise, and `print` inside kernels. | Always compiled code. |
| Julia, Mojo, Futhark, Terra | Nothing to fall back to: one language (Julia, Mojo), a standalone language (Futhark), or a separate subset with no interpreter (Terra). Futhark has its own interpreter, `futhark run`, for the same purpose. | n/a |

### Gains

- **A real debugger.** This is the reason Numba gives. Breakpoints and
  stepping work in the fallback, while compiled code is a black box.
- **A reference implementation for free.** The host-language run is an
  oracle for differential tests. defk does this by hand today: every catalog
  workload has an Elixir twin checked for agreement.
- **Portability.** Pythran and Cython pure mode can ship without a compiler
  at the cost of speed.

### Costs: semantic drift between modes

Running the same Numba file both ways (`nb2.py`):

| Input | `@njit` | `NUMBA_DISABLE_JIT=1` |
|---|---|---|
| `a = np.zeros(3); a[10]` | `1.06099789647e-313` (reads past the end, no error) | `IndexError: index 10 is out of bounds for axis 0 with size 3` |
| `x = 2**62; x * x` | `0` (int64 wrap) | `21267647932558653966460912964485513216` |

and Pythran's `g(1)` gives `68` compiled against a `TypeError` in CPython (above).

So in these systems the fallback answers *"is my algorithm right?"*, not
*"does the compiled code behave like this?"*. A bug that only exists in
compiled mode (overflow, out of bounds, an inferred type) disappears when you
switch to the debugger. Cython makes the choice explicit and per-site with
directives (`boundscheck`, `wraparound`, `cdivision`, `overflowcheck`), and
its defaults lean towards Python semantics (`boundscheck=True`,
`cdivision=False`).

Nx avoids the drift by interpreting the *same graph* rather than the
original source. The cost is that the Evaluator is not "plain Elixir": you
cannot `IO.inspect` a value or step into the body with a debugger. Nx
provides graph-level tools instead (`print_expr`, `print_value`, `hook`,
`debug_expr`).

The fallback is only safe for testing when the compiled mode keeps host
semantics (checked overflow, checked bounds, raising on division by zero) or
documents each difference. That is the position defk already takes with its
Divergence rule.

## 4. What defk could copy

Today `Defk.Compiler.err!/2` raises `CompileError` with `file`, `line` and a
`"defk: …"` description. Many messages already say what to do instead,
e.g. "unknown type …; use i64, f64, bool, [f64], [i64], [u8] or tuples", or
the list of what a `case` guard may use. In priority order:

1. **Use one template for every rejection.** Say what was found, why it is
   not allowed, and what to write instead, as Nx's and Taichi's best messages
   do. Audit the ~60 `err!` sites against it. The weak ones are
   "unsupported expression in kernel: …", "cannot match …" and "empty block",
   which give no reason and no alternative. For a known Elixir construct
   (map, string, `Enum.map`, `while`-style recursion, `try`), name the
   construct and point to the defk equivalent: "`Enum.map/2` is not in the
   kernel subset; use `for … reduce:` or `alloc/2` plus `out[i] = v`".
2. **Report a column, and show a caret.** Elixir's `CompileError` takes
   `line:` and Elixir 1.15+ diagnostics accept columns. `Code.string_to_quoted`
   with `columns: true` (or the `:column` in the metadata of `defk`'s own
   macro arguments) gives Cython/Taichi-style `file:line:col` output that
   editors turn into links.
3. **An error index with stable error codes.** Copy Futhark: each rejection
   gets a short code (`defk-unsupported-call`, `defk-array-branch`, …) and a
   section in a `docs/subset.md` reference, with a failing example, the
   reason and the rewrite. The message ends with the link. Version the URL
   (or point to the repo path at a tag) so it matches the installed defk.
4. **A subset reference with a list for each status, and divergences apart.**
   README's "Language" and "Known limitations" sections already hold the
   content. Restructure it as Numba does: supported / supported with
   restrictions / not supported, plus a separate **Divergences** page (one
   entry per divergence, linked from the error index).
5. **Test the reference.** Both Numba (dict comprehension) and Nx/Pythran
   (recursion, polymorphic variables) have a reference that disagrees with
   the compiler. Have each error-index entry's failing example compile in a
   test that asserts the error code, and each supported example compile and
   run. The reference then cannot drift.
6. **Warnings and opt-in reports for the fast path, not errors.** Julia's
   `@code_warntype` and JET's `@test_opt`, and Cython's `cython -a`, show that
   "legal but slow" belongs in a report. defk analogues: a
   `Mod.__defk_report__/1` or `mix defk.explain` that lists, per kernel, which
   bounds checks were removed, which `if` became a select, and which loops
   lost their safepoint. Then add test helpers (`assert_no_bounds_checks`)
   in the spirit of `@test_opt`.
7. **Dual execution: run kernels as Elixir for tests and debugging, built to
   avoid drift.** Many kernel bodies are close to valid Elixir. A source
   transform could run them in the BEAM: `a[i]` reads the packed binary,
   `len/1` is `byte_size/8`, `alloc/2` plus `out[i] = v` becomes a rebinding
   that threads a binary or tuple through, and builtins map to `:math`. Since
   defk keeps Elixir semantics (checked overflow, `/` raising,
   `Enum.OutOfBoundsError`), most of the drift seen in Numba and Pythran
   would not occur. The two modes could be checked against each other in a
   test helper (`Defk.Test.assert_agrees(Mod, :fun, args)`), turning the
   catalog's hand-written Elixir twins into a generated oracle. Costs:
   - a second semantics to maintain
   - array aliasing on write (README: "`b = a` then `a[i] = x` is visible
     through `b`") cannot be expressed as an Elixir rebinding, so it becomes
     a divergence unless defk-i2e lands first
   - yielding and the runtime contract are not exercised in Elixir mode.

   Treat it as a test and debug tool behind an explicit flag (like
   `NUMBA_DISABLE_JIT`), never a silent fallback.
8. **Make escape hatches explicit.** "Not in the subset" should always point
   somewhere: do it in Elixir before or after the call (the boundary is
   cheap), or call another kernel. Nx's `deftransform` is the model if defk
   ever needs compile-time Elixir in a kernel (e.g. to compute constants).

## Sources

- Numba: [pysupported](https://numba.readthedocs.io/en/stable/reference/pysupported.html) ([rst source](https://numba.readthedocs.io/en/stable/_sources/reference/pysupported.rst.txt)), [pysemantics](https://numba.readthedocs.io/en/stable/reference/pysemantics.html), [troubleshoot](https://numba.readthedocs.io/en/stable/user/troubleshoot.html), [envvars](https://numba.readthedocs.io/en/stable/reference/envvars.html). Messages made with Numba 0.68.0.
- Nx: [Nx.Defn](https://nx.hexdocs.pm/Nx.Defn.html), [Nx.Defn.Evaluator](https://nx.hexdocs.pm/Nx.Defn.Evaluator.html), [defn compiler source](https://github.com/elixir-nx/nx/blob/main/nx/lib/nx/defn/compiler.ex). Messages made with Nx 0.13.1.
- Cython: [pure Python mode](https://cython.readthedocs.io/en/latest/src/tutorial/pure.html), [compilation and directives](https://cython.readthedocs.io/en/latest/src/userguide/source_files_and_compilation.html). Message made with the current pip release.
- Pythran: [manual](https://pythran.readthedocs.io/en/latest/MANUAL.html). Messages and behaviour from Pythran 0.19.0.
- Taichi: [language reference](https://docs.taichi-lang.org/docs/language_reference), [debugging](https://docs.taichi-lang.org/docs/debugging), [ast_transformer.py](https://github.com/taichi-dev/taichi/blob/master/python/taichi/lang/ast/ast_transformer.py), [ast_transformer_utils.py](https://github.com/taichi-dev/taichi/blob/master/python/taichi/lang/ast/ast_transformer_utils.py).
- Futhark: [error index](https://futhark.readthedocs.io/en/latest/error-index.html), [TypeChecker/Monad.hs](https://github.com/diku-dk/futhark/blob/master/src/Language/Futhark/TypeChecker/Monad.hs), [TypeChecker/Consumption.hs](https://github.com/diku-dk/futhark/blob/master/src/Language/Futhark/TypeChecker/Consumption.hs).
- Julia: [performance tips](https://docs.julialang.org/en/v1/manual/performance-tips/); JET: [optimization analysis](https://aviatesk.github.io/JET.jl/stable/optanalysis/).
- Mojo: [functions](https://mojolang.org/docs/manual/functions). The removal of `fn` in Mojo 1.0 comes from a secondary report; it was not checked against the release notes.
- Terra: [getting started](https://terralang.org/getting-started.html).
