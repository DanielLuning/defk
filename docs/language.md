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
`@spec` derived from its types (`i64` is `integer()`, an `f64` parameter is
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
| `f64` | a double | a float, or an integer that fits in `i64` (converted to a float); anything else raises `ArgumentError` "argument N (name) must be a number" | a float, always finite: any operation that would make inf or NaN raised first |
| `bool` | `true` or `false` | `true` or `false`; anything else (including `nil`) raises `ArgumentError` "argument N (name) must be a boolean" | `true` or `false` |
| `[f64]`, `[i64]`, `[u8]` | an array of that element type | a binary of packed native-endian elements; not a binary, or a byte size that is not a multiple of the element size, raises `ArgumentError` | a binary of packed native-endian elements |
| `{t1, t2, ...}` | see below | not allowed ([`tuple-parameter`](#tuple-parameter)) | a tuple |

**Supported:** `i64`, `f64`, `bool`, `[f64]`, `[i64]`, `[u8]`. Any other type
name is [`unknown-type`](#unknown-type), whose hint names the kernel type for
the Elixir one (`integer` is `i64`, `float` and `number` are `f64`, `binary` is
`[u8]`).

**Supported with restrictions:** tuples. A tuple of scalars and arrays is a
return type (`:: {f64, f64}`, `:: {[f64], i64}`). Inside a kernel, tuples exist
only where they are taken apart at once: destructured by `{a, b} = ...`,
as `reduce:` and `Enum.reduce_while` accumulators, and as the result. A
variable cannot hold a tuple ([`tuple-binding`](#tuple-binding)), tuples do not
nest ([`nested-tuple`](#nested-tuple)), a branch cannot give one
([`branch-tuple`](#branch-tuple)), a call cannot take one
([`tuple-argument`](#tuple-argument)), and a kernel that returns one cannot be
called from another kernel ([`tuple-return-call`](#tuple-return-call)).

An array's **element type** is `f64`, `i64` or `u8`. Reading a `[u8]` element
gives an `i64` in 0..255.

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

- Integer literals must fit in `i64`
  ([`integer-literal`](#integer-literal)). `-9223372036854775808` is the
  negation of a literal that does not fit, so it is rejected too; write
  `-9223372036854775807 - 1`.
- Float literals are `f64`. An integer literal where an `f64` is expected
  (a result, an argument, a `[f64]` write) widens, as in Elixir arithmetic.
- `true` and `false` are `bool`. Other atoms and `nil` are
  [`unsupported-atom`](#unsupported-atom); strings are
  [`unsupported-string`](#unsupported-string).

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
does not raise. An `[f64]` input element whose bits are inf or NaN raises
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
| `min(a, b)`, `max(a, b)` | two `i64` or two `f64` (not mixed) | the same type; when the two compare equal, the first argument, as Erlang does (`min(-0.0, 0.0)` is `-0.0`) | |
| `abs(x)` | `i64` or `f64` | the same type | `i64`: `ArithmeticError` for -2^63 |
| `float(x)` | a number | `f64` (an `i64` above 2^53 rounds, as in Elixir) | |
| `trunc(x)`, `round(x)` | a number (an `i64` is returned unchanged) | `i64`; `round` rounds half away from zero (`round(-2.5)` is `-3`) | `ArithmeticError` "trunc/1: ... does not fit in i64" when the result is outside `i64` (a limit) |
| `div(a, b)`, `rem(a, b)` | two `i64` | `i64` | see [Integer arithmetic](#integer-arithmetic) |
| `sqrt(x)` | a number | `f64` | `ArithmeticError` for a negative `x` |
| `log(x)` | a number | `f64` | `ArithmeticError` for `x <= 0` |
| `exp(x)`, `sin(x)`, `cos(x)` | a number | `f64` | |
| `pow(a, b)` | two numbers | `f64`, like `:math.pow/2` (`pow(2, 10)` is `1024.0`) | |
| `alloc(type, n)` | an element type and an `i64` length | a new zero-filled array | see [Arrays](#6-arrays) |
| `wrap64(expr)` | an `i64` expression | the low 64 bits of its exact result as a signed `i64`, as `Defk.Bits.wrap64/1` | see [Masked arithmetic](#masked-arithmetic) |
| `mulhi(a, b)` | two `i64` | `i64`: the high 64 bits of the unsigned 128-bit product of the u64 bit patterns, as `Defk.Bits.mulhi/2` | see [Bit builtins](#bit-builtins) |
| `clz(x)`, `ctz(x)`, `popcount(x)` | an `i64` | `i64` in 0..64: leading zeros, trailing zeros (64 for 0), set bits of the u64 pattern | see [Bit builtins](#bit-builtins) |
| `rotl64(x, n)`, `rotr64(x, n)` | two `i64` | `i64`: the 64-bit pattern of `x` rotated by `band(n, 63)` | see [Bit builtins](#bit-builtins) |
| `u64_le(b, i)`, `u32_le`, `u16_le`, `u64_be`, `u32_be`, `u16_be` | a `[u8]` and an `i64` byte offset | `i64`: the unsigned word at `i` (`u64` as its signed bit pattern) | see [Word loads](#word-loads) |

`length/1`, `byte_size/1` and `tuple_size/1` are
[`unknown-function`](#unknown-function) with the hint to use `len/1`.

`dbg/1` and `IO.inspect/1,2` are accepted around an expression: native code
evaluates the expression and ignores the call, and Elixir mode prints it (see
[section 10](#10-elixir-mode)).

### Bitwise operators

On `i64`: `band(a, b)`, `bor`, `bxor`, `bnot(a)`, `bsl(a, n)`, `bsr(a, n)`,
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

`mulhi(a, b)`, `clz(x)`, `ctz(x)`, `popcount(x)`, `rotl64(x, n)` and
`rotr64(x, n)` work on the u64 bit pattern of an `i64` and return an `i64`
(a pattern, so a value with the top bit set is negative). Each is a plain
function in `Defk.Bits` with a doctest, which Elixir mode calls, so both
modes give the same value:

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

Operands must be `i64`; `f64` and `bool` are rejected
([builtin-arguments](#builtin-arguments)). None of them can raise. (defk-52v.6)

### Masked arithmetic

**Supported:** integer arithmetic inside `band(expr, m)`, where `m` is an
integer literal (or an integer module attribute) equal to 2^k - 1 for
1 <= k <= 63 (`255`, `0xFFFFFFFF`, `0x7FFFFFFFFFFFFFFF`), and inside
`wrap64(expr)`, the 64-bit wrap. This is how hashes and checksums wrap:

```elixir
defk fnv1a(bytes :: [u8]) :: i64 do
  for b <- bytes, reduce: 2_166_136_261 do
    h -> band(bxor(h, b) * 16_777_619, 0xFFFFFFFF)
  end
end
```

The rule, the same in native code and Elixir mode:

- The **wrapped tree** is the contiguous tree of `+`, `-` (binary and
  unary), unary `+`, `*`, and `bsl` (in any spelling: `<<<`,
  `Bitwise.bsl/2`) by a non-negative integer literal, directly under the
  mask (or directly inside `wrap64`). Either `band` operand may be the mask
  (`band(255, x + y)`), and `x &&& m` and `Bitwise.band(x, m)` work the
  same.
- Every other expression inside it is a **leaf**: a variable, a literal, an
  array read, a word load, a call, `div`/`rem`, `bsr`, `bor`/`bxor`, a
  `bsl` by a non-literal count, and another `band` (whose own mask governs
  its own tree). A leaf is lowered as usual, with its own checks, and its
  `i64` value enters the tree. So `band(x * y + rem(x * y, 7), 255)` wraps
  the outer `*` and `+` but raises if the `x * y` inside `rem` overflows.
- The tree is computed with wrapping 64-bit machine arithmetic, with no
  overflow check, and the mask is applied once. Every tree operation is
  arithmetic modulo 2^64, so the low k bits are those of the exact result:
  for k <= 63 the value is Elixir's `band` of the bignum, and nothing in the
  tree raises (`band(x + y, 255)` with `x + y` past the `i64` limit gives
  Elixir's answer).
- `wrap64(expr)` gives the low 64 bits of the exact result as a signed
  `i64` (two's complement). Its Elixir meaning is the function
  `Defk.Bits.wrap64/1` (`<<r::signed-64>> = <<x::64>>`), which Elixir mode
  calls on the exact result and which you can call from plain Elixir for the
  same value: `Defk.Bits.wrap64(h * 1_099_511_628_211 + b)`. `wrap64` of a
  leaf (`wrap64(x)`) is `x`. There is no 64-bit `band` mask: 2^64 - 1 is
  not an `i64` literal ([`integer-literal`](#integer-literal)), and
  `band(expr, -1)` is Elixir's identity, an ordinary `band` whose operand is
  checked.
- A mask `m >= 0` gives a value in `0..m`, so `table[band(h * 31 + b, 255)]`
  skips its bounds check against a 256-element array.
- A `band` whose mask is not a literal 2^k - 1, such as `band(x * y, 254)`,
  `band(x * y, -1)` or `band(x * y, m)` with a variable `m`, is an ordinary
  `band`: its operand is checked arithmetic and raises on `i64` overflow.

FNV-1a 64 with `wrap64`, its offset basis 0xCBF29CE484222325 written
as its `i64` bit pattern:

```elixir
defk fnv1a64(bytes :: [u8]) :: i64 do
  for b <- bytes, reduce: -3_750_763_034_362_895_579 do
    h -> wrap64(bxor(h, b) * 1_099_511_628_211)
  end
end
```

(defk-n4r.2)

### Module attributes

**Supported:** `@name` in a kernel body reads a module attribute as a
constant, with the value it has where the kernel is defined, as in a `def`
(an attribute redefined after the kernel does not change it). The value is
inlined when the module compiles, the same in native code and Elixir mode:

| Attribute value | In the kernel |
|---|---|
| an integer in `i64` | that integer literal, `i64` |
| a float | that float literal, `f64` |
| `true`, `false` | that boolean literal |
| a binary | a read-only `[u8]` array of its bytes, kept in the kernel's static data |

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
It cannot be written ([`read-only-array`](#read-only-array)) or returned
([`return-input-array`](#return-input-array)), and it is not a `case`
pattern. Its bytes are compiled into the NIF, so a large table makes the
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
| string literals, sigils `~s`, `<>`, interpolation | [`unsupported-string`](#unsupported-string) |
| atoms other than `true`/`false`, `nil` | [`unsupported-atom`](#unsupported-atom) |
| lists, `++`, `--` | [`unsupported-list`](#unsupported-list) |
| `fn`, captures `&f/1` (except the `fn` of `Enum.reduce_while/3`, `Enum.all?/2`, `Enum.any?/2`) | [`unsupported-fn`](#unsupported-fn), [`fn-argument`](#fn-argument) |
| the pipe `\|>` | [`pipe`](#pipe) (the hint shows the nested call) |
| a module attribute holding a list, tuple, map, atom or `nil`, or not defined above the kernel | [`attribute-value`](#attribute-value), [`undefined-attribute`](#undefined-attribute) |
| building a bitstring `<<...>>` | [`bitstring-build`](#bitstring-build) (planned) |
| binary patterns `<<a, b, rest::binary>> = arr` | [`bitstring-match`](#bitstring-match) |
| calls to other modules (`Enum.sum/1`, `Enum.map/2`, `String.*`, `:math.tan/1`, ...) | [`unsupported-call`](#unsupported-call), [`enum-reduce`](#enum-reduce) and [`enum-find`](#enum-find) (planned) |
| a range as a value (`r = 1..10`), `x in [1, 2, 3]`, `**`, a match used as a value | [`unsupported-expression`](#unsupported-expression) |
| `unless`, `with`, `try`, `receive`, `raise`, `throw`, `send`, `spawn`, ... | [`unsupported-construct`](#unsupported-construct) |
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
- **`_` and `_name`** discard the value, but the right side is still
  evaluated, so `_ = x * x` raises on overflow as Elixir would.
- **Tuple destructuring:** `{a, b} = expr`, where `expr` gives a tuple (a
  tuple literal, a `reduce:` with a tuple accumulator, an
  `Enum.reduce_while`). `{a, b} = {b, a}` swaps. The sizes must match
  ([`tuple-size`](#tuple-size)).
- **Unsupported:** binding a whole tuple to one variable
  ([`tuple-binding`](#tuple-binding)), other patterns such as lists and maps
  ([`unsupported-pattern`](#unsupported-pattern)), binary patterns
  ([`bitstring-match`](#bitstring-match)), a match used as a value
  (`x = y = 1`, [`unsupported-expression`](#unsupported-expression)), and an
  undefined variable ([`undefined-variable`](#undefined-variable)).
- **Arrays are references.** `b = a` names the same array; it copies nothing.
  Today a write through one name is visible through the other, where Elixir
  would keep `b` unchanged: see [Arrays](#aliasing) and
  [Known divergences](#13-known-divergences).

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
  masked arithmetic or `wrap64`, where only the bits matter.
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

**Supported:** `alloc(f64 | i64 | u8, n)` returns a new array of `n` elements,
all zero. A malformed call is [`alloc-form`](#alloc-form).

- A negative `n` raises `ArgumentError` "alloc/2: negative length n".
- More than 2^48 bytes (the user address space of 64-bit platforms) raises
  `ArgumentError` "alloc/2: length too large". A size under that which the
  allocator cannot provide raises `ArgumentError` "out of memory".
- Every array a kernel allocates lives until the kernel returns; an `alloc`
  inside a loop allocates on every iteration. Arrays that are not returned
  are freed when the kernel returns or raises, or when its process dies while
  it is suspended.

### Writing

**Supported with restrictions:** `out[i] = v` is a statement that stores `v`
at index `i` (bounds-checked like a read).

- Only arrays the kernel created are writable: the result of `alloc/2`, or an
  array returned by a called kernel. Writing to an input array, or to an array
  parameter inside a called kernel, is
  [`read-only-array`](#read-only-array) (not supported yet); its rewrite
  copies the input into an `alloc` first.
- The stored value must have the element type: `[f64]` takes an `f64` or an
  `i64` (widened), `[i64]` takes an `i64`, `[u8]` takes an `i64`
  ([`type-mismatch`](#type-mismatch) otherwise).
- A `[u8]` write of a value outside 0..255 raises `ArgumentError` "value 300
  does not fit in u8". Elixir's `<<300::8>>` would wrap; a kernel never
  wraps silently (a limit). Write `rem(v, 256)` for a non-negative `v` if
  wrapping is what you want.
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

### Returning

**Supported with restrictions:** a kernel may return an array it created
(alone or in a result tuple); it reaches the caller as a binary without a
copy. Returning an input array is
[`return-input-array`](#return-input-array) (not supported yet).

Arrays cannot be the value of an `if`, `cond` or `case`
([`array-in-branch`](#array-in-branch), not supported yet), nor a `reduce:`
or `Enum.reduce_while` accumulator
([`array-accumulator`](#array-accumulator)).

### Inputs

An array argument is read in place, without a copy. A binary whose data is not
aligned to the element size (for example a sub-binary at an odd byte offset)
is copied once, into an aligned buffer, when the kernel starts. Either way the
caller's binary is never changed.

### Aliasing

`b = a` and passing `a` to a called kernel name the same array. Today a write
through `a` after `b = a` is visible through `b`:

```elixir
defk alias_w(n :: i64) :: f64 do
  a = alloc(f64, n)
  b = a
  a[0] = 1.0
  b[0]
end
```

```elixir
iex> M.alias_w(1)
1.0
```

Elixir (and Elixir mode) give `0.0`. This is a divergence, being removed by
defk-auo (copy on an aliased write). Until then, do not write to an array
while another variable still names it.

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
- **Limit:** an error inside a guard (an overflow, `rem` by zero) raises it,
  where Elixir would treat the guard as false and try the next clause.

### `for`

**Supported with restrictions.** Generators:

- `x <- first..last` and `x <- first..last//step` over `i64` bounds.
- `x <- array`: each element in order (a `[u8]` element is an `i64`).

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
  [`accumulator-pattern`](#accumulator-pattern).
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
- An array argument is passed by reference and is read-only in the callee. An
  array the callee returns is a new array the caller may write and return.
- Recursion, direct or through other kernels, is
  [`recursion`](#recursion): write it as a `for ..., reduce:` or
  `Enum.reduce_while/3` loop.
- A kernel that returns a tuple cannot be called from a kernel
  ([`tuple-return-call`](#tuple-return-call)), and a tuple cannot be an
  argument ([`tuple-argument`](#tuple-argument)).
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
  `ArgumentError`, `Enum.OutOfBoundsError`, `CaseClauseError`), after the
  kernel's own buffers are freed. Catch it like any other.
- **Process death.** A process killed while its kernel is suspended between
  steps frees the kernel's frame and arrays (`__defk_stats__().frames_live`
  goes back down; `demo.exs` shows it).
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
- Elixir mode is always compiled in `:test`. There every kernel's NIF is
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

Arrays have value semantics in Elixir mode (a write rebuilds the binary), which
is why the aliasing divergence of [section 6](#aliasing) shows up as a
disagreement.

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
Compiling 6 files (.ex)
Generated defk app
Compiling 2 files (.ex)
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

Kernel types are i64, f64, bool, [f64], [i64], [u8] and tuples of them for results.

- kind: a mistake to fix (in the kernel or the build)
- why: a kernel works on native numbers and packed arrays, and these are the types it has
- hint: use i64, f64, bool, [f64], [i64] or [u8] (a tuple of them for a result)

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

A returned array is one the kernel created with alloc/2; returning an input array is planned.

- kind: not supported yet (planned)
- why: a kernel returns arrays it allocated itself; handing an input array back to the caller is planned
- hint: copy it into an array from alloc/2 and return that

Rejected:

```elixir
defk f(a :: [f64]) :: [f64] do
  a
end
```

Write instead:

```elixir
defk f(a :: [f64]) :: [f64] do
  out = alloc(f64, len(a))

  for i <- 0..(len(a) - 1)//1 do
    out[i] = a[i]
  end

  out
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

Integer literals fit in i64.

- kind: a mistake to fix (in the kernel or the build)
- why: kernel integers are i64 (-2^63..2^63 - 1); a kernel never uses bignums
- hint: use a value that fits, or compute in f64

Rejected:

```elixir
defk f(x :: i64) :: i64 do
  x + 9_223_372_036_854_775_808
end
```

Write instead:

```elixir
defk f(x :: i64) :: f64 do
  x + 9.223372036854776e18
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

### not-an-array

Only arrays can be indexed with a[i].

- kind: a mistake to fix (in the kernel or the build)
- why: a[i] reads an element of an array ([f64], [i64] or [u8]), and this value is not one
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

### read-only-array

Only arrays created with alloc/2 are written; writing to an input array is planned.

- kind: not supported yet (planned)
- why: an input array is the caller's binary, and a kernel never changes a value the caller holds
- hint: copy it into an array from alloc/2 and write that

Rejected:

```elixir
defk f(a :: [f64]) :: [f64] do
  a[0] = 1.0
  a
end
```

Write instead:

```elixir
defk f(a :: [f64]) :: [f64] do
  out = alloc(f64, len(a))

  for i <- 0..(len(a) - 1)//1 do
    out[i] = a[i]
  end

  out[0] = 1.0
  out
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
- why: a kernel runs as native code: it can call its builtins (len, min, max, abs, float, trunc, round, div, rem, sqrt, exp, log, sin, cos, pow, band, bor, bxor, bnot, bsl, bsr, wrap64, u64_le, u64_be, u32_le, u32_be, u16_le, u16_be, mulhi, clz, ctz, popcount, rotl64, rotr64) and the kernels in this module, which are inlined
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

alloc/2 takes an element type (f64, i64 or u8) and a length.

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

### tuple-return-call

A kernel that returns a tuple is called from Elixir only.

- kind: outside the kernel subset (permanent)
- why: a kernel's tuple result becomes a BEAM tuple, and inside a kernel a tuple can't be held as one value
- hint: split it into kernels that return one value each

Rejected:

```elixir
defk g(x :: i64) :: {i64, i64} do
  {x, x + 1}
end

defk f(x :: i64) :: i64 do
  {a, b} = g(x)
  a + b
end
```

Write instead:

```elixir
defk g_lo(x :: i64) :: i64 do
  x
end

defk g_hi(x :: i64) :: i64 do
  x + 1
end

defk f(x :: i64) :: i64 do
  g_lo(x) + g_hi(x)
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

### array-accumulator

Arrays are not accumulators; allocate the array before the loop and write it in the body.

- kind: outside the kernel subset (permanent)
- why: an accumulator is a number or a boolean (or a tuple of them); an array is written in place
- hint: allocate the array before the loop and write it in the body

Rejected:

```elixir
defk f(n :: i64) :: [f64] do
  for i <- 0..(n - 1)//1, reduce: alloc(f64, n) do
    out -> out
  end
end
```

Write instead:

```elixir
defk f(n :: i64) :: [f64] do
  out = alloc(f64, n)

  for i <- 0..(n - 1)//1 do
    out[i] = float(i)
  end

  out
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

Strings are not in the kernel subset; a kernel sees bytes as a [u8] array.

- kind: outside the kernel subset (permanent)
- why: kernels see bytes, not text: there are no UTF-8 or grapheme operations
- hint: pass the bytes as a [u8] argument, and do text work in Elixir before or after the call

Rejected:

```elixir
defk f(x :: i64) :: i64 do
  s = "hello"
  x
end
```

Write instead:

```elixir
defk f(s :: [u8]) :: i64 do
  s[0]
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

### bitstring-build

Building bitstrings with <<...>> is planned (the bitstring accumulator).

- kind: not supported yet (planned)
- why: a kernel produces bytes by writing an alloc/2 array; building bitstrings is planned
- hint: write the bytes into an alloc(u8, n) array

Rejected:

```elixir
defk f(x :: i64) :: i64 do
  b = <<x::8>>
  x
end
```

Write instead:

```elixir
defk f(x :: i64) :: [u8] do
  b = alloc(u8, 1)
  b[0] = rem(x, 256)
  b
end
```

### unsupported-construct

A kernel uses the Elixir forms =, if, cond, case, for, Enum.reduce_while/3, Enum.all?/2 and Enum.any?/2; others such as unless, with, try, receive and raise are not in the kernel subset.

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
- hint: a mask (1 <<< n) - 1 can be computed in i64 for n <= 62; write the 63-bit one as 0x7FFFFFFFFFFFFFFF, and drop a mask that the value already fits

Rejected:

```elixir
defk f(x :: i64) :: i64 do
  band(x, (1 <<< 63) - 1)
end
```

Write instead:

```elixir
defk f(x :: i64) :: i64 do
  band(x, 0x7FFFFFFFFFFFFFFF)
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

A module attribute read in a kernel holds an integer (in i64), a float, a boolean or a binary.

- kind: outside the kernel subset (permanent)
- why: a kernel inlines an attribute as a constant: a number or boolean as its literal, a binary as a read-only [u8]; other terms such as lists, tuples, maps and atoms are BEAM terms it cannot hold
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

## 12. Limits

Every case where a kernel raises or refuses to compile where Elixir would have
succeeded. Each is allowed by the one rule; one missing from this table is a
bug.

| Limit | Elixir | Kernel |
|---|---|---|
| `+`, `-`, `*`, unary `-`, `abs/1` with a result outside `i64` | a bignum | `ArithmeticError` "i64 overflow in a * b" |
| `div(-9223372036854775808, -1)` | `9223372036854775808` | `ArithmeticError` "i64 overflow in div/2" |
| `trunc/1`, `round/1` of a float outside the `i64` range | a bignum | `ArithmeticError` "trunc/1: ... does not fit in i64" |
| an integer literal outside `i64`, including `-9223372036854775808` | a bignum | compile error [`integer-literal`](#integer-literal) |
| a module attribute holding an integer outside `i64`, read in a kernel | a bignum | compile error [`integer-literal`](#integer-literal) |
| u64 loads (`u64_le/2`, `u64_be/2`) return the bit pattern as `i64` | `x::unsigned-64` gives up to 2^64 - 1 | a word with the top bit set is a negative `i64` (see [Word loads](#word-loads)) |
| an `i64` argument outside `i64` | any integer | `ArgumentError` "argument N (name) must be an integer fitting in i64" |
| an `f64` argument that is an integer outside `i64` | converts | `ArgumentError` "argument N (name) must be a number" |
| a `[u8]` write of a value outside 0..255 | `<<300::8>>` wraps | `ArgumentError` "value 300 does not fit in u8" |
| `alloc/2` of more than 2^48 bytes | (the VM would abort) | `ArgumentError` "alloc/2: length too large" |
| `alloc/2` of a size the allocator cannot provide | (the VM would abort) | `ArgumentError` "out of memory"; Elixir mode raises it from 2^47 bytes without trying |
| a range whose last element is within one step of the `i64` limit, e.g. `0..9223372036854775807` | runs | `ArithmeticError` "range element ... is within one step of the i64 limit" before the loop starts, also when the loop would stop earlier |
| an error inside a `case` guard (overflow, `rem` by zero) | the guard fails, the next clause is tried | the error is raised |
| ordering booleans, comparing a boolean with a number | term order | compile error [`operand-type`](#operand-type) |
| `&&`, `\|\|`, `!` on non-boolean values | truthiness | compile error [`operand-type`](#operand-type) |
| recursion, direct or mutual | runs | compile error [`recursion`](#recursion) |
| every construct in [What is not an expression](#what-is-not-an-expression) | runs | a compile error with its code |
| code size: each call to a kernel is inlined | one function | the generated code grows with the number of call sites along each call chain (no error) |
| the C compiler is needed at build time | | compile error [`no-c-compiler`](#no-c-compiler) |

## 13. Known divergences

A divergence is a different value or behaviour without raising; the one rule
does not allow any. The `Defk.Divergences` registry is still a placeholder
(defk-813), so this list is kept by hand. Each entry is a bug with a ticket.

| Divergence | Elixir and Elixir mode | Kernel on `main` | Ticket |
|---|---|---|---|
| A write through an array visible through another variable naming it (`b = a; a[0] = 1.0; b[0]`) | `b` keeps its value (`0.0`) | `1.0` | defk-auo |

Related, though not a divergence (both sides raise): when both operands of an
operator can raise, as in `a[i] + b * c`, Elixir raises the left one's error;
a kernel may raise either, since the generated C leaves the order of the two
unspecified. The exception can then differ between a kernel and Elixir mode.

## 14. Changes in flight

None at the moment: every construct above is on `main`. A feature ticket that
changes the language adds its entries here while its branch is open.
