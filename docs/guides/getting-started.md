# Getting started

This guide takes you from an empty Mix project to a kernel you can call,
and shows how to read the compile error you will most likely meet first.

Before you start, check that defk fits your job. Elixir is the default: defk
helps with loops over numbers or bytes where the data is already packed in a
binary and each call does enough work. When to use defk, and when Elixir or a
wrapper NIF is the better choice, is on the [scope page](../scope.md).

## What you need

- **Elixir 1.20 or later** (tested on OTP 29).
- **A C compiler on the machine that compiles your code.** A kernel is
  compiled to native code when its module compiles, by `cc` or the compiler
  named in the `CC` environment variable. This is the same requirement as
  packages built with `elixir_make` (`bcrypt_elixir`, `exqlite`):
  - macOS: `xcode-select --install`
  - Debian or Ubuntu: `apt install build-essential` (the minimum is
    `gcc libc6-dev`)
  - Alpine: `apk add build-base`

  The machine that only runs your code needs no compiler; see
  [Deploying](deploying.md). Why defk compiles C at build time is recorded in
  [ADR 0002](https://github.com/DanielLuning/defk/blob/main/docs/adr/0002-c-compiler-at-build-time.md).

## Add defk to a project

defk is a research project and is not on Hex. Add it to `deps` in `mix.exs`
from a local checkout or from git:

```elixir
defp deps do
  [
    {:defk, path: "../defk"},
    # or: {:defk, git: "https://github.com/DanielLuning/defk.git", branch: "main"}
    {:stream_data, "~> 1.1", only: :test}
  ]
end
```

`stream_data` is optional; [Testing kernels](testing.md) uses it for
agreement properties. Then run `mix deps.get`.

In a script or a Livebook, use `Mix.install/1` instead. Livebook needs the C
compiler too, on the machine the notebook runs on.

<!-- defk-example skip: Mix.install cannot run inside the project's own tests; the measuring guide's script runs with it removed -->
```elixir
Mix.install([{:defk, path: "../defk"}])
```

## Your first kernel

A kernel is a function written with `defk` in an ordinary module that has
`use Defk`. Put this in `lib/stats.ex` (in an app you would call it
`MyApp.Stats`), then call it from `iex -S mix`:

```elixir
defmodule Stats do
  use Defk

  defk sum(xs :: [f64]) :: f64 do
    for x <- xs, reduce: 0.0 do
      acc -> acc + x
    end
  end
end
```

```elixir
iex> xs = for x <- [1.5, 2.5, 4.0], into: <<>>, do: <<x::float-64-native>>
iex> Stats.sum(xs)
8.0
iex> Stats.sum(<<>>)
0.0
iex> Stats.sum(<<1, 2, 3>>)
** (ArgumentError) argument 1 (xs): byte size 3 is not a multiple of 8 (f64)
iex> big = <<1.0e308::float-64-native, 1.0e308::float-64-native>>
iex> Stats.sum(big)
** (ArithmeticError) float result of 1e+308 + 1e+308 is inf or NaN
```

The kernel:

- Every parameter has a type, and so does the result. `[f64]` is an
  **array** of floats; `f64`, `i64`, `u64` and `bool` are scalars. The types
  are listed in [the reference](../language.md#3-types) and on the
  [cheatsheet](cheatsheet.cheatmd).
- The body is Elixir: `for` with `reduce:`, `if`, `cond`, `case`,
  arithmetic, comparisons and a fixed set of builtins such as `len/1`,
  `min/2` and `sqrt/1`. Anything outside that set is a compile error.
- A module can mix kernels and ordinary `def`s.

`mix compile` type-checks the kernel, turns it into C, builds a native
library with the C compiler and generates `Stats.sum/1` with an `@spec`. The
build is cached by a hash of the generated code, so an unchanged module is
not rebuilt.

## Calling it

To Elixir, an array is a binary of packed native-endian values: the calls
above build one with a binary comprehension and call the kernel like any
function. How to build and read each array type in Elixir is in the table
under [Types](../language.md#3-types).

A kernel gives the result Elixir would, or raises where Elixir would raise
or where its types can't hold the result. It never gives a different answer
(this is **the one rule**). So a binary of the wrong size raises
`ArgumentError`, and a float sum that overflows to infinity raises
`ArithmeticError`, as Elixir's own float arithmetic does. Both are ordinary
exceptions in the calling process.

Packing costs time. A kernel pays off when the data already arrives packed
(from a file, a socket, an image, `:persistent_term`), or is packed once and
used many times. If your data arrives as a list and you only loop over it
once, plain Elixir is usually faster; [Measuring](measuring.md) explains how
to check.

### Results of unknown length

A kernel has no lists, so it can't build a result with `[x | acc]`. When the
length of the result depends on the data, allocate the largest size with
`alloc/2` and return the array with a count, then cut it in Elixir:

```elixir
defmodule Filter do
  use Defk

  defk positives(xs :: [i64]) :: {[i64], i64} do
    out = alloc(i64, len(xs))

    n =
      for x <- xs, reduce: 0 do
        n ->
          if x > 0 do
            out[n] = x
            n + 1
          else
            n
          end
      end

    {out, n}
  end
end
```

```elixir
iex> xs = for x <- [3, -1, 4, -1, 5], into: <<>>, do: <<x::signed-64-native>>
iex> {out, n} = Filter.positives(xs)
iex> n
3
iex> for <<x::signed-64-native <- binary_part(out, 0, n * 8)>>, do: x
[3, 4, 5]
```

The other way is the
[bitstring accumulator](../language.md#the-bitstring-accumulator), which
appends values to a bitstring the kernel returns.

## Reading a compile error

Most Elixir you would write first is rejected with an error that says how to
write it instead. Say you sum with `Enum.sum/1`:

<!-- defk-example error: unsupported-call -->
```elixir
defmodule Stats do
  use Defk

  defk sum(xs :: [f64]) :: f64 do
    Enum.sum(xs)
  end
end
```

`mix compile` stops with:

```text
** (CompileError) lib/stats.ex: cannot compile Stats: 1 kernel compile error

error: Enum.sum/1 is not in the kernel subset
  │
5 │    Enum.sum(xs)
  │    ^^^^^^^^^^^^
  │
  └─ lib/stats.ex:5:5: Stats.sum/1

why: Enum.sum/1 takes a list or a range; a kernel has no lists, and the for ..., reduce: loop is the form a kernel compiles
hint: write the for ..., reduce: loop (start from 0.0 if the values are floats):

    for x <- xs, reduce: 0.0 do
      acc -> acc + x
    end
(defk unsupported-call: docs/language.md#unsupported-call)
```

Each error has the same parts:

- **The frame** points at the code, in Elixir's own diagnostic format.
- **why** says why the construct is rejected.
- **hint** says what to write instead, often with a rewrite of your own code
  that compiles.
- **The code** in the last line (`unsupported-call`) is stable. Its entry in
  [Compile errors](../language.md#11-compile-errors) has an example and the
  rewrite; this one is [`unsupported-call`](../language.md#unsupported-call).
  `mix run -e 'Defk.Errors.explain!("unsupported-call")'` prints the same
  entry in a terminal.

"not in the kernel subset" means the construct stays out by design; "not
supported yet" means it is planned. The [scope page](../scope.md) lists
both, with the reason or the ticket. Every rejection in a module is reported
at once (the first 10 are shown).

If the error instead says `defk: C compilation failed`, the C compiler ran
and failed: that is a defk bug or a broken toolchain, not a mistake in your
kernel. If it says `C compiler ... not found`, see [What you need](#what-you-need).

## Things that trip people up

From people writing their first kernels:

- **Integers overflow by raising.** `i64` arithmetic raises
  `ArithmeticError` where Elixir would make a bignum. Hashes and checksums
  that wrap are written as
  [masked arithmetic](../language.md#masked-arithmetic)
  (`band(expr, 0xFFFFFFFFFFFFFFFF)`), which gives Elixir's exact result, and
  values up to 2^64 - 1 are [`u64`](../language.md#u64).
- **Arrays can't come out of an `if`.** Write to the array inside each
  branch instead of returning it from the branch (planned:
  [`array-in-branch`](../language.md#array-in-branch)).
- **Elixir mode in a script.** In a `Mix.install` script, add
  `use Defk, elixir_mode: true` to get the plain Elixir version of each
  kernel for checking (see [Testing kernels](testing.md)). In a Mix
  project's `:test` environment it is always there.
- **Measure outside `:test`.** In `:test` every kernel call first checks
  whether to run in Elixir mode; time kernels in `:dev` or `:prod`.

## Next

- [Testing kernels](testing.md): check a kernel against its Elixir mode.
- [Measuring](measuring.md): find out whether the kernel helps.
- [The runtime contract](runtime-contract.md): what a kernel promises the
  BEAM while it runs.
- [Deploying](deploying.md): releases and the C compiler.
- [Cheatsheet](cheatsheet.cheatmd): types, builtins and common rewrites.
- [The kernel subset](../language.md): the full reference.
