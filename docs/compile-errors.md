# Compile errors

A construct outside the kernel subset, or a mistake in one inside it, is a
compile error when the module compiles. Each error is printed with why it is
rejected, a hint, and its stable code, which is the heading of its entry on
this page: the last line of the error is a link to that entry. The
[language reference](language.md#11-compile-errors) shows the format; this page
is the catalogue. From 0.1.0, codes are never renamed. `Defk.Errors.entries/0` lists them,
and `mix run -e 'Defk.Errors.explain!("unsupported-map")'` prints one entry.

Each entry gives the code's summary, its kind, the default why and hint (an
error may say more about your code), and a failing example with the rewrite;
the test suite checks that each example is rejected with its code and each
rewrite compiles. The entries are generated from the registry in
`lib/defk/errors.ex` and checked by the test suite (maintainers:
`docs/agents/generated-docs.md`).

The headings are the codes themselves (lowercase letters and hyphens), so the
anchor `#<code>` is the same on GitHub and on HexDocs.

## Codes

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

Kernel types are i64, u64, f64, bool, arrays of f64, f32, i64, i32, i16, u8 and u64 ([f64], [f32], [i64], [i32], [i16], [u8], [u64]) and tuples of them for results; bitstring is a result type too, and a parameter type of a kernel other kernels call (the bitstring accumulator).

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

A kernel name and arity is defined once: one typed definition with a body, or one bodiless head and its clauses.

- kind: a mistake to fix (in the kernel or the build)
- why: a kernel has one typed head; several bodies are clauses, which follow a bodiless head without types, as in Elixir
- hint: for several clauses, write the typed head once without a body, then the clauses without types

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

### builtin-name

A kernel cannot take the name and arity of a builtin: the builtin would answer its calls.

- kind: a mistake to fix (in the kernel or the build)
- why: `copy_back/4` is a builtin, so calls to it would reach the builtin, not this kernel; a builtin added later would change what a module computes without a warning
- hint: rename the kernel and its calls (my_copy_back/4, say); the same name at another arity is fine

Rejected:

```elixir
defk abs(x :: i64) :: i64 do
  if x < 0, do: -x, else: x
end
```

Write instead:

```elixir
defk my_abs(x :: i64) :: i64 do
  if x < 0, do: -x, else: x
end
```

### clause-head

A multi-clause kernel starts with a bodiless typed head, before its clauses.

- kind: a mistake to fix (in the kernel or the build)
- why: a clause has patterns, not types; the head gives the kernel its parameter and return types, and Elixir reads the head first too
- hint: write `defk name(param :: type, ...) :: return_type` without a body above the first clause

Rejected:

```elixir
defk f(0), do: 1
defk f(x), do: x * 2
```

Write instead:

```elixir
defk f(x :: i64) :: i64
defk f(0), do: 1
defk f(x), do: x * 2
```

### clause-types

Only the head of a multi-clause kernel has types; its clauses have patterns.

- kind: a mistake to fix (in the kernel or the build)
- why: the head declares each parameter's type and the result once, for every clause
- hint: remove the types from the clause

Rejected:

```elixir
defk f(x :: i64) :: i64
defk f(0 :: i64) :: i64, do: 1
defk f(x), do: x * 2
```

Write instead:

```elixir
defk f(x :: i64) :: i64
defk f(0), do: 1
defk f(x), do: x * 2
```

### clause-pattern

A clause parameter is an integer literal (i64), true/false (bool), a variable or _, each variable once, with an optional guard.

- kind: outside the kernel subset (permanent)
- why: the clauses compile to a case over the parameters, which matches single i64 and bool values: a kernel has no binaries, lists or maps to take apart in a head, and a function head has no variables to pin
- hint: match a literal, a variable or _, and test the rest in the guard

Rejected:

```elixir
defk f(x :: i64, y :: i64) :: i64
defk f(x, x), do: 0
defk f(x, y), do: x - y
```

Write instead:

```elixir
defk f(x :: i64, y :: i64) :: i64
defk f(x, y) when x == y, do: 0
defk f(x, y), do: x - y
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

The arms of an if, cond or case that gives a tuple are all tuples of the same size.

- kind: a mistake to fix (in the kernel or the build)
- why: a tuple from a branch is one branch per element, so every arm gives every element
- hint: give every arm a tuple of the same size; compute an element in a block before the tuple

Rejected:

```elixir
defk f(x :: i64) :: i64 do
  {a, b} = if x > 0, do: {x, 1}, else: x
  a + b
end
```

Write instead:

```elixir
defk f(x :: i64) :: i64 do
  {a, b} = if x > 0, do: {x, 1}, else: {x, 0}
  a + b
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

### u64-with-i64

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

### undefined-function

A kernel calls builtins and the other kernels in its module.

- kind: a mistake to fix (in the kernel or the build)
- why: a kernel runs as native code: it can call its builtins (length, bit_size, min, max, abs, float, trunc, round, div, rem, sqrt, exp, log, log2, log10, sin, cos, pow, band, bor, bxor, bnot, bsl, bsr, wrap64, u64_le, u64_be, u32_le, u32_be, u16_le, u16_be, copy, copy_back, mulhi, clz, ctz, popcount, rotl, rotr, f64_bits, crc32c) and the kernels in this module, which are inlined
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
  out = alloc(f64, length(a))

  for i <- 0..(length(a) - 1)//1 do
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
  Enum.reduce_while(0..(length(a) - 1)//1, -1, fn i, _ ->
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
  out = alloc(f64, length(a))

  for i <- 0..(length(a) - 1)//1 do
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
  for i <- 0..(length(a) - 1)//1, reduce: 0.0 do
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

A case guard uses guard-safe expressions: variables, literals, arithmetic, comparisons, and/or/not, in with a literal list or a range, div, rem, abs, trunc, round, min and max.

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
- hint: pass the values as separate arguments, or pack them into an array before the call; for a count per key, index an array by the key (counts = alloc(i64, 256), then counts[b] = counts[b] + 1)

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
  length(s) + x
end
```

Write instead:

```elixir
defk f(x :: i64) :: i64 do
  s = "abcd"
  length(s) + x
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
- hint: pass the values as an array, a binary such as `for x <- list, into: <<>>, do: <<x::float-native-64>>`; build a result of unknown length by appending to a bitstring, `<<acc::bitstring, x::64>>`

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

A bitstring accumulator starts from `<<>>`, is appended to (also in a kernel it is passed to), measured with `bit_size/1` and returned; nothing else.

- kind: not supported yet (planned)
- why: a bitstring is a kernel's output: reading it or starting from an input binary is not supported yet, and only a kernel can pass one to a kernel (Elixir cannot pass one to an entry kernel)
- hint: measure it with bit_size/1, and keep what the kernel needs to read in variables or an array

Rejected:

```elixir
defk f(n :: i64) :: i64 do
  acc = <<>>
  acc = <<acc::bitstring, n::8>>
  length(acc)
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
