# The kernel subset

This is the reference for writing a kernel: what compiles, what it means, where
it raises, and what each compile error says. It describes the language on
`main`; the compiler (`lib/defk/compiler.ex`) and the runtime
(`priv/defk_runtime.h`) are the source of truth, and the tests check this
document's error section against the compiler's registry. The README is the
overview; this document supersedes its short-form "Language", "Design
decisions" and "Known limitations" lists where they differ.

Vocabulary is `CONTEXT.md`'s: kernel, kernel subset, runtime contract,
convenience construct, the one rule, agreement, limit, divergence, array,
element type, Elixir mode.

Contents:

1. [What a kernel is, and the one rule](#1-what-a-kernel-is-and-the-one-rule)
2. [Defining a kernel](#2-defining-a-kernel)
3. [Types](#3-types)
4. [Expressions and operators](#4-expressions-and-operators)
5. [Variables and binding](#5-variables-and-binding)
6. [Arrays](#6-arrays)
7. [Control flow](#7-control-flow)
8. [Calls](#8-calls)
9. [Yielding and the runtime contract in practice](#9-yielding-and-the-runtime-contract-in-practice)
10. [Elixir mode](#10-elixir-mode)
11. [Compile errors](#11-compile-errors)
12. [Limits](#12-limits)
13. [Known divergences](#13-known-divergences)
14. [Changes in flight](#14-changes-in-flight)

Each construct below is marked **supported**, **supported with restrictions**
or **unsupported** (with the error code it gets). Examples are kernels inside a
module that has `use Defk`; `iex>` lines show what a call returns or raises.

The tests run every example (`test/language_doc_examples_test.exs`). A
block with a kernel in it is followed by a block of `iex>` lines calling the
module as `M` (or by its own `defmodule` name), which run in native code and
in Elixir mode and must give the result shown; or it has one of these
comments on the line above its opening fence:
`<!-- defk-example compiles: <reason> -->` (compiled only, where a run makes
no sense), `<!-- defk-example error: <code> -->` (must fail with that code),
`<!-- defk-example skip: <reason> -->` (a fragment, not checked), or
`<!-- defk-example known-failure: <ticket> -->` (checked, and must still fail
until the ticket is fixed). A kernel block with none of these fails the tests.
Every skip needs a reason, and the test run lists the skips.

The other `elixir` blocks of the docs run too, in a separate BEAM
(`test/support/language_doc.ex` has the details): a plain block is run as a sketch, and
a trailing `# => value` on a line is checked; a block with `use ExUnit.Case`
runs as a test file; and `<!-- defk-example run: <bindings> | defs: <code> -->`
gives a sketch what it needs. A fragment gets a `skip:` comment.

## 1. What a kernel is, and the one rule

A **kernel** is a function written in the kernel subset with `defk`, compiled
to native code and called from Elixir like any other function. The **kernel
subset** is the part of Elixir a kernel may use: its types, constructs,
convenience constructs, and the semantics they keep.

The one rule:

> A kernel is Elixir over numbers and binaries: it gives the result Elixir
> would, or raises where its types can't hold that result, or doesn't compile.
> It never gives a different answer.

A case where a kernel raises or refuses to compile where Elixir would have
succeeded is a **limit** (allowed, and listed in [Limits](#12-limits)). A case
where it gives a different value or behaviour without raising is a
**divergence** (not allowed; each known one is a bug, listed in
[Known divergences](#13-known-divergences) until it is fixed).

The **runtime contract** is what a kernel promises the BEAM while it runs:

1. A long kernel yields to its scheduler, so it never starves other processes
   (preemption).
2. A kernel touches only its own arguments and the arrays it allocates, and an
   error in it is an Elixir exception in the calling process (isolation).
3. If the process dies while its kernel is suspended, everything the kernel
   allocated is freed (cleanup).
4. A kernel suspended across a reload of its module finishes in the code it
   started in (hot code upgrade).

[Section 9](#9-yielding-and-the-runtime-contract-in-practice) says what each
of these means for a kernel author.

## 2. Defining a kernel

```elixir
defmodule Stats do
  use Defk

  defk dot(a :: [f64], b :: [f64]) :: f64 do
    n = min(len(a), len(b))

    for i <- 0..(n - 1)//1, reduce: 0.0 do
      acc -> acc + a[i] * b[i]
    end
  end
end
```

```elixir
iex> Stats.dot(<<1.0::float-native, 2.0::float-native>>, <<3.0::float-native, 4.0::float-native>>)
11.0
```

- `use Defk` imports the `defk` macro. A module may mix kernels with ordinary
  `def`s.
- The head is `defk name(param :: type, ...) :: return_type`. Every parameter
  has a type ([`untyped-parameter`](compile-errors.md#untyped-parameter)) and the return type is
  required ([`kernel-head`](compile-errors.md#kernel-head)). A kernel may have no parameters:
  `defk pi() :: f64 do 3.14159 end`.
- The body is a `do ... end` block or `, do: expr`. Its last expression is the
  result, converted to the return type the way Elixir would never need: only
  an `i64` widens to `f64`; anything else is
  [`return-type`](compile-errors.md#return-type).
- One option exists: `yield: false`, written after the return type
  (`defk f(x :: i64) :: i64, yield: false do ... end`). It compiles the kernel
  without safepoints (see [section 9](#9-yielding-and-the-runtime-contract-in-practice)).
  Any other option is [`unknown-option`](compile-errors.md#unknown-option).
- Each name/arity is defined once ([`duplicate-kernel`](compile-errors.md#duplicate-kernel)):
  by one typed definition with a body, or by a bodiless head and its clauses
  ([below](#multi-clause-kernels)).

### Multi-clause kernels

**Supported with restrictions:** a kernel written as Elixir writes a
multi-clause function. A head without a body gives the types, then each
clause gives patterns, an optional guard, and a body:

```elixir
defk classify(x :: i64, strict :: bool) :: i64
defk classify(0, _), do: 0
defk classify(x, true) when x in 1..9, do: 1
defk classify(x, _strict) when x > 0, do: 2
defk classify(_, false), do: -1
```

```elixir
iex> M.classify(0, true)
0
iex> M.classify(5, true)
1
iex> M.classify(50, true)
2
iex> M.classify(-3, false)
-1
iex> M.classify(-3, true)
** (FunctionClauseError) no function clause matching in M.classify/2
```

- **The head** is `defk name(param :: type, ...) :: return_type` with no
  body, optionally followed by `, yield: false`. The clauses come after it,
  with the same name and arity, without types
  ([`clause-types`](compile-errors.md#clause-types)) or options
  ([`unknown-option`](compile-errors.md#unknown-option)). Clauses without a head, or before
  it, are [`clause-head`](compile-errors.md#clause-head); a head without clauses is
  [`no-body`](compile-errors.md#no-body).
- **Patterns:** an integer literal for an `i64` parameter (also negative),
  `true`/`false` for a `bool`, `_`, or a variable, which names that
  parameter in the clause's guard and body. A literal of the wrong type, a
  float, a tuple, `^pin` (a function head has no variable to pin) and a
  variable named twice (`f(x, x)`: write `when x == y`) are
  [`clause-pattern`](compile-errors.md#clause-pattern). A parameter of any type may be a
  variable or `_`.
- **Scope:** as in Elixir, a clause sees only its own variables: a head
  parameter's name that the clause does not bind at its position is
  [`undefined-variable`](compile-errors.md#undefined-variable) there (a body may still bind
  it as a new local), and `_name` patterns give no warnings.
- **Guards** are `case` guards ([`case`](#case)): the same expressions,
  `in` with literal lists and ranges, and an error in a guard (a zero
  divisor, an inf or NaN) fails the clause, so the next one is tried.
- **No clause matching** raises `FunctionClauseError` with the kernel's
  `module`, `function` and `arity`, and `kind`, `args` and `clauses` `nil`,
  field for field what Elixir raises for the same `def` clauses. For a
  kernel another kernel calls, `function` is that kernel, as for a `defp`
  in Elixir. Elixir mode raises the same.
- **Values:** every clause gives a value of one type (one tuple shape), as
  the arms of a `case` do ([`branch-types`](compile-errors.md#branch-types)), and the
  result converts to the return type as a body's would.
- **Entry kernels and helpers alike:** a multi-clause kernel may be called
  from Elixir or from other kernels, including one that takes a
  [bitstring accumulator](#the-bitstring-accumulator).
- Clauses are tried in order. The kernel compiles to one `case` over its
  parameters: the first parameter that a clause matches with a literal is
  the subject, and a literal at another parameter is a test in front of that
  clause's guard. Nothing is copied: the C is what the same `case` or `cond`
  written by hand gives, an if-chain over the parameter (which clang turns
  into a switch where that pays). (defk-u9c)

A helper over the bitstring accumulator, as Gorilla's encoder writes its
delta-of-delta buckets:

```elixir
defk dod_bits(acc :: bitstring, dod :: i64) :: bitstring
defk dod_bits(acc, 0), do: <<acc::bitstring, 0::1>>

defk dod_bits(acc, dod) when dod >= -64 and dod <= 63,
  do: <<acc::bitstring, 0b10::2, dod::7-signed>>

defk dod_bits(acc, dod), do: <<acc::bitstring, 0b11::2, band(dod, 0xFFFFFFFF)::32>>

defk dods(ds :: [i64]) :: bitstring do
  for d <- ds, reduce: <<>> do
    acc -> dod_bits(acc, d)
  end
end
```

```elixir
iex> M.dods(<<0::64-native, -1::64-native, 100::64-native>>)
<<0::1, 0b10::2, -1::7-signed, 0b11::2, 100::32>>
```

### What `use Defk` generates

For each kernel, a public function with the kernel's name and arity and an
`@spec` derived from its types (`i64` is `integer()`, `u64` is
`non_neg_integer()`, an `f64` parameter is
`number()` and an `f64` result `float()`, `bool` is `boolean()`, an array is
`binary()`, a tuple result is a tuple of those). Calling it runs the native
code.

Per module, also these functions. They are `@doc false` in your module; the
`Defk` module docs describe them once, with which are public and which are
unstable (debugging output that may change in any version):

| Function | Returns |
|---|---|
| `__defk_c_source__/0` | the generated C source of the module's kernels |
| `__defk_report__/0` | the fast-path report as data, `[{kernel, line, fact}]` (see `Defk.Report`; `Defk.Report.print/1` prints it) |
| `__defk_lib__/0` | the path of the compiled NIF library (`.so`) |
| `__defk_kernels__/0` | each kernel's signature: `%{name:, arity:, params: [{name, type}], ret:}` |
| `__defk_stats__/0` | runtime counters of this library: `%{frames_live:, promotions:, yields:, crc32c:, max_owned:}` (`crc32c` is `:instruction` or `:table`, the [crc32c](#hardware-builtins) implementation it picked at its first call, or `:not_called`; `max_owned` is the [owned-buffer budget](#the-owned-buffer-budget) in bytes) |
| `__defk_force_yields__/1` | testing: `true` makes this module's kernels yield at every clock read, so every resume path runs; `false` turns it off |
| `__defk_elixir__/2` | Elixir mode: `Mod.__defk_elixir__(:name, args)` runs one call as plain Elixir (only where Elixir mode is compiled, see [section 10](#10-elixir-mode)) |
| `__defk_elixir_source__/0` | the generated Elixir mode code (same condition) |

### Compile-time behaviour

At `mix compile`, when the module is compiled:

1. Every kernel is type-checked and lowered to C. Every rejection in the
   module is collected and reported together as one `CompileError` (the first
   10 are shown), in the format of [section 11](#11-compile-errors).
2. The C source is written to `_build/<env>/defk/<Module>-<key>.c` and built
   into `<Module>-<key>.so` with the system C compiler (`cc`, or the `CC`
   environment variable) at `-O3`, with `-ffp-contract=off` (no fused
   multiply-add: float results stay bit-exact with Elixir) and hardening flags.
3. The build is cached: `<key>` is a hash of the compiler flags, the C source,
   the runtime header, the ERTS version, `ERTS_INCLUDE_DIR` when set, and the
   compiler (`CC`) and its `--version` line. An unchanged module reuses its
   library.
4. `ERTS_INCLUDE_DIR` (the elixir_make convention) builds against another
   ERTS's `erl_nif.h` instead of the running one's.
5. A module of a Mix app (compiled from the project's `elixirc_paths`) gets
   a copy of its library in the app's `ebin/`, beside its `.beam`, and loads
   it from there through `:code.lib_dir(app)`, so it ships in a `mix release`
   and works wherever the app is moved ([Deploying](guides/deploying.md#releases)).
   Any other module (a script, `Code.compile_string/2`, a test file) loads it
   from the absolute build path.
6. The module loads its library in an `@on_load` hook.

The C compiler runs on the build machine, at compile time only. If it cannot
be run, the build fails with [`no-c-compiler`](compile-errors.md#no-c-compiler):

```
error: cannot compile MyApp.Kernels: C compiler `cc` not found

why: a kernel is compiled to native code at build time, so a C toolchain is needed on the build machine, as for elixir_make packages
hint: install one (macOS: `xcode-select --install`; Debian/Ubuntu: `apt install build-essential`; Alpine: `apk add build-base`), or set `CC` to a compiler path
(defk no-c-compiler: https://github.com/DanielLuning/defk/blob/main/docs/compile-errors.md#no-c-compiler)
```

If the C compiler runs but fails, the `CompileError` says
`defk: C compilation failed (<path>.c)` followed by the compiler's output.
That is a defk bug or a broken toolchain, not a kernel error.

## 3. Types

| Type | Inside a kernel | As an argument | As a result |
|---|---|---|---|
| `i64` | a signed 64-bit integer | an integer in -2^63..2^63-1; anything else (a float, a bignum) raises `ArgumentError` "argument N (name) must be an integer fitting in i64" | an integer |
| `u64` | an unsigned 64-bit integer ([u64](#u64)) | an integer in 0..2^64-1; anything else raises `ArgumentError` "argument N (name) must be an integer fitting in u64" | a non-negative integer |
| `f64` | a double | a float, or an integer that fits in `i64` (converted to a float); anything else raises `ArgumentError` "argument N (name) must be a number" | a float, always finite: any operation that would make inf or NaN raised first |
| `bool` | `true` or `false` | `true` or `false`; anything else (including `nil`) raises `ArgumentError` "argument N (name) must be a boolean" | `true` or `false` |
| `[f64]`, `[i64]`, `[u8]`, `[f32]`, `[i32]`, `[i16]`, `[u64]` | an array of that element type | a binary of packed native-endian elements; not a binary, or a byte size that is not a multiple of the element size, raises `ArgumentError` | a binary of packed native-endian elements |
| `{t1, t2, ...}` | see below | not allowed ([`tuple-parameter`](compile-errors.md#tuple-parameter)) | a tuple |
| `bitstring` | a [bitstring accumulator](#the-bitstring-accumulator) | not allowed from Elixir: only a kernel passes one, to a kernel it calls ([`bitstring-use`](compile-errors.md#bitstring-use)) | a bitstring (any number of bits) |

**Supported:** `i64`, `u64`, `f64`, `bool`, `[f64]`, `[f32]`, `[i64]`,
`[i32]`, `[i16]`, `[u8]`, `[u64]`. Any other type
name is [`unknown-type`](compile-errors.md#unknown-type), whose hint names the kernel type for
the Elixir one (`integer` is `i64`, `float` and `number` are `f64`, `binary` is
`[u8]`).

**Supported with restrictions:** `bitstring`, the type of a [bitstring
accumulator](#the-bitstring-accumulator): a result type, alone or in a tuple
(`:: {bitstring, i64}`), and the parameter type of a kernel other kernels
call ([Passing it to a kernel](#the-bitstring-accumulator)), never of one
called from Elixir.

**Supported with restrictions:** tuples. A tuple of scalars and arrays is a
return type (`:: {f64, f64}`, `:: {[f64], i64}`). Inside a kernel, tuples exist
only where they are taken apart at once: destructured by `{a, b} = ...`,
as `reduce:` and `Enum.reduce_while` accumulators, as the value of an `if`,
`cond` or `case` ([section 7](#tuples-from-branches)), and as the result. A
variable cannot hold a tuple ([`tuple-binding`](compile-errors.md#tuple-binding)), tuples do not
nest ([`nested-tuple`](compile-errors.md#nested-tuple)), a call cannot take one
([`tuple-argument`](compile-errors.md#tuple-argument)), and a call to a kernel that returns
one is destructured at once (`{out, n} = fill(out, v)`).

An array's **element type** is `f64`, `f32`, `i64`, `i32`, `i16`, `u8` or
`u64` (the unknown-type error for any other, such as `[u16]`, lists these).
The narrow ones (`f32`, `i32`, `i16`, `u8`) exist only inside arrays; there
are no narrow scalars. Reading an element widens it exactly, as Elixir's
bitstring match does: a `[u8]`, `[i16]` or `[i32]` element is an `i64` in that
type's range, an `[f32]` element is the `f64` of the same value. A `[u64]`
element is a [`u64`](#u64), a scalar type of its own. All arithmetic is
`i64`, `u64` or `f64`, never `f32`. A write must fit the element type (see
[Writing](#writing)).

An Elixir caller builds and reads these arrays as binaries of native-endian
elements:

| Element type | Build | Read |
|---|---|---|
| `f64` | `for x <- xs, into: <<>>, do: <<x::float-64-native>>` | `for <<x::float-64-native <- bin>>, do: x` |
| `f32` | `for x <- xs, into: <<>>, do: <<x::float-32-native>>` | `for <<x::float-32-native <- bin>>, do: x` |
| `i64` | `for x <- xs, into: <<>>, do: <<x::signed-64-native>>` | `for <<x::signed-64-native <- bin>>, do: x` |
| `i32` | `for x <- xs, into: <<>>, do: <<x::signed-32-native>>` | `for <<x::signed-32-native <- bin>>, do: x` |
| `i16` | `for x <- xs, into: <<>>, do: <<x::signed-16-native>>` | `for <<x::signed-16-native <- bin>>, do: x` |
| `u8` | `:erlang.list_to_binary(xs)` | `:binary.bin_to_list(bin)` |
| `u64` | `for x <- xs, into: <<>>, do: <<x::unsigned-64-native>>` | `for <<x::unsigned-64-native <- bin>>, do: x` |

`Nx.to_binary/1` of an `{:f, 32}`, `{:s, 16}`, ... tensor is the same layout.
Building an `f32` element rounds to nearest; a value that rounds to inf
(over about 3.4028235e38) makes inf bits, which the kernel rejects when it
reads them (see [Inputs](#inputs)).

**Unsupported:** maps, structs, lists, strings, atoms other than `true` and
`false`, `nil`, functions, and arrays of `bool` or tuples. A kernel that needs
them is the wrong tool: pack the data into binaries in Elixir first.

```elixir
defk mean_var(a :: [f64]) :: {f64, f64} do
  {_n, mean, m2} =
    for x <- a, reduce: {0, 0.0, 0.0} do
      {n, mean, m2} ->
        n1 = n + 1
        d = x - mean
        mean1 = mean + d / n1
        {n1, mean1, m2 + d * (x - mean1)}
    end

  {mean, m2 / len(a)}
end
```

```elixir
iex> M.mean_var(<<1.0::float-native, 2.0::float-native, 3.0::float-native, 4.0::float-native>>)
{2.5, 1.25}
```

### Literals

- Integer literals must fit in `i64` or `u64`
  ([`integer-literal`](compile-errors.md#integer-literal)): a literal from 2^63 to 2^64 - 1,
  such as FNV's offset basis `0xCBF29CE484222325`, is a `u64`.
  `-9223372036854775808` is the negation of a literal that does not fit in
  `i64`, so it is rejected; write `-9223372036854775807 - 1`.
- Float literals are `f64`. An integer literal where an `f64` is expected
  (a result, an argument, a `[f64]` write) widens, as in Elixir arithmetic.
- `true` and `false` are `bool`. Other atoms and `nil` are
  [`unsupported-atom`](compile-errors.md#unsupported-atom). A string or `<<1, 2, 3>>` is a
  `[u8]` ([binary literals](#binary-literals)). `<<>>` is the empty `[u8]`,
  or the empty bitstring where a [bitstring
  accumulator](#the-bitstring-accumulator) starts.

## 4. Expressions and operators

### Integer arithmetic

**Supported:** `+`, `-`, `*`, unary `-` and `+` on `i64`. The result is
Elixir's exact result; when it does not fit in `i64` the kernel raises
`ArithmeticError` (a limit: Elixir would give a bignum).

```elixir
defk mul(a :: i64, b :: i64) :: i64 do
  a * b
end
```

```elixir
iex> M.mul(4611686018427387904, 2)
** (ArithmeticError) i64 overflow in 4611686018427387904 * 2
```

Unary minus and `abs/1` of -2^63 overflow the same way.

The check is left out where the compiler proves the result fits, as for
`2 * i + 1` with `i <- 0..(len(a) - 1)//1` (array lengths are below 2^61).
That changes speed, never results.

`div/2` and `rem/2` take two `i64` values
([`builtin-arguments`](compile-errors.md#builtin-arguments) otherwise) and round as Elixir does:
`div` truncates toward zero, and `rem` has the sign of the dividend
(`div(-7, 2)` is `-3`, `rem(-7, 2)` is `-1`). A zero divisor raises
`ArithmeticError` "div/2 by zero" / "rem/2 by zero"; `div(-2^63, -1)` raises
"i64 overflow in div/2".

The power operator `**` is
[`unsupported-expression`](compile-errors.md#unsupported-expression): use `pow/2` (a float) or
multiply.

### u64

**Supported with restrictions.** A `u64` is an integer in 0..2^64 - 1: a
`u64` parameter, result or `[u64]` element, a literal from 2^63 up,
`band(x, 0xFFFFFFFFFFFFFFFF)` ([masked arithmetic](#masked-arithmetic)) and
`f64_to_u64/1`. It holds a 64-bit hash with its top bit set as the
non-negative integer Elixir has.

- `+`, `-`, `*`, `div`, `rem`, `min`, `max`, `band`, `bor` and `bxor` of two
  `u64` give a `u64`, Elixir's exact result. A result outside 0..2^64 - 1,
  `a - b` below 0 included, raises `ArithmeticError` "u64 overflow in 3 - 5"
  (a limit). `div` and `rem` by 0 raise as for `i64`.
- An `i64` the compiler knows is `>= 0` (a literal, `len(a)`, a `[u8]`
  element, `band(x, 255)`, ...) is a `u64` next to a `u64`: `h * 31 + 1`.
- Any other `i64` next to a `u64` outside a mask is
  [`u64-mix`](compile-errors.md#u64-mix): no one type holds every result. Its hint moves the
  arithmetic inside `band(..., 0xFFFFFFFFFFFFFFFF)`, where `i64` and `u64`
  mix freely.
- `bsl`/`bsr` of a `u64` shift exactly (`bsr` is logical, as for any
  non-negative integer); `bsl` raises `ArithmeticError` when a bit would
  leave the 64. `bnot` and unary `-` of a `u64` are negative, so they are
  [`operand-type`](compile-errors.md#operand-type): write them inside a mask.
- `/`, `float/1` and the math builtins convert a `u64` to the nearest `f64`,
  as Elixir does.
- A `u64` compared with an `i64` or `f64` compares exact values, and `===`
  holds between a `u64` and an `i64` with the same value (both are integers).
- **A `u64` where an `i64` is expected** (an array index, an `alloc/2`
  length, a range bound, an `i64` parameter, result or accumulator) is
  converted, and one above 2^63 - 1 raises `ArithmeticError` "... does not
  fit in i64" (a limit). **An `i64` where a `u64` is expected** raises
  `ArithmeticError` "-1 does not fit in u64" when it is negative.
- An `if`, `cond` or `case` whose branches give a `u64` and `i64` values
  known to be `>= 0` gives a `u64`: `if c, do: h, else: 0`.
- An accumulator whose initial value is an integer literal `>= 0` becomes a
  `u64` when its new value is one, or when it meets a `u64` in one of the
  operations above, so `reduce: 0` folds hashes:

  ```elixir
  defk total(hashes :: [u64]) :: u64 do
    for h <- hashes, reduce: 0 do
      acc -> acc + h
    end
  end
  ```

  ```elixir
  iex> M.total(<<9223372036854775808::unsigned-64-native, 1::unsigned-64-native>>)
  9223372036854775809
  iex> M.total(<<18446744073709551615::unsigned-64-native, 1::unsigned-64-native>>)
  ** (ArithmeticError) u64 overflow in 18446744073709551615 + 1
  ```

- A `case` on a `u64` is [`case-subject`](compile-errors.md#case-subject).

(defk-wlu)

### Float arithmetic

**Supported:** `+`, `-`, `*`, `/` and unary `-` on `f64`. When one operand is
`i64` and the other `f64`, the `i64` is converted to a float first, as in
Elixir (`1 + 0.5` is `1.5`).

`/` always gives an `f64`, also for two `i64` operands (`7 / 2` is `3.5`), and
a zero divisor (`0`, `0.0` or `-0.0`) raises `ArithmeticError`.

Float operations are evaluated as written, in IEEE double precision, with no
fused multiply-add, reassociation or fast-math, so a finite result is bit for
bit Elixir's. A float operation whose result would be inf or NaN raises `ArithmeticError`
at that operation, as Elixir does: `1.0e308 * 10.0`, `x / 0.0`, `0.0 / 0.0`,
`sqrt(-1.0)`, `log(0.0)`, `exp(1000.0)`, `:math.pow(10.0, 400.0)`. This holds
even when the value would never be returned. Underflow to `0.0` or a subnormal
does not raise. An `[f64]` or `[f32]` input element whose bits are inf or NaN raises
`ArgumentError` when it is read; elements never read don't. An `if`/`cond` arm
that isn't taken never raises. Messages differ from Elixir's (they name the
operation, not the line); run the kernel in Elixir mode to find the line.
(defk-i00; the checks cost 17-24% on float reductions and about 2x on a
vectorised elementwise loop today, see [performance.md 6.5](performance.md#65-float-checks-flag-the-strip-replay-on-failure) and
defk-6tt.)

### Comparisons

**Supported:** `==`, `!=`, `<`, `>`, `<=`, `>=`, `===`, `!==` on numbers, and
`==`, `!=`, `===`, `!==` on two booleans. The result is a `bool`.

- An `i64` compared with an `f64` compares exact values, as Erlang does, never
  by rounding the integer to a float:

  ```elixir
  defk gt(a :: i64, b :: f64) :: bool do
    a > b
  end
  ```

  ```elixir
  iex> M.gt(9007199254740993, 9007199254740992.0)
  true
  ```

- `==` compares values, so `1 == 1.0` is `true`. `===` also compares types, so
  `1 === 1.0` is `false`.
- On two floats, `==` treats `0.0` and `-0.0` as equal and `===` does not, as
  in Erlang (`0.0 == -0.0` is `true`, `0.0 === -0.0` is `false`).
- A `u64` compares with an `i64` or `f64` by exact value too; an `i64` and a
  `u64` are both integers, so `===` is `==` between them.
- Ordering booleans (`a < true`) or comparing a boolean with a number is
  [`operand-type`](compile-errors.md#operand-type) (a limit: Elixir orders all terms).

### Boolean operators

**Supported:** `and`, `or`, `not`, `&&`, `||`, `!` on `bool` operands. Both
families short-circuit: the right operand is evaluated only when it decides
the result, so `x != 0 && div(10, x) > 1` does not raise for `x = 0`.

**Restriction:** the operands must be `bool`
([`operand-type`](compile-errors.md#operand-type)). Elixir's `&&`, `||` and `!` accept any
truthy value; a kernel has no `nil`, so it refuses that (a limit), and the
hint shows the comparison to write (`x != 0`).

### Builtins

Builtins are called like local functions. `sqrt`, `exp`, `log`, `log2`, `log10`, `sin`,
`cos` and `pow` are also callable as `:math.sqrt/1` and so on; any other `:math`
function is [`unsupported-call`](compile-errors.md#unsupported-call). A builtin called with the
wrong types is [`builtin-arguments`](compile-errors.md#builtin-arguments).

A kernel cannot take the name and arity of a builtin (`copy_back/4`, `clz/1`, `clz/2`):
calls to it would reach the builtin, so the definition is
[`builtin-name`](compile-errors.md#builtin-name), and a builtin added in a later version
breaks a kernel module that already used its name and arity, at compile time. Rename
the kernel (`my_copy_back/4`). The same name at an arity the builtin does not take
(`log/2`, `clz/3`) is an ordinary kernel: calls are looked up by name and arity.

| Builtin | Takes | Gives | Raises |
|---|---|---|---|
| `len(a)` | an array | its number of elements, `i64` | |
| `bit_size(b)` | a [bitstring](#the-bitstring-accumulator) | its number of bits, `i64` | |
| `min(a, b)`, `max(a, b)` | two `i64`, two `u64` or two `f64` (not mixed) | the same type; when the two compare equal, the first argument, as Erlang does (`min(-0.0, 0.0)` is `-0.0`) | |
| `abs(x)` | `i64`, `u64` or `f64` | the same type | `i64`: `ArithmeticError` for -2^63 |
| `float(x)` | a number | `f64` (an `i64` above 2^53 rounds, as in Elixir) | |
| `trunc(x)`, `round(x)` | a number (an `i64` or `u64` is returned unchanged) | `i64`; `round` rounds half away from zero (`round(-2.5)` is `-3`) | `ArithmeticError` "trunc/1: ... does not fit in i64" when the result is outside `i64` (a limit) |
| `div(a, b)`, `rem(a, b)` | two `i64`, or two `u64` | the same type | see [Integer arithmetic](#integer-arithmetic) and [u64](#u64) |
| `sqrt(x)` | a number | `f64` | `ArithmeticError` for a negative `x` |
| `log(x)` | a number | `f64` | `ArithmeticError` for `x <= 0` |
| `log2(x)`, `log10(x)` | a number | `f64`, the same bits as `:math.log2/1` and `:math.log10/1` | `ArithmeticError` for `x <= 0` |
| `exp(x)`, `sin(x)`, `cos(x)` | a number | `f64` | |
| `pow(a, b)` | two numbers | `f64`, like `:math.pow/2` (`pow(2, 10)` is `1024.0`) | |
| `alloc(type, n)` | an element type and an `i64` length | a new zero-filled array | see [Arrays](#6-arrays) |
| `wrap64(expr)` | an `i64` expression | the low 64 bits of its exact result as a signed `i64`, as `Defk.Bits.wrap64/1` | see [Masked arithmetic](#masked-arithmetic) |
| `mulhi(a, b)` | two `i64` | `i64`: the high 64 bits of the unsigned 128-bit product of the u64 bit patterns, as `Defk.Bits.mulhi/2` | see [Bit builtins](#bit-builtins) |
| `clz(x)`, `ctz(x)`, `popcount(x)` | an `i64` or `u64` | `i64` in 0..64: leading zeros, trailing zeros (64 for 0), set bits of the u64 pattern | see [Bit builtins](#bit-builtins) |
| `clz(x, w)`, `ctz(x, w)` | an `i64` or `u64` x in 0..2^w - 1 and an `i64` width w in 1..64 | `i64` in 0..w: leading or trailing zeros of x as a w-bit value (w for 0) | `ArgumentError` for a width or x out of range |
| `rotl(x, n, w)`, `rotr(x, n, w)` | an `i64` or `u64` x in 0..2^w - 1, an `i64` count, an `i64` width w in 1..64 | x's type: the w-bit value x rotated by n mod w | as `clz(x, w)`; an `i64` x whose result is above 2^63 - 1 raises `ArithmeticError` |
| `rotl64(x, n)`, `rotr64(x, n)` | two `i64` | `i64`: the 64-bit pattern of `x` rotated by `band(n, 63)` | see [Bit builtins](#bit-builtins) |
| `f64_to_u64(x)` | a number | `u64`: the IEEE 754 bits of `x` as a float | |
| `crc32c(crc, x, w)` | an `i64` or `u64` crc in 0..2^32 - 1, an `i64` or `u64` x in 0..2^w - 1, an `i64` width w of 8, 16, 32 or 64 | `i64` in 0..2^32 - 1: one CRC32C step over the w/8 bytes of x, as `Defk.Bits.crc32c/3`. A hardware builtin: the CPU's instruction where it has one, a table otherwise, the same value | `ArgumentError` for a width or value out of range; see [Hardware builtins](#hardware-builtins) |
| `u64_le(b, i)`, `u32_le`, `u16_le`, `u64_be`, `u32_be`, `u16_be` | a `[u8]` and an `i64` byte offset | `i64`: the unsigned word at `i` (`u64` as its signed bit pattern) | see [Word loads](#word-loads) |
| `copy(out, at, src, from, n)` | two arrays of one element type and three `i64`: index, source index, length | `out` with `out[at..at+n-1]` replaced by `src[from..from+n-1]` | see [Range copies](#range-copies) |
| `copy_back(out, at, off, n)` | an array and three `i64`: index, offset, length | `out` with `out[at + j] = out[at + j - off]` for `j` in `0..n-1`, in order (an LZ match) | see [Range copies](#range-copies) |

`length/1`, `byte_size/1` and `tuple_size/1` are
[`unknown-function`](compile-errors.md#unknown-function) with the hint to use `len/1`.

Other `:math` functions are written from the builtins, or computed in
Elixir. `log2` and `log10` call the same libm function as `:math.log2/1` and
`:math.log10/1`, so they agree with `:math` bit for bit (not so
`log(x) / log(2.0)`, which can differ in the last bit).

`dbg/1` and `IO.inspect/1,2` are accepted around an expression: native code
evaluates the expression and ignores the call, and Elixir mode prints it (see
[section 10](#10-elixir-mode)).

### Bitwise operators

On `i64` (and on `u64`, see [u64](#u64)): `band(a, b)`, `bor`, `bxor`, `bnot(a)`, `bsl(a, n)`, `bsr(a, n)`,
also written `a &&& b`, `|||`, `^^^`, `~~~a`, `<<<`, `>>>`, or
`Bitwise.band(a, b)`; no `import Bitwise` is needed. Results are Elixir's:
`band`/`bor`/`bxor`/`bnot` are two's complement. `bsl`/`bsr` shift exactly: a
negative shift goes the other way, `bsr` fills with the sign (a shift of 64
or more gives 0 or -1), and `bsl` raises `ArithmeticError` when the exact
result does not fit in i64, where Elixir would return a bignum (a limit, see
[shift-overflow](compile-errors.md#shift-overflow)). Operands must be `i64`; `bool` and `f64`
are rejected ([operand-type](compile-errors.md#operand-type)). `band` with a constant mask
gives the compiler a range: `table[band(h, 255)]` skips its bounds check
against a 256-element array. Elixir 1.20 deprecates `~~~` and `^^^`; prefer
`bnot/1` and `bxor/2`. (defk-w38)

### Bit builtins

Each bit builtin is a plain function in `Defk.Bits` with a doctest, which
Elixir mode calls and plain Elixir can call too, so the kernel, Elixir mode
and your own Elixir code give the same value. A kernel calls them by their
bare names (`clz(x, 32)`) or as `Defk.Bits.clz(x, 32)`.

`clz(x, w)`, `ctz(x, w)`, `rotl(x, n, w)` and `rotr(x, n, w)` take a width:
x is a w-bit value, w is 1 to 64 and x is in 0..2^w - 1 (an `i64` or a
`u64`), and anything else raises `ArgumentError` ("Defk.Bits.clz/2: width
65 is not in 1..64", "... 256 does not fit in a 8-bit field"), as the
Elixir functions do. `rotl`/`rotr` rotate by `n` modulo `w` (any `i64` n)
and give x's type, so a 32-bit hash rotates as 32 bits in an `i64`
(`rotl(k, 15, 32)` is MurmurHash3's `ROTL32(k, 15)`) and a 64-bit one in a
`u64`. `f64_to_u64(x)` is the bits of a float, `<<b::64>> = <<x::float-64>>`.
(defk-wlu)

`mulhi(a, b)`, `clz(x)`, `ctz(x)`, `popcount(x)`, `rotl64(x, n)` and
`rotr64(x, n)` work on the u64 bit pattern of an `i64` (`clz`, `ctz` and
`popcount` also take a `u64`) and return an `i64` (a pattern, so a value
with the top bit set is negative):

- `mulhi` is the high 64 bits of the unsigned 128-bit product, as
  `band(bsr(ua * ub, 64), 2^64 - 1)` on the unsigned values, then
  `Defk.Bits.wrap64/1`. It is the half of a 64x64 multiply that
  `wrap64(a * b)` drops (xxh3, Murmur3-128).
- `clz` and `ctz` count leading and trailing zero bits: 0 to 64, and 64 for 0
  (the C builtins are undefined there; the kernel guards it).
- `popcount` counts set bits: 0 to 64. The three counts give the compiler the
  range 0..64.
- `rotl64` and `rotr64` rotate the 64-bit pattern by `band(n, 63)`, so `n`
  may be any `i64`, negative included.

Operands must be integers; `f64` and `bool` are rejected
([builtin-arguments](compile-errors.md#builtin-arguments)). None of these six can raise.
(defk-52v.6)

### Hardware builtins

A hardware builtin is a bit builtin with an exact integer meaning in
`Defk.Bits` (which Elixir mode calls) that some CPUs compute in one
instruction. The kernel uses the instruction where the CPU running it has
one, and a portable C version elsewhere: **the value is the same on every
CPU, only the speed differs.** The choice is made at run time, once per
kernel library (at its first call of the builtin), so a portable build
never needs an architecture flag and never runs an instruction the CPU
lacks. There is one so far, `crc32c/3`. (defk-ulk.4)

`crc32c(crc, x, w)` is one CRC32C (Castagnoli) step: the CRC register
`crc` after the `w` bits of `x`, as `w / 8` bytes, least significant byte
first, with the reflected polynomial 0x82F63B78 and no inversion. That is
exactly what the ARMv8 `CRC32CB/H/W/X` and the SSE4.2 `crc32` instructions
compute. `w` is 8, 16, 32 or 64, `crc` is in 0..2^32 - 1 and `x` in
0..2^w - 1 (an `i64` or a `u64`), and anything else raises `ArgumentError`
("Defk.Bits.crc32c/3: width 12 is not 8, 16, 32 or 64", "... 256 does not
fit in a 8-bit field"), as the Elixir function does. The result is an
`i64` in 0..2^32 - 1. The standard CRC-32C of a message (iSCSI, ext4, Kafka
record batches) starts from `0xFFFFFFFF` and inverts the end:

```elixir
defk crc32c_of(b :: [u8]) :: i64 do
  n = len(b)
  words = n - rem(n, 8)

  crc =
    for i <- 0..(words - 8)//8, reduce: 0xFFFFFFFF do
      crc -> crc32c(crc, band(u64_le(b, i), 0xFFFFFFFFFFFFFFFF), 64)
    end

  crc =
    for i <- words..(n - 1)//1, reduce: crc do
      crc -> crc32c(crc, b[i], 8)
    end

  bxor(crc, 0xFFFFFFFF)
end
```

```elixir
iex> M.crc32c_of("123456789")
0xE3069283
iex> M.crc32c_of(<<>>)
0
```

`u64_le/2` gives the word as its signed `i64` pattern, so a word with the
top bit set is negative and does not fit in 64 bits; `band(..., 0xFFFFFFFFFFFFFFFF)`
makes it the `u64` value, at no cost. One step waits for the previous one
(3 cycles on an Apple M4), so this loop runs at about 10 GB/s; three
independent streams joined at the end run at about 28 GB/s, level with the
crc32cer NIF (`examples/hashes.exs` has that kernel, and
[Performance notes](performance.md), 6.21 and 6.22, the numbers).

Which implementation runs, and what it costs, depends on the CPU:

| Target | `crc32c/3` runs | Measured, 4 MB, three streams |
|---|---|---|
| arm64 macOS (every Apple CPU) | the CRC32C instruction | 0.15 ms (27 GB/s), 0.9x crc32cer, 17x Elixir slicing-by-8 |
| arm64 Linux with the CRC extension (all ARMv8.1 and later, most v8.0 servers; `getauxval(AT_HWCAP) & HWCAP_CRC32`) | the CRC32C instruction | 0.19 ms (GCC 14, Debian, in a Linux VM on the same M4; the table 0.72 ms); no Linux arm64 hardware timed |
| x86-64 with SSE4.2 (every x86-64 CPU since 2008; checked with CPUID) | `crc32` | compiled and checked, not timed on x86 hardware |
| anything else, or `DEFK_PORTABLE_BUILTINS=1` | a slicing-by-8 table step | 0.68-0.70 ms (6 GB/s), 3.8x Elixir |

The check and the branch to the instruction cost nothing measurable (0.389
vs 0.390 ms for 4 MB one word at a time, with and without them). On a CPU
without the instruction the table is about 4.5x slower than the
instruction, and still faster than the same table in Elixir.

- `Mod.__defk_stats__().crc32c` tells which one a kernel library picked:
  `:instruction`, `:table`, or `:not_called` before its first call.
- Setting `DEFK_PORTABLE_BUILTINS` to anything but `""` or `"0"` (in the
  shell, or with `System.put_env/2` before the library's first call) makes
  the library use the table, to test or measure the fallback on a CPU that
  has the instruction.

### Masked arithmetic

**Supported:** integer arithmetic inside `band(expr, m)`, where `m` is
2^k - 1 for 1 <= k <= 64, written as an integer literal (`255`,
`0xFFFFFFFF`, `0xFFFFFFFFFFFFFFFF`), an integer module attribute, or a
constant expression of literals such as `(1 <<< 64) - 1`; and inside
`wrap64(expr)`, the 64-bit wrap to an `i64` pattern. This is how hashes and
checksums wrap:

```elixir
@mask64 0xFFFFFFFFFFFFFFFF

defk fnv1a64(bytes :: [u8]) :: u64 do
  for b <- bytes, reduce: 0xCBF29CE484222325 do
    h -> band(bxor(h, b) * 0x100000001B3, @mask64)
  end
end
```

```elixir
iex> M.fnv1a64("")
14695981039346656037
iex> M.fnv1a64("a")
12638187200555641996
```

The rule, the same in native code and Elixir mode:

- The **wrapped tree** is the contiguous tree of `+`, `-` (binary and
  unary), unary `+`, `*`, `band`, `bor`, `bxor`, `bnot` and `bsl` (in any
  spelling: `<<<`, `&&&`, `Bitwise.bsl/2`, ...) directly under the mask (or
  directly inside `wrap64`). These nest freely: the low k bits of each
  depend only on the low k bits of its operands. Either `band` operand may
  be the mask (`band(255, x + y)`).
- Every other expression inside it is a **leaf**: a variable, a literal, an
  array read, a word load, a call, `div`/`rem`, `bsr`, and a `bsl` by a
  negative literal. `div`, `rem` and `bsr` would bring high bits down, so
  they take values that are already in range: their operands are lowered as
  usual, with their own checks, outside the tree. A leaf may be an `i64` or
  a `u64`; its value enters the tree. So `band(x * y + rem(x * y, 7), 255)`
  wraps the outer `*` and `+` but raises if the `x * y` inside `rem`
  overflows, and a rotation is `band(bor(bsl(x, r), bsr(x, 64 - r)), @mask64)`
  with `x` a `u64` variable.
- The tree is computed with wrapping 64-bit machine arithmetic, with no
  overflow check, and the mask is applied once. The low k bits are those of
  the exact result, so the value is Elixir's `band` of the bignum and nothing
  in the tree raises (`band(x + y, 255)` with `x + y` past the `i64` limit
  gives Elixir's answer). One exception: a `bsl` by a count that is not a
  literal raises `ArithmeticError` when the count is negative (a limit: it
  would shift high bits down); a count of 64 or more gives 0.
- **Recognition is syntactic:** the arithmetic must sit inside the visible
  `band(...)`. `x = h * p` followed by `band(x, @mask64)` computes `h * p`
  checked, and raises there if it overflows (a limit: in Elixir `x` is a
  bignum); no mask is tracked through variables. Mixing an `i64` with a
  `u64` outside a mask is [`u64-mix`](compile-errors.md#u64-mix), whose hint shows the
  expression moved inside `band(..., 0xFFFFFFFFFFFFFFFF)`.
- **The result type:** the 64-bit mask gives a `u64` in 0..2^64 - 1, and
  `band(x, 0xFFFFFFFFFFFFFFFF)` of an `i64` x is the `i64` to `u64`
  conversion Elixir means (`band(-1, 0xFFFFFFFFFFFFFFFF)` is
  18446744073709551615). A narrower mask gives an `i64` in 0..m, so
  `table[band(h * 31 + b, 255)]` skips its bounds check against a 256-element
  array.
- `wrap64(expr)` gives the low 64 bits of the exact result as a signed
  `i64` (two's complement). Its Elixir meaning is the function
  `Defk.Bits.wrap64/1` (`<<r::signed-64>> = <<x::64>>`), which Elixir mode
  calls on the exact result and which you can call from plain Elixir for the
  same value. `wrap64` of a leaf (`wrap64(x)`) is `x` (a `u64` x gives its
  `i64` pattern).
- A `band` whose other operand is not 2^k - 1, such as `band(x * y, 254)`,
  `band(x * y, -1)` (Elixir's identity) or `band(x * y, m)` with a variable
  `m`, is an ordinary `band`: its operand is checked arithmetic and raises on
  overflow.

A mask keeps the low bits and drops the rest without raising, in both
modes, as Elixir's `band` does. A decoder that must reject values wider than
the mask checks for it: an LEB128 varint decoder that masks to 64 bits
accepts an over-long varint (11 bytes or more) and returns its low 64 bits,
so it should raise when the shift reaches 64.

MurmurHash3's 32-bit mixing stays in `i64` with 32-bit masks:

```elixir
defk mix32(h :: i64, k :: i64) :: i64 do
  k = band(rotl(band(k * 0xCC9E2D51, 0xFFFFFFFF), 15, 32) * 0x1B873593, 0xFFFFFFFF)
  band(rotl(bxor(h, k), 13, 32) * 5 + 0xE6546B64, 0xFFFFFFFF)
end
```

```elixir
iex> M.mix32(0, 1)
651101558
```

(defk-n4r.2, defk-wlu)

### Binary literals

**Supported:** a string literal `"abc"` (its UTF-8 bytes) and `<<1, 2, 3>>`
with integer-literal segments (each `0..255`, optionally `::8` or
`::size(8)`) are a `[u8]`, the same value a binary module attribute
is: indexed (out of range raises `Enum.OutOfBoundsError`), measured with
`len/1`, iterated with `for x <- "abc"`, bound to a variable, passed to a
kernel, compared byte by byte in a loop. Natively it is a static const view in
the NIF: no allocation and no copy, and its length is known, so
`"0123456789abcdef"[band(x, 15)]` has no bounds check. In Elixir mode it is
the binary itself. `""` and `<<>>` are a zero-length array (`len` is 0, any
index raises); `<<>>` is also where a [bitstring
accumulator](#the-bitstring-accumulator) starts.

```elixir
defk hex_digit(x :: i64) :: i64 do
  "0123456789abcdef"[band(x, 15)]
end

defk starts_with?(s :: [u8], p :: [u8]) :: bool do
  if len(p) > len(s) do
    false
  else
    for i <- 0..(len(p) - 1)//1, reduce: true do
      acc -> acc and s[i] == p[i]
    end
  end
end

defk is_ham?(s :: [u8]) :: bool, do: starts_with?(s, "Ham")
```

```elixir
iex> M.hex_digit(255)
102
iex> M.is_ham?("Hamburg")
true
iex> M.starts_with?("Ha", "Ham")
false
```

A write to a literal bound to a variable copies it first, like an input
array's ([Copies](#copies)); a literal cannot be returned unwritten
([`return-input-array`](compile-errors.md#return-input-array)), and it is not a `case`
pattern.

**Unsupported:** interpolation, charlists (`'abc'`, `~c"abc"`; write
`"abc"`), a segment that is a float, a variable, a string, a value outside
`0..255`, or any type or size other than 8-bit integer
([`binary-literal`](compile-errors.md#binary-literal)); build it in Elixir and pass it as a
`[u8]` parameter, or use a module attribute. `<>` and `~s` are
[`unsupported-string`](compile-errors.md#unsupported-string). (defk-n4r.5)

### The bitstring accumulator

**Supported with restrictions.** A kernel builds output whose length depends
on the data, such as a compressed bit stream, the way Elixir code does: a
local that starts as `<<>>` and is only appended to, then returned as a
bitstring (the signature type is `bitstring`).

```elixir
defk pack(xs :: [i64], n :: i64) :: bitstring do
  for x <- xs, reduce: <<>> do
    acc -> <<acc::bitstring, x::size(n)>>
  end
end
```

```
iex> M.pack(<<1::64-native, 2::64-native, 3::64-native>>, 3)
<<41, 1::size(1)>>
```

- **Appending.** `<<acc::bitstring, seg, ...>>` gives a new bitstring with
  the segments after `acc`'s bits. A segment is an `i64` expression `v` (or
  a [`u64`](#u64) one, up to `2^64 - 1`, in an unsigned segment) in 8
  bits, `v::k` with a literal `k`, or `v::size(n)` with any `i64` expression
  `n`; it is unsigned and big-endian (most significant bit first), Elixir's
  default, so `unsigned`, `big` and `integer` may be written and change
  nothing. The head, then every value and size, are evaluated left to right,
  then the segments are appended in order. Several segments in one append,
  sizes from 0 to 64, and any total length (not only whole bytes) are fine.
- **Starting.** `<<>>` bound to a variable the kernel appends to
  (`acc = <<>>`), or given as the initial value of an accumulator it appends
  to (`reduce: {<<>>, 0}`, `Enum.reduce_while(xs, <<>>, ...)`), is the empty
  bitstring. So is `<<>>` returned where the kernel returns a `bitstring`,
  or given by a branch whose other branches give a bitstring.
- **Where it can go.** A variable, a `for ..., reduce:` or
  `Enum.reduce_while/3` accumulator (alone or in a tuple), a branch of an
  `if`, `cond` or `case`, a called kernel's result (a kernel that returns a
  `bitstring` is inlined like any other, and the caller may append to what
  it returns), a called kernel's `bitstring` parameter (see below), and the
  kernel's result, alone or in a tuple.
- **Passing it to a kernel.** A kernel may take a `bitstring` parameter,
  append to it and return it, alone or in a tuple, so a step of the
  encoding can be its own kernel:

  ```elixir
  defk dod_bits(acc :: bitstring, dod :: i64) :: bitstring do
    cond do
      dod == 0 -> <<acc::bitstring, 0::1>>
      dod >= -64 and dod <= 63 -> <<acc::bitstring, 0b10::2, dod::7-signed>>
      true -> <<acc::bitstring, 0b11::2, band(dod, 0xFFFFFFFF)::32>>
    end
  end

  defk dods(ds :: [i64]) :: bitstring do
    for d <- ds, reduce: <<>> do
      acc -> dod_bits(acc, d)
    end
  end
  ```

  ```elixir
  iex> M.dods(<<0::64-native, -1::64-native, 100::64-native>>)
  <<0::1, 0b10::2, -1::7-signed, 0b11::2, 100::32>>
  ```

  Such a kernel may also be written as [clauses](#multi-clause-kernels).
  The call is inlined, so the parameter is the caller's accumulator under
  another name: appending to it appends in place, and a loop in the callee
  yields with the bits built so far kept. It is still a plain Elixir value:
  if the caller still holds what it passed, that value keeps its bits, as
  after any append to an older value. A variable passed to a `bitstring`
  parameter counts as appended to, so `<<>>` bound to it, or given as its
  initial value, is the empty bitstring (`dod_bits(<<>>, d)` too). A kernel
  that takes a bitstring has no function of its own (no NIF, nothing in
  `__defk_kernels__/0`): only a kernel has a bitstring to pass, so one that
  no kernel called from Elixir calls, directly or through other kernels, is
  [`bitstring-use`](compile-errors.md#bitstring-use).
- **Signed segments.** `v::size(n)-signed` and `v::k-signed` (the
  specifiers in any order) take a negative `v` and write its two's
  complement bits, which is what `band(v, 2^n - 1)::size(n)` also gives:
  `<<1::1, 0::1, dod::7-signed>>` appends the two flag bits and the 7-bit
  two's complement of `dod`. The value must be in `-2^(n-1)..2^(n-1) - 1`
  (see Limits), so `::1-signed` takes `-1..0` and `::64-signed` every `i64`.
  A signed segment of width 0 holds no bits and only 0 fits it, as an
  unsigned one. `signed` together with `unsigned` is
  [`bitstring-segment`](compile-errors.md#bitstring-segment).
- **Measuring.** `bit_size(acc)` is its number of bits, an `i64`. Pad to a
  whole number of bytes, if you need to, with an explicit append:
  `<<acc::bitstring, 0::size(rem(8 - rem(bit_size(acc), 8), 8))>>`.
- **Values.** As in Elixir, appending never changes an existing value: after
  `b = <<a::bitstring, 1::1>>`, `a` is still what it was, and appending to
  `a` again gives a bitstring unrelated to `b`. Natively the common
  `acc = <<acc::bitstring, ...>>` appends in place to a growable buffer
  (doubling as it fills); appending to an older value copies its bits first.
- **Limits.** A segment value outside `0..2^n - 1` raises `ArgumentError`
  "bitstring segment value v does not fit in n bits", where Elixir keeps the
  low `n` bits: mask it first (`band(v, 255)::8`), which also writes a
  negative value's two's complement bits. A `signed` segment's range is
  `-2^(n-1)..2^(n-1) - 1`, and its message ends "in n signed bits". A size outside `0..64` raises
  `ArgumentError` "bitstring segment size n is outside 0..64". Elixir mode
  raises both too. A value with the top bit of a 64-bit segment set is a
  negative `i64`, so it does not fit `::64`; append it as two 32-bit halves
  (`band(bsr(v, 32), 0xFFFFFFFF)::32, band(v, 0xFFFFFFFF)::32`).
- **Runtime.** The buffer belongs to the call: it is kept across yields, and
  freed when the kernel raises or its process dies, like an array the kernel
  allocated. The NIF copies the bits into a binary and returns it with the
  bit length; the kernel's generated Elixir function takes the bitstring
  from it as a sub-binary
  (`<<b::bitstring-size(len), _::bitstring>> = bin`). So a kernel returning
  a bitstring has its NIF registered as `__defk_native_<name>__`, as in
  Elixir mode.

**Unsupported, until a workload needs them** ([`bitstring-segment`](compile-errors.md#bitstring-segment),
[`bitstring-use`](compile-errors.md#bitstring-use)): little- or native-endian, float,
binary, bitstring and UTF segments; reading or indexing a bitstring
(`acc[i]`, `len(acc)`, `for b <- acc`; a `<<...>> = acc` match is
[`bitstring-match`](compile-errors.md#bitstring-match)); starting from
an input binary (`<<input::bitstring, ...>>` with `input :: [u8]`); a
`bitstring` parameter of a kernel called from Elixir; and passing a
bitstring where a kernel takes another type. (defk-cmr, defk-ooq)

### Module attributes

**Supported:** `@name` in a kernel body reads a module attribute as a
constant, with the value it has where the kernel is defined, as in a `def`
(an attribute redefined after the kernel does not change it). The value is
inlined when the module compiles, the same in native code and Elixir mode:

| Attribute value | In the kernel |
|---|---|
| an integer in `i64` | that integer literal, `i64` |
| an integer in 2^63..2^64 - 1 (`@mask64 0xFFFFFFFFFFFFFFFF`) | that integer literal, `u64` |
| a float | that float literal, `f64` |
| `true`, `false` | that boolean literal |
| a binary | a `[u8]` array of its bytes, kept in the kernel's static data (a write copies it) |

An integer, float or boolean attribute works wherever its literal does: in
arithmetic, as a range bound or step, as a `case` pattern
(`case x do @lim -> ... end`) and in a guard. A mask attribute gives the
compiler the same range as a literal mask, so with `@mask 255`,
`table[band(h, @mask)]` skips its bounds check against a 256-element array.

```elixir
@s16_min -32_768
@s16_max 32_767
@table <<0, 1, 3, 7, 15, 31, 63, 127>>

defk clip(x :: i64) :: i64 do
  min(max(x, @s16_min), @s16_max)
end

defk ones(i :: i64) :: i64 do
  @table[band(i, 7)]
end
```

```elixir
iex> M.clip(40_000)
32767
iex> M.clip(-40_000)
-32768
iex> M.ones(10)
3
```

A binary attribute is an array like an input array: it can be indexed (a
read out of range raises `Enum.OutOfBoundsError`), measured with `len/1`,
iterated with `for c <- @table`, bound to a variable and passed to a kernel.
A write copies it first, like an input array's ([Copies](#copies)); it
cannot be returned unwritten ([`return-input-array`](compile-errors.md#return-input-array)),
and it is not a `case` pattern. Its bytes are compiled into the NIF, so a large table makes the
library larger, not the call slower.

**Unsupported:** an attribute that is not defined above the kernel
([`undefined-attribute`](compile-errors.md#undefined-attribute)), an integer outside `i64`
([`integer-literal`](compile-errors.md#integer-literal), a limit), and any other value: a
list, tuple, map, atom, `nil`, or a bitstring that is not whole bytes
([`attribute-value`](compile-errors.md#attribute-value)). An accumulating attribute
(`Module.register_attribute(__MODULE__, :a, accumulate: true)`) is a list. A
list of bytes packs into a binary attribute (`@table <<1, 2, 4>>`); the error
shows that rewrite. (defk-ivt)

### What is not an expression

Each of these is a compile error with a code; the code's entry on the
[compile errors](compile-errors.md) page has an example and the rewrite.

| Construct | Code |
|---|---|
| maps, structs, `map.field` | [`unsupported-map`](compile-errors.md#unsupported-map) |
| string concatenation `<>`, the sigil `~s` | [`unsupported-string`](compile-errors.md#unsupported-string) |
| interpolation `"#{x}"`, charlists `'abc'`/`~c"abc"`, a `<<...>>` with a non-byte segment | [`binary-literal`](compile-errors.md#binary-literal) |
| atoms other than `true`/`false`, `nil` | [`unsupported-atom`](compile-errors.md#unsupported-atom) |
| lists, `++`, `--` | [`unsupported-list`](compile-errors.md#unsupported-list) |
| `fn`, captures `&f/1` (except the `fn` of `Enum.reduce_while/3`, `Enum.all?/2`, `Enum.any?/2`) | [`unsupported-fn`](compile-errors.md#unsupported-fn), [`fn-argument`](compile-errors.md#fn-argument) |
| the pipe `\|>` | [`pipe`](compile-errors.md#pipe) (the hint shows the nested call) |
| a module attribute holding a list, tuple, map, atom or `nil`, or not defined above the kernel | [`attribute-value`](compile-errors.md#attribute-value), [`undefined-attribute`](compile-errors.md#undefined-attribute) |
| binary patterns `<<a, b, rest::binary>> = arr` | [`bitstring-match`](compile-errors.md#bitstring-match) |
| calls to other modules (`Enum.sum/1`, `Enum.map/2`, `String.*`, `:math.tan/1`, ...) | [`unsupported-call`](compile-errors.md#unsupported-call), [`enum-reduce`](compile-errors.md#enum-reduce) and [`enum-find`](compile-errors.md#enum-find) (planned) |
| a range as a value (`r = 1..10`), `x in [1, 2, 3]`, `**`, a match used as a value | [`unsupported-expression`](compile-errors.md#unsupported-expression) |
| `unless`, `with`, `try`, `receive`, `reraise`, `throw`, `send`, `spawn`, ... | [`unsupported-construct`](compile-errors.md#unsupported-construct) |
| `raise` with an interpolated or computed message, of another module, or used as a value | [`raise-message`](compile-errors.md#raise-message), [`raise-module`](compile-errors.md#raise-module), [`raise-value`](compile-errors.md#raise-value) (see [`raise`](#raise)) |
| a call to a function that is neither a builtin nor a kernel of this module (`while`, `length`) | [`unknown-function`](compile-errors.md#unknown-function) |

### Unsupported, write this instead

The forms a developer writes first that the subset rejects, with the form
that compiles. The error for each says the same.

| Written first | Write instead | Code |
|---|---|---|
| `a \|> f(b)` | `f(a, b)` | [`pipe`](compile-errors.md#pipe) |
| `Enum.sum(a)`, `Enum.max(a)` over an array or range | `for x <- a, reduce: 0.0 do acc -> acc + x end` | [`unsupported-call`](compile-errors.md#unsupported-call) |
| `Enum.min([a, b, c])` | `min(min(a, b), c)` | [`unsupported-call`](compile-errors.md#unsupported-call) |
| `for {x, i} <- Enum.with_index(a)` | `for i <- 0..(len(a) - 1)//1` and `x = a[i]` in the body | [`generator-pattern`](compile-errors.md#generator-pattern) |
| `for x <- a, do: x * 2` as a value, or `for ..., into:` | `out = alloc(f64, len(a))`, a `for` that writes `out[i]`, then `out` | [`for-collect`](compile-errors.md#for-collect) |
| `[x \| acc]` then `Enum.reverse(acc)` to build a result of unknown length | append to a [bitstring accumulator](#the-bitstring-accumulator) started at `<<>>`: `<<acc::bitstring, x::64>>`, read in Elixir with `for <<x::64 <- out>>, do: x`; or `alloc` the largest size and return `{out, count}` | [`unsupported-list`](compile-errors.md#unsupported-list) |
| `<<a, b, _::16, rest::binary>> = arr` | indexed reads `a = arr[0]`, `b = arr[1]` | [`bitstring-match`](compile-errors.md#bitstring-match) |
| `<<b::64>> = <<x::float-64>>` | convert in Elixir before the call | [`bitstring-match`](compile-errors.md#bitstring-match) |
| `x ** 2` | `x * x`, or `pow(x, 2)` for a float | [`unsupported-expression`](compile-errors.md#unsupported-expression) |
| `x in [1, 2, 3]` | `x == 1 or x == 2 or x == 3` | [`unsupported-expression`](compile-errors.md#unsupported-expression) |
| `Enum.all?(a, &(&1 > 0))` | `Enum.all?(a, fn x -> x > 0 end)` | [`fn-argument`](compile-errors.md#fn-argument) |
| `length(a)`, `byte_size(a)` | `len(a)` | [`unknown-function`](compile-errors.md#unknown-function) |
| `unless c do ... end` | `if not c do ... end` | [`unsupported-construct`](compile-errors.md#unsupported-construct) |
| a map of counters, `Map.update(m, k, 1, &(&1 + 1))` | an array indexed by the key: `counts = alloc(i64, 256)`, `counts[k] = counts[k] + 1` | [`unsupported-map`](compile-errors.md#unsupported-map) |
| `xs :: list(float)` | `xs :: [f64]`, packed in Elixir with `for x <- xs, into: <<>>, do: <<x::float-64-native>>` | [`unknown-type`](compile-errors.md#unknown-type) |
| `:: String.t()` as a result | `:: [u8]`: it reaches Elixir as a binary, text if the bytes are | [`unknown-type`](compile-errors.md#unknown-type) |

## 5. Variables and binding

**Supported:** `name = expr`. A variable may be rebound; each binding is a new
value, as in Elixir.

- **Scope is Elixir's.** A variable bound inside an `if`, `case`, `cond` or
  `for` body is not visible after it, and rebinding an outer variable there
  does not change it outside:

  ```elixir
  defk rebind(n :: i64) :: i64 do
    x = 0

    for i <- 0..n//1 do
      x = x + i
    end

    x
  end
  ```

  ```elixir
  iex> M.rebind(5)
  0
  ```

  Carry a value out of a loop with `reduce:` (see
  [section 7](#7-control-flow)).
- **A plain parenthesised block does not scope**, as in Elixir:
  `(x = a + 1; x); x * 2` sees `x`, so macro-generated bodies that arrive as
  a nested block work. This holds for a block used as a statement, as the
  right side of a match, or as the last expression of a block; a block nested
  deeper inside an expression (an operand, an argument) keeps its bindings to
  itself.
- **`_` and `_name`** discard the value, but the right side is still
  evaluated, so `_ = x * x` raises on overflow as Elixir would.
- **Tuple destructuring:** `{a, b} = expr`, where `expr` gives a tuple (a
  tuple literal, a `reduce:` with a tuple accumulator, an
  `Enum.reduce_while`, a call to a kernel that returns one). `{a, b} = {b, a}`
  swaps. The sizes must match
  ([`tuple-size`](compile-errors.md#tuple-size)).
- **Unsupported:** binding a whole tuple to one variable
  ([`tuple-binding`](compile-errors.md#tuple-binding)), other patterns such as lists and maps
  ([`unsupported-pattern`](compile-errors.md#unsupported-pattern)), binary patterns
  ([`bitstring-match`](compile-errors.md#bitstring-match)), a match used as a value
  (`x = y = 1`, [`unsupported-expression`](compile-errors.md#unsupported-expression)), and an
  undefined variable ([`undefined-variable`](compile-errors.md#undefined-variable)).
- **Arrays are values.** `b = a` binds `b` to the array `a` has; a later
  write to `a` gives `a` a new array and leaves `b` as it was, as in Elixir
  (see [Copies](#copies) for what that costs: usually nothing).
- **An array variable bound again inside a loop body** is, as in Elixir,
  gone after the loop. Reading it after the loop would give the array from
  before the loop, which is never what the code means, so it is a compile
  error ([`array-rebind-in-loop`](compile-errors.md#array-rebind-in-loop)): write the array's
  elements instead (`a[i] = v`, which does carry over), carry the array as
  a `reduce:` accumulator, which is how a rebound array such as
  `{slots, n} = insert(slots, ...)` reaches the next iteration (see
  [Array accumulators](#array-accumulators)), or use a new name inside the
  loop. Binding it again in an `if` or `case` branch follows Elixir's
  scoping like any variable.

## 6. Arrays

An **array** is a kernel value holding elements of one element type; to the
caller it is a binary of native-endian values of that type.

### Reading

**Supported:** `a[i]`, with an `i64` index
([`type-mismatch`](compile-errors.md#type-mismatch) for an `f64` index,
[`not-an-array`](compile-errors.md#not-an-array) when `a` is not an array).

An index outside `0..len(a) - 1`, including a negative one, raises
`Enum.OutOfBoundsError` with the index:

```elixir
defk get(a :: [f64], i :: i64) :: f64 do
  a[i]
end
```

```elixir
iex> M.get(<<1.0::float-native>>, 1)
** (Enum.OutOfBoundsError) index 1 out of bounds for array of length 1
```

The check is left out where the compiler proves the index in range, for
example `i <- 0..(n - 1)//1` with `n = min(len(a), len(b))`, a
`for x <- a` generator, a `[u8]` value indexing a 256-element `alloc`, or
`out[2 * i + 1]` with `out = alloc(u8, 2 * len(a))` and
`i <- 0..(len(a) - 1)//1` (a literal multiple or `div` by a literal of a
length). That changes speed, never results.

### Word loads

**Supported:** `u64_le(bytes, i)`, `u32_le(bytes, i)`, `u16_le(bytes, i)`
and the big-endian `u64_be`, `u32_be`, `u16_be` read the unsigned 8-, 4- or
2-byte integer at byte offset `i` of a `[u8]`, as Elixir's

<!-- defk-example skip: a pattern shown for comparison, with free variables (bytes, i) -->
```elixir
<<_::binary-size(i), x::little-unsigned-size(64), _::binary>> = bytes
```

- `bytes` must be a `[u8]` and `i` an `i64`
  ([`builtin-arguments`](compile-errors.md#builtin-arguments) otherwise).
- The result is an `i64`. `u32_*` and `u16_*` are exact (0..2^32 - 1,
  0..65535). **`u64_*` returns the 64 bits as a signed `i64`**: a value with
  the top bit set is negative (`u64_le(<<255, 255, 255, 255, 255, 255, 255,
  255>>, 0)` is `-1`), in native code and Elixir mode alike: the builtin is
  defined as the signed reinterpretation of the word, `Defk.Bits.wrap64/1`
  of the unsigned value (see [Limits](#12-limits)). Mix it into a hash with
  masked arithmetic or `wrap64`, where only the bits matter;
  `band(u64_le(b, i), 0xFFFFFFFFFFFFFFFF)` is the unsigned word as a `u64`.
- `i < 0` or `i + width > len(bytes)` raises `Enum.OutOfBoundsError` with
  index `i`, like `a[i]`: "8-byte load at index 5 out of bounds for array of
  length 8".
- The check is left out where the compiler proves `0 <= i` and
  `i + width <= len(bytes)`, as in `for i <- 0..(len(b) - 8)//1` (or
  `//8`) followed by `u64_le(b, i)`. A `u16_*` value indexes a
  65536-element `alloc` without a check.
- The load is unaligned and compiles to one machine load (plus a byte swap
  for the other byte order).

```elixir
defk sum_words(b :: [u8]) :: i64 do
  for i <- 0..(len(b) - 8)//8, reduce: 0 do
    acc -> wrap64(acc + u64_le(b, i))
  end
end
```

```elixir
iex> M.sum_words(<<1::64-little, 2::64-little, 7>>)
3
iex> M.sum_words(<<-1::64-little, 1::64-little>>)
0
```

(defk-n4r.2)

### Range copies

**Supported:** `out = copy(out, at, src, from, n)` and
`out = copy_back(out, at, off, n)` replace a range of `out` with elements
from `src`, or from `out` itself, at the cost of one check for the whole
range. They are what a decoder copies with: a literal from its input, a
match from earlier output. `copy` is Elixir's

<!-- defk-example skip: a pattern shown for comparison, with free variables (out, src, at, from, n, w) -->
```elixir
<<pre::binary-size(at * w), _::binary-size(n * w), post::binary>> = out
<<pre::binary, binary_part(src, from * w, n * w)::binary, post::binary>>
```

- `copy(out, at, src, from, n)` gives `out` with `out[at..at+n-1]`
  replaced by `src[from..from+n-1]` (the Elixir above, `w` the element
  size). `src` is read as it was before the call, so it may be `out`
  itself: overlapping ranges move as `memmove` does.
- `copy_back(out, at, off, n)` gives `out` after
  `out[at + j] = out[at + j - off]` for `j = 0, 1, ..., n - 1`, **in that
  order**. When `off < n` the range overlaps what it writes and the `off`
  elements before `at` repeat (`copy_back(<<1, 2, 3, 0, 0, 0, 0>>, 3, 3, 4)`
  gives `<<1, 2, 3, 1, 2, 3, 1>>`; offset 1 is a run of one element). This
  is the LZ77 match of LZ4, Snappy and Deflate, and it is **not** `memmove`,
  which would copy the old bytes. Elixir mode computes it with
  `:binary.copy/2` of the `off`-element pattern.
- Both work on any element type: `out` and `src` must have the same one, and
  the positions and length are elements, not bytes
  ([`builtin-arguments`](compile-errors.md#builtin-arguments) otherwise).
- A negative `n` raises `ArgumentError` "copy/5: negative length -1". A
  range outside an array raises `Enum.OutOfBoundsError` with `index` the
  start of the range: "copy/5: 3 elements at index 8 out of bounds for
  array of length 10", then "... from index 4 out of bounds for source array
  of length 5". `copy_back` checks the destination range, then, when
  `n > 0`, the offset: `off < 1` raises `ArgumentError` "copy_back/4: offset
  0 is not positive", and `at - off < 0` raises `Enum.OutOfBoundsError` with
  index `at - off`. An empty copy (`n == 0`) reads nothing, so its offset is
  not checked (an LZ4 sequence with no match passes any). The checks never
  depend on the elements, so a copy from an input `[f64]` holding NaN bits
  copies them; reading one later raises as usual.
- They are array writes, with the [Copies](#copies) rules of a kernel that
  writes and returns its array parameter: the result is written into `out`'s
  buffer in place when nothing reads the old `out` after the call (the usual
  case, `out = copy(out, ...)` in a loop accumulator), and into a copy of it
  otherwise (an input array, or `b = out` read later).
- Natively a copy is a few loads and stores (up to 32 bytes) or `memmove`;
  `copy_back` with `off < n` copies 8-byte words from at least 8 bytes back
  (after at most 7 single bytes when `off < 8`). A copy of up to 1 MiB runs at
  once and counts towards the next safepoint like a loop over its bytes; a
  longer one runs in 1 MiB strips with a safepoint after each, so a 100 MB
  copy yields like a loop (`yield: false` kernels copy at once).

```elixir
defk unpack(lits :: [u8], seqs :: [i64], size :: i64) :: [u8] do
  out = alloc(u8, size)

  {out, _, _} =
    for s <- 0..(div(len(seqs), 3) - 1)//1, reduce: {out, 0, 0} do
      {out, ip, op} ->
        ln = seqs[3 * s]
        out = copy(out, op, lits, ip, ln)
        out = copy_back(out, op + ln, seqs[3 * s + 1], seqs[3 * s + 2])
        {out, ip + ln, op + ln + seqs[3 * s + 2]}
    end

  out
end
```

```elixir
iex> seqs = for x <- [2, 0, 0, 1, 1, 4], into: <<>>, do: <<x::signed-64-native>>
iex> M.unpack("abc", seqs, 7)
"abccccc"
```

(defk-52v.16; `examples/lz4_snappy_decode.exs` decodes with them.)

### Allocating

**Supported:** `alloc(type, n)`, with `type` one of `f64`, `f32`, `i64`,
`i32`, `i16`, `u8`, `u64`, returns a new array of `n` elements, all zero. A
malformed call is [`alloc-form`](compile-errors.md#alloc-form).

- A negative `n` raises `ArgumentError` "alloc/2: negative length n".
- More than 2^48 bytes (the user address space of 64-bit platforms) raises
  `ArgumentError` "alloc/2: length too large". A size under that which the
  allocator cannot provide raises `ArgumentError` "out of memory".
- Every array a kernel allocates lives until the kernel returns; an `alloc`
  inside a loop allocates on every iteration, and keeps every one of those
  arrays until then (the fast-path report notes such an `alloc`). Arrays
  that are not returned are freed when the kernel returns or raises, or when
  its process dies while it is suspended. A call that would hold more than
  its [owned-buffer budget](#the-owned-buffer-budget) raises
  `ArgumentError` "out of memory".
- The zeroing yields like a loop: a large buffer is zeroed in strips with a
  safepoint after each, so an 85 MB `alloc` does not hold the scheduler.
  When the first statement after `x = alloc(type, k * n)` that mentions `x`
  is a `for i <- 0..(n - 1)//1` whose body writes `x[k * i + c]` for every
  `c` in `0..k-1` (not in a branch) and mentions `x` nowhere else, and
  nothing in between rebinds a variable of `n`, every element is written
  before anything can read it, and the buffer is not zeroed at all (the
  fast-path report notes which allocs are). This is an optimisation:
  the array is all zeros wherever it is not written, either way.

### Writing

**Supported:** `a[i] = v` is a statement that stores `v` at index `i`
(bounds-checked like a read). It is the one array construct that is not
Elixir syntax, and its meaning is Elixir's value semantics: **the write gives
`a` a new array, from the write on, through the enclosing branches and loops;
every other variable keeps the array it had.** Elixir mode compiles it to
`a = put(a, i, v)` and threads `a` out of each branch and loop as an
accumulator.

- Any array variable can be written: one from `alloc/2`, a kernel's input
  array, a binary module attribute, an array a called kernel returned, or an
  array parameter of a called kernel (which must then return it, see
  [Calls to other kernels](#calls-to-other-kernels)). The caller's binary is
  never changed.
- The stored value must have the element type's wide type: `[f64]` and
  `[f32]` take an `f64`, an `i64` or a `u64` (widened), `[i64]`, `[i32]`,
  `[i16]`, `[u8]` and `[u64]` take an `i64` or a `u64`
  ([`type-mismatch`](compile-errors.md#type-mismatch) otherwise).
- A `[u64]` write of a negative value raises `ArgumentError` "value -1 does
  not fit in u64", and an `[i64]` write of a `u64` above 2^63 - 1 raises
  `ArgumentError` "value ... does not fit in i64" (limits, like the narrow
  ones below).
- A `[u8]` write of a value outside 0..255 raises `ArgumentError` "value 300
  does not fit in u8". Elixir's `<<300::8>>` would wrap; a kernel never
  wraps silently (a limit). Write `rem(v, 256)` for a non-negative `v` if
  wrapping is what you want. Likewise an `[i16]` write outside
  -32768..32767 raises "value 32768 does not fit in i16", and an `[i32]`
  write outside -2^31..2^31-1 "... does not fit in i32".
- An `[f32]` write rounds the `f64` to the nearest `f32`, as
  `<<v::float-32-native>>` does (`0.1` is stored as `0.10000000149011612`).
  A value that rounds to inf (`1.0e40`, or anything from
  `3.4028235677973366e38` up) raises `ArgumentError` "value ... does not fit
  in f32", where Elixir would store inf (a limit). Underflow is Elixir's:
  `1.0e-50` stores `0.0`, `1.0e-40` an `f32` subnormal.
- The range check is left out where the compiler proves the value fits, as
  for a clamp: `out[i] = max(min(a[i] + b[i], 32_767), -32_768)` into an
  `[i16]` stores without a check (and clang vectorises the loop to
  saturating adds, like the hand-written C).
- A write has no value, so it cannot end a block that needs one
  ([`write-as-value`](compile-errors.md#write-as-value)).

```elixir
defk histogram(bytes :: [u8]) :: [i64] do
  h = alloc(i64, 256)

  for b <- bytes do
    h[b] = h[b] + 1
  end

  h
end
```

```elixir
iex> h = M.histogram(<<1, 1, 255>>)
iex> {byte_size(h), :binary.part(h, 8, 8)}
{2048, <<2::64-native>>}
```

An input array is written the same way; here a HyperLogLog register update:

```elixir
defk update(regs :: [u8], idx :: [i64], ranks :: [i64]) :: [u8] do
  for k <- 0..(len(idx) - 1)//1 do
    j = idx[k]
    regs[j] = max(regs[j], ranks[k])
  end

  regs
end
```

```elixir
iex> regs = <<0, 3, 1, 0>>
iex> M.update(regs, <<0::64-native, 2::64-native>>, <<2::64-native, 5::64-native>>)
<<2, 3, 5, 0>>
iex> regs
<<0, 3, 1, 0>>
```

A count-min sketch update over `[u64]` hashes combines both: an input
`[u64]` table bumped in place (copied once, before the first write), and a
bucket index from a hash. `band(..., 0xFFFFFFFF)` keeps the per-row hash
`h1 + r * h2` inside a mask, where `u64` and `i64` mix freely, and gives an
`i64` in 0..2^32 - 1, so `rem(..., w)` takes the `i64` width (see
[Masked arithmetic](#masked-arithmetic)). Written by the cold test
(defk-sgw.3) from this document alone:

```elixir
defk update_many(sk :: [u64], d :: i64, w :: i64, hashes :: [u64]) :: [u64] do
  for h <- hashes do
    h1 = band(h, 0xFFFFFFFF)
    h2 = bsr(h, 32)

    for r <- 0..(d - 1)//1 do
      col = rem(band(h1 + r * h2, 0xFFFFFFFF), w)
      idx = r * w + col
      sk[idx] = sk[idx] + 1
    end
  end

  sk
end
```

```elixir
iex> sk = <<0::size(6 * 64)>>
iex> out = M.update_many(sk, 2, 3, <<4294967297::64-native, 4294967297::64-native>>)
iex> for <<c::64-native <- out>>, do: c
[0, 2, 0, 0, 0, 2]
```

### Copies

A write is in place, with no copy, when nothing else can see the array's
buffer afterwards. The compiler decides this from the code, with no reference
count at run time, and copies the buffer once, into an array the kernel owns,
where it cannot prove that:

- **An input array** (or a binary attribute) is copied before its first write.
  A write inside a loop or branch copies before that loop or branch statement
  starts, once, and also when the branch is not taken; the loop then writes
  the copy in place.
- **Another variable with the same buffer is read after the write** (`b = a`
  earlier, `b` read later): the written variable gets a copy before the
  write, or before the loop or branch statement holding the write. Inside a
  loop, "later" includes the next iterations, so `b = a` in a loop body with
  `a` written and `b` read after it copies on every iteration.
- **A loop over an array its body writes** (`for x <- a do a[j] = ... end`)
  walks the array as it was when the loop started: the written variable is
  copied before the loop. Walking an input array while writing it copies it
  twice.
- **A called kernel writes its array parameter** while the caller still reads
  the array it passed (after the call, or in a later iteration): the callee
  copies. When the caller rebinds the result instead
  (`{out, n} = fill(out, v)`), the callee writes the caller's array in place.
  That holds for a call in one branch of an `if`, `cond` or `case` whose
  other branch reads the array, as in an `Enum.reduce_while/3` fn that
  halts with `{:halt, {out, s + out[0]}}` and otherwise continues with
  `out = put(out, i)`: the other branch runs instead of the call, so its read
  is not a read after it, and the call writes in place on every iteration,
  as a write `out[i] = v` in that branch would. The same holds when the
  condition, `case` subject or clause head that chose the branch reads the
  array (`if out[0] == 5, do: {:halt, out}, else: (out = put(out, i); {:cont, out})`):
  it ran before the call, and the next iteration reads the call's result.
  The callee still copies when
  the array from before the call is read after the `if`, later in the same
  statement, through another variable (`old = out`), or, for an array bound
  outside a loop and rebound in a branch of its body, in the next iteration
  (where the name means the array from outside again).
- **An array accumulator** (see [Array accumulators](#array-accumulators))
  starts as a copy of its initial array when that is an input array, or
  when another variable with the same buffer is read in the loop or after
  it; and the array the body gives for the next iteration is copied on the
  same test (an input array, an array from outside the loop that the loop
  reads, or one array given to two accumulators). Otherwise the
  accumulator's buffer is the loop's alone and every write to it, in the
  body or in a called kernel that returns it, is in place. The loop's
  range (start, end and step of its first generator) and its initial value
  are evaluated once, before the first iteration, so reading the array
  there is not a read in the loop:
  `for k <- 0..(st[0] - 1)//1, reduce: st do st -> (st[k] = 0; st) end` and
  `Enum.reduce_while(0..st[0]//1, {st, st[1]}, fn ...)` write `st` in place,
  also as nested loops. An array the generator walks (`x <- st`), a later
  generator (evaluated again for each value of the ones before it) and a
  filter read the array while the loop runs, so there it still copies.

Renaming copies nothing: `b = a`, a swap `{prev, cur} = {cur, prev}`, passing
an array to a kernel and returning one are each a pointer move. So does a
write when the old array is not read again:

```elixir
defk snapshot(n :: i64) :: {f64, f64} do
  a = alloc(f64, n)
  b = a
  a[0] = 1.0
  {a[0], b[0]}
end
```

```elixir
iex> M.snapshot(1)
{1.0, 0.0}
```

Here `a` is copied at the write, because `b` is read after it; without the
`b[0]`, there is no copy. The test of "read after" is by variable name
through the rest of the block, and for a loop, everything its whole
statement reads; a branch of an `if`, `cond` or `case` leaves out what the
other branches read, since only one of them runs, and the condition, subject
or clause head that chose it, which ran before it. It is conservative, so a
kernel may copy where Elixir would not have to (for example when `b` is read
earlier in the loop body than the write, which is not a read after it).
The fast-path report (`Defk.Report`) notes each copy, and
`Mod.__defk_c_source__/0` shows them as `defk_copy_*` calls. Like `alloc`,
every copy lives until the kernel returns, so a copy in a loop body keeps
one array per iteration (the report notes that too), counted against the
[owned-buffer budget](#the-owned-buffer-budget).

### The owned-buffer budget

Every array a call allocates (`alloc/2`), every copy above, the buffer of a
[bitstring accumulator](#the-bitstring-accumulator) and the aligned copy of
a misaligned input are the kernel's own until it returns. Elixir would
garbage-collect an array no variable sees any more; a kernel frees them all
at once when it returns, raises, or its process dies. So a call keeps a
running total of the bytes it holds, and an allocation that would take it
past the module's budget raises `ArgumentError`:

```
** (ArgumentError) out of memory (allocating 1024 bytes would take this call's buffers past max_owned, 8192 bytes)
```

This keeps a runaway loop from exhausting the machine: an operating system
that overcommits memory kills the whole node long before an allocation
fails, which would break the [runtime contract](guides/runtime-contract.md).

- The budget is `use Defk, max_owned: bytes`, a positive integer (an
  expression such as `4 * 1024 ** 3` or a module attribute is fine), for
  every kernel of the module. Any other value is an `ArgumentError` when the
  module compiles.
- The default is half of the machine's physical memory, read once when the
  library loads: one call may build any result that fits comfortably in
  memory, and a loop that keeps a buffer per iteration raises before it
  takes the memory the node and the OS need. A fixed default would be too
  small on large servers or too large on small machines. In a container
  whose memory limit is below the host's, set `max_owned` (the default sees
  the host's memory). `Mod.__defk_stats__().max_owned` shows the budget.
- The count is per call: concurrent calls each have their own, a call
  after a raise starts from zero, and a yield keeps it. An array a kernel
  returns counts until it returns.
- It is a [limit](#12-limits) of native code only: Elixir mode does not
  know which arrays native code would still hold, so it never raises it.
- A single allocation of 2^47 bytes or more, which no allocator serves,
  raises the plain "out of memory (allocating N bytes)" of
  [Allocating](#allocating) instead, the same in both modes.

### Returning

**Supported with restrictions:** a kernel may return an array it created
or wrote (alone or in a result tuple); it reaches the caller as a binary
without a copy. Returning an input array it never writes is
[`return-input-array`](compile-errors.md#return-input-array) (not supported yet); the caller
already has it.

Arrays cannot be the value of an `if`, `cond` or `case`
([`array-in-branch`](compile-errors.md#array-in-branch), not supported yet). They can be a
`reduce:` or `Enum.reduce_while` accumulator, alone or in a tuple, which is
how an array rebound in a loop body is carried out of the loop (see
[Array accumulators](#array-accumulators)).

### Inputs

An array argument is read in place, without a copy. A binary whose data is not
aligned to the element size (for example a sub-binary at an odd byte offset)
is copied once, into an aligned buffer, when the kernel starts. Either way the
caller's binary is never changed: a write copies it first (see
[Copies](#copies)).

A binary whose byte size is not a multiple of the element size raises
`ArgumentError` at the call, before the kernel runs: "argument 1 (a): byte
size 5 is not a multiple of 4 (f32)". An `[f64]` or `[f32]` element whose
bits are inf or NaN raises `ArgumentError` when it is read, as Elixir's
`<<x::float-32-native>>` match fails on it; elements never read don't.

## 7. Control flow

### `if`

**Supported:** `if cond do ... else ... end` and `if cond, do: ..., else: ...`.
The condition must be a `bool` ([`operand-type`](compile-errors.md#operand-type); the hint shows
the comparison to write for a number).

- **As a value**, it needs an `else` ([`if-without-else`](compile-errors.md#if-without-else)),
  and both branches have one type ([`branch-types`](compile-errors.md#branch-types): convert
  with `float/1`, `trunc/1` or `round/1`). A branch may contain statements
  (array writes, loops) before its value, and the value may be a tuple
  (see [Tuples from branches](#tuples-from-branches)).
- **As a statement** (its value unused), `else` is optional and the branches
  may end in array writes.

Only the branch taken is evaluated, as in Elixir. (An `if` whose branches are
cheap arithmetic (`+ - *`, comparisons, `band`/`bor`/`bxor`, shifts) may be
compiled to compute both sides, so an untaken branch can still be evaluated;
an integer overflow in it never raises. A branch holding a division (`div/2`,
`rem/2`, or the float `/`), an array read or a call is never computed untaken:
the `if` is compiled to a real branch, which skips the division.)

### `cond`

**Supported with restrictions:** `cond do c1 -> v1; ...; true -> vn end`. A
`cond` always ends with a `true ->` clause
([`cond-without-true`](compile-errors.md#cond-without-true)), also when its value is unused,
and every clause has a value of one type. For branches that only write
arrays, use `if`/`else` or `case`.

### `case`

**Supported with restrictions:** `case` on an `i64` or `bool` subject, as a
value or a statement.

```elixir
defk classify(x :: i64, y :: i64) :: i64 do
  case x do
    ^y -> 0
    -1 -> 1
    n when n > 10 and rem(n, 2) == 0 -> n
    _ -> 2
  end
end
```

```elixir
iex> M.classify(3, 3)
0
iex> M.classify(12, 0)
12
iex> M.classify(11, 0)
2
```

- Patterns: integer literals (also negative), `true`/`false` for a `bool`
  subject, `^pinned` variables, `_`, and a variable, which binds the subject.
  A literal of the wrong type is [`case-pattern-type`](compile-errors.md#case-pattern-type);
  floats, tuples, ranges and several patterns per clause are
  [`case-pattern`](compile-errors.md#case-pattern); a subject of another type is
  [`case-subject`](compile-errors.md#case-subject).
- Guards (`when`): literals, variables, `+ - * /`, comparisons, `and`, `or`,
  `not`, `div`, `rem`, `abs`, `trunc`, `round`, `min`, `max`, and `in` /
  `not in` (below). Kernel calls, indexing and `&&`/`||` are
  [`case-guard`](compile-errors.md#case-guard) (Elixir rejects most of them in guards too).
- `in` in a guard: `x in [1, 2, 3]`, `x in 1..10`, `x in a..b//step`, and
  `not in`. The left side is any guard-safe `i64` expression (a `bool` with a
  list of `true`/`false`). The right side is
  - a literal list of integers or of booleans (written out: no variable, no
    `++`), lowered to `x === 1 or x === 2 ...`; an empty list matches nothing;
  - a range of integer literals, with or without a step (`10..1` counts down by
    one, as in Elixir). A step is a non-zero literal within
    +-9223372036854775807. A negative step counts down (`10..1//-3` is 10, 7,
    4, 1), and a range that cannot reach its last (`1..0//1`, `1..5//-1`) is
    empty. Membership is exactly that of `Enum.member?/2` for integers,
    computed at compile time (the last element is found, then `x >= first`,
    `x <= last` and a remainder test), so no runtime arithmetic can overflow;
  - a range with variable (guard-safe `i64`) bounds, which needs the explicit
    step `//1` or `//-1`: `x in a..b//1` is `a <= x <= b`. Without a step
    Elixir rejects it in a guard (its direction is only known at runtime), and
    any other step needs literal bounds, as the remainder test is built at
    compile time. Anything else on the right (a variable list, a list element
    that is not a literal, a float or a zero step) is
    [`case-guard`](compile-errors.md#case-guard), as is a left side of the wrong type (`1.0 in
    1..3` is false in Elixir, so a float is rejected, not compared).
- A subject no clause matches raises `CaseClauseError`, as in Elixir, so a
  catch-all is optional.
- An error inside a guard fails the guard, as in Elixir, and the next clause
  is tried: a zero divisor in `div`, `rem` or `/`, and a float result that is
  inf or NaN. The whole guard is false, so an error on the left of an `or`
  fails it too, while an operand a short-circuit skips never runs. Elixir mode
  does the same. A guard with no operation that can fail compiles as before.
  If no later clause matches, the case raises `CaseClauseError`.
- **Limit:** a guard result outside `i64` (`n * n > 100` at `n = 2^40`, `abs`
  of the minimum, a `trunc` out of range) is no error in Elixir, which has
  bignums, so it does not fail the clause: it raises `ArithmeticError`, as the
  same operation does outside a guard. When one guard has both a zero divisor
  and such a result, evaluated without a short-circuit between them
  (`rem(n, y) < n * n`), the kernel raises, where Elixir mode may fail the
  clause for the zero divisor it reaches first.

### Tuples from branches

**Supported with restrictions:** an `if`, `cond` or `case` used as a value may
give a tuple, when every arm is one of the same size
([`branch-tuple`](compile-errors.md#branch-tuple)):

```elixir
defk split(x :: i64, f :: f64) :: f64 do
  {n, g} =
    cond do
      x > 100 -> {x - 100, f}
      x < 0 -> {-x, -f}
      true -> {0, f * 0.5}
    end

  float(n) + g
end
```

```elixir
iex> M.split(150, 1.0)
51.0
iex> M.split(-3, 2.0)
1.0
iex> M.split(7, 3.0)
1.5
```

- Each element position has one type, checked on its own: `{x, f}` beside
  `{0, 0.5}` is an `{i64, f64}`, and `{x, f}` beside `{f, f}` is
  [`branch-types`](compile-errors.md#branch-types) for element 1.
- An arm may be any tuple value: a literal tuple, a block that ends in one,
  or a call to a kernel that returns one. The tuple is destructured at once,
  returned, or is the next accumulator of a `for ..., reduce:` (a variable
  cannot hold it, [`tuple-binding`](compile-errors.md#tuple-binding)).
- An element may be a bitstring accumulator, as a whole branch may: `{acc, n}`
  beside `{<<acc::bitstring, 1::1>>, n + 1}`. An array element is
  [`array-in-branch`](compile-errors.md#array-in-branch), as an array branch is.
- Natively each condition runs once and each element gets its own branch
  value; arms of plain arithmetic become one select per element, as a
  number branch does. Elixir mode runs the branch as written.

(defk-uew)

### `for`

**Supported with restrictions.** Generators:

- `x <- first..last` and `x <- first..last//step` over `i64` bounds.
- `x <- array`: each element in order, widened (a `[u8]`, `[i16]` or
  `[i32]` element is an `i64`, an `[f32]` element an `f64`, a `[u64]`
  element a `u64`).

Several generators nest, and filters (any `bool` expression) skip the rest of
the body. Without `reduce:`, a `for` is a statement and its body's value is
discarded. With `reduce:`, it is a fold whose value is the final accumulator:

```elixir
defk even_sum(n :: i64) :: i64 do
  for i <- 0..n//1, rem(i, 2) == 0, reduce: 0 do
    acc -> acc + i
  end
end
```

```elixir
iex> M.even_sum(10)
30
iex> M.even_sum(-1)
0
```

- `reduce:` takes one `acc -> body` clause
  ([`reduce-clauses`](compile-errors.md#reduce-clauses)). The accumulator may be a tuple,
  `{a, b} -> ...`, with an initial tuple of the same size
  ([`accumulator-shape`](compile-errors.md#accumulator-shape)); other accumulator patterns are
  [`accumulator-pattern`](compile-errors.md#accumulator-pattern). An accumulator, or a tuple
  element of one, may be an array (see
  [Array accumulators](#array-accumulators)).
- A `for` without `reduce:` used as a value, and `into:`, are
  [`for-collect`](compile-errors.md#for-collect); other options are
  [`for-option`](compile-errors.md#for-option); a generator over anything but a range or an
  array is [`generator-source`](compile-errors.md#generator-source); a pattern other than a
  variable on the left of `<-` is [`generator-pattern`](compile-errors.md#generator-pattern).
- `{:halt, acc}` in a `for ..., reduce:` is not early exit: as in Elixir, the
  tuple is the next accumulator.

**Range semantics are Elixir's:**

- `first..last` without a step counts down when `first > last`. So
  `0..(n - 1)` with `n = 0` visits `0` and `-1`; write `0..(n - 1)//1` for a
  range that may be empty.
- `first..last//step` with a positive step counts up and is empty when
  `first > last`; a negative step counts down. A literal step of 0 is
  [`range-step`](compile-errors.md#range-step); a step expression that is 0 at run time raises
  `ArgumentError` "range step cannot be zero".
- **Limit:** a range whose last element is within one step of the `i64` limit
  (`0..9223372036854775807`) raises `ArithmeticError` before its loop starts,
  even if the loop would stop earlier, because stepping past that element
  would overflow the loop counter.

### Early exit: `Enum.reduce_while/3`, `Enum.all?/2`, `Enum.any?/2`

**Supported with restrictions.** The enumerable is a range or an array, as in a
`for` generator, and the function is a literal one-clause `fn`
([`fn-argument`](compile-errors.md#fn-argument) for a capture).

```elixir
defk prime_early?(x :: i64) :: bool do
  Enum.all?(2..trunc(:math.sqrt(x))//1, fn d -> rem(x, d) != 0 end)
end
```

```elixir
iex> M.prime_early?(97)
true
iex> M.prime_early?(91)
false
```

- `Enum.reduce_while(src, init, fn x, acc -> ... end)`: the accumulator may be
  a tuple. **The tail rule:** every path through the `fn` body ends in a
  literal `{:cont, acc}` or `{:halt, acc}`, directly or through
  `if`/`else`, `cond` or `case` ([`reduce-while-tail`](compile-errors.md#reduce-while-tail)).
- A `{:halt, acc}` ends only the `Enum.reduce_while` it belongs to, also when
  it is nested in other loops or in a called kernel.
- `Enum.all?(src, fn x -> bool end)` and `Enum.any?/2` stop at the first
  element that decides the result; over an empty range or array they give
  `true` and `false`.
- There is no `while`, `break` or `return`, and no `Enum.reduce/3`
  ([`enum-reduce`](compile-errors.md#enum-reduce)) or `Enum.find`/`find_index`
  ([`enum-find`](compile-errors.md#enum-find)) yet.

### Array accumulators

**Supported:** an array, alone or as an element of a tuple accumulator, in
`for ..., reduce:` and `Enum.reduce_while/3`. This is how a loop body binds
an array again, typically through a kernel that writes it and returns it,
and carries the result to the next iteration and out of the loop:

```elixir
defk insert(slots :: [i64], counts :: [i64], key :: i64) :: {[i64], [i64], i64} do
  j = band(key, len(slots) - 1)
  new = if counts[j] == 0, do: 1, else: 0
  slots[j] = key
  counts[j] = counts[j] + 1
  {slots, counts, new}
end

defk tally(keys :: [i64]) :: {[i64], [i64], i64} do
  for k <- keys, reduce: {alloc(i64, 64), alloc(i64, 64), 0} do
    {slots, counts, n} ->
      {slots, counts, new} = insert(slots, counts, k)
      {slots, counts, n + new}
  end
end
```

```elixir
iex> {_slots, counts, n} = M.tally(<<1::64-native, 2::64-native, 1::64-native>>)
iex> {:binary.part(counts, 8, 16), n}
{<<2::64-native, 1::64-native>>, 2}
```

- The value the body gives (or the `acc` of `{:cont, acc}` and
  `{:halt, acc}`) is the accumulator of the next iteration, and after the
  last one the loop's value, as in Elixir. `tally` returns both tables.
- **The accumulator array is threaded in place.** Its buffer is the loop's
  own, so the body's writes, and those of a called kernel that returns it,
  go to that buffer, and `tally` copies nothing. The initial array, or a
  new value, is copied first only where another variable could see the
  change (see [Copies](#copies)): `tally(keys)` with
  `reduce: {slots0, ...}` copies `slots0` once, before the loop, if
  `slots0` is read after it.
- An array cannot be the value of an `if`, `cond` or `case`
  ([`array-in-branch`](compile-errors.md#array-in-branch)), so a body that changes the array
  only sometimes writes its elements in a branch, or calls the kernel that
  writes it on every iteration. In `Enum.reduce_while/3` each tail is its
  own value, so `if done, do: {:halt, {slots, n}}, else: {:cont, {slots, n + 1}}`
  works.
- Elixir mode runs the same `for ..., reduce:` or `Enum.reduce_while/3`,
  with the arrays as binaries.

(defk-n4r.10)

### `raise`

**Supported with restrictions:** `raise Module, "message"`, `raise Module`
and `raise "message"`, with `Module` one of `ArgumentError`,
`ArithmeticError` and `RuntimeError`. It raises what Elixir would: the
exception with that message, or the module's default message for
`raise Module` ("argument error", "bad argument in arithmetic expression",
"runtime error"), and `raise "message"` is a `RuntimeError`.

```elixir
defk fft_size(n :: i64) :: i64 do
  if n < 1 or band(n, n - 1) != 0, do: raise(ArgumentError, "n must be a power of two")
  ctz(n)
end
```

```elixir
iex> M.fft_size(1024)
10
iex> M.fft_size(12)
** (ArgumentError) n must be a power of two
```

- **A statement**, anywhere a statement goes: in a block before its value, in
  `if`/`case` statements, in a branch before the branch's value, in a loop
  body, and in an `Enum.reduce_while/3` `fn` before its tail. A `raise` as a
  value (`x = raise ...`, the last expression of a kernel, or a value
  branch that only raises, `if ok, do: v, else: raise(...)`) is
  [`raise-value`](compile-errors.md#raise-value): write the check as a statement first,
  `if not ok, do: raise(...)`, then the value. A `cond` whose arms only
  raise needs a value in each; write the checks as `if` statements instead.
- **The message is a string literal**, of any length and any bytes (also
  `raise Module, message: "..."`). Interpolation and computed messages are
  [`raise-message`](compile-errors.md#raise-message): the message is a C string in the
  kernel's static storage. Put the value in Elixir, before or after the
  call. Other modules are [`raise-module`](compile-errors.md#raise-module).
- Natively the exception is raised in the calling process like the
  kernel's own errors, after its buffers are freed, also from inside a
  yielding loop or an inlined call. In Elixir mode it is the `raise` itself,
  so both give the same exception with the same message.

### Blocks

Every block that needs a value ends in an expression; an empty block is
[`empty-block`](compile-errors.md#empty-block) (Elixir's empty block is `nil`, which a kernel
does not have).

## 8. Calls

### Calls to other kernels

**Supported with restrictions:** a kernel may call any kernel of the same
module, defined before or after it.

```elixir
defk count_primes(n :: i64) :: i64 do
  for i <- 2..n//1, reduce: 0 do
    count -> if prime?(i), do: count + 1, else: count
  end
end

defk prime?(x :: i64) :: bool do
  limit = trunc(:math.sqrt(x))

  for d <- 2..limit//1, reduce: true do
    p -> p and rem(x, d) != 0
  end
end
```

```elixir
iex> M.count_primes(100)
25
```

- The call is inlined: the callee's body is compiled into the caller, so its
  loops yield like the caller's own. Code size grows with the number of call
  sites along each call chain: a helper called from two sites of a helper
  called from three sites is compiled six times, and each kernel called from
  Elixir has its own copy. A kernel called from Elixir whose generated C
  passes 80,000 lines gets a compile warning (not an error) at its head,
  naming the size and the kernels inlined most, each with the chain that
  copies it most:

  ```text
  warning: argon2id/6 compiles to 295,722 lines of C (16.0 MB), past the 80,000 at which defk warns: ...
    * b2b_compress/12 is inlined 14 times (78,148 AST nodes), 12 of them via argon2id/6 -> argon2/9 (1 call site) -> hprime/3 (2 call sites) -> blake2b/3 (3 call sites) -> b2b_compress/12 (2 call sites)
  ```

  Give each helper one call site: call it from one loop over its inputs, or
  copy the inputs into a buffer and call it once. The largest kernels in the
  examples are under 30,000 lines; the threshold and the measurements behind
  it are [Performance notes](performance.md) 6.26.
- Arguments are converted like a result: an `i64` widens to an `f64`
  parameter, anything else must match ([`type-mismatch`](compile-errors.md#type-mismatch)).
- An array argument is passed without a copy. A callee that writes an array
  parameter must return it, alone or in a result tuple, and the caller
  binds the result: `{out, n} = fill(out, v)`. A write to a parameter the
  callee does not return would be lost to the caller (valid Elixir that does
  nothing), so it is a compile error
  ([`write-not-returned`](compile-errors.md#write-not-returned)). The array
  returned may be the parameter bound again after the write, as long as it
  holds the written array: `a = step(a)` with a helper that returns its
  parameter, or `a = for ..., reduce: a do a -> ... end` with an accumulator
  that starts from it. Binding the name to a new array (`a = alloc(i64, n)`,
  a helper's new array, a reduce body that gives a new array) loses the write,
  and is still the error. See [Copies](#copies) for when the callee's write
  copies.
- A [bitstring accumulator](#the-bitstring-accumulator) argument is passed to
  a `bitstring` parameter, which the callee may append to and return, alone
  or in a result tuple. A kernel with a `bitstring` parameter is only
  inlined: it has no function of its own, and some kernel called from Elixir
  must call it ([`bitstring-use`](compile-errors.md#bitstring-use)).
- Recursion, direct or through other kernels, is
  [`recursion`](compile-errors.md#recursion): write it as a `for ..., reduce:` or
  `Enum.reduce_while/3` loop.
- A call to a kernel that returns a tuple is destructured at once
  (`{a, b} = f(x)`); a tuple cannot be an argument
  ([`tuple-argument`](compile-errors.md#tuple-argument)).
- A rejection inside the callee is reported once, in the callee.

### Builtins and other calls

The builtins are listed in [section 4](#builtins). Functions of other modules,
including ordinary `def`s of the kernel's own module, are not callable
([`unsupported-call`](compile-errors.md#unsupported-call), [`unknown-function`](compile-errors.md#unknown-function)).

## 9. Yielding and the runtime contract in practice

- **What yields.** Every loop back-edge is a safepoint. A kernel reads the
  clock every few tens of microseconds of work (the safepoint budget adapts so
  that a read comes every 25-60 µs, whatever one iteration costs), charges the
  time to its process, and yields to its scheduler after about 250 µs of wall
  time (`DEFK_SLICE_US`), then resumes where it stopped. A kernel with no loops
  never yields. Loops in called kernels yield too, because calls are inlined.
  A short flat inner loop (no nested loop) runs without per-iteration checks;
  a long one runs in strips of 2048 iterations with one safepoint per strip.
  Yielding never changes a result.
- **`yield: false`** compiles the kernel called from Elixir, including the
  kernels it calls, without safepoints. Use it only for kernels that always
  finish in well under a millisecond: a long kernel without safepoints blocks
  its scheduler for its whole run (the README measured an 867 ms gap on a
  1 ms ticker).
- **Errors are exceptions.** Every runtime error in this document is raised in
  the calling process as an ordinary Elixir exception (`ArithmeticError`,
  `ArgumentError`, `Enum.OutOfBoundsError`, `CaseClauseError`, and
  `RuntimeError` from a kernel's own [`raise`](#raise)), after the
  kernel's own buffers are freed. Catch it like any other.
- **Process death.** A process killed while its kernel is suspended between
  steps frees the kernel's frame, arrays and bitstring buffers
  (`__defk_stats__().frames_live` goes back down; `demo.exs` shows it).
- **Hot code upgrade.** A kernel suspended across a reload of its module
  finishes in the library it started in. A second reload (or `:code.purge/1`)
  before it finishes kills it, like any process running old Erlang code
  (`test/upgrade_test.exs`).
- **Testing yields.** `Mod.__defk_force_yields__(true)` makes the module's
  kernels yield at every clock read, so a test can run every resume path.

The BEAM side of all this (scheduling, `enif_schedule_nif`, resources,
upgrade) is in [docs/beam-nifs.md](https://github.com/DanielLuning/defk/blob/main/docs/beam-nifs.md).

## 10. Elixir mode

**Elixir mode** compiles each kernel body to plain Elixir as well, for tests
and debugging only: it is never a fallback in production and never a
baseline. It applies the kernel subset's limits (an `i64` overflow, a `[u8]`
write of 300, an `alloc` that is too large, a range at the `i64` limit raise
there too), so a kernel and its Elixir mode **agree**: both return identical
values (`===`, bit-exact floats) or both raise the same exception module for
the same reason. Messages may differ (Elixir's own float errors read "bad
argument in arithmetic expression").

How to run it:

- `Mod.__defk_elixir__(:name, args)` runs one call in Elixir mode.
- `config :defk, mode: :elixir` makes every kernel call run in Elixir mode.
  It is read when the kernel module compiles, and is allowed only in `:dev`
  and `:test` (any other environment is a compile error).
- `Defk.ElixirMode.with_mode(:elixir, fun)` (or `:native`) switches the
  calling process for modules compiled with Elixir mode.
- `use Defk, elixir_mode: true` compiles Elixir mode into that module in any
  environment, including a `Mix.install` script run with `elixir script.exs`
  (no Mix project, where `config :defk, mode: :elixir` is refused with an
  error naming the condition). The default call path stays native; call
  `Mod.__defk_elixir__/2` or use `Defk.ElixirMode.with_mode/2` to run Elixir
  mode. Scripts use this for their agreement check.
- Without the option, Elixir mode is compiled in `:test`. There every kernel's NIF is
  registered as `__defk_native_<name>__` and the public function checks the
  process's mode on each call, so measure speed in `:dev` or `:prod`.
- `Defk.Test.assert_agrees(Mod, :fun, args)` runs a call both ways and asserts
  agreement.

When to use it:

- To debug a kernel: `dbg/1` and `IO.inspect/1,2` print inside a kernel body
  in Elixir mode (native code ignores them), and
  `Mod.__defk_elixir_source__/0` shows the generated Elixir.
- To test a kernel: Elixir mode is the oracle for what the same code gives in
  Elixir, so a property test can compare the two on generated inputs.

Arrays have value semantics in Elixir mode (a write rebuilds the binary), as
they do natively ([section 6](#writing)), where the compiler copies a buffer
only when the write would otherwise be visible elsewhere.

## 11. Compile errors

A construct outside the kernel subset, or a mistake in one inside it, is a
compile error when the module compiles. Every rejection in the module is
reported in one `CompileError` (up to 10 shown, the rest counted), without
the errors an earlier one causes. The compiler does not look inside a
construct it rejected, so errors in the body of a rejected `for` appear on
the next compile, once it is rewritten. Each is printed in Elixir's diagnostic
frame, then why it is rejected, a hint (with a rewrite from your own code
where the compiler has one, which compiles where it is shown), and its stable
code, with a link to the code's entry in the [compile errors](compile-errors.md)
page:

```
error: maps are not in the kernel subset
  │
5 │    m = %{a: x}
  │        ^^^^^^^
  │
  └─ lib/my_app/kernels.ex:5:9: MyApp.Kernels.f/1

why: a kernel works on numbers, booleans, tuples and packed arrays; a map is a BEAM term it can neither build nor read
hint: pass the values as separate arguments, or pack them into an array before the call; for a count per key, index an array by the key (counts = alloc(i64, 256), then counts[b] = counts[b] + 1)
(defk unsupported-map: https://github.com/DanielLuning/defk/blob/main/docs/compile-errors.md#unsupported-map)
```

"not in the kernel subset" means the construct stays out; "not supported yet"
means it is planned; other wordings ("is not a kernel builtin", "is not a
kernel type") are mistakes with a fix in the hint. The link in the last line
is a URL in a project that depends on defk, and the page's path inside the
defk repository. Codes are never renamed. `Defk.Errors.codes/0` lists them,
and `mix run -e 'Defk.Errors.explain!("unsupported-map")'` prints one entry.
The [compile errors](compile-errors.md) page has every code, its default why
and hint, a failing example and the rewrite.

## 12. Limits

Every case where a kernel raises or refuses to compile where Elixir would have
succeeded. Each is allowed by the one rule; one missing from this table is a
bug.

| Limit | Elixir | Kernel |
|---|---|---|
| `+`, `-`, `*`, unary `-`, `abs/1` with a result outside `i64` | a bignum | `ArithmeticError` "i64 overflow in a * b" |
| `div(-9223372036854775808, -1)` | `9223372036854775808` | `ArithmeticError` "i64 overflow in div/2" |
| `trunc/1`, `round/1` of a float outside the `i64` range | a bignum | `ArithmeticError` "trunc/1: ... does not fit in i64" |
| an integer literal outside -2^63..2^64 - 1, and `-9223372036854775808` | a bignum | compile error [`integer-literal`](compile-errors.md#integer-literal) |
| a module attribute holding an integer outside -2^63..2^64 - 1, read in a kernel | a bignum | compile error [`integer-literal`](compile-errors.md#integer-literal) |
| `u64` `+`, `-`, `*`, `bsl` with a result outside 0..2^64 - 1 | a bignum, or a negative integer | `ArithmeticError` "u64 overflow in 3 - 5" |
| a `u64` above 2^63 - 1 where an `i64` is expected (index, length, range bound, `i64` parameter, result or accumulator), and `rotl/3`, `rotr/3` of an `i64` giving one | the integer | `ArithmeticError` "... does not fit in i64" |
| a negative `i64` where a `u64` is expected | the integer | `ArithmeticError` "-1 does not fit in u64" |
| a `[u64]` write of a negative value, an `[i64]` write of a `u64` above 2^63 - 1 | `<<-1::64>>` wraps | `ArgumentError` "value -1 does not fit in u64" |
| a `u64` mixed with an `i64` that may be negative in `+ - * band bor bxor div rem min max`, outside a mask | runs | compile error [`u64-mix`](compile-errors.md#u64-mix) |
| `bnot` or unary `-` of a `u64` outside a mask | a negative integer | compile error [`operand-type`](compile-errors.md#operand-type) |
| arithmetic bound to a variable and masked later, `x = h * p` then `band(x, m)` | a bignum, then masked | `x = h * p` is checked and raises on overflow (see [Masked arithmetic](#masked-arithmetic)) |
| `bsl` inside a mask by a count that is not a literal and is negative | an exact right shift | `ArithmeticError` "bsl/2 by the negative count -1 inside a mask" |
| u64 loads (`u64_le/2`, `u64_be/2`) return the bit pattern as `i64` | `x::unsigned-64` gives up to 2^64 - 1 | a word with the top bit set is a negative `i64` (see [Word loads](#word-loads)) |
| an `i64` argument outside `i64` | any integer | `ArgumentError` "argument N (name) must be an integer fitting in i64" |
| an `f64` argument that is an integer outside `i64` | converts | `ArgumentError` "argument N (name) must be a number" |
| a `[u8]` write of a value outside 0..255 | `<<300::8>>` wraps | `ArgumentError` "value 300 does not fit in u8" |
| an `[i16]` or `[i32]` write of a value outside its range | `<<32768::signed-16>>` wraps | `ArgumentError` "value 32768 does not fit in i16" |
| an `[f32]` write of a value that rounds to inf | `<<1.0e40::float-32>>` stores inf | `ArgumentError` "value 1.0e40 does not fit in f32" |
| a [bitstring accumulator](#the-bitstring-accumulator) segment `v::size(n)` with `v` outside `0..2^n - 1` (a negative `v` included) | keeps the low `n` bits | `ArgumentError` "bitstring segment value v does not fit in n bits" |
| a bitstring accumulator segment `v::size(n)-signed` with `v` outside `-2^(n-1)..2^(n-1) - 1` (a width of 0 takes only 0) | keeps the low `n` bits | `ArgumentError` "bitstring segment value v does not fit in n signed bits" |
| a bitstring segment size outside `0..64` | any non-negative size | `ArgumentError` "bitstring segment size n is outside 0..64" |
| a `bitstring` parameter of a kernel no kernel called from Elixir calls (an entry kernel taking a bitstring) | a function taking any bitstring | compile error [`bitstring-use`](compile-errors.md#bitstring-use) |
| `alloc/2` of more than 2^48 bytes | (the VM would abort) | `ArgumentError` "alloc/2: length too large" |
| `alloc/2` of a size the allocator cannot provide | (the VM would abort) | `ArgumentError` "out of memory"; Elixir mode raises it from 2^47 bytes without trying |
| a range whose last element is within one step of the `i64` limit, e.g. `0..9223372036854775807` | runs | `ArithmeticError` "range element ... is within one step of the i64 limit" before the loop starts, also when the loop would stop earlier |
| an `i64` overflow inside a `case` guard (`n * n > 100`) | the guard is computed exactly | `ArithmeticError`. A zero divisor in a guard is no limit: it fails the clause, as in Elixir |
| ordering booleans, comparing a boolean with a number | term order | compile error [`operand-type`](compile-errors.md#operand-type) |
| `&&`, `\|\|`, `!` on non-boolean values | truthiness | compile error [`operand-type`](compile-errors.md#operand-type) |
| recursion, direct or mutual | runs | compile error [`recursion`](compile-errors.md#recursion) |
| every construct in [What is not an expression](#what-is-not-an-expression) | runs | a compile error with its code |
| code size: each call to a kernel is inlined | one function | the generated code grows with the number of call sites along each call chain; past 80,000 lines of C a kernel called from Elixir gets a compile warning naming the chain (no error) |
| an array variable bound again inside a loop body and read after the loop | the binding is gone after the loop | compile error [`array-rebind-in-loop`](compile-errors.md#array-rebind-in-loop) |
| a called kernel writing an array parameter it does not return | the write is lost | compile error [`write-not-returned`](compile-errors.md#write-not-returned) |
| memory of arrays written in a loop while another variable still reads them | the old binaries are garbage collected | each copy (see [Copies](#copies)) lives until the kernel returns |
| a call holding more bytes in arrays it allocated or copied (an `alloc` or a copy in a loop body) than its [owned-buffer budget](#the-owned-buffer-budget) (`max_owned`, by default half of physical memory) | the old binaries are garbage collected | `ArgumentError` "out of memory (allocating N bytes would take this call's buffers past max_owned, M bytes)"; Elixir mode never raises it |
| the C compiler is needed at build time | | compile error [`no-c-compiler`](compile-errors.md#no-c-compiler) |

## 13. Known divergences

A divergence is a different value or behaviour without raising; the one rule
does not allow any. There is no registry: this list is kept by hand, and each
entry is a bug with a ticket until it is fixed or turned into a limit.

None at the moment. (The last, an array write visible through another
variable naming the same array, was removed by giving arrays value semantics,
[section 6](#writing).)

Related, though not a divergence (both sides raise): when both operands of an
operator can raise, as in `a[i] + b * c`, Elixir raises the left one's error;
a kernel may raise either, since the generated C leaves the order of the two
unspecified. The exception can then differ between a kernel and Elixir mode.

## 14. Changes in flight

None at the moment: every construct above is on `main`. A feature ticket that
changes the language adds its entries here while its branch is open.
