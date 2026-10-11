# Scope: what defk is, isn't yet, and won't be

This page says what defk is for, when to use something else, what is planned
but not built, and what will stay out by design. The two lists of compile
errors on it are generated from the compiler's error registry
(`Defk.Errors`), and the tests fail if the page and the compiler disagree.

## What defk is

defk asks one question: **can a typed subset of Elixir compile to native code
that runs at C speed, with a cheap call boundary, while keeping the BEAM's
promises?** It is a research project working towards that answer, not a
released library (it is not on Hex).

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
  the calling process. If the process dies while its kernel is suspended,
  everything the kernel allocated is freed. A kernel suspended across a
  reload of its module finishes in the code it started in.
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
such as base64, and similar numeric or byte-level jobs.

**Elixir is the right choice** when:

- the data arrives as a list (Ecto rows, decoded JSON): packing it costs
  more than Elixir's whole loop;
- each call does little work, such as one kernel call per element inside
  `Enum.map`, or small inputs: the call costs more than the work;
- the job builds BEAM terms, such as maps, strings or lists: a kernel cannot
  build them;
- the BEAM already has a native answer: `:binary.match/2`, `:crypto`,
  `String.valid?/1`, `:erlang.crc32/1`;
- the work is tensor or ML maths: use Nx (with EXLA), and keep defk for a
  custom loop beside it.

**A wrapper NIF (Rustler, Zigler or an existing binding) is the right
choice** when the value is in an existing native library rather than in a
loop: secret-dependent cryptography (a kernel cannot promise constant time),
parsers whose output is a tree of terms, regular expressions, large codecs
such as zstd or video, and whole systems such as databases or tensor
compilers. The catalog's
[rewrite boundary](https://github.com/DanielLuning/defk/blob/main/examples/README.md#where-a-wrapper-is-the-right-choice)
says, for each, what would change that.

## Not yet: planned

Each planned item has a ticket in the project's issue tracker (beadwork,
`bw show <id>`). Constructs the compiler rejects as planned say "not supported
yet" in the compile error.

