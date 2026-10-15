# defk usage rules

defk compiles a typed subset of Elixir, written with `defk` in an ordinary
module, to a checked native function (a NIF). These rules are for writing,
changing and testing a kernel. A kernel is not Elixir with types added: most
of Elixir is not in the subset, and the compiler rejects it.

## Use Elixir first

Elixir is the default. A kernel helps only with loops over numbers or bytes,
on data already packed in a binary, with enough work per call to pay for the
call. Stay in Elixir when:

- the data arrives as a list or a map: packing it costs more than Elixir's loop;
- the job is one call per element, or the inputs are small;
- the result is BEAM terms (maps, strings, lists): a kernel cannot build them;
- the BEAM already has it natively: `:binary.match/2` and `:binary.matches/2`,
  `:crypto`, `:erlang.crc32/1`, `:erlang.adler32/1`, `:zlib`. Check OTP before
  writing a checksum, a search or a codec.

A kernel is worth keeping only when it is at least 2x faster than the best
Elixir version, measured (see Measuring below).
[When to use it, and when not](https://hexdocs.pm/defk/0.1.0/scope.html#when-to-use-it-and-when-not)

## A kernel

```elixir
defmodule Stats do
  use Defk

  defk dot(a :: [f64], b :: [f64]) :: f64 do
    n = min(length(a), length(b))

    for i <- 0..(n - 1)//1, reduce: 0.0 do
      acc -> acc + a[i] * b[i]
    end
  end
end
```

```elixir
iex> a = <<1.0::float-64-native, 2.0::float-64-native>>
iex> Stats.dot(a, a)
5.0
```

- Every parameter has a type, and the return type is required.
- A module can mix kernels and ordinary `def`s, but a kernel cannot call a `def`.
- `@doc` and `@impl` before `defk` apply to the kernel's function, as before a `def`.
- A kernel gives the result Elixir would, or raises where its types can't
  hold it (`ArithmeticError` on `i64` overflow, `Enum.OutOfBoundsError` on a
  bad index). It never gives a different answer.

## Types

| Type | From and to Elixir |
|---|---|
| `i64`, `u64` | an integer in range; overflow raises, it never becomes a bignum |
| `f64` | a float (an integer argument converts); inf or NaN raises |
| `bool` | `true` or `false` |
| `[f64]` `[f32]` `[i64]` `[i32]` `[i16]` `[u8]` `[u64]` | a binary of packed native-endian elements |
| `{t1, t2}` | a result only: a tuple in Elixir; a kernel that calls it takes it apart at once, `{a, b} = f(x)` |
| `bitstring` | the result of a bitstring accumulator |

Pack an array in Elixir with `for x <- xs, into: <<>>, do: <<x::float-64-native>>`
(`signed-64-native` for `i64`). Read it with `for <<x::float-64-native <- bin>>, do: x`.
A string is a `[u8]`. There are no lists, maps, structs, strings as values,
atoms, `nil` or anonymous functions.

## The subset

- Forms: `=`, `if` (with an `else` when used as a value), `cond`, `case` on
  an `i64` or `bool`, `for`, `Enum.reduce/3`, `Enum.reduce_while/3`,
  `Enum.find/3` (with a default), `Enum.all?/2`, `Enum.any?/2`, and `raise` with a literal message (which may interpolate
  integers: `"bad offset #{i}"`).
- Write the step of a range: `0..(n - 1)//1`. Without it, `0..-1` counts down
  and runs twice.
- A `for` without `reduce:` is a statement. For a value, use `reduce:`. For
  an array, `out = alloc(f64, n)`, write `out[i] = v` in the loop, and return `out`.
- `a[i]` reads and `a[i] = v` writes, with bounds checks. Arrays are values:
  the caller's binary never changes.
- A kernel calls builtins and the kernels of its own module (inlined; no
  recursion). It does not call `def`s or other modules, except the `:math`
  functions that have a builtin (`sqrt`, `exp`, `log`, `log2`, `log10`,
  `sin`, `cos`, `pow`).
- Integer arithmetic raises on overflow. A hash that wraps at 64 bits is
  written as `band(expr, 0xFFFFFFFFFFFFFFFF)`, which gives Elixir's exact result.
- A result of unknown length is a bitstring accumulator
  (`<<acc::bitstring, x::64>>`), or an `alloc` of the largest size returned
  as `{out, count}`.

[The kernel subset](https://hexdocs.pm/defk/0.1.0/language.html),
[Builtins](https://hexdocs.pm/defk/0.1.0/language.html#builtins),
[Cheatsheet](https://hexdocs.pm/defk/0.1.0/cheatsheet.html)

## Write this instead

| Written first | Write instead |
|---|---|
| `Enum.sum(a)` | `for x <- a, reduce: 0.0 do acc -> acc + x end` |
| `a \|> f(b)` | `f(a, b)` |
| `for x <- a, do: x * 2` as a value | `out = alloc(f64, length(a))`, write `out[i]`, return `out` |
| `[x \| acc]` then `Enum.reverse/1` | a bitstring accumulator, or `{out, count}` |
| `for {x, i} <- Enum.with_index(a)` | `for i <- 0..(length(a) - 1)//1` and `x = a[i]` |
| `<<a, b, rest::binary>> = bin` | `a = bin[0]`, `b = bin[1]` |
| `x ** 2` | `x * x`, or `pow(x, 2)` |
| `byte_size(a)` | `length(a)` |
| `unless c do` | `if not c do` |
| a map of counters per key | `counts = alloc(i64, 256)`, `counts[k] = counts[k] + 1` |
| `xs :: list(float)` | `xs :: [f64]`, packed in Elixir |
| returning text, `:: String.t()` | `:: [u8]`, a binary in Elixir |

## Not yet

These are planned, not built. Do not write them; use the rewrite.

<!-- generated: mix run -e 'IO.write(Defk.Errors.scope(:planned, :hexdocs))' -->
- [`bitstring-segment`](https://hexdocs.pm/defk/0.1.0/compile-errors.html#bitstring-segment): An append to a bitstring accumulator takes big-endian integer segments, unsigned or `signed`: `v::size(n)`, `v::k` or `v`.
- [`bitstring-use`](https://hexdocs.pm/defk/0.1.0/compile-errors.html#bitstring-use): A bitstring accumulator starts from `<<>>`, is appended to (also in a kernel it is passed to), measured with `bit_size/1` and returned; nothing else.
<!-- end generated -->

There are no sub-array views, no SIMD and no state kept between calls: pass
state in as a binary and return the new one.
[Scope](https://hexdocs.pm/defk/0.1.0/scope.html)

## Testing

- In the `:test` environment, every kernel also compiles to plain Elixir
  (Elixir mode). Elixir mode defines the right result.
- `Defk.Test.assert_agrees(Mod, :fun, args)` runs one call natively and in
  Elixir mode, asserts that they agree, and returns `{:ok, value}` or
  `{:raise, exception}`. Use it in property tests, with edge values mixed in.
  It calls a kernel by name: test a `def` that wraps a kernel on its own.
- Check each test in both modes: with `assert_agrees`, or by running the
  suite again with `config :defk, mode: :elixir` in `config/test.exs`.

[Testing kernels](https://hexdocs.pm/defk/0.1.0/testing.html)

## Measuring

- Make the Elixir version as fast as you can first (the stdlib, BIFs, a
  better algorithm), and give the kernel the same algorithm. A win over a
  first attempt in Elixir is provisional.
- Time kernels in `:dev` or `:prod`, never in `:test`.
- Time end to end from the data the caller has: packing a list is part of
  the kernel's cost.
- `Defk.Report.print(Mod)` explains a slow kernel: bounds checks kept,
  copies, safepoints.
- When the kernel wins only above a size, call it from a guard clause
  (`when byte_size(bin) < 1024` goes to the Elixir version), and test that
  the two sides agree around the threshold.

[Measuring](https://hexdocs.pm/defk/0.1.0/measuring.html)

## Compile errors

A compile error gives why, a hint, and a footer `(defk <code>: <url>)`. The
code's entry has a failing example and its rewrite; print it with
`mix run -e 'Defk.Errors.explain!("unsupported-map")'`. Apply the rewrite.
When the construct is outside the subset, do that part in Elixir, before or
after the call. `defk: C compilation failed` is a defk bug or a broken
toolchain, not a mistake in the kernel.
[Compile errors](https://hexdocs.pm/defk/0.1.0/compile-errors.html)
