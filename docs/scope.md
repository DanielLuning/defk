# Scope: what defk is, isn't yet, and won't be

This page says what defk is for, when to use something else, what is planned
but not built, and what will stay out by design. The two lists of compile
errors on it are generated from the compiler's error registry
(`Defk.Errors`), and the tests fail if the page and the compiler disagree.

## What defk is

defk asks one question: **can a typed subset of Elixir compile to native code
that runs at C speed, with a cheap call boundary, while keeping the BEAM's
promises?** For loops over numbers and bytes the answer was yes, and defk is
a library on Hex, from `0.1.0` with a [stability promise](guides/stability.md).

You write a **kernel** with `defk` in an ordinary module. It reads like
Elixir, takes typed numbers and packed binaries, and compiles to a checked
native function (a NIF) when the module compiles:

```elixir
defk total(xs :: [i64]) :: i64 do
  for x <- xs, reduce: 0 do
    acc -> acc + x
  end
end
```

```elixir
iex> M.total(<<1::native-64, 2::native-64, 3::native-64>>)
6
iex> M.total(<<9223372036854775807::native-64, 1::native-64>>)
** (ArithmeticError) i64 overflow in 9223372036854775807 + 1
```

What a kernel promises:

- **The one rule.** A kernel is Elixir over numbers and binaries: it gives
  the result Elixir would, or raises where its types can't hold that result
  (the overflow above, where Elixir would give a bignum), or doesn't compile.
  It never gives a different answer. Every kernel also compiles to plain
  Elixir (Elixir mode), so tests can check the two agree.
- **The runtime contract.** A long kernel yields to its scheduler, so it
  never starves other processes. An error in it is an ordinary exception in
  the calling process, and so is a fault inside its native code (a defk
  bug): the node keeps running. If the process dies while its kernel is
  suspended, everything the kernel allocated is freed. A kernel suspended
  across a reload of its module finishes in the code it started in.
- **Checked memory access.** Every array read and write is bounds-checked; the
  compiler leaves a check out only where it proves the index in range.

The full language, its limits and every compile error are in
[the kernel subset reference](language.md).

## When to use it, and when not