- Arrays through `if`, `cond` and `case`, and returning an input array the
  kernel never writes (defk-gqk):
  [`array-in-branch`](language.md#array-in-branch),
  [`return-input-array`](language.md#return-input-array).
- `Enum.reduce/3`, and `Enum.find/2` and `Enum.find_index/2` in a form that
  keeps their meaning without `nil` (defk-nii):
  [`enum-reduce`](language.md#enum-reduce),
  [`enum-find`](language.md#enum-find).
- More bitstring accumulator segments (little-endian, float, binary) and
  reading a bitstring, when a workload needs them (defk-pe3):
  [`bitstring-segment`](language.md#bitstring-segment),
  [`bitstring-use`](language.md#bitstring-use).
- Sub-array views: `slice(a, start, len)` as an array without a copy
  (defk-n4r.3).
- `u64` values in 64-bit bitstring segments (defk-oit).
- SIMD and builds for a specific CPU: research and prototypes first, then
  how to choose between a portable build and a faster one for one
  architecture (defk-ulk).
- Turning a crash inside a kernel's native code (which would be a defk bug)
  into an exception in the calling process instead of a node crash; today
  such a crash takes the node down, as any NIF crash does (defk-7dm).
- Kernel `.so` files shipped inside `mix release` (defk-n8f).
- A Hex release, which waits for the project's verdict (defk-sgw.5,
  defk-djy.8).

Under exploration, with no promise either way: kernel-owned state that lives
between calls and is changed in place (defk-sve). Today state travels as
values, binaries in and new binaries out.

Every compile error the compiler marks as planned:

- [`return-input-array`](language.md#return-input-array): A returned array is one the kernel created with alloc/2 or wrote; returning an unwritten input array is planned.
- [`array-in-branch`](language.md#array-in-branch): An if, cond or case used as a value gives no array, alone or in a tuple; arrays through branches are planned.
- [`enum-reduce`](language.md#enum-reduce): Enum.reduce/3 is planned; write the same fold as `for ..., reduce:`.
- [`enum-find`](language.md#enum-find): Enum.find/2 and Enum.find_index/2 are planned; stop early with Enum.reduce_while/3.
- [`bitstring-segment`](language.md#bitstring-segment): An append to a bitstring accumulator takes big-endian integer segments, unsigned or `signed`: `v::size(n)`, `v::k` or `v`.
- [`bitstring-use`](language.md#bitstring-use): A bitstring accumulator starts from `<<>>`, is appended to (also in a kernel it is passed to), measured with `bit_size/1` and returned; nothing else.

## Won't be: by design

These stay out because adding them would break the one rule, the runtime
contract, or the reason a kernel is fast. Constructs the compiler rejects for
good say "not in the kernel subset" in the compile error.

- **Lists, maps, atoms and other BEAM terms**
  ([`unsupported-list`](language.md#unsupported-list),
  [`unsupported-map`](language.md#unsupported-map),
  [`unsupported-atom`](language.md#unsupported-atom)). A kernel works on
  numbers, booleans, tuples of them and packed arrays, and never touches the
  BEAM heap while it computes: its result becomes a term only when it
  returns. Where terms are the product, building them is the cost, and a NIF
  builds them at the same price Elixir does. Pass packed binaries in, and
  turn results into terms in Elixir.
- **Strings as values**
  ([`unsupported-string`](language.md#unsupported-string)). A kernel sees
  bytes, not text: a string literal is a read-only `[u8]`, and there are no
  UTF-8 or grapheme operations and no building a string at run time. Do text
  work in Elixir before or after the call.
- **Anonymous functions as values, and recursion**
  ([`unsupported-fn`](language.md#unsupported-fn),
  [`recursion`](language.md#recursion)). Calls between kernels are inlined,
  which is what lets a loop in a called kernel yield and run at full speed. A
  function value would need a BEAM closure, and recursion cannot be inlined.
  Define another kernel and call it, and write recursion as a loop.
- **Calls into other modules**
  ([`unsupported-call`](language.md#unsupported-call)). Native code cannot
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
  SIMD work, defk-ulk, keeps).
- **Wrapping integers by default.** `i64` and `u64` arithmetic raises on
  overflow where Elixir would give a bignum. Wrapping is written explicitly,
  as [masked arithmetic](language.md#masked-arithmetic), which still gives
  Elixir's exact result.

Every compile error the compiler marks as outside the kernel subset for good:

- [`tuple-parameter`](language.md#tuple-parameter): Tuples are only for returning several values; a kernel takes its inputs as separate parameters.
- [`clause-pattern`](language.md#clause-pattern): A clause parameter is an integer literal (i64), true/false (bool), a variable or _, each variable once, with an optional guard.
- [`tuple-binding`](language.md#tuple-binding): A tuple is taken apart where it is bound: `{a, b} = ...`.
- [`unsupported-pattern`](language.md#unsupported-pattern): `=` binds a variable or a tuple of variables.
- [`bitstring-match`](language.md#bitstring-match): Binary patterns `<<...>> = bin` are not in the kernel subset; read array elements by index.
- [`u64-mix`](language.md#u64-mix): Outside a mask, + - * band bor bxor div rem min max mix a u64 only with a u64 or an i64 known to be >= 0.
- [`nested-tuple`](language.md#nested-tuple): Tuples don't nest.
- [`tuple-argument`](language.md#tuple-argument): Tuples are not passed as arguments.
- [`recursion`](language.md#recursion): A kernel can't call itself, directly or through other kernels; write the recursion as a loop.
- [`unsupported-call`](language.md#unsupported-call): Calls into other modules are not in the kernel subset, except Enum.reduce_while/3, Enum.all?/2, Enum.any?/2 and :math functions with a builtin.
- [`fn-argument`](language.md#fn-argument): Enum.reduce_while/3, Enum.all?/2 and Enum.any?/2 take a literal fn with one clause and no guard.
- [`pipe`](language.md#pipe): The pipe operator |> is not in the kernel subset; write the nested call.
- [`for-collect`](language.md#for-collect): A `for` collects nothing: without reduce: it is a statement, and into: is not in the kernel subset.
- [`for-option`](language.md#for-option): `for` takes `reduce:` and `do`; other options are not in the kernel subset.
- [`generator-pattern`](language.md#generator-pattern): A generator binds one variable: `x <- array` or `i <- range`.
- [`reduce-clauses`](language.md#reduce-clauses): `for ..., reduce:` has exactly one `acc -> body` clause.
- [`accumulator-pattern`](language.md#accumulator-pattern): An accumulator is a variable or a tuple of variables.
- [`case-subject`](language.md#case-subject): `case` matches an i64 or a bool.
- [`case-pattern`](language.md#case-pattern): A case pattern is an integer literal, true/false, ^var, _ or a variable, with an optional guard.
- [`unsupported-map`](language.md#unsupported-map): Maps and structs are not in the kernel subset.
- [`unsupported-string`](language.md#unsupported-string): String concatenation with <> and the ~s sigil are not in the kernel subset; a string literal is a [u8].
- [`unsupported-atom`](language.md#unsupported-atom): Atoms (other than true and false) and nil are not in the kernel subset.
- [`unsupported-list`](language.md#unsupported-list): Lists are not in the kernel subset; a kernel takes packed arrays.
- [`unsupported-fn`](language.md#unsupported-fn): Anonymous functions are not values in a kernel; define another kernel and call it.
- [`unsupported-construct`](language.md#unsupported-construct): A kernel uses the Elixir forms =, if, cond, case, for, Enum.reduce_while/3, Enum.all?/2 and Enum.any?/2; others such as unless, with, try, receive and throw are not in the kernel subset.
- [`unsupported-expression`](language.md#unsupported-expression): Any other expression is not in the kernel subset.
- [`attribute-value`](language.md#attribute-value): A module attribute read in a kernel holds an integer (in i64 or u64), a float, a boolean or a binary.
- [`binary-literal`](language.md#binary-literal): A binary literal in a kernel is a string or <<...>> of integer bytes (0..255); anything else is built in Elixir.
- [`raise-message`](language.md#raise-message): A kernel's `raise` message is a string literal: no interpolation or computed value.
- [`raise-module`](language.md#raise-module): A kernel raises ArgumentError, ArithmeticError or RuntimeError.

## Keeping this page true

The two lists of compile errors are generated from `Defk.Errors`. After
changing the registry, regenerate them with
`mix run -e 'IO.write(Defk.Errors.scope(:planned))'` and
`mix run -e 'IO.write(Defk.Errors.scope(:subset))'`, and replace each list
with its output. `test/scope_doc_test.exs` fails until they match, and also
checks that every planned code is named in the "Not yet" list with a ticket,
and that every code named in "Won't be" is outside the subset for good. The
example kernel above runs in native code and in Elixir mode in the tests.
