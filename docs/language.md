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
  has a type ([`untyped-parameter`](#untyped-parameter)) and the return type is
  required ([`kernel-head`](#kernel-head)). A kernel may have no parameters:
  `defk pi() :: f64 do 3.14159 end`.
- The body is a `do ... end` block or `, do: expr`. Its last expression is the
  result, converted to the return type the way Elixir would never need: only
  an `i64` widens to `f64`; anything else is
  [`return-type`](#return-type).
- One option exists: `yield: false`, written after the return type
  (`defk f(x :: i64) :: i64, yield: false do ... end`). It compiles the kernel
  without safepoints (see [section 9](#9-yielding-and-the-runtime-contract-in-practice)).
  Any other option is [`unknown-option`](#unknown-option).
- Each name/arity is defined once; multi-clause kernels are not supported yet
  ([`duplicate-kernel`](#duplicate-kernel)).

### What `use Defk` generates

For each kernel, a public function with the kernel's name and arity and an
`@spec` derived from its types (`i64` is `integer()`, `u64` is
`non_neg_integer()`, an `f64` parameter is
`number()` and an `f64` result `float()`, `bool` is `boolean()`, an array is
`binary()`, a tuple result is a tuple of those). Calling it runs the native
code.

Per module, also:

| Function | Returns |
|---|---|
| `__defk_source__/0` | the generated C source of the module's kernels |
| `__defk_lib__/0` | the path of the compiled NIF library (`.so`) |
| `__defk_kernels__/0` | each kernel's signature: `%{name:, arity:, params: [{name, type}], ret:}` |
| `__defk_stats__/0` | runtime counters of this library: `%{frames_live:, promotions:, yields:}` |
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
5. The module loads its library in an `@on_load` hook.

The C compiler runs on the build machine, at compile time only. If it cannot
be run, the build fails with [`no-c-compiler`](#no-c-compiler):

```
error: cannot compile MyApp.Kernels: C compiler `cc` not found

why: a kernel is compiled to native code at build time, so a C toolchain is needed on the build machine, as for elixir_make packages
hint: install one (macOS: `xcode-select --install`; Debian/Ubuntu: `apt install build-essential`; Alpine: `apk add build-base`), or set `CC` to a compiler path
(defk no-c-compiler: docs/language.md#no-c-compiler)
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
| `{t1, t2, ...}` | see below | not allowed ([`tuple-parameter`](#tuple-parameter)) | a tuple |
| `bitstring` | a [bitstring accumulator](#the-bitstring-accumulator) | not allowed ([`bitstring-use`](#bitstring-use)) | a bitstring (any number of bits) |

**Supported:** `i64`, `u64`, `f64`, `bool`, `[f64]`, `[f32]`, `[i64]`,
`[i32]`, `[i16]`, `[u8]`, `[u64]`. Any other type
name is [`unknown-type`](#unknown-type), whose hint names the kernel type for
the Elixir one (`integer` is `i64`, `float` and `number` are `f64`, `binary` is
`[u8]`).

**Supported with restrictions:** `bitstring`, the type of a [bitstring
accumulator](#the-bitstring-accumulator): a result type, alone or in a tuple
(`:: {bitstring, i64}`), never a parameter type.

**Supported with restrictions:** tuples. A tuple of scalars and arrays is a
return type (`:: {f64, f64}`, `:: {[f64], i64}`). Inside a kernel, tuples exist
only where they are taken apart at once: destructured by `{a, b} = ...`,
as `reduce:` and `Enum.reduce_while` accumulators, and as the result. A
variable cannot hold a tuple ([`tuple-binding`](#tuple-binding)), tuples do not
nest ([`nested-tuple`](#nested-tuple)), a branch cannot give one
([`branch-tuple`](#branch-tuple)), a call cannot take one
([`tuple-argument`](#tuple-argument)), and a call to a kernel that returns
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

### Literals

- Integer literals must fit in `i64` or `u64`
  ([`integer-literal`](#integer-literal)): a literal from 2^63 to 2^64 - 1,
  such as FNV's offset basis `0xCBF29CE484222325`, is a `u64`.
  `-9223372036854775808` is the negation of a literal that does not fit in
  `i64`, so it is rejected; write `-9223372036854775807 - 1`.
- Float literals are `f64`. An integer literal where an `f64` is expected
  (a result, an argument, a `[f64]` write) widens, as in Elixir arithmetic.
- `true` and `false` are `bool`. Other atoms and `nil` are
  [`unsupported-atom`](#unsupported-atom). A string or `<<1, 2, 3>>` is a
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

`div/2` and `rem/2` take two `i64` values
([`builtin-arguments`](#builtin-arguments) otherwise) and round as Elixir does:
`div` truncates toward zero, and `rem` has the sign of the dividend
(`div(-7, 2)` is `-3`, `rem(-7, 2)` is `-1`). A zero divisor raises
`ArithmeticError` "div/2 by zero" / "rem/2 by zero"; `div(-2^63, -1)` raises
"i64 overflow in div/2".

The power operator `**` is
[`unsupported-expression`](#unsupported-expression): use `pow/2` (a float) or
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
  [`u64-mix`](#u64-mix): no one type holds every result. Its hint moves the
  arithmetic inside `band(..., 0xFFFFFFFFFFFFFFFF)`, where `i64` and `u64`
  mix freely.
- `bsl`/`bsr` of a `u64` shift exactly (`bsr` is logical, as for any
  non-negative integer); `bsl` raises `ArithmeticError` when a bit would
  leave the 64. `bnot` and unary `-` of a `u64` are negative, so they are
  [`operand-type`](#operand-type): write them inside a mask.
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

- A `case` on a `u64` is [`case-subject`](#case-subject).

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
vectorised elementwise loop today, see README "Known limitations" and
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
  [`operand-type`](#operand-type) (a limit: Elixir orders all terms).

### Boolean operators

**Supported:** `and`, `or`, `not`, `&&`, `||`, `!` on `bool` operands. Both
families short-circuit: the right operand is evaluated only when it decides
the result, so `x != 0 && div(10, x) > 1` does not raise for `x = 0`.

**Restriction:** the operands must be `bool`
([`operand-type`](#operand-type)). Elixir's `&&`, `||` and `!` accept any
truthy value; a kernel has no `nil`, so it refuses that (a limit), and the
hint shows the comparison to write (`x != 0`).

### Builtins

Builtins are called like local functions. `sqrt`, `exp`, `log`, `sin`, `cos`
and `pow` are also callable as `:math.sqrt/1` and so on; any other `:math`
function is [`unsupported-call`](#unsupported-call). A builtin called with the
wrong types is [`builtin-arguments`](#builtin-arguments).

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
| `u64_le(b, i)`, `u32_le`, `u16_le`, `u64_be`, `u32_be`, `u16_be` | a `[u8]` and an `i64` byte offset | `i64`: the unsigned word at `i` (`u64` as its signed bit pattern) | see [Word loads](#word-loads) |

`length/1`, `byte_size/1` and `tuple_size/1` are
[`unknown-function`](#unknown-function) with the hint to use `len/1`.

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
[shift-overflow](#shift-overflow)). Operands must be `i64`; `bool` and `f64`
are rejected ([operand-type](#operand-type)). `band` with a constant mask
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
([builtin-arguments](#builtin-arguments)). None of these six can raise.
(defk-52v.6)

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
  `u64` outside a mask is [`u64-mix`](#u64-mix), whose hint shows the
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

MurmurHash3's 32-bit mixing stays in `i64` with 32-bit masks:

```elixir
defk mix32(h :: i64, k :: i64) :: i64 do
  k = band(rotl(band(k * 0xCC9E2D51, 0xFFFFFFFF), 15, 32) * 0x1B873593, 0xFFFFFFFF)
  band(rotl(bxor(h, k), 13, 32) * 5 + 0xE6546B64, 0xFFFFFFFF)
end
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

A write to a literal bound to a variable copies it first, like an input
array's ([Copies](#copies)); a literal cannot be returned unwritten
([`return-input-array`](#return-input-array)), and it is not a `case`
pattern.

**Unsupported:** interpolation, charlists (`'abc'`, `~c"abc"`; write
`"abc"`), a segment that is a float, a variable, a string, a value outside
`0..255`, or any type or size other than 8-bit integer
([`binary-literal`](#binary-literal)); build it in Elixir and pass it as a
`[u8]` parameter, or use a module attribute. `<>` and `~s` are
[`unsupported-string`](#unsupported-string). (defk-n4r.5)

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
iex> Mod.pack(<<1::64-native, 2::64-native, 3::64-native>>, 3)
<<41, 1::size(1)>>
```

- **Appending.** `<<acc::bitstring, seg, ...>>` gives a new bitstring with
  the segments after `acc`'s bits. A segment is an `i64` expression `v` in 8
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
  it returns), and the kernel's result, alone or in a tuple.
- **Signed segments.** `v::size(n)-signed` and `v::k-signed` (the
  specifiers in any order) take a negative `v` and write its two's
  complement bits, which is what `band(v, 2^n - 1)::size(n)` also gives:
  `<<1::1, 0::1, dod::7-signed>>` appends the two flag bits and the 7-bit
  two's complement of `dod`. The value must be in `-2^(n-1)..2^(n-1) - 1`
  (see Limits), so `::1-signed` takes `-1..0` and `::64-signed` every `i64`.
  A signed segment of width 0 holds no bits and only 0 fits it, as an
  unsigned one. `signed` together with `unsigned` is
  [`bitstring-segment`](#bitstring-segment).
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

**Unsupported, until a workload needs them** ([`bitstring-segment`](#bitstring-segment),
[`bitstring-use`](#bitstring-use)): little- or native-endian, float,
binary, bitstring and UTF segments; reading or indexing a bitstring
(`acc[i]`, `len(acc)`, `for b <- acc`; a `<<...>> = acc` match is
[`bitstring-match`](#bitstring-match)); starting from
an input binary (`<<input::bitstring, ...>>` with `input :: [u8]`); a
`bitstring` parameter; and passing a bitstring to another kernel.
(defk-cmr)

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

A binary attribute is an array like an input array: it can be indexed (a
read out of range raises `Enum.OutOfBoundsError`), measured with `len/1`,
iterated with `for c <- @table`, bound to a variable and passed to a kernel.
A write copies it first, like an input array's ([Copies](#copies)); it
cannot be returned unwritten ([`return-input-array`](#return-input-array)),
and it is not a `case` pattern. Its bytes are compiled into the NIF, so a large table makes the
library larger, not the call slower.

**Unsupported:** an attribute that is not defined above the kernel
([`undefined-attribute`](#undefined-attribute)), an integer outside `i64`
([`integer-literal`](#integer-literal), a limit), and any other value: a
list, tuple, map, atom, `nil`, or a bitstring that is not whole bytes
([`attribute-value`](#attribute-value)). An accumulating attribute
(`Module.register_attribute(__MODULE__, :a, accumulate: true)`) is a list. A
list of bytes packs into a binary attribute (`@table <<1, 2, 4>>`); the error
shows that rewrite. (defk-ivt)

### What is not an expression

Each of these is a compile error with a code; the code's entry in
[section 11](#11-compile-errors) has an example and the rewrite.

| Construct | Code |
|---|---|
| maps, structs, `map.field` | [`unsupported-map`](#unsupported-map) |
| string concatenation `<>`, the sigil `~s` | [`unsupported-string`](#unsupported-string) |
| interpolation `"#{x}"`, charlists `'abc'`/`~c"abc"`, a `<<...>>` with a non-byte segment | [`binary-literal`](#binary-literal) |
| atoms other than `true`/`false`, `nil` | [`unsupported-atom`](#unsupported-atom) |
| lists, `++`, `--` | [`unsupported-list`](#unsupported-list) |
| `fn`, captures `&f/1` (except the `fn` of `Enum.reduce_while/3`, `Enum.all?/2`, `Enum.any?/2`) | [`unsupported-fn`](#unsupported-fn), [`fn-argument`](#fn-argument) |
| the pipe `\|>` | [`pipe`](#pipe) (the hint shows the nested call) |
| a module attribute holding a list, tuple, map, atom or `nil`, or not defined above the kernel | [`attribute-value`](#attribute-value), [`undefined-attribute`](#undefined-attribute) |
| binary patterns `<<a, b, rest::binary>> = arr` | [`bitstring-match`](#bitstring-match) |
| calls to other modules (`Enum.sum/1`, `Enum.map/2`, `String.*`, `:math.tan/1`, ...) | [`unsupported-call`](#unsupported-call), [`enum-reduce`](#enum-reduce) and [`enum-find`](#enum-find) (planned) |
| a range as a value (`r = 1..10`), `x in [1, 2, 3]`, `**`, a match used as a value | [`unsupported-expression`](#unsupported-expression) |
| `unless`, `with`, `try`, `receive`, `reraise`, `throw`, `send`, `spawn`, ... | [`unsupported-construct`](#unsupported-construct) |
| `raise` with an interpolated or computed message, of another module, or used as a value | [`raise-message`](#raise-message), [`raise-module`](#raise-module), [`raise-value`](#raise-value) (see [`raise`](#raise)) |
| a call to a function that is neither a builtin nor a kernel of this module (`while`, `length`) | [`unknown-function`](#unknown-function) |

### Unsupported, write this instead

The forms a developer writes first that the subset rejects, with the form
that compiles. The error for each says the same.

| Written first | Write instead | Code |
|---|---|---|
| `a \|> f(b)` | `f(a, b)` | [`pipe`](#pipe) |
| `Enum.sum(a)`, `Enum.max(a)` over an array or range | `for x <- a, reduce: 0.0 do acc -> acc + x end` | [`unsupported-call`](#unsupported-call) |
| `Enum.min([a, b, c])` | `min(min(a, b), c)` | [`unsupported-call`](#unsupported-call) |
| `for {x, i} <- Enum.with_index(a)` | `for i <- 0..(len(a) - 1)//1` and `x = a[i]` in the body | [`generator-pattern`](#generator-pattern) |
| `for x <- a, do: x * 2` as a value, or `for ..., into:` | `out = alloc(f64, len(a))`, a `for` that writes `out[i]`, then `out` | [`for-collect`](#for-collect) |
| `<<a, b, _::16, rest::binary>> = arr` | indexed reads `a = arr[0]`, `b = arr[1]` | [`bitstring-match`](#bitstring-match) |
| `<<b::64>> = <<x::float-64>>` | convert in Elixir before the call | [`bitstring-match`](#bitstring-match) |
| `x ** 2` | `x * x`, or `pow(x, 2)` for a float | [`unsupported-expression`](#unsupported-expression) |
| `x in [1, 2, 3]` | `x == 1 or x == 2 or x == 3` | [`unsupported-expression`](#unsupported-expression) |
| `Enum.all?(a, &(&1 > 0))` | `Enum.all?(a, fn x -> x > 0 end)` | [`fn-argument`](#fn-argument) |
| `length(a)`, `byte_size(a)` | `len(a)` | [`unknown-function`](#unknown-function) |
| `unless c do ... end` | `if not c do ... end` | [`unsupported-construct`](#unsupported-construct) |

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
  ([`tuple-size`](#tuple-size)).
- **Unsupported:** binding a whole tuple to one variable
  ([`tuple-binding`](#tuple-binding)), other patterns such as lists and maps
  ([`unsupported-pattern`](#unsupported-pattern)), binary patterns
  ([`bitstring-match`](#bitstring-match)), a match used as a value
  (`x = y = 1`, [`unsupported-expression`](#unsupported-expression)), and an
  undefined variable ([`undefined-variable`](#undefined-variable)).
- **Arrays are values.** `b = a` binds `b` to the array `a` has; a later
  write to `a` gives `a` a new array and leaves `b` as it was, as in Elixir
  (see [Copies](#copies) for what that costs: usually nothing).
- **An array variable bound again inside a loop body** is, as in Elixir,
  gone after the loop. Reading it after the loop would give the array from
  before the loop, which is never what the code means, so it is a compile
  error ([`array-rebind-in-loop`](#array-rebind-in-loop)): write the array's
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
([`type-mismatch`](#type-mismatch) for an `f64` index,
[`not-an-array`](#not-an-array) when `a` is not an array).

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
`for x <- a` generator, or a `[u8]` value indexing a 256-element `alloc`. That
changes speed, never results.

### Word loads

**Supported:** `u64_le(bytes, i)`, `u32_le(bytes, i)`, `u16_le(bytes, i)`
and the big-endian `u64_be`, `u32_be`, `u16_be` read the unsigned 8-, 4- or
2-byte integer at byte offset `i` of a `[u8]`, as Elixir's

```elixir
<<_::binary-size(i), x::little-unsigned-size(64), _::binary>> = bytes
```

- `bytes` must be a `[u8]` and `i` an `i64`
  ([`builtin-arguments`](#builtin-arguments) otherwise).
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

(defk-n4r.2)

### Allocating

**Supported:** `alloc(type, n)`, with `type` one of `f64`, `f32`, `i64`,
`i32`, `i16`, `u8`, `u64`, returns a new array of `n` elements, all zero. A
malformed call is [`alloc-form`](#alloc-form).

- A negative `n` raises `ArgumentError` "alloc/2: negative length n".
- More than 2^48 bytes (the user address space of 64-bit platforms) raises
  `ArgumentError` "alloc/2: length too large". A size under that which the
  allocator cannot provide raises `ArgumentError` "out of memory".
- Every array a kernel allocates lives until the kernel returns; an `alloc`
  inside a loop allocates on every iteration. Arrays that are not returned
  are freed when the kernel returns or raises, or when its process dies while
  it is suspended.

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
  ([`type-mismatch`](#type-mismatch) otherwise).
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
  ([`write-as-value`](#write-as-value)).

```elixir
defk histogram(bytes :: [u8]) :: [i64] do
  h = alloc(i64, 256)

  for b <- bytes do
    h[b] = h[b] + 1
  end

  h
end
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
- **An array accumulator** (see [Array accumulators](#array-accumulators))
  starts as a copy of its initial array when that is an input array, or
  when another variable with the same buffer is read in the loop or after
  it; and the array the body gives for the next iteration is copied on the
  same test (an input array, an array from outside the loop that the loop
  reads, or one array given to two accumulators). Otherwise the
  accumulator's buffer is the loop's alone and every write to it, in the
  body or in a called kernel that returns it, is in place.

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
through the rest of the block, and for a loop or branch, everything its whole
statement reads: it is conservative, so a kernel may copy where Elixir would
not have to (for example when `b` is read only in the other branch of an
`if`). Copies are not reported; `Mod.__defk_source__/0` shows them as
`defk_copy_*` calls. Like `alloc`, every copy lives until the kernel returns.

### Returning

**Supported with restrictions:** a kernel may return an array it created
or wrote (alone or in a result tuple); it reaches the caller as a binary
without a copy. Returning an input array it never writes is
[`return-input-array`](#return-input-array) (not supported yet); the caller
already has it.

Arrays cannot be the value of an `if`, `cond` or `case`
([`array-in-branch`](#array-in-branch), not supported yet). They can be a
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
The condition must be a `bool` ([`operand-type`](#operand-type); the hint shows
the comparison to write for a number).

- **As a value**, it needs an `else` ([`if-without-else`](#if-without-else)),
  and both branches have one type ([`branch-types`](#branch-types): convert
  with `float/1`, `trunc/1` or `round/1`). A branch may contain statements
  (array writes, loops) before its value.
- **As a statement** (its value unused), `else` is optional and the branches
  may end in array writes.

Only the branch taken is evaluated, as in Elixir. (An `if` whose branches are
plain arithmetic may be compiled to compute both sides; an integer overflow in
the branch not taken never raises.)

### `cond`

**Supported with restrictions:** `cond do c1 -> v1; ...; true -> vn end`. A
`cond` always ends with a `true ->` clause
([`cond-without-true`](#cond-without-true)), also when its value is unused,
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

- Patterns: integer literals (also negative), `true`/`false` for a `bool`
  subject, `^pinned` variables, `_`, and a variable, which binds the subject.
  A literal of the wrong type is [`case-pattern-type`](#case-pattern-type);
  floats, tuples, ranges and several patterns per clause are
  [`case-pattern`](#case-pattern); a subject of another type is
  [`case-subject`](#case-subject).
- Guards (`when`): literals, variables, `+ - * /`, comparisons, `and`, `or`,
  `not`, `div`, `rem`, `abs`, `trunc`, `round`, `min`, `max`. Kernel calls,
  indexing, `&&`/`||` and `in` are [`case-guard`](#case-guard) (Elixir rejects
  most of them in guards too).
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

- `reduce:` takes one `acc -> body` clause
  ([`reduce-clauses`](#reduce-clauses)). The accumulator may be a tuple,
  `{a, b} -> ...`, with an initial tuple of the same size
  ([`accumulator-shape`](#accumulator-shape)); other accumulator patterns are
  [`accumulator-pattern`](#accumulator-pattern). An accumulator, or a tuple
  element of one, may be an array (see
  [Array accumulators](#array-accumulators)).
- A `for` without `reduce:` used as a value, and `into:`, are
  [`for-collect`](#for-collect); other options are
  [`for-option`](#for-option); a generator over anything but a range or an
  array is [`generator-source`](#generator-source); a pattern other than a
  variable on the left of `<-` is [`generator-pattern`](#generator-pattern).
- `{:halt, acc}` in a `for ..., reduce:` is not early exit: as in Elixir, the
  tuple is the next accumulator.

**Range semantics are Elixir's:**

- `first..last` without a step counts down when `first > last`. So
  `0..(n - 1)` with `n = 0` visits `0` and `-1`; write `0..(n - 1)//1` for a
  range that may be empty.
- `first..last//step` with a positive step counts up and is empty when
  `first > last`; a negative step counts down. A literal step of 0 is
  [`range-step`](#range-step); a step expression that is 0 at run time raises
  `ArgumentError` "range step cannot be zero".
- **Limit:** a range whose last element is within one step of the `i64` limit
  (`0..9223372036854775807`) raises `ArithmeticError` before its loop starts,
  even if the loop would stop earlier, because stepping past that element
  would overflow the loop counter.

### Early exit: `Enum.reduce_while/3`, `Enum.all?/2`, `Enum.any?/2`

**Supported with restrictions.** The enumerable is a range or an array, as in a
`for` generator, and the function is a literal one-clause `fn`
([`fn-argument`](#fn-argument) for a capture).

```elixir
defk prime_early?(x :: i64) :: bool do
  Enum.all?(2..trunc(:math.sqrt(x))//1, fn d -> rem(x, d) != 0 end)
end
```

- `Enum.reduce_while(src, init, fn x, acc -> ... end)`: the accumulator may be
  a tuple. **The tail rule:** every path through the `fn` body ends in a
  literal `{:cont, acc}` or `{:halt, acc}`, directly or through
  `if`/`else`, `cond` or `case` ([`reduce-while-tail`](#reduce-while-tail)).
- A `{:halt, acc}` ends only the `Enum.reduce_while` it belongs to, also when
  it is nested in other loops or in a called kernel.
- `Enum.all?(src, fn x -> bool end)` and `Enum.any?/2` stop at the first
  element that decides the result; over an empty range or array they give
  `true` and `false`.
- There is no `while`, `break` or `return`, and no `Enum.reduce/3`
  ([`enum-reduce`](#enum-reduce)) or `Enum.find`/`find_index`
  ([`enum-find`](#enum-find)) yet.

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
  ([`array-in-branch`](#array-in-branch)), so a body that changes the array
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

- **A statement**, anywhere a statement goes: in a block before its value, in
  `if`/`case` statements, in a branch before the branch's value, in a loop
  body, and in an `Enum.reduce_while/3` `fn` before its tail. A `raise` as a
  value (`x = raise ...`, the last expression of a kernel, or a value
  branch that only raises, `if ok, do: v, else: raise(...)`) is
  [`raise-value`](#raise-value): write the check as a statement first,
  `if not ok, do: raise(...)`, then the value. A `cond` whose arms only
  raise needs a value in each; write the checks as `if` statements instead.
- **The message is a string literal**, of any length and any bytes (also
  `raise Module, message: "..."`). Interpolation and computed messages are
  [`raise-message`](#raise-message): the message is a C string in the
  kernel's static storage. Put the value in Elixir, before or after the
  call. Other modules are [`raise-module`](#raise-module).
- Natively the exception is raised in the calling process like the
  kernel's own errors, after its buffers are freed, also from inside a
  yielding loop or an inlined call. In Elixir mode it is the `raise` itself,
  so both give the same exception with the same message.

### Blocks

Every block that needs a value ends in an expression; an empty block is
[`empty-block`](#empty-block) (Elixir's empty block is `nil`, which a kernel
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

- The call is inlined: the callee's body is compiled into the caller, so its
  loops yield like the caller's own. Code size grows with the number of call
  sites along each call chain.
- Arguments are converted like a result: an `i64` widens to an `f64`
  parameter, anything else must match ([`type-mismatch`](#type-mismatch)).
- An array argument is passed without a copy. A callee that writes an array
  parameter must return it, alone or in a result tuple, and the caller
  binds the result: `{out, n} = fill(out, v)`. A write to a parameter the
  callee does not return would be lost to the caller (valid Elixir that does
  nothing), so it is a compile error
  ([`write-not-returned`](#write-not-returned)). See [Copies](#copies) for
  when the callee's write copies.
- Recursion, direct or through other kernels, is
  [`recursion`](#recursion): write it as a `for ..., reduce:` or
  `Enum.reduce_while/3` loop.
- A call to a kernel that returns a tuple is destructured at once
  (`{a, b} = f(x)`); a tuple cannot be an argument
  ([`tuple-argument`](#tuple-argument)).
- A rejection inside the callee is reported once, in the callee.

### Builtins and other calls

The builtins are listed in [section 4](#builtins). Functions of other modules,
including ordinary `def`s of the kernel's own module, are not callable
([`unsupported-call`](#unsupported-call), [`unknown-function`](#unknown-function)).

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
upgrade) is in [docs/beam-nifs.md](beam-nifs.md).

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
the errors an earlier one causes. Each is printed in Elixir's diagnostic
frame, then why it is rejected, a hint (with a rewrite from your own code
where the compiler has one, which compiles where it is shown), and its stable
code:

```
error: maps are not in the kernel subset
  │
5 │    m = %{a: x}
  │        ^^^^^^^
  │
  └─ lib/my_app/kernels.ex:5:9: MyApp.Kernels.f/1

why: a kernel works on numbers, booleans, tuples and packed arrays; a map is a BEAM term it can neither build nor read
hint: pass the values as separate arguments, or pack them into an array before the call
(defk unsupported-map: docs/language.md#unsupported-map)
```

"not in the kernel subset" means the construct stays out; "not supported yet"
means it is planned. Codes are never renamed. `Defk.Errors.codes/0` lists them,
and `mix run -e 'Defk.Errors.explain!("unsupported-map")'` prints one entry.

Each entry below gives the code's summary, its kind, the default why and hint
(an error may say more about your code), and a failing example with the
rewrite; the test suite checks that each example is rejected with its code and
each rewrite compiles. The entries are generated from the registry in
`lib/defk/errors.ex`; after changing it, regenerate them with

```
mix run -e 'IO.write(Defk.Errors.reference())'
```

and replace everything from the first `###` heading of this section to the
end of the section with its output (`test/language_doc_test.exs` fails until
they match).

Compiling 2 files (.ex)
### kernel-head

A kernel head is `name(arg :: type, ...) :: return_type`.

- kind: a mistake to fix (in the kernel or the build)
- why: a kernel's parameter and return types are part of its definition: defk compiles to native code before anything runs
- hint: declare the return type after the parameter list

Rejected:

```elixir
defk f(x :: i64) do
  x
end
```

Write instead:

```elixir
defk f(x :: i64) :: i64 do
  x
end
```

### untyped-parameter

Every kernel parameter is `name :: type`.

- kind: a mistake to fix (in the kernel or the build)
- why: a kernel decodes each argument into a native value of its declared type
- hint: give the parameter a type

Rejected:

```elixir
defk f(x) :: i64 do
  x
end
```

Write instead:

```elixir
defk f(x :: i64) :: i64 do
  x
end
```

### unknown-type

Kernel types are i64, u64, f64, bool, arrays of f64, f32, i64, i32, i16, u8 and u64 ([f64], [f32], [i64], [i32], [i16], [u8], [u64]) and tuples of them for results; bitstring is a result type too (the bitstring accumulator).

- kind: a mistake to fix (in the kernel or the build)
- why: a kernel works on native numbers and packed arrays, and these are the types it has
- hint: use i64, u64, f64, bool, [f64], [f32], [i64], [i32], [i16], [u8] or [u64] (a tuple of them for a result)

Rejected:

```elixir
defk f(x :: integer) :: integer do
  x
end
```

Write instead:

```elixir
defk f(x :: i64) :: i64 do
  x
end
```

### tuple-parameter

Tuples are only for returning several values; a kernel takes its inputs as separate parameters.

- kind: outside the kernel subset (permanent)
- why: a tuple is a BEAM term; a kernel keeps each element in a register and takes them as separate arguments
- hint: pass the elements as separate parameters

Rejected:

```elixir
defk f(p :: {i64, i64}) :: i64 do
  {a, b} = p
  a + b
end
```

Write instead:

```elixir
defk f(a :: i64, b :: i64) :: i64 do
  a + b
end
```

### unknown-option

defk takes one option, `yield:`.

- kind: a mistake to fix (in the kernel or the build)
- why: `yield: false` (run without safepoints) is the only option a kernel has
- hint: remove the option

Rejected:

```elixir
defk f(x :: i64) :: i64, inline: true do
  x
end
```

Write instead:

```elixir
defk f(x :: i64) :: i64, yield: false do
  x
end
```

### no-body

A kernel needs a body.

- kind: a mistake to fix (in the kernel or the build)
- why: a kernel's body is the code defk compiles; without one there is nothing to run
- hint: write the body in a do block

Rejected:

```elixir
defk f(x :: i64) :: i64, do: nil
```

Write instead:

```elixir
defk f(x :: i64) :: i64, do: x
```

### duplicate-kernel

A kernel name and arity is defined once; multi-clause kernels are planned.

- kind: not supported yet (planned)
- why: a kernel has one head and one body
- hint: merge the clauses into one body with case or cond

Rejected:

```elixir
defk f(x :: i64) :: i64 do
  x
end

defk f(x :: i64) :: i64 do
  x + 1
end
```

Write instead:

```elixir
defk f(x :: i64) :: i64 do
  x + 1
end
```

### return-type

The value a kernel returns has its declared return type.

- kind: a mistake to fix (in the kernel or the build)
- why: defk never converts a value to another type implicitly; only i64 widens to f64, as in arithmetic
- hint: convert explicitly, or change the declared return type

Rejected:

```elixir
defk f(x :: i64, y :: f64) :: i64 do
  x + y
end
```

Write instead:

```elixir
defk f(x :: i64, y :: f64) :: i64 do
  trunc(x + y)
end
```

### return-input-array

A returned array is one the kernel created with alloc/2 or wrote; returning an unwritten input array is planned.

- kind: not supported yet (planned)
- why: a kernel returns arrays it owns: one from alloc/2, or an input array it wrote, which is a copy; handing an unwritten input array back to the caller is planned
- hint: return the input itself from the Elixir caller, which already holds it

Rejected:

```elixir
defk f(a :: [f64]) :: [f64] do
  a
end
```

Write instead:

```elixir
defk f(a :: [f64]) :: f64 do
  a[0]
end
```

### empty-block

Every block in a kernel has a value, its last expression.

- kind: a mistake to fix (in the kernel or the build)
- why: in Elixir an empty block is nil, and a kernel has no nil
- hint: write the value the block should have

Rejected:

```elixir
defk f(x :: i64) :: i64 do
  y =
    if x > 0 do
    else
      1
    end

  y
end
```

Write instead:

```elixir
defk f(x :: i64) :: i64 do
  y = if x > 0, do: 0, else: 1
  y
end
```

### write-as-value

An array write `out[i] = v` is a statement and cannot end a block that needs a value.

- kind: a mistake to fix (in the kernel or the build)
- why: a kernel writes the array in place, so the write has no value, and the last expression of a block is the block's value
- hint: end the block with the value it should have

Rejected:

```elixir
defk f(n :: i64) :: [f64] do
  out = alloc(f64, 1)
  out[0] = float(n)
end
```

Write instead:

```elixir
defk f(n :: i64) :: [f64] do
  out = alloc(f64, 1)
  out[0] = float(n)
  out
end
```

### if-without-else

An `if` used as a value has an else branch.

- kind: a mistake to fix (in the kernel or the build)
- why: in Elixir an if without else is nil when the condition is false, and a kernel has no nil
- hint: add an else branch

Rejected:

```elixir
defk f(x :: i64) :: i64 do
  y = if x > 0, do: 1
  y
end
```

Write instead:

```elixir
defk f(x :: i64) :: i64 do
  y = if x > 0, do: 1, else: 0
  y
end
```

### cond-without-true

A `cond` used as a value (or ending an Enum.reduce_while fn) ends with a `true ->` clause.

- kind: a mistake to fix (in the kernel or the build)
- why: every path through a kernel has a value, so the last clause must always match
- hint: end the cond with a `true ->` clause

Rejected:

```elixir
defk f(x :: i64) :: i64 do
  cond do
    x > 0 -> 1
    x < 0 -> -1
  end
end
```

Write instead:

```elixir
defk f(x :: i64) :: i64 do
  cond do
    x > 0 -> 1
    x < 0 -> -1
    true -> 0
  end
end
```

### branch-types

The branches of an if, cond or case used as a value have one type.

- kind: a mistake to fix (in the kernel or the build)
- why: a value has one type, and defk never converts between i64 and f64 implicitly
- hint: convert one branch explicitly, e.g. with float/1

Rejected:

```elixir
defk f(x :: i64) :: f64 do
  if x > 0, do: 1, else: 2.5
end
```

Write instead:

```elixir
defk f(x :: i64) :: f64 do
  if x > 0, do: 1.0, else: 2.5
end
```

### branch-tuple

An if, cond or case used as a value gives a number or a boolean, not a tuple.

- kind: outside the kernel subset (permanent)
- why: a kernel keeps a tuple's elements in separate registers, so each branch value is a single number or boolean
- hint: compute each element with its own if

Rejected:

```elixir
defk f(x :: i64) :: i64 do
  {a, b} = if x > 0, do: {1, 2}, else: {3, 4}
  a + b
end
```

Write instead:

```elixir
defk f(x :: i64) :: i64 do
  a = if x > 0, do: 1, else: 3
  b = if x > 0, do: 2, else: 4
  a + b
end
```

### array-in-branch

An if, cond or case used as a value gives a number or a boolean; arrays through branches are planned.

- kind: not supported yet (planned)
- why: an if/cond/case may give numbers or booleans, not arrays yet
- hint: do the array work inside each branch

Rejected:

```elixir
defk f(p :: bool, a :: [f64], b :: [f64]) :: f64 do
  c = if p, do: a, else: b
  c[0]
end
```

Write instead:

```elixir
defk f(p :: bool, a :: [f64], b :: [f64]) :: f64 do
  if p, do: a[0], else: b[0]
end
```

### undefined-variable

A variable is bound before it is used.

- kind: a mistake to fix (in the kernel or the build)
- why: variables are bound by =, parameters, generators and accumulators, and a binding inside if, case or for stays inside it, as in Elixir
- hint: bind it before this point, or pass it in as a parameter

Rejected:

```elixir
defk f(x :: i64) :: i64 do
  x + y
end
```

Write instead:

```elixir
defk f(x :: i64, y :: i64) :: i64 do
  x + y
end
```

### tuple-binding

A tuple is taken apart where it is bound: `{a, b} = ...`.

- kind: outside the kernel subset (permanent)
- why: a kernel keeps a tuple's elements in separate registers, so a tuple can't be held in one variable
- hint: destructure it

Rejected:

```elixir
defk f(x :: i64) :: i64 do
  t = {x, x + 1}
  x
end
```

Write instead:

```elixir
defk f(x :: i64) :: i64 do
  {a, b} = {x, x + 1}
  a + b
end
```

### tuple-size

A tuple pattern has as many elements as the tuple it matches.

- kind: a mistake to fix (in the kernel or the build)
- why: in Elixir a tuple pattern of another size never matches
- hint: match every element (use _ for the ones you don't need)

Rejected:

```elixir
defk f(x :: i64) :: i64 do
  {a, b} = {x, x, x}
  a + b
end
```

Write instead:

```elixir
defk f(x :: i64) :: i64 do
  {a, b, _} = {x, x, x}
  a + b
end
```

### unsupported-pattern

`=` binds a variable or a tuple of variables.

- kind: outside the kernel subset (permanent)
- why: any other pattern needs a match that can fail, and a kernel only matches in case clauses
- hint: bind variables, and test values with if or case

Rejected:

```elixir
defk f(x :: i64) :: i64 do
  [a, b] = {x, x + 1}
  a + b
end
```

Write instead:

```elixir
defk f(x :: i64) :: i64 do
  {a, b} = {x, x + 1}
  a + b
end
```

### bitstring-match

Binary patterns `<<...>> = bin` are not in the kernel subset; read array elements by index.

- kind: outside the kernel subset (permanent)
- why: a kernel sees a binary as an array of elements, which it reads by index
- hint: read the fields by index

Rejected:

```elixir
defk f(arr :: [u8]) :: i64 do
  <<a, b, _::16, _rest::binary>> = arr
  a + b
end
```

Write instead:

```elixir
defk f(arr :: [u8]) :: i64 do
  a = arr[0]
  b = arr[1]
  a + b
end
```

### integer-literal

Integer literals fit in i64 or u64 (-2^63..2^64 - 1).

- kind: a mistake to fix (in the kernel or the build)
- why: kernel integers are i64 (-2^63..2^63 - 1) or u64 (0..2^64 - 1, a literal from 2^63 up); a kernel never uses bignums
- hint: use a value that fits, or compute in f64

Rejected:

```elixir
defk f(x :: i64) :: i64 do
  x + 18_446_744_073_709_551_616
end
```

Write instead:

```elixir
defk f(x :: i64) :: f64 do
  x + 1.8446744073709552e19
end
```

### type-mismatch

A value has the type its position needs (an index or length is i64, a stored value has the element type, ...).

- kind: a mistake to fix (in the kernel or the build)
- why: defk never converts a value to another type implicitly; only i64 widens to f64
- hint: convert explicitly

Rejected:

```elixir
defk f(a :: [f64], i :: f64) :: f64 do
  a[i]
end
```

Write instead:

```elixir
defk f(a :: [f64], i :: f64) :: f64 do
  a[trunc(i)]
end
```

### operand-type

Arithmetic takes numbers, bitwise operators take integers, and/or/not take booleans, comparisons take two numbers or two booleans.

- kind: a mistake to fix (in the kernel or the build)
- why: booleans are not numbers in Elixir, and defk keeps that
- hint: turn the value into the type the operator takes

Rejected:

```elixir
defk f(x :: i64, b :: bool) :: i64 do
  x + b
end
```

Write instead:

```elixir
defk f(x :: i64, b :: bool) :: i64 do
  if b, do: x + 1, else: x
end
```

### u64-mix

Outside a mask, + - * band bor bxor div rem min max mix a u64 only with a u64 or an i64 known to be >= 0.

- kind: outside the kernel subset (permanent)
- why: outside a mask a kernel computes a u64 operation exactly in 0..2^64 - 1 and an i64 one in i64, and with an i64 that may be negative no type holds every result Elixir gives; inside band(..., 2^k - 1) only the low bits count, so i64 and u64 mix freely there
- hint: to wrap, as hashes do, move the arithmetic inside band(..., 0xFFFFFFFFFFFFFFFF); to stay exact, make the i64 a u64 first with band(x, 0xFFFFFFFFFFFFFFFF), or keep both i64

Rejected:

```elixir
defk f(h :: u64, x :: i64) :: u64 do
  h * 31 + x
end
```

Write instead:

```elixir
defk f(h :: u64, x :: i64) :: u64 do
  band(h * 31 + x, 0xFFFFFFFFFFFFFFFF)
end
```

### not-an-array

Only arrays can be indexed with a[i].

- kind: a mistake to fix (in the kernel or the build)
- why: a[i] reads an element of an array ([f64], [f32], [i64], [i32], [i16] or [u8]), and this value is not one
- hint: index an array

Rejected:

```elixir
defk f(x :: i64) :: i64 do
  x[0]
end
```

Write instead:

```elixir
defk f(x :: [i64]) :: i64 do
  x[0]
end
```

### nested-tuple

Tuples don't nest.

- kind: outside the kernel subset (permanent)
- why: a kernel returns a tuple as separate registers, one per element
- hint: flatten the tuple

Rejected:

```elixir
defk f(x :: i64) :: {i64, {i64, i64}} do
  {x, {x, x}}
end
```

Write instead:

```elixir
defk f(x :: i64) :: {i64, i64, i64} do
  {x, x, x}
end
```

### unknown-function

A kernel calls builtins and the other kernels in its module.

- kind: a mistake to fix (in the kernel or the build)
- why: a kernel runs as native code: it can call its builtins (len, bit_size, min, max, abs, float, trunc, round, div, rem, sqrt, exp, log, sin, cos, pow, band, bor, bxor, bnot, bsl, bsr, wrap64, u64_le, u64_be, u32_le, u32_be, u16_le, u16_be, mulhi, clz, ctz, popcount, rotl64, rotr64, rotl, rotr, f64_to_u64) and the kernels in this module, which are inlined
- hint: define it as a kernel in this module, or compute it in Elixir and pass the result in

Rejected:

```elixir
defk f(x :: i64) :: i64 do
  double(x)
end
```

Write instead:

```elixir
defk double(x :: i64) :: i64 do
  x * 2
end

defk f(x :: i64) :: i64 do
  double(x)
end
```

### builtin-arguments

A builtin is called with the number and types of arguments it takes.

- kind: a mistake to fix (in the kernel or the build)
- why: defk never converts a value to another type implicitly
- hint: convert the arguments

Rejected:

```elixir
defk f(x :: i64, y :: f64) :: i64 do
  div(x, y)
end
```

Write instead:

```elixir
defk f(x :: i64, y :: f64) :: i64 do
  div(x, trunc(y))
end
```

### alloc-form

alloc/2 takes an element type (f64, f32, i64, i32, i16, u8 or u64) and a length.

- kind: a mistake to fix (in the kernel or the build)
- why: an array's element type is fixed when it is created
- hint: name the element type first

Rejected:

```elixir
defk f(n :: i64) :: [f64] do
  alloc(n)
end
```

Write instead:

```elixir
defk f(n :: i64) :: [f64] do
  alloc(f64, n)
end
```

### tuple-argument

Tuples are not passed as arguments.

- kind: outside the kernel subset (permanent)
- why: a kernel keeps a tuple's elements in separate registers and passes them as separate arguments
- hint: pass the elements as separate arguments

Rejected:

```elixir
defk g(a :: i64, b :: i64) :: i64 do
  a + b
end

defk f(x :: i64) :: i64 do
  g({x, x})
end
```

Write instead:

```elixir
defk g(a :: i64, b :: i64) :: i64 do
  a + b
end

defk f(x :: i64) :: i64 do
  g(x, x)
end
```

### recursion

A kernel can't call itself, directly or through other kernels; write the recursion as a loop.

- kind: outside the kernel subset (permanent)
- why: kernel calls are inlined into the caller, so a kernel can't call itself, directly or through another kernel
- hint: write the recursion as a loop

Rejected:

```elixir
defk f(x :: i64) :: i64 do
  if x == 0, do: 0, else: x + f(x - 1)
end
```

Write instead:

```elixir
defk f(x :: i64) :: i64 do
  for i <- 1..x//1, reduce: 0 do
    acc -> acc + i
  end
end
```

### unsupported-call

Calls into other modules are not in the kernel subset, except Enum.reduce_while/3, Enum.all?/2, Enum.any?/2 and :math functions with a builtin.

- kind: outside the kernel subset (permanent)
- why: a kernel runs as native code and can't call Elixir functions
- hint: compute it in Elixir before or after the call and pass the result in

Rejected:

```elixir
defk f(a :: [f64]) :: [f64] do
  Enum.map(a, fn x -> x * 2.0 end)
end
```

Write instead:

```elixir
defk f(a :: [f64]) :: [f64] do
  out = alloc(f64, len(a))

  for i <- 0..(len(a) - 1)//1 do
    out[i] = a[i] * 2.0
  end

  out
end
```

### enum-reduce

Enum.reduce/3 is planned; write the same fold as `for ..., reduce:`.

- kind: not supported yet (planned)
- why: Enum.reduce/3 is planned; `for ..., reduce:` is the same fold
- hint: write it as a for ..., reduce: loop

Rejected:

```elixir
defk f(a :: [f64]) :: f64 do
  Enum.reduce(a, 0.0, fn x, acc -> acc + x end)
end
```

Write instead:

```elixir
defk f(a :: [f64]) :: f64 do
  for x <- a, reduce: 0.0 do
    acc -> acc + x
  end
end
```

### enum-find

Enum.find/2 and Enum.find_index/2 are planned; stop early with Enum.reduce_while/3.

- kind: not supported yet (planned)
- why: Enum.find/2 and Enum.find_index/2 return nil when nothing is found, a kernel has no nil, and a form that keeps their meaning is planned
- hint: stop at the first match with Enum.reduce_while/3 and a value that means not found

Rejected:

```elixir
defk f(a :: [f64], t :: f64) :: i64 do
  Enum.find_index(a, fn x -> x > t end)
end
```

Write instead:

```elixir
defk f(a :: [f64], t :: f64) :: i64 do
  Enum.reduce_while(0..(len(a) - 1)//1, -1, fn i, _ ->
    if a[i] > t, do: {:halt, i}, else: {:cont, -1}
  end)
end
```

### fn-argument

Enum.reduce_while/3, Enum.all?/2 and Enum.any?/2 take a literal fn with one clause and no guard.

- kind: outside the kernel subset (permanent)
- why: the fn is inlined as the loop body, so it must be written out where it is passed
- hint: write the function as a literal fn

Rejected:

```elixir
defk f(x :: i64) :: bool do
  Enum.all?(1..x//1, &(&1 > 0))
end
```

Write instead:

```elixir
defk f(x :: i64) :: bool do
  Enum.all?(1..x//1, fn i -> i > 0 end)
end
```

### reduce-while-tail

Every branch of an Enum.reduce_while/3 fn ends in a literal {:cont, acc} or {:halt, acc}.

- kind: a mistake to fix (in the kernel or the build)
- why: a kernel compiles {:cont, acc} to the next iteration and {:halt, acc} to a jump out of the loop, so each must be written where the fn returns
- hint: return {:cont, acc} or {:halt, acc} from every branch

Rejected:

```elixir
defk f(x :: i64) :: i64 do
  Enum.reduce_while(1..x//1, 0, fn i, acc -> acc + i end)
end
```

Write instead:

```elixir
defk f(x :: i64) :: i64 do
  Enum.reduce_while(1..x//1, 0, fn i, acc -> {:cont, acc + i} end)
end
```

### pipe

The pipe operator |> is not in the kernel subset; write the nested call.

- kind: outside the kernel subset (permanent)
- why: kernels keep to the forms of a numeric loop, and a pipe there is a nested call written another way
- hint: write the nested call

Rejected:

```elixir
defk f(x :: f64) :: f64 do
  x |> abs() |> sqrt()
end
```

Write instead:

```elixir
defk f(x :: f64) :: f64 do
  sqrt(abs(x))
end
```

### for-collect

A `for` collects nothing: without reduce: it is a statement, and into: is not in the kernel subset.

- kind: outside the kernel subset (permanent)
- why: a for without reduce: builds a list in Elixir (into: another collection), and a kernel has no lists
- hint: allocate the output array and write it in the loop

Rejected:

```elixir
defk f(a :: [f64]) :: [f64] do
  for x <- a, do: x * 2.0
end
```

Write instead:

```elixir
defk f(a :: [f64]) :: [f64] do
  out = alloc(f64, len(a))

  for i <- 0..(len(a) - 1)//1 do
    out[i] = a[i] * 2.0
  end

  out
end
```

### for-option

`for` takes `reduce:` and `do`; other options are not in the kernel subset.

- kind: outside the kernel subset (permanent)
- why: uniq: needs a set of the values seen, a BEAM term a kernel doesn't have
- hint: remove the option

Rejected:

```elixir
defk f(a :: [f64]) :: f64 do
  for x <- a, uniq: true, reduce: 0.0 do
    acc -> acc + x
  end
end
```

Write instead:

```elixir
defk f(a :: [f64]) :: f64 do
  for x <- a, reduce: 0.0 do
    acc -> acc + x
  end
end
```

### for-form

A `for` starts with a generator and has a do block.

- kind: a mistake to fix (in the kernel or the build)
- why: a for loops over its first generator
- hint: start the for with a generator such as i <- 0..(n - 1)//1

Rejected:

```elixir
defk f(x :: i64) :: i64 do
  for x > 0, reduce: 0 do
    acc -> acc + 1
  end
end
```

Write instead:

```elixir
defk f(x :: i64) :: i64 do
  for i <- 1..x//1, i > 0, reduce: 0 do
    acc -> acc + 1
  end
end
```

### generator-pattern

A generator binds one variable: `x <- array` or `i <- range`.

- kind: outside the kernel subset (permanent)
- why: a generator walks a range or an array, one value per iteration
- hint: bind a single variable

Rejected:

```elixir
defk f(a :: [f64]) :: f64 do
  for {x, i} <- Enum.with_index(a), reduce: 0.0 do
    acc -> acc + x * i
  end
end
```

Write instead:

```elixir
defk f(a :: [f64]) :: f64 do
  for i <- 0..(len(a) - 1)//1, reduce: 0.0 do
    acc -> acc + a[i] * i
  end
end
```

### generator-source

A generator walks a range or an array.

- kind: a mistake to fix (in the kernel or the build)
- why: a for or Enum.reduce_while/all?/any? walks a range a..b//step or an array
- hint: walk a range

Rejected:

```elixir
defk f(n :: i64) :: i64 do
  for i <- n, reduce: 0 do
    acc -> acc + i
  end
end
```

Write instead:

```elixir
defk f(n :: i64) :: i64 do
  for i <- 0..(n - 1)//1, reduce: 0 do
    acc -> acc + i
  end
end
```

### range-step

A range step is never zero.

- kind: a mistake to fix (in the kernel or the build)
- why: Elixir raises ArgumentError for a range with step 0
- hint: step by 1 (or -1 to count down)

Rejected:

```elixir
defk f(n :: i64) :: i64 do
  for i <- 0..n//0, reduce: 0 do
    acc -> acc + i
  end
end
```

Write instead:

```elixir
defk f(n :: i64) :: i64 do
  for i <- 0..n//1, reduce: 0 do
    acc -> acc + i
  end
end
```

### reduce-clauses

`for ..., reduce:` has exactly one `acc -> body` clause.

- kind: outside the kernel subset (permanent)
- why: a kernel binds the accumulator to a variable; choosing between clauses by pattern is not in the kernel subset
- hint: use one clause and branch inside it

Rejected:

```elixir
defk f(n :: i64) :: i64 do
  for i <- 1..n//1, reduce: 0 do
    0 -> i
    acc -> acc + i
  end
end
```

Write instead:

```elixir
defk f(n :: i64) :: i64 do
  for i <- 1..n//1, reduce: 0 do
    acc -> if acc == 0, do: i, else: acc + i
  end
end
```

### accumulator-shape

An accumulator pattern, its initial value and each new value have the same number of elements.

- kind: a mistake to fix (in the kernel or the build)
- why: each accumulator element is its own variable, so every value of it has the same elements
- hint: give the initial value and every new value one element per accumulator variable

Rejected:

```elixir
defk f(n :: i64) :: i64 do
  {s, c} =
    for i <- 1..n//1, reduce: {0, 0} do
      {s, c} -> {s + i}
    end

  s + c
end
```

Write instead:

```elixir
defk f(n :: i64) :: i64 do
  {s, c} =
    for i <- 1..n//1, reduce: {0, 0} do
      {s, c} -> {s + i, c + 1}
    end

  s + c
end
```

### accumulator-pattern

An accumulator is a variable or a tuple of variables.

- kind: outside the kernel subset (permanent)
- why: a kernel keeps each accumulator element in its own variable; patterns that test values are not in the kernel subset
- hint: bind a variable and test the value inside the body

Rejected:

```elixir
defk f(n :: i64) :: i64 do
  for i <- 1..n//1, reduce: 0 do
    acc when acc < 100 -> acc + i
  end
end
```

Write instead:

```elixir
defk f(n :: i64) :: i64 do
  for i <- 1..n//1, reduce: 0 do
    acc -> if acc < 100, do: acc + i, else: acc
  end
end
```

### case-form

A `case` has a do block of `pattern -> body` clauses.

- kind: a mistake to fix (in the kernel or the build)
- why: a case chooses the first clause whose pattern matches
- hint: write the clauses in a do block

Rejected:

```elixir
defk f(x :: i64) :: i64 do
  case x, do: 1
end
```

Write instead:

```elixir
defk f(x :: i64) :: i64 do
  case x do
    _ -> 1
  end
end
```

### case-subject

`case` matches an i64 or a bool.

- kind: outside the kernel subset (permanent)
- why: a case clause matches integer literals, true/false, pins and variables; a float has no exact literal match worth keeping, and other values are not in the kernel subset
- hint: compare with cond

Rejected:

```elixir
defk f(x :: f64) :: i64 do
  case x do
    0.0 -> 0
    _ -> 1
  end
end
```

Write instead:

```elixir
defk f(x :: f64) :: i64 do
  cond do
    x == 0.0 -> 0
    true -> 1
  end
end
```

### case-pattern

A case pattern is an integer literal, true/false, ^var, _ or a variable, with an optional guard.

- kind: outside the kernel subset (permanent)
- why: a kernel matches its i64 or bool subject against single values
- hint: use one of those patterns, or a guard

Rejected:

```elixir
defk f(x :: i64) :: i64 do
  case x do
    {a, b} -> a + b
    _ -> 0
  end
end
```

Write instead:

```elixir
defk f(x :: i64) :: i64 do
  case x do
    n when n > 0 -> n
    _ -> 0
  end
end
```

### case-pattern-type

A case pattern can match the subject's type.

- kind: a mistake to fix (in the kernel or the build)
- why: a literal of another type never matches, as in Elixir
- hint: match a value of the subject's type

Rejected:

```elixir
defk f(b :: bool) :: i64 do
  case b do
    1 -> 1
    _ -> 0
  end
end
```

Write instead:

```elixir
defk f(b :: bool) :: i64 do
  case b do
    true -> 1
    _ -> 0
  end
end
```

### case-guard

A case guard uses guard-safe expressions: variables, literals, arithmetic, comparisons, and/or/not, div, rem, abs, trunc, round, min and max.

- kind: a mistake to fix (in the kernel or the build)
- why: Elixir allows only guard-safe expressions in guards, and kernel calls and indexing are not guard-safe
- hint: compute the value before the case, and use the variable in the guard

Rejected:

```elixir
defk g(x :: i64) :: i64 do
  x * 2
end

defk f(x :: i64) :: i64 do
  case x do
    n when g(n) > 4 -> 1
    _ -> 0
  end
end
```

Write instead:

```elixir
defk g(x :: i64) :: i64 do
  x * 2
end

defk f(x :: i64) :: i64 do
  y = g(x)

  case x do
    _ when y > 4 -> 1
    _ -> 0
  end
end
```

### unsupported-map

Maps and structs are not in the kernel subset.

- kind: outside the kernel subset (permanent)
- why: a kernel works on numbers, booleans, tuples and packed arrays; a map is a BEAM term it can neither build nor read
- hint: pass the values as separate arguments, or pack them into an array before the call

Rejected:

```elixir
defk f(x :: i64) :: i64 do
  m = %{a: x}
  x
end
```

Write instead:

```elixir
defk f(a :: i64) :: i64 do
  a
end
```

### unsupported-string

String concatenation with <> and the ~s sigil are not in the kernel subset; a string literal is a [u8].

- kind: outside the kernel subset (permanent)
- why: kernels see bytes, not text: there are no UTF-8 or grapheme operations, and a kernel cannot build a string at run time
- hint: write one string literal, or pass the bytes as a [u8] argument and do text work in Elixir before or after the call

Rejected:

```elixir
defk f(x :: i64) :: i64 do
  s = "ab" <> "cd"
  len(s) + x
end
```

Write instead:

```elixir
defk f(x :: i64) :: i64 do
  s = "abcd"
  len(s) + x
end
```

### unsupported-atom

Atoms (other than true and false) and nil are not in the kernel subset.

- kind: outside the kernel subset (permanent)
- why: a kernel returns numbers, booleans, tuples and arrays; an atom is a BEAM term
- hint: return a bool or an integer code, and turn it into an atom in Elixir

Rejected:

```elixir
defk f(x :: i64) :: i64 do
  s = if x > 0, do: :pos, else: :neg
  x
end
```

Write instead:

```elixir
defk f(x :: i64) :: bool do
  x > 0
end
```

### unsupported-list

Lists are not in the kernel subset; a kernel takes packed arrays.

- kind: outside the kernel subset (permanent)
- why: a list is a linked BEAM term; a kernel works on packed arrays
- hint: pass the values as an array, a binary such as `for x <- list, into: <<>>, do: <<x::float-native-64>>`

Rejected:

```elixir
defk f(x :: i64) :: i64 do
  xs = [x, x + 1]
  x
end
```

Write instead:

```elixir
defk f(xs :: [i64]) :: i64 do
  xs[0] + xs[1]
end
```

### unsupported-fn

Anonymous functions are not values in a kernel; define another kernel and call it.

- kind: outside the kernel subset (permanent)
- why: a kernel inlines the kernels it calls; a function value would need a BEAM closure
- hint: define the function as a kernel in this module and call it

Rejected:

```elixir
defk f(x :: i64) :: i64 do
  g = fn y -> y * 2 end
  x
end
```

Write instead:

```elixir
defk g(y :: i64) :: i64 do
  y * 2
end

defk f(x :: i64) :: i64 do
  g(x)
end
```

### unsupported-construct

A kernel uses the Elixir forms =, if, cond, case, for, Enum.reduce_while/3, Enum.all?/2 and Enum.any?/2; others such as unless, with, try, receive and throw are not in the kernel subset.

- kind: outside the kernel subset (permanent)
- why: a kernel uses a fixed set of Elixir forms: =, if, cond, case, for, Enum.reduce_while/3, Enum.all?/2 and Enum.any?/2
- hint: write it with those forms

Rejected:

```elixir
defk f(x :: i64) :: i64 do
  unless x > 0, do: 0, else: x
end
```

Write instead:

```elixir
defk f(x :: i64) :: i64 do
  if not (x > 0), do: 0, else: x
end
```

### unsupported-expression

Any other expression is not in the kernel subset.

- kind: outside the kernel subset (permanent)
- why: a kernel uses a fixed set of Elixir forms: =, if, cond, case, for, Enum.reduce_while/3, Enum.all?/2 and Enum.any?/2, over numbers, booleans, tuples and arrays
- hint: write it with those forms, or compute it in Elixir and pass the result in

Rejected:

```elixir
defk f(x :: i64) :: i64 do
  r = 1..x
  x
end
```

Write instead:

```elixir
defk f(x :: i64) :: i64 do
  for i <- 1..x//1, reduce: 0 do
    acc -> acc + i
  end
end
```

### no-c-compiler

No C compiler could be run to build the kernels.

- kind: a mistake to fix (in the kernel or the build)
- why: a kernel is compiled to native code at build time, so a C toolchain is needed on the build machine, as for elixir_make packages
- hint: install one (macOS: `xcode-select --install`; Debian/Ubuntu: `apt install build-essential`; Alpine: `apk add build-base`), or set `CC` to a compiler path

### shift-overflow

A shift of two integer literals whose result does not fit in i64.

- kind: a mistake to fix (in the kernel or the build)
- why: bsl/<<< gives the exact result as Elixir does, and raises ArithmeticError when it does not fit in i64; with literal operands it would raise every time
- hint: write a value past 2^63 - 1 as a u64 literal (0x8000000000000000); a mask (1 <<< k) - 1 directly in band(x, mask) is computed at compile time, for k up to 64

Rejected:

```elixir
defk f(x :: i64) :: i64 do
  band(x, 1 <<< 63)
end
```

Write instead:

```elixir
defk f(x :: u64) :: u64 do
  band(x, 0x8000000000000000)
end
```

### undefined-attribute

A module attribute read in a kernel is defined before the kernel.

- kind: a mistake to fix (in the kernel or the build)
- why: a kernel reads @name as a def does: the attribute's value where the kernel is defined, inlined as a constant
- hint: define the attribute above the kernel, or pass the value as a parameter

Rejected:

```elixir
defk f(x :: i64) :: i64 do
  x * @scale
end
```

Write instead:

```elixir
@scale 3

defk f(x :: i64) :: i64 do
  x * @scale
end
```

### attribute-value

A module attribute read in a kernel holds an integer (in i64 or u64), a float, a boolean or a binary.

- kind: outside the kernel subset (permanent)
- why: a kernel inlines an attribute as a constant: a number or boolean as its literal, a binary as a [u8] that a write copies first; other terms such as lists, tuples, maps and atoms are BEAM terms it cannot hold
- hint: pass the value as a parameter; pack a list of bytes into a binary attribute

Rejected:

```elixir
@table [1, 2, 4, 8]

defk f(i :: i64) :: i64 do
  i + @table
end
```

Write instead:

```elixir
@table <<1, 2, 4, 8>>

defk f(i :: i64) :: i64 do
  @table[i]
end
```

### binary-literal

A binary literal in a kernel is a string or <<...>> of integer bytes (0..255); anything else is built in Elixir.

- kind: outside the kernel subset (permanent)
- why: a binary literal is a read-only [u8] in static storage, so every byte must be known when the kernel compiles: no interpolation, charlists, floats, other segment types or sizes, and no value over 255
- hint: build it in Elixir and pass it as a [u8] parameter, or use a module attribute

Rejected:

```elixir
defk f(i :: i64) :: i64 do
  t = <<1, 2, 300>>
  t[i]
end
```

Write instead:

```elixir
defk f(i :: i64) :: i64 do
  t = <<1, 2, 44>>
  t[i]
end
```

### bitstring-segment

An append to a bitstring accumulator takes big-endian integer segments, unsigned or `signed`: `v::size(n)`, `v::k` or `v`.

- kind: not supported yet (planned)
- why: a kernel appends integer bits; little-endian, float and binary segments are not supported until a workload needs them
- hint: write big-endian integer segments: v::size(n), v::k or v (8 bits), optionally signed

Rejected:

```elixir
defk f(x :: i64) :: bitstring do
  acc = <<>>
  <<acc::bitstring, x::little-16>>
end
```

Write instead:

```elixir
defk f(x :: i64) :: bitstring do
  acc = <<>>
  <<acc::bitstring, band(x, 255)::8, band(bsr(x, 8), 255)::8>>
end
```

### bitstring-use

A bitstring accumulator starts from `<<>>`, is appended to, measured with `bit_size/1` and returned; nothing else.

- kind: not supported yet (planned)
- why: a bitstring is a kernel's output: reading it, starting from an input binary, taking it as a parameter or passing it to another kernel is not supported yet
- hint: measure it with bit_size/1, and keep what the kernel needs to read in variables or an array

Rejected:

```elixir
defk f(n :: i64) :: i64 do
  acc = <<>>
  acc = <<acc::bitstring, n::8>>
  len(acc)
end
```

Write instead:

```elixir
defk f(n :: i64) :: i64 do
  acc = <<>>
  acc = <<acc::bitstring, n::8>>
  bit_size(acc)
end
```

### raise-value

`raise` in a kernel is a statement: it cannot be a value, the last expression of a kernel or of a branch that gives one.

- kind: a mistake to fix (in the kernel or the build)
- why: a kernel's values are numbers, booleans, tuples and arrays; a raise has no value to give, so it goes where a statement goes
- hint: raise is a statement; put it before the value: `if not ok, do: raise(...)` on its own line, then the value

Rejected:

```elixir
defk f(x :: i64) :: i64 do
  if x >= 0, do: x * 2, else: raise(ArgumentError, "x must not be negative")
end
```

Write instead:

```elixir
defk f(x :: i64) :: i64 do
  if x < 0, do: raise(ArgumentError, "x must not be negative")
  x * 2
end
```

### raise-message

A kernel's `raise` message is a string literal: no interpolation or computed value.

- kind: outside the kernel subset (permanent)
- why: the message is a C string in the kernel's static storage, so it is known when the kernel compiles; formatting a value would need a BEAM binary
- hint: a kernel raises with a literal message: put the value in Elixir, before or after the call

Rejected:

```elixir
defk f(n :: i64) :: i64 do
  if n < 1, do: raise(ArgumentError, "bad length #{n}")
  n
end
```

Write instead:

```elixir
defk f(n :: i64) :: i64 do
  if n < 1, do: raise(ArgumentError, "length must be positive")
  n
end
```

### raise-module

A kernel raises ArgumentError, ArithmeticError or RuntimeError.

- kind: outside the kernel subset (permanent)
- why: the runtime builds the exception natively, for the modules whose only field is the message
- hint: use ArgumentError, ArithmeticError or RuntimeError

Rejected:

```elixir
defk f(n :: i64) :: i64 do
  if n < 1, do: raise(KeyError, "no such key")
  n
end
```

Write instead:

```elixir
defk f(n :: i64) :: i64 do
  if n < 1, do: raise(ArgumentError, "no such key")
  n
end
```

### array-rebind-in-loop

An array variable read after a loop is not bound again inside the loop body; write its elements, or carry it as a reduce accumulator.

- kind: a mistake to fix (in the kernel or the build)
- why: as in Elixir, a variable bound inside a loop body is gone after the loop, so the array after the loop is still the one from before it; an element write `a[i] = v` changes the array for the rest of the kernel, and a reduce accumulator carries a rebound array to the next iteration and out of the loop
- hint: write the array's elements in the loop (a[i] = v); to bind it again, as {a, k} = helper(a, ...) does, make it a reduce accumulator: {a, n} = for ..., reduce: {a, 0} do {a, n} -> ... end; or give the array bound inside the loop a new name

Rejected:

```elixir
defk f(n :: i64) :: [i64] do
  a = alloc(i64, n)

  for i <- 0..(n - 1)//1 do
    a = alloc(i64, n)
    a[i] = i
  end

  a
end
```

Write instead:

```elixir
defk f(n :: i64) :: [i64] do
  a = alloc(i64, n)

  for i <- 0..(n - 1)//1 do
    a[i] = i
  end

  a
end
```

### write-not-returned

A kernel called from another kernel returns every array parameter it writes.

- kind: a mistake to fix (in the kernel or the build)
- why: arrays are values: a write gives the callee's parameter a new array, and the caller sees it only if the callee returns it and the caller binds it
- hint: return the array (in a tuple with the other results) and bind it again at the call: {out, n} = fill(out, ...)

Rejected:

```elixir
defk fill(out :: [i64], v :: i64) :: i64 do
  out[0] = v
  v
end

defk f(n :: i64) :: [i64] do
  out = alloc(i64, n)
  _ = fill(out, 7)
  out
end
```

Write instead:

```elixir
defk fill(out :: [i64], v :: i64) :: {[i64], i64} do
  out[0] = v
  {out, v}
end

defk f(n :: i64) :: [i64] do
  out = alloc(i64, n)
  {out, _} = fill(out, 7)
  out
end
```

## 12. Limits

Every case where a kernel raises or refuses to compile where Elixir would have
succeeded. Each is allowed by the one rule; one missing from this table is a
bug.

| Limit | Elixir | Kernel |
|---|---|---|
| `+`, `-`, `*`, unary `-`, `abs/1` with a result outside `i64` | a bignum | `ArithmeticError` "i64 overflow in a * b" |
| `div(-9223372036854775808, -1)` | `9223372036854775808` | `ArithmeticError` "i64 overflow in div/2" |
| `trunc/1`, `round/1` of a float outside the `i64` range | a bignum | `ArithmeticError` "trunc/1: ... does not fit in i64" |
| an integer literal outside -2^63..2^64 - 1, and `-9223372036854775808` | a bignum | compile error [`integer-literal`](#integer-literal) |
| a module attribute holding an integer outside -2^63..2^64 - 1, read in a kernel | a bignum | compile error [`integer-literal`](#integer-literal) |
| `u64` `+`, `-`, `*`, `bsl` with a result outside 0..2^64 - 1 | a bignum, or a negative integer | `ArithmeticError` "u64 overflow in 3 - 5" |
| a `u64` above 2^63 - 1 where an `i64` is expected (index, length, range bound, `i64` parameter, result or accumulator), and `rotl/3`, `rotr/3` of an `i64` giving one | the integer | `ArithmeticError` "... does not fit in i64" |
| a negative `i64` where a `u64` is expected | the integer | `ArithmeticError` "-1 does not fit in u64" |
| a `[u64]` write of a negative value, an `[i64]` write of a `u64` above 2^63 - 1 | `<<-1::64>>` wraps | `ArgumentError` "value -1 does not fit in u64" |
| a `u64` mixed with an `i64` that may be negative in `+ - * band bor bxor div rem min max`, outside a mask | runs | compile error [`u64-mix`](#u64-mix) |
| `bnot` or unary `-` of a `u64` outside a mask | a negative integer | compile error [`operand-type`](#operand-type) |
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
| `alloc/2` of more than 2^48 bytes | (the VM would abort) | `ArgumentError` "alloc/2: length too large" |
| `alloc/2` of a size the allocator cannot provide | (the VM would abort) | `ArgumentError` "out of memory"; Elixir mode raises it from 2^47 bytes without trying |
| a range whose last element is within one step of the `i64` limit, e.g. `0..9223372036854775807` | runs | `ArithmeticError` "range element ... is within one step of the i64 limit" before the loop starts, also when the loop would stop earlier |
| an `i64` overflow inside a `case` guard (`n * n > 100`) | the guard is computed exactly | `ArithmeticError`. A zero divisor in a guard is no limit: it fails the clause, as in Elixir |
| ordering booleans, comparing a boolean with a number | term order | compile error [`operand-type`](#operand-type) |
| `&&`, `\|\|`, `!` on non-boolean values | truthiness | compile error [`operand-type`](#operand-type) |
| recursion, direct or mutual | runs | compile error [`recursion`](#recursion) |
| every construct in [What is not an expression](#what-is-not-an-expression) | runs | a compile error with its code |
| code size: each call to a kernel is inlined | one function | the generated code grows with the number of call sites along each call chain (no error) |
| an array variable bound again inside a loop body and read after the loop | the binding is gone after the loop | compile error [`array-rebind-in-loop`](#array-rebind-in-loop) |
| a called kernel writing an array parameter it does not return | the write is lost | compile error [`write-not-returned`](#write-not-returned) |
| memory of arrays written in a loop while another variable still reads them | the old binaries are garbage collected | each copy (see [Copies](#copies)) lives until the kernel returns |
| the C compiler is needed at build time | | compile error [`no-c-compiler`](#no-c-compiler) |

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