Elixir is the default. defk exists to help where Elixir today pushes people
towards a hand-written NIF, not to beat Elixir. Every claim below comes from
the [example catalog](https://github.com/DanielLuning/defk/blob/main/examples/README.md),
where each job is written in Elixir and as a kernel, the Elixir side is
optimised first, and both are measured end to end. A kernel counts as a win
only when it is at least 2x faster than the best Elixir; below that, use
Elixir.

**defk can help** with loops over numbers or bytes, where the data is
already packed in a binary (or is packed once and reused), and each call does
enough work to pay for the call: rolling statistics, nearest-neighbour
search, image filters, FFT and convolution, non-cryptographic hashes, codecs
such as base64, and similar numeric or byte-level jobs. Most of the numbers
behind this list were measured on a loaded machine and are provisional until
a quiet-machine run. A provisional win is a reason to measure your own job
([Measuring](guides/measuring.md)), not a promise.

**Elixir is the right choice** when:

- the data arrives as a list (Ecto rows, decoded JSON): packing it costs
  more than Elixir's whole loop;
- each call does little work, such as one kernel call per element inside
  `Enum.map`, or small inputs: the call costs more than the work;
- the job builds BEAM terms, such as maps, strings or lists: a kernel cannot
  build them;
- the BEAM already has a native answer: `:binary.match/2`, `:crypto`,
  `String.valid?/1`, `:erlang.crc32/1`.

**Nx is the right choice** when the app already uses Nx with a compiled
backend (EXLA, EMLX or Torchx), or the job is whole-tensor work at scale:
large arrays of a fixed shape, linear algebra, convolutions, gradients, a GPU,
or many requests of one shape batched with `Nx.Serving`. On that work Nx with
EXLA is faster than a kernel: a dot-product top-k over 100k embeddings ran
6-8x faster than defk (provisional). The speed comes from the compiled
backend: Nx's default `BinaryBackend` is written in Elixir and is slower than
plain Elixir.

**defk is a fair choice beside Nx, or instead of it**, when the numeric job is
a loop rather than tensor algebra (each step depends on the last, it stops
early, or it is a state machine), when inputs change length from call to call
or are small and called often, when the results must be integer-exact, when
the call must stay preemptible and stop with its process, or when it is the
one numeric job in an app that doesn't otherwise need Nx and a compiled
backend. Some overlap with Nx is fine: a kernel that saves you adding EXLA for
one loop is a good use of defk. A kernel takes the same packed layout as
`Nx.to_binary/1`, so the two work side by side. The small-input and
early-exit cases are not measured
against EXLA yet.

**A wrapper NIF (Rustler, Zigler or an existing binding) is the right
choice** when the value is in an existing native library rather than in a
loop: secret-dependent cryptography (a kernel cannot promise constant time),
parsers whose output is a tree of terms, regular expressions, large codecs
such as zstd or video, and whole systems such as databases or tensor
compilers. The catalog's
[rewrite boundary](https://github.com/DanielLuning/defk/blob/main/examples/README.md#where-a-wrapper-is-the-right-choice)
says, for each, what would change that.

## Not yet: planned

Constructs the compiler rejects as planned say "not supported yet" in the
compile error. Under the [stability promise](guides/stability.md), each can
arrive in a minor release.

- `Enum.reduce/3`, and `Enum.find/2` and `Enum.find_index/2` in a form that
  keeps their meaning without `nil`:
  [`enum-reduce`](compile-errors.md#enum-reduce),
  [`enum-find`](compile-errors.md#enum-find).
- More bitstring accumulator segments (little-endian, float, binary) and
  reading a bitstring, when a workload needs them:
  [`bitstring-segment`](compile-errors.md#bitstring-segment),
  [`bitstring-use`](compile-errors.md#bitstring-use).
- Sub-array views: `slice(a, start, len)` as an array without a copy.
- `u64` values in 64-bit bitstring segments.
- SIMD and builds for a specific CPU: research and prototypes first, then
  how to choose between a portable build and a faster one for one
  architecture.

Every compile error the compiler marks as planned:

- [`enum-reduce`](compile-errors.md#enum-reduce): Enum.reduce/3 is planned; write the same fold as `for ..., reduce:`.
- [`enum-find`](compile-errors.md#enum-find): Enum.find/2 and Enum.find_index/2 are planned; stop early with Enum.reduce_while/3.
- [`bitstring-segment`](compile-errors.md#bitstring-segment): An append to a bitstring accumulator takes big-endian integer segments, unsigned or `signed`: `v::size(n)`, `v::k` or `v`.
- [`bitstring-use`](compile-errors.md#bitstring-use): A bitstring accumulator starts from `<<>>`, is appended to (also in a kernel it is passed to), measured with `bit_size/1` and returned; nothing else.

## Under exploration: no promise either way

These are being looked at, with no commitment to build them:

- Kernel-owned state that lives between calls and is changed in place.
  Today state travels as values: pass it in as a binary and
  return the updated one (see
  [Array accumulators](language.md#array-accumulators)).

## Won't be: by design

These stay out because adding them would break the one rule, the runtime
contract, or the reason a kernel is fast. Constructs the compiler rejects for
good say "not in the kernel subset" in the compile error.

- **Lists, maps, atoms and other BEAM terms**
  ([`unsupported-list`](compile-errors.md#unsupported-list),
  [`unsupported-map`](compile-errors.md#unsupported-map),
  [`unsupported-atom`](compile-errors.md#unsupported-atom)). A kernel works on
  numbers, booleans, tuples of them and packed arrays, and never touches the
  BEAM heap while it computes: its result becomes a term only when it
  returns. Where terms are the product, building them is the cost, and a NIF
  builds them at the same price Elixir does. Pass packed binaries in, and
  turn results into terms in Elixir.
- **Strings as values**
  ([`unsupported-string`](compile-errors.md#unsupported-string)). A kernel sees
  bytes, not text: a string literal is a read-only `[u8]`, and there are no
  UTF-8 or grapheme operations and no building a string at run time. Do text
  work in Elixir before or after the call. A kernel can still produce bytes
  that are text: return a `[u8]` (or a bitstring), and it reaches Elixir as a
  binary, a string if the bytes are valid UTF-8.
- **Anonymous functions as values, and recursion**
  ([`unsupported-fn`](compile-errors.md#unsupported-fn),
  [`recursion`](compile-errors.md#recursion)). Calls between kernels are inlined,
  which is what lets a loop in a called kernel yield and run at full speed. A
  function value would need a BEAM closure, and recursion cannot be inlined.
  Define another kernel and call it, and write recursion as a loop.
- **Calls into other modules**
  ([`unsupported-call`](compile-errors.md#unsupported-call)). Native code cannot
  call Elixir functions. A kernel gets a fixed set of builtins, the `:math`
  functions that have one, and the early-exit forms of `Enum`.
- **Fast-math floats.** Kernels build with `-ffp-contract=off` and never
  `-ffast-math`, reassociation or fused multiply-add, so float results match
  Elixir bit for bit. A float operation that would give inf or NaN raises, as
  in Elixir. The cost is that an in-order float reduction does not vectorise
  across lanes; see [Float arithmetic](language.md#float-arithmetic).
- **Unchecked memory access.** There is no way to turn bounds checks off or
  to read outside an array: an out-of-range index raises. Speed comes from the
  compiler proving an index in range, never from trusting the author. Raw
  CPU intrinsics in kernel source are out too: they are not portable, Elixir
  mode cannot run them, and their loads are not checked (a constraint the
  SIMD work keeps).
- **Wrapping integers by default.** `i64` and `u64` arithmetic raises on
  overflow where Elixir would give a bignum. Wrapping is written explicitly,
  as [masked arithmetic](language.md#masked-arithmetic), which still gives
  Elixir's exact result.

Every compile error the compiler marks as outside the kernel subset for good:

- [`tuple-parameter`](compile-errors.md#tuple-parameter): Tuples are only for returning several values; a kernel takes its inputs as separate parameters.
- [`clause-pattern`](compile-errors.md#clause-pattern): A clause parameter is an integer literal (i64), true/false (bool), a variable or _, each variable once, with an optional guard.
- [`tuple-binding`](compile-errors.md#tuple-binding): A tuple is taken apart where it is bound: `{a, b} = ...`.
- [`unsupported-pattern`](compile-errors.md#unsupported-pattern): `=` binds a variable or a tuple of variables.
- [`bitstring-match`](compile-errors.md#bitstring-match): Binary patterns `<<...>> = bin` are not in the kernel subset; read array elements by index.
- [`u64-with-i64`](compile-errors.md#u64-with-i64): Outside a mask, + - * band bor bxor div rem min max mix a u64 only with a u64 or an i64 known to be >= 0.
- [`nested-tuple`](compile-errors.md#nested-tuple): Tuples don't nest.
- [`tuple-argument`](compile-errors.md#tuple-argument): Tuples are not passed as arguments.
- [`recursion`](compile-errors.md#recursion): A kernel can't call itself, directly or through other kernels; write the recursion as a loop.
- [`unsupported-call`](compile-errors.md#unsupported-call): Calls into other modules are not in the kernel subset, except Enum.reduce_while/3, Enum.all?/2, Enum.any?/2 and :math functions with a builtin.
- [`fn-argument`](compile-errors.md#fn-argument): Enum.reduce_while/3, Enum.all?/2 and Enum.any?/2 take a literal fn with one clause and no guard.
- [`pipe`](compile-errors.md#pipe): The pipe operator |> is not in the kernel subset; write the nested call.
- [`for-collect`](compile-errors.md#for-collect): A `for` collects nothing: without reduce: it is a statement, and into: is not in the kernel subset.
- [`for-option`](compile-errors.md#for-option): `for` takes `reduce:` and `do`; other options are not in the kernel subset.
- [`generator-pattern`](compile-errors.md#generator-pattern): A generator binds one variable: `x <- array` or `i <- range`.
- [`reduce-clauses`](compile-errors.md#reduce-clauses): `for ..., reduce:` has exactly one `acc -> body` clause.
- [`accumulator-pattern`](compile-errors.md#accumulator-pattern): An accumulator is a variable or a tuple of variables.
- [`case-subject`](compile-errors.md#case-subject): `case` matches an i64 or a bool.
- [`case-pattern`](compile-errors.md#case-pattern): A case pattern is an integer literal, true/false, ^var, _ or a variable, with an optional guard.
- [`unsupported-map`](compile-errors.md#unsupported-map): Maps and structs are not in the kernel subset.
- [`unsupported-string`](compile-errors.md#unsupported-string): String concatenation with <> and the ~s sigil are not in the kernel subset; a string literal is a [u8].
- [`unsupported-atom`](compile-errors.md#unsupported-atom): Atoms (other than true and false) and nil are not in the kernel subset.
- [`unsupported-list`](compile-errors.md#unsupported-list): Lists are not in the kernel subset; a kernel takes packed arrays.
- [`unsupported-fn`](compile-errors.md#unsupported-fn): Anonymous functions are not values in a kernel; define another kernel and call it.
- [`unsupported-construct`](compile-errors.md#unsupported-construct): A kernel uses the Elixir forms =, if, cond, case, for, Enum.reduce_while/3, Enum.all?/2 and Enum.any?/2; others such as unless, with, try, receive and throw are not in the kernel subset.
- [`unsupported-expression`](compile-errors.md#unsupported-expression): Any other expression is not in the kernel subset.
- [`attribute-value`](compile-errors.md#attribute-value): A module attribute read in a kernel holds an integer (in i64 or u64), a float, a boolean or a binary.
- [`binary-literal`](compile-errors.md#binary-literal): A binary literal in a kernel is a string or <<...>> of integer bytes (0..255); anything else is built in Elixir.
- [`raise-message`](compile-errors.md#raise-message): A kernel's `raise` message is a string literal: no interpolation or computed value.
- [`raise-module`](compile-errors.md#raise-module): A kernel raises ArgumentError, ArithmeticError or RuntimeError.

## Keeping this page true

The two lists of compile errors are generated from `Defk.Errors` and checked
by the test suite (maintainers: `docs/agents/generated-docs.md`). The tests
also check that every planned code is named in the "Not yet" list with a
ticket, and that every code named in "Won't be" is outside the subset for
good. The example kernel above runs in native code and in Elixir mode in the
tests.
