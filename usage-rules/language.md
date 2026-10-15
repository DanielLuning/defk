# defk: the kernel subset in practice

The forms a kernel uses most, with the rules that catch people. The exact
rules are in [the kernel subset](https://hexdocs.pm/defk/0.1.0/language.html).

## Arrays out

A kernel returns an array it allocates and writes. `alloc(type, n)` gives
`n` zeros. A `for` without `reduce:` is a statement, so write each element:

```elixir
defk scale(a :: [f64], k :: f64) :: [f64] do
  n = length(a)
  out = alloc(f64, n)

  for i <- 0..(n - 1)//1 do
    out[i] = a[i] * k
  end

  out
end
```

```elixir
iex> M.scale(<<1.0::float-64-native, 2.0::float-64-native>>, 3.0)
<<3.0::float-64-native, 6.0::float-64-native>>
```

- A write must fit the element type: a `[u8]` write of 300 raises. It never
  wraps silently; write `rem(v, 256)` to wrap.
- An `alloc` inside a loop allocates on every pass, and nothing is freed
  before the kernel returns. Allocate a scratch array once, before the loop,
  and clear it in each pass.
- Index with a range the compiler can see, such as `i <- 0..(n - 1)//1` with
  `n = length(a)`: the bounds check is then left out.

## Arrays are values

A write gives the variable a new array; the caller's binary never changes.
A kernel that writes an array parameter must return it, and the caller binds
the result again (`write-not-returned` otherwise):

```elixir
defk bump(counts :: [i64], k :: i64) :: [i64] do
  counts[k] = counts[k] + 1
  counts
end

defk histogram(bytes :: [u8]) :: [i64] do
  for b <- bytes, reduce: alloc(i64, 256) do
    counts -> bump(counts, b)
  end
end
```

```elixir
iex> h = M.histogram("abca")
iex> for <<n::signed-64-native <- binary_part(h, 97 * 8, 3 * 8)>>, do: n
[2, 1, 1]
```

An array in a `reduce:` accumulator is updated in place, without copies.
State that lives between calls travels the same way: pass it in as a binary
and return the new one.

## Loops and early exit

- `for x <- array` and `for i <- first..last//step` are the generators. Write
  the step: `0..(n - 1)` with `n = 0` visits 0 and -1.
- `for ..., reduce: acc0 do acc -> ... end` has one clause; the accumulator
  may be a tuple of scalars and arrays, `{a, b} -> ...`.
- There is no `while`, `break` or `return`. Stop early with
  `Enum.reduce_while/3`, `Enum.all?/2` or `Enum.any?/2`, over a range or an
  array, with a literal `fn`. Every path of a `reduce_while` body ends in a
  literal `{:cont, acc}` or `{:halt, acc}`:

```elixir
defk index_of(a :: [i64], x :: i64) :: i64 do
  Enum.reduce_while(0..(length(a) - 1)//1, -1, fn i, acc ->
    if a[i] == x, do: {:halt, i}, else: {:cont, acc}
  end)
end
```

```elixir
iex> M.index_of(<<5::signed-64-native, 7::signed-64-native>>, 7)
1
iex> M.index_of(<<5::signed-64-native>>, 9)
-1
```

## Branches

`if` used as a value needs an `else`. `cond` takes any `bool` conditions.
`case` matches an `i64` or a `bool` against literals, `^pinned`, `_` and
variables, with guards. A branch may give a tuple when every arm gives one
of the same size: `{n, g} = cond do ... end`.

## Integers

- `i64` and `u64` arithmetic raises `ArithmeticError` on overflow, where
  Elixir would make a bignum.
- Inside `band(expr, 2^k - 1)` (or `wrap64(expr)`), `+ - *` and the bit
  operations wrap and give Elixir's exact masked result. Hashes are written
  this way:

```elixir
@mask64 0xFFFFFFFFFFFFFFFF

defk fnv1a64(bytes :: [u8]) :: u64 do
  for b <- bytes, reduce: 0xCBF29CE484222325 do
    h -> band(bxor(h, b) * 0x100000001B3, @mask64)
  end
end
```

```elixir
iex> M.fnv1a64("a")
12638187200555641996
```

- A `u64` mixes with an `i64` only where the `i64` is known to be `>= 0`, or
  inside a mask (`u64-with-i64` otherwise).
- `/` always gives an `f64`; `div` and `rem` are integer division.

## Output of unknown length

Append to a bitstring that starts as `<<>>`, and return it as `bitstring`.
Segments are big-endian integers: `v`, `v::k` or `v::size(n)`:

```elixir
defk above(a :: [i64], t :: i64) :: bitstring do
  for x <- a, reduce: <<>> do
    acc -> if x > t, do: <<acc::bitstring, x::32>>, else: acc
  end
end
```

```elixir
iex> M.above(<<1::signed-64-native, 7::signed-64-native, 9::signed-64-native>>, 5)
<<7::32, 9::32>>
```

Or `alloc` the largest size and return `{out, count}`; the caller takes
`binary_part(out, 0, count * 8)`.

## Other kernels

A kernel calls the kernels of its own module, defined before or after it.
Each call is inlined: a helper called from many places makes the native code
large, so call it from one loop. Recursion is a compile error: write it as a
loop.

## Outside the subset for good

Every construct the compiler rejects for good, with the code of its error:

<!-- generated: mix run -e 'IO.write(Defk.Errors.scope(:subset, :hexdocs))' -->
- [`tuple-parameter`](https://hexdocs.pm/defk/0.1.0/compile-errors.html#tuple-parameter): Tuples are only for returning several values; a kernel takes its inputs as separate parameters.
- [`clause-pattern`](https://hexdocs.pm/defk/0.1.0/compile-errors.html#clause-pattern): A clause parameter is an integer literal (i64), true/false (bool), a variable or _, each variable once, with an optional guard.
- [`tuple-binding`](https://hexdocs.pm/defk/0.1.0/compile-errors.html#tuple-binding): A tuple is taken apart where it is bound: `{a, b} = ...`.
- [`unsupported-pattern`](https://hexdocs.pm/defk/0.1.0/compile-errors.html#unsupported-pattern): `=` binds a variable or a tuple of variables.
- [`bitstring-match`](https://hexdocs.pm/defk/0.1.0/compile-errors.html#bitstring-match): Binary patterns `<<...>> = bin` are not in the kernel subset; read array elements by index.
- [`u64-with-i64`](https://hexdocs.pm/defk/0.1.0/compile-errors.html#u64-with-i64): Outside a mask, + - * band bor bxor div rem min max mix a u64 only with a u64 or an i64 known to be >= 0.
- [`nested-tuple`](https://hexdocs.pm/defk/0.1.0/compile-errors.html#nested-tuple): Tuples don't nest.
- [`tuple-argument`](https://hexdocs.pm/defk/0.1.0/compile-errors.html#tuple-argument): Tuples are not passed as arguments.
- [`recursion`](https://hexdocs.pm/defk/0.1.0/compile-errors.html#recursion): A kernel can't call itself, directly or through other kernels; write the recursion as a loop.
- [`unsupported-call`](https://hexdocs.pm/defk/0.1.0/compile-errors.html#unsupported-call): Calls into other modules are not in the kernel subset, except Enum.reduce_while/3, Enum.all?/2, Enum.any?/2 and :math functions with a builtin.
- [`fn-argument`](https://hexdocs.pm/defk/0.1.0/compile-errors.html#fn-argument): Enum.reduce_while/3, Enum.all?/2 and Enum.any?/2 take a literal fn with one clause and no guard.
- [`pipe`](https://hexdocs.pm/defk/0.1.0/compile-errors.html#pipe): The pipe operator |> is not in the kernel subset; write the nested call.
- [`for-collect`](https://hexdocs.pm/defk/0.1.0/compile-errors.html#for-collect): A `for` collects nothing: without reduce: it is a statement, and into: is not in the kernel subset.
- [`for-option`](https://hexdocs.pm/defk/0.1.0/compile-errors.html#for-option): `for` takes `reduce:` and `do`; other options are not in the kernel subset.
- [`generator-pattern`](https://hexdocs.pm/defk/0.1.0/compile-errors.html#generator-pattern): A generator binds one variable: `x <- array` or `i <- range`.
- [`reduce-clauses`](https://hexdocs.pm/defk/0.1.0/compile-errors.html#reduce-clauses): `for ..., reduce:` has exactly one `acc -> body` clause.
- [`accumulator-pattern`](https://hexdocs.pm/defk/0.1.0/compile-errors.html#accumulator-pattern): An accumulator is a variable or a tuple of variables.
- [`case-subject`](https://hexdocs.pm/defk/0.1.0/compile-errors.html#case-subject): `case` matches an i64 or a bool.
- [`case-pattern`](https://hexdocs.pm/defk/0.1.0/compile-errors.html#case-pattern): A case pattern is an integer literal, true/false, ^var, _ or a variable, with an optional guard.
- [`unsupported-map`](https://hexdocs.pm/defk/0.1.0/compile-errors.html#unsupported-map): Maps and structs are not in the kernel subset.
- [`unsupported-string`](https://hexdocs.pm/defk/0.1.0/compile-errors.html#unsupported-string): String concatenation with <> and the ~s sigil are not in the kernel subset; a string literal is a [u8].
- [`unsupported-atom`](https://hexdocs.pm/defk/0.1.0/compile-errors.html#unsupported-atom): Atoms (other than true and false) and nil are not in the kernel subset.
- [`unsupported-list`](https://hexdocs.pm/defk/0.1.0/compile-errors.html#unsupported-list): Lists are not in the kernel subset; a kernel takes packed arrays.
- [`unsupported-fn`](https://hexdocs.pm/defk/0.1.0/compile-errors.html#unsupported-fn): Anonymous functions are not values in a kernel; define another kernel and call it.
- [`unsupported-construct`](https://hexdocs.pm/defk/0.1.0/compile-errors.html#unsupported-construct): A kernel uses the Elixir forms =, if, cond, case, for, Enum.reduce_while/3, Enum.all?/2 and Enum.any?/2; others such as unless, with, try, receive and throw are not in the kernel subset.
- [`unsupported-expression`](https://hexdocs.pm/defk/0.1.0/compile-errors.html#unsupported-expression): Any other expression is not in the kernel subset.
- [`attribute-value`](https://hexdocs.pm/defk/0.1.0/compile-errors.html#attribute-value): A module attribute read in a kernel holds an integer (in i64 or u64), a float, a boolean or a binary.
- [`binary-literal`](https://hexdocs.pm/defk/0.1.0/compile-errors.html#binary-literal): A binary literal in a kernel is a string or <<...>> of integer bytes (0..255); anything else is built in Elixir.
- [`raise-message`](https://hexdocs.pm/defk/0.1.0/compile-errors.html#raise-message): A kernel's `raise` message is a string literal: no interpolation or computed value.
- [`raise-module`](https://hexdocs.pm/defk/0.1.0/compile-errors.html#raise-module): A kernel raises ArgumentError, ArithmeticError or RuntimeError.
<!-- end generated -->
