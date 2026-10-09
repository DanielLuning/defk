defmodule Defk.Errors do
  @moduledoc """
  Kernel compile errors: the registry of error codes and the error format.

  Every rejection the compiler makes has a stable code, a readable slug that is
  also its anchor in `docs/language.md` (`docs/language.md#<code>`) once that
  file exists. Codes are never renamed. `explain!/1` prints a code's entry. `codes/0` lists them with a one-line summary, whether the
  construct is outside the kernel subset for good (`:subset`), planned
  (`:planned`), or a mistake in a construct that is in it (`:error`), the
  default `why`/`hint`, and a failing `example` with its `rewrite` (both module
  bodies; the test suite checks the example is rejected with that code and the
  rewrite compiles).

  A compile error prints in Elixir's diagnostic frame, then why and how to fix:

      error: maps are not in the kernel subset
         │
      12 │     m = %{a: x}
         │         ^^^^^^^
         │
         └─ lib/my_app/kernels.ex:12:9: MyApp.Kernels.f/1

      why: a kernel works on numbers, booleans, tuples and packed arrays; ...
      hint: pass the values as separate arguments, ...
      (defk unsupported-map; mix run -e 'Defk.Errors.explain!("unsupported-map")')

  Once `docs/language.md` exists the footer is `(defk unsupported-map: docs/language.md#unsupported-map)`.
  """

  @docs "docs/language.md#"

  # The footer names docs/language.md only when that file exists, so no rendered
  # error points at a missing path. defk-sgw.1 writes the file; this attribute
  # then flips to true on the next compile of this module (touch it to force).
  @language_doc_exists File.exists?(Path.expand("../../docs/language.md", __DIR__))

  # Rejections reported per module; later ones are counted, not shown.
  @cap 10

  @calls Enum.join(Defk.Builtins.all() -- [:alloc], ", ")
  @math Enum.join(Defk.Builtins.math1(), ", ") <> " and pow"
  @bitwise_ops [:&&&, :|||, :"^^^", :<<<, :>>>, :"~~~"]
  @bitwise_funs [:band, :bor, :bxor, :bnot, :bsl, :bsr]
  @forms "=, if, cond, case, for, Enum.reduce_while/3, Enum.all?/2 and Enum.any?/2"

  # ------------------------------------------------------------- registry --

  @codes [
    # -- kernel definitions
    %{
      code: "kernel-head",
      kind: :error,
      summary: "A kernel head is `name(arg :: type, ...) :: return_type`.",
      why:
        "a kernel's parameter and return types are part of its definition: defk compiles to native code before anything runs",
      hint: "declare the return type after the parameter list",
      example: "defk f(x :: i64) do\n  x\nend",
      rewrite: "defk f(x :: i64) :: i64 do\n  x\nend"
    },
    %{
      code: "untyped-parameter",
      kind: :error,
      summary: "Every kernel parameter is `name :: type`.",
      why: "a kernel decodes each argument into a native value of its declared type",
      hint: "give the parameter a type",
      example: "defk f(x) :: i64 do\n  x\nend",
      rewrite: "defk f(x :: i64) :: i64 do\n  x\nend"
    },
    %{
      code: "unknown-type",
      kind: :error,
      summary:
        "Kernel types are i64, f64, bool, [f64], [i64], [u8] and tuples of them for results.",
      why: "a kernel works on native numbers and packed arrays, and these are the types it has",
      hint: "use i64, f64, bool, [f64], [i64] or [u8] (a tuple of them for a result)",
      example: "defk f(x :: integer) :: integer do\n  x\nend",
      rewrite: "defk f(x :: i64) :: i64 do\n  x\nend"
    },
    %{
      code: "tuple-parameter",
      kind: :subset,
      summary:
        "Tuples are only for returning several values; a kernel takes its inputs as separate parameters.",
      why:
        "a tuple is a BEAM term; a kernel keeps each element in a register and takes them as separate arguments",
      hint: "pass the elements as separate parameters",
      example: "defk f(p :: {i64, i64}) :: i64 do\n  {a, b} = p\n  a + b\nend",
      rewrite: "defk f(a :: i64, b :: i64) :: i64 do\n  a + b\nend"
    },
    %{
      code: "unknown-option",
      kind: :error,
      summary: "defk takes one option, `yield:`.",
      why: "`yield: false` (run without safepoints) is the only option a kernel has",
      hint: "remove the option",
      example: "defk f(x :: i64) :: i64, inline: true do\n  x\nend",
      rewrite: "defk f(x :: i64) :: i64, yield: false do\n  x\nend"
    },
    %{
      code: "no-body",
      kind: :error,
      summary: "A kernel needs a body.",
      why: "a kernel's body is the code defk compiles; without one there is nothing to run",
      hint: "write the body in a do block",
      example: "defk f(x :: i64) :: i64, do: nil",
      rewrite: "defk f(x :: i64) :: i64, do: x"
    },
    %{
      code: "duplicate-kernel",
      kind: :planned,
      summary: "A kernel name and arity is defined once; multi-clause kernels are planned.",
      why: "a kernel has one head and one body",
      hint: "merge the clauses into one body with case or cond",
      example: "defk f(x :: i64) :: i64 do\n  x\nend\n\ndefk f(x :: i64) :: i64 do\n  x + 1\nend",
      rewrite: "defk f(x :: i64) :: i64 do\n  x + 1\nend"
    },

    # -- results and blocks
    %{
      code: "return-type",
      kind: :error,
      summary: "The value a kernel returns has its declared return type.",
      why:
        "defk never converts a value to another type implicitly; only i64 widens to f64, as in arithmetic",
      hint: "convert explicitly, or change the declared return type",
      example: "defk f(x :: i64, y :: f64) :: i64 do\n  x + y\nend",
      rewrite: "defk f(x :: i64, y :: f64) :: i64 do\n  trunc(x + y)\nend"
    },
    %{
      code: "return-input-array",
      kind: :planned,
      summary:
        "A returned array is one the kernel created with alloc/2; returning an input array is planned.",
      why:
        "a kernel returns arrays it allocated itself; handing an input array back to the caller is planned",
      hint: "copy it into an array from alloc/2 and return that",
      example: "defk f(a :: [f64]) :: [f64] do\n  a\nend",
      rewrite:
        "defk f(a :: [f64]) :: [f64] do\n  out = alloc(f64, len(a))\n\n  for i <- 0..(len(a) - 1)//1 do\n    out[i] = a[i]\n  end\n\n  out\nend"
    },
    %{
      code: "empty-block",
      kind: :error,
      summary: "Every block in a kernel has a value, its last expression.",
      why: "in Elixir an empty block is nil, and a kernel has no nil",
      hint: "write the value the block should have",
      example:
        "defk f(x :: i64) :: i64 do\n  y =\n    if x > 0 do\n    else\n      1\n    end\n\n  y\nend",
      rewrite: "defk f(x :: i64) :: i64 do\n  y = if x > 0, do: 0, else: 1\n  y\nend"
    },
    %{
      code: "write-as-value",
      kind: :error,
      summary:
        "An array write `out[i] = v` is a statement and cannot end a block that needs a value.",
      why:
        "a kernel writes the array in place, so the write has no value, and the last expression of a block is the block's value",
      hint: "end the block with the value it should have",
      example: "defk f(n :: i64) :: [f64] do\n  out = alloc(f64, 1)\n  out[0] = float(n)\nend",
      rewrite:
        "defk f(n :: i64) :: [f64] do\n  out = alloc(f64, 1)\n  out[0] = float(n)\n  out\nend"
    },
    %{
      code: "if-without-else",
      kind: :error,
      summary: "An `if` used as a value has an else branch.",
      why:
        "in Elixir an if without else is nil when the condition is false, and a kernel has no nil",
      hint: "add an else branch",
      example: "defk f(x :: i64) :: i64 do\n  y = if x > 0, do: 1\n  y\nend",
      rewrite: "defk f(x :: i64) :: i64 do\n  y = if x > 0, do: 1, else: 0\n  y\nend"
    },
    %{
      code: "cond-without-true",
      kind: :error,
      summary:
        "A `cond` used as a value (or ending an Enum.reduce_while fn) ends with a `true ->` clause.",
      why: "every path through a kernel has a value, so the last clause must always match",
      hint: "end the cond with a `true ->` clause",
      example:
        "defk f(x :: i64) :: i64 do\n  cond do\n    x > 0 -> 1\n    x < 0 -> -1\n  end\nend",
      rewrite:
        "defk f(x :: i64) :: i64 do\n  cond do\n    x > 0 -> 1\n    x < 0 -> -1\n    true -> 0\n  end\nend"
    },
    %{
      code: "branch-types",
      kind: :error,
      summary: "The branches of an if, cond or case used as a value have one type.",
      why: "a value has one type, and defk never converts between i64 and f64 implicitly",
      hint: "convert one branch explicitly, e.g. with float/1",
      example: "defk f(x :: i64) :: f64 do\n  if x > 0, do: 1, else: 2.5\nend",
      rewrite: "defk f(x :: i64) :: f64 do\n  if x > 0, do: 1.0, else: 2.5\nend"
    },
    %{
      code: "branch-tuple",
      kind: :subset,
      summary: "An if, cond or case used as a value gives a number or a boolean, not a tuple.",
      why:
        "a kernel keeps a tuple's elements in separate registers, so each branch value is a single number or boolean",
      hint: "compute each element with its own if",
      example:
        "defk f(x :: i64) :: i64 do\n  {a, b} = if x > 0, do: {1, 2}, else: {3, 4}\n  a + b\nend",
      rewrite:
        "defk f(x :: i64) :: i64 do\n  a = if x > 0, do: 1, else: 3\n  b = if x > 0, do: 2, else: 4\n  a + b\nend"
    },
    %{
      code: "array-in-branch",
      kind: :planned,
      summary:
        "An if, cond or case used as a value gives a number or a boolean; arrays through branches are planned.",
      why: "an if/cond/case may give numbers or booleans, not arrays yet",
      hint: "do the array work inside each branch",
      example:
        "defk f(p :: bool, a :: [f64], b :: [f64]) :: f64 do\n  c = if p, do: a, else: b\n  c[0]\nend",
      rewrite:
        "defk f(p :: bool, a :: [f64], b :: [f64]) :: f64 do\n  if p, do: a[0], else: b[0]\nend"
    },

    # -- variables and patterns
    %{
      code: "undefined-variable",
      kind: :error,
      summary: "A variable is bound before it is used.",
      why:
        "variables are bound by =, parameters, generators and accumulators, and a binding inside if, case or for stays inside it, as in Elixir",
      hint: "bind it before this point, or pass it in as a parameter",
      example: "defk f(x :: i64) :: i64 do\n  x + y\nend",
      rewrite: "defk f(x :: i64, y :: i64) :: i64 do\n  x + y\nend"
    },
    %{
      code: "module-attribute",
      kind: :planned,
      summary: "Module attributes as constants are planned.",
      why:
        "a kernel body is compiled on its own, and reading module attributes as constants is planned",
      hint: "write the value as a literal for now",
      example: "@scale 3\n\ndefk f(x :: i64) :: i64 do\n  x * @scale\nend",
      rewrite: "defk f(x :: i64) :: i64 do\n  x * 3\nend"
    },
    %{
      code: "tuple-binding",
      kind: :subset,
      summary: "A tuple is taken apart where it is bound: `{a, b} = ...`.",
      why:
        "a kernel keeps a tuple's elements in separate registers, so a tuple can't be held in one variable",
      hint: "destructure it",
      example: "defk f(x :: i64) :: i64 do\n  t = {x, x + 1}\n  x\nend",
      rewrite: "defk f(x :: i64) :: i64 do\n  {a, b} = {x, x + 1}\n  a + b\nend"
    },
    %{
      code: "tuple-size",
      kind: :error,
      summary: "A tuple pattern has as many elements as the tuple it matches.",
      why: "in Elixir a tuple pattern of another size never matches",
      hint: "match every element (use _ for the ones you don't need)",
      example: "defk f(x :: i64) :: i64 do\n  {a, b} = {x, x, x}\n  a + b\nend",
      rewrite: "defk f(x :: i64) :: i64 do\n  {a, b, _} = {x, x, x}\n  a + b\nend"
    },
    %{
      code: "unsupported-pattern",
      kind: :subset,
      summary: "`=` binds a variable or a tuple of variables.",
      why:
        "any other pattern needs a match that can fail, and a kernel only matches in case clauses",
      hint: "bind variables, and test values with if or case",
      example: "defk f(x :: i64) :: i64 do\n  [a, b] = {x, x + 1}\n  a + b\nend",
      rewrite: "defk f(x :: i64) :: i64 do\n  {a, b} = {x, x + 1}\n  a + b\nend"
    },
    %{
      code: "bitstring-match",
      kind: :subset,
      summary:
        "Binary patterns `<<...>> = bin` are not in the kernel subset; read array elements by index.",
      why: "a kernel sees a binary as an array of elements, which it reads by index",
      hint: "read the fields by index",
      example:
        "defk f(arr :: [u8]) :: i64 do\n  <<a, b, _::16, _rest::binary>> = arr\n  a + b\nend",
      rewrite: "defk f(arr :: [u8]) :: i64 do\n  a = arr[0]\n  b = arr[1]\n  a + b\nend"
    },
    %{
      code: "integer-literal",
      kind: :error,
      summary: "Integer literals fit in i64.",
      why: "kernel integers are i64 (-2^63..2^63 - 1); a kernel never uses bignums",
      hint: "use a value that fits, or compute in f64",
      example: "defk f(x :: i64) :: i64 do\n  x + 9_223_372_036_854_775_808\nend",
      rewrite: "defk f(x :: i64) :: f64 do\n  x + 9.223372036854776e18\nend"
    },

    # -- types and operators
    %{
      code: "type-mismatch",
      kind: :error,
      summary:
        "A value has the type its position needs (an index or length is i64, a stored value has the element type, ...).",
      why: "defk never converts a value to another type implicitly; only i64 widens to f64",
      hint: "convert explicitly",
      example: "defk f(a :: [f64], i :: f64) :: f64 do\n  a[i]\nend",
      rewrite: "defk f(a :: [f64], i :: f64) :: f64 do\n  a[trunc(i)]\nend"
    },
    %{
      code: "operand-type",
      kind: :error,
      summary:
        "Arithmetic takes numbers, and/or/not take booleans, comparisons take two numbers or two booleans.",
      why: "booleans are not numbers in Elixir, and defk keeps that",
      hint: "turn the value into the type the operator takes",
      example: "defk f(x :: i64, b :: bool) :: i64 do\n  x + b\nend",
      rewrite: "defk f(x :: i64, b :: bool) :: i64 do\n  if b, do: x + 1, else: x\nend"
    },
    %{
      code: "not-an-array",
      kind: :error,
      summary: "Only arrays can be indexed with a[i].",
      why: "a[i] reads an element of an array ([f64], [i64] or [u8]), and this value is not one",
      hint: "index an array",
      example: "defk f(x :: i64) :: i64 do\n  x[0]\nend",
      rewrite: "defk f(x :: [i64]) :: i64 do\n  x[0]\nend"
    },
    %{
      code: "read-only-array",
      kind: :planned,
      summary:
        "Only arrays created with alloc/2 are written; writing to an input array is planned.",
      why:
        "an input array is the caller's binary, and a kernel never changes a value the caller holds",
      hint: "copy it into an array from alloc/2 and write that",
      example: "defk f(a :: [f64]) :: [f64] do\n  a[0] = 1.0\n  a\nend",
      rewrite:
        "defk f(a :: [f64]) :: [f64] do\n  out = alloc(f64, len(a))\n\n  for i <- 0..(len(a) - 1)//1 do\n    out[i] = a[i]\n  end\n\n  out[0] = 1.0\n  out\nend"
    },
    %{
      code: "nested-tuple",
      kind: :subset,
      summary: "Tuples don't nest.",
      why: "a kernel returns a tuple as separate registers, one per element",
      hint: "flatten the tuple",
      example: "defk f(x :: i64) :: {i64, {i64, i64}} do\n  {x, {x, x}}\nend",
      rewrite: "defk f(x :: i64) :: {i64, i64, i64} do\n  {x, x, x}\nend"
    },

    # -- calls
    %{
      code: "unknown-function",
      kind: :error,
      summary: "A kernel calls builtins and the other kernels in its module.",
      why:
        "a kernel runs as native code: it can call its builtins (#{@calls}) and the kernels in this module, which are inlined",
      hint:
        "define it as a kernel in this module, or compute it in Elixir and pass the result in",
      example: "defk f(x :: i64) :: i64 do\n  double(x)\nend",
      rewrite:
        "defk double(x :: i64) :: i64 do\n  x * 2\nend\n\ndefk f(x :: i64) :: i64 do\n  double(x)\nend"
    },
    %{
      code: "builtin-arguments",
      kind: :error,
      summary: "A builtin is called with the number and types of arguments it takes.",
      why: "defk never converts a value to another type implicitly",
      hint: "convert the arguments",
      example: "defk f(x :: i64, y :: f64) :: i64 do\n  div(x, y)\nend",
      rewrite: "defk f(x :: i64, y :: f64) :: i64 do\n  div(x, trunc(y))\nend"
    },
    %{
      code: "alloc-form",
      kind: :error,
      summary: "alloc/2 takes an element type (f64, i64 or u8) and a length.",
      why: "an array's element type is fixed when it is created",
      hint: "name the element type first",
      example: "defk f(n :: i64) :: [f64] do\n  alloc(n)\nend",
      rewrite: "defk f(n :: i64) :: [f64] do\n  alloc(f64, n)\nend"
    },
    %{
      code: "tuple-argument",
      kind: :subset,
      summary: "Tuples are not passed as arguments.",
      why:
        "a kernel keeps a tuple's elements in separate registers and passes them as separate arguments",
      hint: "pass the elements as separate arguments",
      example:
        "defk g(a :: i64, b :: i64) :: i64 do\n  a + b\nend\n\ndefk f(x :: i64) :: i64 do\n  g({x, x})\nend",
      rewrite:
        "defk g(a :: i64, b :: i64) :: i64 do\n  a + b\nend\n\ndefk f(x :: i64) :: i64 do\n  g(x, x)\nend"
    },
    %{
      code: "tuple-return-call",
      kind: :subset,
      summary: "A kernel that returns a tuple is called from Elixir only.",
      why:
        "a kernel's tuple result becomes a BEAM tuple, and inside a kernel a tuple can't be held as one value",
      hint: "split it into kernels that return one value each",
      example:
        "defk g(x :: i64) :: {i64, i64} do\n  {x, x + 1}\nend\n\ndefk f(x :: i64) :: i64 do\n  {a, b} = g(x)\n  a + b\nend",
      rewrite:
        "defk g_lo(x :: i64) :: i64 do\n  x\nend\n\ndefk g_hi(x :: i64) :: i64 do\n  x + 1\nend\n\ndefk f(x :: i64) :: i64 do\n  g_lo(x) + g_hi(x)\nend"
    },
    %{
      code: "recursion",
      kind: :subset,
      summary:
        "A kernel can't call itself, directly or through other kernels; write the recursion as a loop.",
      why:
        "kernel calls are inlined into the caller, so a kernel can't call itself, directly or through another kernel",
      hint: "write the recursion as a loop",
      example: "defk f(x :: i64) :: i64 do\n  if x == 0, do: 0, else: x + f(x - 1)\nend",
      rewrite:
        "defk f(x :: i64) :: i64 do\n  for i <- 1..x//1, reduce: 0 do\n    acc -> acc + i\n  end\nend"
    },
    %{
      code: "unsupported-call",
      kind: :subset,
      summary:
        "Calls into other modules are not in the kernel subset, except Enum.reduce_while/3, Enum.all?/2, Enum.any?/2 and :math functions with a builtin.",
      why: "a kernel runs as native code and can't call Elixir functions",
      hint: "compute it in Elixir before or after the call and pass the result in",
      example: "defk f(a :: [f64]) :: [f64] do\n  Enum.map(a, fn x -> x * 2.0 end)\nend",
      rewrite:
        "defk f(a :: [f64]) :: [f64] do\n  out = alloc(f64, len(a))\n\n  for i <- 0..(len(a) - 1)//1 do\n    out[i] = a[i] * 2.0\n  end\n\n  out\nend"
    },
    %{
      code: "enum-reduce",
      kind: :planned,
      summary: "Enum.reduce/3 is planned; write the same fold as `for ..., reduce:`.",
      why: "Enum.reduce/3 is planned; `for ..., reduce:` is the same fold",
      hint: "write it as a for ..., reduce: loop",
      example:
        "defk f(a :: [f64]) :: f64 do\n  Enum.reduce(a, 0.0, fn x, acc -> acc + x end)\nend",
      rewrite:
        "defk f(a :: [f64]) :: f64 do\n  for x <- a, reduce: 0.0 do\n    acc -> acc + x\n  end\nend"
    },
    %{
      code: "enum-find",
      kind: :planned,
      summary:
        "Enum.find/2 and Enum.find_index/2 are planned; stop early with Enum.reduce_while/3.",
      why:
        "Enum.find/2 and Enum.find_index/2 return nil when nothing is found, a kernel has no nil, and a form that keeps their meaning is planned",
      hint: "stop at the first match with Enum.reduce_while/3 and a value that means not found",
      example:
        "defk f(a :: [f64], t :: f64) :: i64 do\n  Enum.find_index(a, fn x -> x > t end)\nend",
      rewrite:
        "defk f(a :: [f64], t :: f64) :: i64 do\n  Enum.reduce_while(0..(len(a) - 1)//1, -1, fn i, _ ->\n    if a[i] > t, do: {:halt, i}, else: {:cont, -1}\n  end)\nend"
    },
    %{
      code: "fn-argument",
      kind: :subset,
      summary:
        "Enum.reduce_while/3, Enum.all?/2 and Enum.any?/2 take a literal fn with one clause and no guard.",
      why: "the fn is inlined as the loop body, so it must be written out where it is passed",
      hint: "write the function as a literal fn",
      example: "defk f(x :: i64) :: bool do\n  Enum.all?(1..x//1, &(&1 > 0))\nend",
      rewrite: "defk f(x :: i64) :: bool do\n  Enum.all?(1..x//1, fn i -> i > 0 end)\nend"
    },
    %{
      code: "reduce-while-tail",
      kind: :error,
      summary:
        "Every branch of an Enum.reduce_while/3 fn ends in a literal {:cont, acc} or {:halt, acc}.",
      why:
        "a kernel compiles {:cont, acc} to the next iteration and {:halt, acc} to a jump out of the loop, so each must be written where the fn returns",
      hint: "return {:cont, acc} or {:halt, acc} from every branch",
      example:
        "defk f(x :: i64) :: i64 do\n  Enum.reduce_while(1..x//1, 0, fn i, acc -> acc + i end)\nend",
      rewrite:
        "defk f(x :: i64) :: i64 do\n  Enum.reduce_while(1..x//1, 0, fn i, acc -> {:cont, acc + i} end)\nend"
    },
    %{
      code: "pipe",
      kind: :subset,
      summary: "The pipe operator |> is not in the kernel subset; write the nested call.",
      why:
        "kernels keep to the forms of a numeric loop, and a pipe there is a nested call written another way",
      hint: "write the nested call",
      example: "defk f(x :: f64) :: f64 do\n  x |> abs() |> sqrt()\nend",
      rewrite: "defk f(x :: f64) :: f64 do\n  sqrt(abs(x))\nend"
    },
    %{
      code: "bitwise",
      kind: :planned,
      summary: "Bitwise operators (&&&, |||, ^^^, <<<, >>>, band, bor, ...) are planned.",
      why: "bitwise operators on i64 are planned",
      hint: "for a non-negative x, rem(x, 2) is band(x, 1) and x * 4 is x <<< 2",
      example: "defk f(x :: i64) :: i64 do\n  Bitwise.band(x, 1)\nend",
      rewrite: "defk f(x :: i64) :: i64 do\n  rem(x, 2)\nend"
    },

    # -- loops
    %{
      code: "for-collect",
      kind: :subset,
      summary:
        "A `for` collects nothing: without reduce: it is a statement, and into: is not in the kernel subset.",
      why:
        "a for without reduce: builds a list in Elixir (into: another collection), and a kernel has no lists",
      hint: "allocate the output array and write it in the loop",
      example: "defk f(a :: [f64]) :: [f64] do\n  for x <- a, do: x * 2.0\nend",
      rewrite:
        "defk f(a :: [f64]) :: [f64] do\n  out = alloc(f64, len(a))\n\n  for i <- 0..(len(a) - 1)//1 do\n    out[i] = a[i] * 2.0\n  end\n\n  out\nend"
    },
    %{
      code: "for-option",
      kind: :subset,
      summary: "`for` takes `reduce:` and `do`; other options are not in the kernel subset.",
      why: "uniq: needs a set of the values seen, a BEAM term a kernel doesn't have",
      hint: "remove the option",
      example:
        "defk f(a :: [f64]) :: f64 do\n  for x <- a, uniq: true, reduce: 0.0 do\n    acc -> acc + x\n  end\nend",
      rewrite:
        "defk f(a :: [f64]) :: f64 do\n  for x <- a, reduce: 0.0 do\n    acc -> acc + x\n  end\nend"
    },
    %{
      code: "for-form",
      kind: :error,
      summary: "A `for` starts with a generator and has a do block.",
      why: "a for loops over its first generator",
      hint: "start the for with a generator such as i <- 0..(n - 1)//1",
      example:
        "defk f(x :: i64) :: i64 do\n  for x > 0, reduce: 0 do\n    acc -> acc + 1\n  end\nend",
      rewrite:
        "defk f(x :: i64) :: i64 do\n  for i <- 1..x//1, i > 0, reduce: 0 do\n    acc -> acc + 1\n  end\nend"
    },
    %{
      code: "generator-pattern",
      kind: :subset,
      summary: "A generator binds one variable: `x <- array` or `i <- range`.",
      why: "a generator walks a range or an array, one value per iteration",
      hint: "bind a single variable",
      example:
        "defk f(a :: [f64]) :: f64 do\n  for {x, i} <- Enum.with_index(a), reduce: 0.0 do\n    acc -> acc + x * i\n  end\nend",
      rewrite:
        "defk f(a :: [f64]) :: f64 do\n  for i <- 0..(len(a) - 1)//1, reduce: 0.0 do\n    acc -> acc + a[i] * i\n  end\nend"
    },
    %{
      code: "generator-source",
      kind: :error,
      summary: "A generator walks a range or an array.",
      why: "a for or Enum.reduce_while/all?/any? walks a range a..b//step or an array",
      hint: "walk a range",
      example:
        "defk f(n :: i64) :: i64 do\n  for i <- n, reduce: 0 do\n    acc -> acc + i\n  end\nend",
      rewrite:
        "defk f(n :: i64) :: i64 do\n  for i <- 0..(n - 1)//1, reduce: 0 do\n    acc -> acc + i\n  end\nend"
    },
    %{
      code: "range-step",
      kind: :error,
      summary: "A range step is never zero.",
      why: "Elixir raises ArgumentError for a range with step 0",
      hint: "step by 1 (or -1 to count down)",
      example:
        "defk f(n :: i64) :: i64 do\n  for i <- 0..n//0, reduce: 0 do\n    acc -> acc + i\n  end\nend",
      rewrite:
        "defk f(n :: i64) :: i64 do\n  for i <- 0..n//1, reduce: 0 do\n    acc -> acc + i\n  end\nend"
    },
    %{
      code: "reduce-clauses",
      kind: :subset,
      summary: "`for ..., reduce:` has exactly one `acc -> body` clause.",
      why:
        "a kernel binds the accumulator to a variable; choosing between clauses by pattern is not in the kernel subset",
      hint: "use one clause and branch inside it",
      example:
        "defk f(n :: i64) :: i64 do\n  for i <- 1..n//1, reduce: 0 do\n    0 -> i\n    acc -> acc + i\n  end\nend",
      rewrite:
        "defk f(n :: i64) :: i64 do\n  for i <- 1..n//1, reduce: 0 do\n    acc -> if acc == 0, do: i, else: acc + i\n  end\nend"
    },
    %{
      code: "accumulator-shape",
      kind: :error,
      summary:
        "An accumulator pattern, its initial value and each new value have the same number of elements.",
      why:
        "each accumulator element is its own variable, so every value of it has the same elements",
      hint: "give the initial value and every new value one element per accumulator variable",
      example:
        "defk f(n :: i64) :: i64 do\n  {s, c} =\n    for i <- 1..n//1, reduce: {0, 0} do\n      {s, c} -> {s + i}\n    end\n\n  s + c\nend",
      rewrite:
        "defk f(n :: i64) :: i64 do\n  {s, c} =\n    for i <- 1..n//1, reduce: {0, 0} do\n      {s, c} -> {s + i, c + 1}\n    end\n\n  s + c\nend"
    },
    %{
      code: "accumulator-pattern",
      kind: :subset,
      summary: "An accumulator is a variable or a tuple of variables.",
      why:
        "a kernel keeps each accumulator element in its own variable; patterns that test values are not in the kernel subset",
      hint: "bind a variable and test the value inside the body",
      example:
        "defk f(n :: i64) :: i64 do\n  for i <- 1..n//1, reduce: 0 do\n    acc when acc < 100 -> acc + i\n  end\nend",
      rewrite:
        "defk f(n :: i64) :: i64 do\n  for i <- 1..n//1, reduce: 0 do\n    acc -> if acc < 100, do: acc + i, else: acc\n  end\nend"
    },
    %{
      code: "array-accumulator",
      kind: :subset,
      summary:
        "Arrays are not accumulators; allocate the array before the loop and write it in the body.",
      why:
        "an accumulator is a number or a boolean (or a tuple of them); an array is written in place",
      hint: "allocate the array before the loop and write it in the body",
      example:
        "defk f(n :: i64) :: [f64] do\n  for i <- 0..(n - 1)//1, reduce: alloc(f64, n) do\n    out -> out\n  end\nend",
      rewrite:
        "defk f(n :: i64) :: [f64] do\n  out = alloc(f64, n)\n\n  for i <- 0..(n - 1)//1 do\n    out[i] = float(i)\n  end\n\n  out\nend"
    },

    # -- case
    %{
      code: "case-form",
      kind: :error,
      summary: "A `case` has a do block of `pattern -> body` clauses.",
      why: "a case chooses the first clause whose pattern matches",
      hint: "write the clauses in a do block",
      example: "defk f(x :: i64) :: i64 do\n  case x, do: 1\nend",
      rewrite: "defk f(x :: i64) :: i64 do\n  case x do\n    _ -> 1\n  end\nend"
    },
    %{
      code: "case-subject",
      kind: :subset,
      summary: "`case` matches an i64 or a bool.",
      why:
        "a case clause matches integer literals, true/false, pins and variables; a float has no exact literal match worth keeping, and other values are not in the kernel subset",
      hint: "compare with cond",
      example: "defk f(x :: f64) :: i64 do\n  case x do\n    0.0 -> 0\n    _ -> 1\n  end\nend",
      rewrite:
        "defk f(x :: f64) :: i64 do\n  cond do\n    x == 0.0 -> 0\n    true -> 1\n  end\nend"
    },
    %{
      code: "case-pattern",
      kind: :subset,
      summary:
        "A case pattern is an integer literal, true/false, ^var, _ or a variable, with an optional guard.",
      why: "a kernel matches its i64 or bool subject against single values",
      hint: "use one of those patterns, or a guard",
      example:
        "defk f(x :: i64) :: i64 do\n  case x do\n    {a, b} -> a + b\n    _ -> 0\n  end\nend",
      rewrite:
        "defk f(x :: i64) :: i64 do\n  case x do\n    n when n > 0 -> n\n    _ -> 0\n  end\nend"
    },
    %{
      code: "case-pattern-type",
      kind: :error,
      summary: "A case pattern can match the subject's type.",
      why: "a literal of another type never matches, as in Elixir",
      hint: "match a value of the subject's type",
      example: "defk f(b :: bool) :: i64 do\n  case b do\n    1 -> 1\n    _ -> 0\n  end\nend",
      rewrite: "defk f(b :: bool) :: i64 do\n  case b do\n    true -> 1\n    _ -> 0\n  end\nend"
    },
    %{
      code: "case-guard",
      kind: :error,
      summary:
        "A case guard uses guard-safe expressions: variables, literals, arithmetic, comparisons, and/or/not, div, rem, abs, trunc, round, min and max.",
      why:
        "Elixir allows only guard-safe expressions in guards, and kernel calls and indexing are not guard-safe",
      hint: "compute the value before the case, and use the variable in the guard",
      example:
        "defk g(x :: i64) :: i64 do\n  x * 2\nend\n\ndefk f(x :: i64) :: i64 do\n  case x do\n    n when g(n) > 4 -> 1\n    _ -> 0\n  end\nend",
      rewrite:
        "defk g(x :: i64) :: i64 do\n  x * 2\nend\n\ndefk f(x :: i64) :: i64 do\n  y = g(x)\n\n  case x do\n    _ when y > 4 -> 1\n    _ -> 0\n  end\nend"
    },

    # -- values outside the kernel subset
    %{
      code: "unsupported-map",
      kind: :subset,
      summary: "Maps and structs are not in the kernel subset.",
      why:
        "a kernel works on numbers, booleans, tuples and packed arrays; a map is a BEAM term it can neither build nor read",
      hint: "pass the values as separate arguments, or pack them into an array before the call",
      example: "defk f(x :: i64) :: i64 do\n  m = %{a: x}\n  x\nend",
      rewrite: "defk f(a :: i64) :: i64 do\n  a\nend"
    },
    %{
      code: "unsupported-string",
      kind: :subset,
      summary: "Strings are not in the kernel subset; a kernel sees bytes as a [u8] array.",
      why: "kernels see bytes, not text: there are no UTF-8 or grapheme operations",
      hint:
        "pass the bytes as a [u8] argument, and do text work in Elixir before or after the call",
      example: "defk f(x :: i64) :: i64 do\n  s = \"hello\"\n  x\nend",
      rewrite: "defk f(s :: [u8]) :: i64 do\n  s[0]\nend"
    },
    %{
      code: "unsupported-atom",
      kind: :subset,
      summary: "Atoms (other than true and false) and nil are not in the kernel subset.",
      why: "a kernel returns numbers, booleans, tuples and arrays; an atom is a BEAM term",
      hint: "return a bool or an integer code, and turn it into an atom in Elixir",
      example: "defk f(x :: i64) :: i64 do\n  s = if x > 0, do: :pos, else: :neg\n  x\nend",
      rewrite: "defk f(x :: i64) :: bool do\n  x > 0\nend"
    },
    %{
      code: "unsupported-list",
      kind: :subset,
      summary: "Lists are not in the kernel subset; a kernel takes packed arrays.",
      why: "a list is a linked BEAM term; a kernel works on packed arrays",
      hint:
        "pass the values as an array, a binary such as `for x <- list, into: <<>>, do: <<x::float-native-64>>`",
      example: "defk f(x :: i64) :: i64 do\n  xs = [x, x + 1]\n  x\nend",
      rewrite: "defk f(xs :: [i64]) :: i64 do\n  xs[0] + xs[1]\nend"
    },
    %{
      code: "unsupported-fn",
      kind: :subset,
      summary:
        "Anonymous functions are not values in a kernel; define another kernel and call it.",
      why: "a kernel inlines the kernels it calls; a function value would need a BEAM closure",
      hint: "define the function as a kernel in this module and call it",
      example: "defk f(x :: i64) :: i64 do\n  g = fn y -> y * 2 end\n  x\nend",
      rewrite:
        "defk g(y :: i64) :: i64 do\n  y * 2\nend\n\ndefk f(x :: i64) :: i64 do\n  g(x)\nend"
    },
    %{
      code: "bitstring-build",
      kind: :planned,
      summary: "Building bitstrings with <<...>> is planned (the bitstring accumulator).",
      why: "a kernel produces bytes by writing an alloc/2 array; building bitstrings is planned",
      hint: "write the bytes into an alloc(u8, n) array",
      example: "defk f(x :: i64) :: i64 do\n  b = <<x::8>>\n  x\nend",
      rewrite: "defk f(x :: i64) :: [u8] do\n  b = alloc(u8, 1)\n  b[0] = rem(x, 256)\n  b\nend"
    },
    %{
      code: "unsupported-construct",
      kind: :subset,
      summary:
        "A kernel uses the Elixir forms #{@forms}; others such as unless, with, try, receive and raise are not in the kernel subset.",
      why: "a kernel uses a fixed set of Elixir forms: #{@forms}",
      hint: "write it with those forms",
      example: "defk f(x :: i64) :: i64 do\n  unless x > 0, do: 0, else: x\nend",
      rewrite: "defk f(x :: i64) :: i64 do\n  if not (x > 0), do: 0, else: x\nend"
    },
    %{
      code: "unsupported-expression",
      kind: :subset,
      summary: "Any other expression is not in the kernel subset.",
      why:
        "a kernel uses a fixed set of Elixir forms: #{@forms}, over numbers, booleans, tuples and arrays",
      hint: "write it with those forms, or compute it in Elixir and pass the result in",
      example: "defk f(x :: i64) :: i64 do\n  r = 1..x\n  x\nend",
      rewrite:
        "defk f(x :: i64) :: i64 do\n  for i <- 1..x//1, reduce: 0 do\n    acc -> acc + i\n  end\nend"
    }
  ]

  @by_code Map.new(@codes, &{&1.code, &1})

  @doc "Every error code, in documentation order."
  def codes, do: @codes

  @doc "The registry entry for `code`."
  def fetch!(code), do: Map.fetch!(@by_code, code)

  @doc "The docs/language.md anchor for `code`."
  def docs(code), do: @docs <> code

  @doc """
  Prints the registry entry for `code`: summary, why, hint, example and rewrite.

  Raises `ArgumentError` for an unknown code.

      mix run -e 'Defk.Errors.explain!("unsupported-map")'
  """
  @spec explain!(String.t()) :: :ok
  def explain!(code) do
    entry =
      case Map.fetch(@by_code, code) do
        {:ok, entry} -> entry
        :error -> raise ArgumentError, "unknown defk error code #{inspect(code)}"
      end

    IO.puts(
      Enum.join(
        [
          "defk #{entry.code}",
          "",
          entry.summary,
          "",
          "why: #{entry.why}",
          "hint: #{entry.hint}",
          "",
          "example:",
          indent_block(entry.example),
          "",
          "rewrite:",
          indent_block(entry.rewrite)
        ],
        "\n"
      )
    )
  end

  defp indent_block(text), do: text |> String.split("\n") |> Enum.map_join("\n", &indent/1)

  defp footer(code) do
    if @language_doc_exists do
      "(defk #{code}: #{docs(code)})"
    else
      "(defk #{code}; mix run -e 'Defk.Errors.explain!(\"#{code}\")')"
    end
  end

  # ------------------------------------------------------------ rendering --

  @doc false
  # The CompileError for a module's rejections, at most @cap of them shown.
  def compile_error(module, file, diags) do
    diags = Enum.sort_by(diags, &{&1.line, &1.col})
    {shown, rest} = Enum.split(diags, @cap)
    n = length(diags)

    head =
      "cannot compile #{inspect(module)}: #{n} kernel compile error#{if n == 1, do: "", else: "s"}"

    more = if rest == [], do: [], else: ["#{length(rest)} more not shown; fix these first"]

    %CompileError{
      file: file,
      line: 0,
      description: Enum.join([head | Enum.map(shown, &render/1)] ++ more, "\n\n")
    }
  end

  @doc false
  # Style D: Elixir's diagnostic frame, then why, hint (with a rewrite) and the code.
  def render(d) do
    entry = fetch!(d.code)
    why = d[:why] || entry.why
    hint = d[:hint] || entry.hint

    hint =
      case d[:rewrite] do
        nil -> hint
        rw -> "#{hint}:\n\n" <> indent_block(rw)
      end

    Enum.join(
      [frame(d), "", "why: #{why}", "hint: #{hint}", footer(d.code)],
      "\n"
    )
  end

  defp indent(""), do: ""
  defp indent(line), do: "    " <> line

  defp frame(d) do
    loc = "#{relative(d.file)}:#{d.line}#{if d.col, do: ":#{d.col}"}"
    fun = with {name, arity} <- d.fun, do: ": #{inspect(d.module)}.#{name}/#{arity}"

    case d.text do
      nil ->
        "error: #{d.what}\n└─ #{loc}#{fun}"

      text ->
        pad = String.duplicate(" ", String.length("#{d.line}"))
        caret = String.duplicate(" ", d.col - 1) <> String.duplicate("^", max(d.width, 1))

        Enum.join(
          [
            "error: #{d.what}",
            "#{pad} │",
            "#{d.line} │#{text}",
            "#{pad} │#{caret}",
            "#{pad} │",
            "#{pad} └─ #{loc}#{fun}"
          ],
          "\n"
        )
    end
  end

  defp relative(nil), do: "nofile"
  defp relative(file), do: Path.relative_to_cwd(file)

  # ------------------------------------------------------------- location --

  @doc false
  # {line, col, width, line_text} of `node` in the source. A node without
  # metadata (a literal) is searched for inside `ctx`, the enclosing statement.
  def locate(node, ctx, lines) do
    case start(node) do
      {line, col} ->
        place(lines, line, col, node)

      nil ->
        case start(ctx) do
          nil -> {0, nil, 1, nil}
          {line, col} -> find_literal(lines, line, col, node) || place(lines, line, col, ctx)
        end
    end
  end

  # earliest {line, column} in the node's metadata
  defp start(nil), do: nil

  defp start(node) do
    {_, acc} =
      Macro.prewalk(node, [], fn
        {_, m, _} = n, acc when is_list(m) ->
          if m[:line] && m[:column], do: {n, [{m[:line], m[:column]} | acc]}, else: {n, acc}

        n, acc ->
          {n, acc}
      end)

    if acc == [], do: line_only(node), else: Enum.min(acc)
  end

  defp line_only({_, m, _}) when is_list(m), do: if(m[:line], do: {m[:line], nil})
  defp line_only(_), do: nil

  defp source_line(nil, _), do: nil

  defp source_line(lines, line) when line >= 1 and line <= tuple_size(lines),
    do: elem(lines, line - 1)

  defp source_line(_, _), do: nil

  defp place(lines, line, nil, _node), do: {line, nil, 1, nil} |> with_text(lines)

  defp place(lines, line, col, node) do
    case source_line(lines, line) do
      nil ->
        {line, col, 1, nil}

      text ->
        {col, width} = span(text, col, node)
        {line, col, width, text}
    end
  end

  defp with_text({line, col, width, _}, lines), do: {line, col, width, source_line(lines, line)}

  # The columns of `node` on its first line: the longest slice from its start
  # (or an opening bracket just before it) that parses back to the node. A node
  # that doesn't fit on one line is underlined to the end of its first line.
  defp span(text, col, node) do
    norm = strip(node)
    len = String.length(text)

    starts = [col | opening_brackets(text, col)]

    exact =
      Enum.find_value(starts, fn s ->
        Enum.find_value((len - s + 1)..1//-1, fn w ->
          if parses_to?(String.slice(text, s - 1, w), norm), do: {s, w}
        end)
      end)

    exact || {col, max(String.length(String.trim_trailing(text)) - col + 1, 1)}
  end

  # columns of `(`, `{` or `[` directly before `col` (whitespace between)
  defp opening_brackets(text, col) do
    text
    |> String.slice(0, col - 1)
    |> String.graphemes()
    |> Enum.with_index(1)
    |> Enum.reverse()
    |> Enum.reduce_while([], fn
      {c, i}, acc when c in ["(", "{", "["] -> {:cont, acc ++ [i]}
      {c, _}, acc when c in [" ", "\t"] -> {:cont, acc}
      _, acc -> {:halt, acc}
    end)
  end

  defp parses_to?(snippet, norm) do
    case Code.string_to_quoted(snippet, emit_warnings: false) do
      {:ok, ast} -> strip(ast) == norm
      _ -> false
    end
  rescue
    _ -> false
  end

  defp strip(ast) do
    Macro.prewalk(ast, fn
      {a, m, b} when is_list(m) -> {a, [], b}
      other -> other
    end)
  end

  # a literal (no metadata) is found by its text after the statement's start
  defp find_literal(nil, _line, _col, _node), do: nil

  defp find_literal(lines, line, col, node) do
    needle = Macro.to_string(node)

    Enum.find_value(line..min(line + 30, tuple_size(lines)), fn l ->
      text = elem(lines, l - 1)
      from = if l == line, do: col - 1, else: 0
      {pre, rest} = String.split_at(text, from)

      case :binary.match(rest, needle) do
        {pos, _} ->
          {l, String.length(pre) + String.length(binary_part(rest, 0, pos)) + 1,
           String.length(needle), text}

        :nomatch ->
          nil
      end
    end)
  end

  # ------------------------------------------------- constructs not in it --

  @doc false
  # The rejection for a construct outside the kernel subset: {code, what,
  # opts}. Used for expressions the compiler has no clause for. `type_of`
  # gives the kernel type of an expression where the construct is, or nil.
  #
  # A `rewrite:` is one candidate or a list of them, written from the
  # developer's code; the compiler shows the first one that compiles where the
  # construct is, and only the hint if none does. A rewrite never names
  # anything the developer has to fill in.
  def unsupported(node, type_of \\ fn _ -> nil end)

  def unsupported({:**, _, [a, b]} = n, type_of) do
    {"unsupported-expression",
     "the power operator in #{Macro.to_string(n)} is not in the kernel subset",
     hint:
       "use pow/2, which returns a float like :math.pow/2, or multiply for a small integer power",
     rewrite: power_rewrite(a, b, type_of.(a), type_of.(b))}
  end

  def unsupported(node, _type_of), do: form(node)

  # Elixir's ** gives an integer for two integers and a float otherwise
  defp power_rewrite(_a, 0, :i64, :i64), do: "1"

  defp power_rewrite(a, b, :i64, :i64) when is_integer(b) and b in 1..8,
    do: a |> List.duplicate(b) |> Enum.reduce(&{:*, [], [&2, &1]}) |> Macro.to_string()

  defp power_rewrite(a, b, ta, tb)
       when ta in [:i64, :f64] and tb in [:i64, :f64] and :f64 in [ta, tb],
       do: Macro.to_string({:pow, [], [a, b]})

  defp power_rewrite(_a, _b, _ta, _tb), do: nil

  defp form({:%{}, _, _}), do: map()

  defp form({:%, _, [{:__aliases__, _, parts} | _]}),
    do: map("structs (%#{Enum.join(parts, ".")}{})")

  defp form({:%, _, _}), do: map("structs")

  defp form(s) when is_binary(s), do: string()
  defp form({:<>, _, _}), do: string("string concatenation with <>")
  defp form({sigil, _, _}) when sigil in [:sigil_s, :sigil_S], do: string()

  defp form({:<<>>, _, parts} = node) do
    if Enum.any?(parts, &string_part?/1),
      do: string(),
      else:
        {"bitstring-build",
         "building a bitstring with #{Macro.to_string(node)} is not supported yet", []}
  end

  defp form(nil), do: {"unsupported-atom", "nil is not in the kernel subset", []}

  defp form(a) when is_atom(a),
    do: {"unsupported-atom", "atoms such as #{inspect(a)} are not in the kernel subset", []}

  defp form(list) when is_list(list),
    do:
      {"unsupported-list", "lists such as #{Macro.to_string(list)} are not in the kernel subset",
       []}

  defp form({op, _, _}) when op in [:++, :--],
    do: {"unsupported-list", "list operator #{op} is not in the kernel subset", []}

  defp form({:fn, _, _}),
    do: {"unsupported-fn", "anonymous functions are not in the kernel subset", []}

  defp form({:&, _, _} = n),
    do: {"unsupported-fn", "the capture #{Macro.to_string(n)} is not in the kernel subset", []}

  defp form({:|>, _, [_, _]} = node) do
    {"pipe", "the pipe operator |> is not in the kernel subset",
     rewrite: Macro.to_string(unpipe(node))}
  end

  defp form({:@, _, [{name, _, ctx}]}) when is_atom(name) and is_atom(ctx) do
    {"module-attribute", "module attributes such as @#{name} are not supported yet", []}
  end

  defp form({op, _, args}) when op in @bitwise_ops or (op in @bitwise_funs and is_list(args)) do
    {"bitwise",
     "the bitwise #{if op in @bitwise_ops, do: "operator #{op}", else: "function #{op}/#{length(args)}"} is not supported yet",
     []}
  end

  defp form({{:., _, [{:__aliases__, _, [:Bitwise]}, f]}, _, args}) do
    {"bitwise", "Bitwise.#{f}/#{length(args)} is not supported yet", []}
  end

  # map.field
  defp form({{:., _, [{v, _, ctx}, field]}, m, []})
       when is_atom(v) and is_atom(ctx) and is_atom(field) do
    if m[:no_parens],
      do: map("field access #{v}.#{field} (maps and structs)"),
      else: call_rejection(nil, field, [], nil)
  end

  defp form({{:., _, [mod, fun]}, _, args} = node) when is_atom(fun) and is_list(args) do
    call_rejection(module_name(mod), fun, args, node)
  end

  defp form({range, _, _} = n) when range in [:.., :..//],
    do:
      {"unsupported-expression",
       "the range #{Macro.to_string(n)} as a value is not in the kernel subset",
       hint:
         "use the range as the generator of a for, Enum.reduce_while/3, Enum.all?/2 or Enum.any?/2"}

  defp form({:in, _, [x, list]} = n) when is_list(list) and list != [] do
    rewrite =
      list
      |> Enum.map(&{:==, [], [x, &1]})
      |> Enum.reduce(&{:or, [], [&2, &1]})
      |> Macro.to_string()

    {"unsupported-expression", "#{Macro.to_string(n)} is not in the kernel subset",
     hint: "compare with each value", rewrite: rewrite}
  end

  defp form({:=, _, _} = n) do
    {"unsupported-expression",
     "the match #{Macro.to_string(n)} used as a value is not in the kernel subset",
     hint: "bind it on its own line, then use the variable"}
  end

  defp form({:unless, _, [c, kw]}) when is_list(kw) do
    rewrite = Macro.to_string({:if, [], [{:not, [], [c]}, kw]})

    {"unsupported-construct", "unless is not in the kernel subset",
     hint: "write if not", rewrite: rewrite}
  end

  defp form({name, _, args}) when name in [:raise, :reraise, :throw, :exit] and is_list(args) do
    {"unsupported-construct", "#{name} is not in the kernel subset",
     why:
       "a kernel raises only Elixir's own errors (an i64 overflow, an index out of range, ...), where Elixir would raise them",
     hint: "check the arguments in Elixir before the call"}
  end

  defp form({name, _, args})
       when name in [
              :with,
              :try,
              :receive,
              :send,
              :spawn,
              :quote,
              :unquote,
              :import,
              :alias,
              :require,
              :def,
              :defp,
              :defk,
              :__block__
            ] and is_list(args) do
    {"unsupported-construct", "#{name} is not in the kernel subset", []}
  end

  defp form({name, _, args} = node) when is_atom(name) and is_list(args) do
    case local_hint(name, args) do
      nil ->
        {"unsupported-expression", "#{Macro.to_string(node)} is not in the kernel subset", []}

      found ->
        found
    end
  end

  defp form(node),
    do: {"unsupported-expression", "#{Macro.to_string(node)} is not in the kernel subset", []}

  @doc false
  # A local call to `name` that isn't a builtin or a kernel: a construct
  # outside the subset, checked before its arguments are compiled.
  def unsupported_local({name, _, args} = node, type_of) do
    cond do
      name in [
        :%{},
        :%,
        :<<>>,
        :<>,
        :++,
        :--,
        :fn,
        :&,
        :|>,
        :@,
        :..,
        :..//,
        :in,
        :**,
        :=,
        :unless
      ] ->
        unsupported(node, type_of)

      name in @bitwise_ops or name in @bitwise_funs ->
        unsupported(node, type_of)

      name in [
        :raise,
        :reraise,
        :throw,
        :exit,
        :with,
        :try,
        :receive,
        :send,
        :spawn,
        :quote,
        :unquote,
        :import,
        :alias,
        :require,
        :def,
        :defp,
        :defk
      ] ->
        unsupported(node, type_of)

      String.starts_with?(Atom.to_string(name), "sigil_") ->
        if name in [:sigil_s, :sigil_S],
          do: string(),
          else:
            {"unsupported-expression",
             "sigil ~#{String.trim_leading(Atom.to_string(name), "sigil_")} is not in the kernel subset",
             []}

      true ->
        local_hint(name, args)
    end
  end

  # Elixir functions a developer reaches for that have a builtin form
  defp local_hint(name, [a]) when name in [:length, :byte_size, :tuple_size] do
    {"unknown-function", "#{name}/1 is not in the kernel subset",
     why: "the length of a kernel array is len/1",
     hint: "use len/1",
     rewrite: Macro.to_string({:len, [], [a]})}
  end

  defp local_hint(:elem, [_t, i]) do
    {"unknown-function", "elem/2 is not in the kernel subset",
     why: "a kernel takes a tuple apart where it is bound",
     hint:
       "destructure the tuple where it is bound, e.g. {a, b} = ..., and use element #{Macro.to_string(i)} by name"}
  end

  defp local_hint(_name, _args), do: nil

  defp map(what \\ "maps"), do: {"unsupported-map", "#{what} are not in the kernel subset", []}

  defp string(what \\ "string literals"),
    do:
      {"unsupported-string",
       "#{what} #{if what =~ "literals", do: "are", else: "is"} not in the kernel subset", []}

  defp string_part?(s) when is_binary(s), do: true
  defp string_part?({:"::", _, [{{:., _, [Kernel, :to_string]}, _, _}, _]}), do: true
  defp string_part?(_), do: false

  defp unpipe({:|>, _, [l, r]}) do
    l = unpipe(l)

    case r do
      {{:., _, _} = f, m, args} -> {f, m, [l | args]}
      {f, m, args} when is_atom(f) and is_list(args) -> {f, m, [l | args]}
      {f, m, ctx} when is_atom(f) and is_atom(ctx) -> {f, m, [l]}
      other -> {{:., [], [other]}, [], [l]}
    end
  end

  defp unpipe(other), do: other

  defp module_name({:__aliases__, _, parts}), do: Enum.join(parts, ".")
  defp module_name(a) when is_atom(a), do: inspect(a)
  defp module_name(other), do: Macro.to_string(other)

  # ------------------------------------------------- calls not in subset --

  @list_why "a kernel has no lists, and"
  @loop "write the for loop it stands for"

  defp call_rejection(nil, fun, args, _node),
    do:
      {"unsupported-expression",
       "#{fun}/#{length(args)} called on a value is not in the kernel subset", []}

  defp call_rejection("Enum", :map, [src, {:fn, _, [{:->, _, [[x], body]}]}], _node) do
    {"unsupported-call", "Enum.map/2 is not in the kernel subset",
     why: "Enum.map/2 builds a list, and kernels have no lists",
     hint: "allocate the output array and fill it in a for loop",
     rewrite: fill_rewrites(src, x, body)}
  end

  defp call_rejection("Enum", fun, [src], _node) when fun in [:sum, :product] do
    zero = if fun == :sum, do: 0, else: 1

    {"unsupported-call", "Enum.#{fun}/1 is not in the kernel subset",
     why:
       "Enum.#{fun}/1 takes a list or a range; #{@list_why} the for ..., reduce: loop is the form a kernel compiles",
     hint: "write the for ..., reduce: loop (start from #{zero}.0 if the values are floats)",
     rewrite: fold_rewrites(src, if(fun == :sum, do: :+, else: :*), zero)}
  end

  defp call_rejection("Enum", fun, [[_, _ | _] = list], _node) when fun in [:min, :max] do
    rewrite = list |> Enum.reduce(&{fun, [], [&2, &1]}) |> Macro.to_string()

    {"unsupported-call", "Enum.#{fun}/1 over a list is not in the kernel subset",
     why: "#{String.trim_trailing(@list_why, ", and")}; #{fun}/2 is a builtin",
     hint: "nest #{fun}/2",
     rewrite: rewrite}
  end

  defp call_rejection("Enum", fun, [src], _node) when fun in [:min, :max] do
    rewrite =
      if var?(src) do
        [i, acc] = fresh_names(~w(i acc), [src])

        "for #{i} <- 1..(len(#{s(src)}) - 1)//1, reduce: #{s(src)}[0] do\n  #{acc} -> #{fun}(#{acc}, #{s(index(src, i))})\nend"
      end

    {"unsupported-call", "Enum.#{fun}/1 is not in the kernel subset",
     why:
       "Enum.#{fun}/1 takes a list or a range; #{@list_why} the for ..., reduce: loop is the form a kernel compiles",
     hint:
       "#{@loop}, starting from the first element (Enum.#{fun}/1 raises on an empty list; decide what an empty array gives)",
     rewrite: rewrite}
  end

  defp call_rejection("Enum", fun, args, _node) when fun in [:min_by, :max_by, :min_max] do
    {"unsupported-call", "Enum.#{fun}/#{length(args)} is not in the kernel subset",
     why:
       "Enum.#{fun}/#{length(args)} takes a list or a range; #{@list_why} the for ..., reduce: loop is the form a kernel compiles",
     hint: "#{@loop}, with a tuple accumulator",
     rewrite: extreme_rewrite(fun, args)}
  end

  defp call_rejection("Enum", :with_index, [src | _] = args, _node) do
    a = if var?(src), do: s(src), else: "a"

    {"unsupported-call", "Enum.with_index/#{length(args)} is not in the kernel subset",
     why: "Enum.with_index builds a list of tuples, and a kernel has no lists",
     hint: "walk the index with i <- 0..(len(#{a}) - 1)//1 and read #{a}[i]"}
  end

  defp call_rejection("Enum", :reduce, [src, init, {:fn, _, [{:->, _, [[x, acc], body]}]}], _node) do
    rewrite = "for #{s(x)} <- #{s(src)}, reduce: #{s(init)} do\n  #{s(acc)} -> #{s(body)}\nend"
    {"enum-reduce", "Enum.reduce/3 is not supported yet", rewrite: rewrite}
  end

  defp call_rejection("Enum", :reduce, args, _node),
    do: {"enum-reduce", "Enum.reduce/#{length(args)} is not supported yet", []}

  defp call_rejection("Enum", fun, args, _node) when fun in [:find, :find_index, :find_value] do
    {"enum-find", "Enum.#{fun}/#{length(args)} is not supported yet",
     rewrite: find_index_rewrite(fun, args)}
  end

  defp call_rejection("Enum", :count, [src, {:fn, _, [{:->, _, [[x], pred]}]}], _node) do
    rewrite = "for #{s(x)} <- #{s(src)}, #{s(pred)}, reduce: 0 do\n  acc -> acc + 1\nend"

    {"unsupported-call", "Enum.count/2 is not in the kernel subset",
     why:
       "Enum.count/2 takes a list or a range; #{@list_why} the for ..., reduce: loop with a filter is the form a kernel compiles",
     hint: "count with a filtered for ..., reduce: loop",
     rewrite: rewrite}
  end

  defp call_rejection("Enum", :each, [src, {:fn, _, [{:->, _, [[x], body]}]}], _node) do
    rewrite = "for #{s(x)} <- #{s(src)} do\n  #{s(body)}\nend"

    {"unsupported-call", "Enum.each/2 is not in the kernel subset",
     why: "a for loop is the form a kernel compiles", hint: "write the for loop", rewrite: rewrite}
  end

  defp call_rejection("Enum", fun, args, _node) do
    {"unsupported-call", "Enum.#{fun}/#{length(args)} is not in the kernel subset",
     why:
       "Enum functions take and build lists, and a kernel has none; Enum.reduce_while/3, Enum.all?/2 and Enum.any?/2 are the ones that compile, to loops",
     hint: "write it as a for loop over the array or range"}
  end

  defp call_rejection(":math", fun, args, _node) do
    {"unsupported-call", ":math.#{fun}/#{length(args)} is not in the kernel subset",
     why: "a kernel's math builtins are #{@math} (also as :math.sqrt/1 and so on)",
     hint: "compute it from those, or in Elixir"}
  end

  defp call_rejection(mod, fun, args, _node) do
    {"unsupported-call", "#{mod}.#{fun}/#{length(args)} is not in the kernel subset", []}
  end

  # ------------------------------------------------------------- rewrites --

  # Enum.sum/product over a comprehension, an array or a range as a
  # for ..., reduce: loop, from an integer zero or a float one
  defp fold_rewrites(src, op, zero) do
    {quals, body} =
      case src do
        {:for, _, args} ->
          {kw, quals} = Enum.split_with(args, &(is_list(&1) and Keyword.keyword?(&1)))
          kw = Enum.concat(kw)
          if Keyword.keys(kw) == [:do], do: {quals, kw[:do]}, else: {nil, nil}

        src ->
          [x] = fresh_names(~w(x), [src])
          {[{:<-, [], [var(x), src]}], var(x)}
      end

    if quals do
      [acc] = fresh_names(~w(acc), [quals, body])
      head = "for #{Enum.map_join(quals, ", ", &s/1)}, reduce: "
      step = s({op, [], [var(acc), body]})
      for z <- [zero, zero * 1.0], do: "#{head}#{z} do\n  #{acc} -> #{step}\nend"
    end
  end

  # Enum.min_max/1, min_by/2 and max_by/2 over an array variable, from its
  # first element; the comparison is strict, so the first extreme element
  # wins, as in Elixir
  defp extreme_rewrite(:min_max, [src]) do
    if var?(src) do
      [i, lo, hi] = fresh_names(~w(i lo hi), [src])
      ai = s(index(src, i))

      "for #{i} <- 1..(len(#{s(src)}) - 1)//1, reduce: {#{s(src)}[0], #{s(src)}[0]} do\n  {#{lo}, #{hi}} -> {min(#{lo}, #{ai}), max(#{hi}, #{ai})}\nend"
    end
  end

  defp extreme_rewrite(fun, [src, {:fn, _, [{:->, _, [[x], key]}]}])
       when fun in [:min_by, :max_by] do
    if var?(src) do
      [i, best, k, ki, better] = fresh_names(~w(i best k ki better), [src, key])
      key_at = &s(subst(key, x, index(src, &1)))
      cmp = if fun == :min_by, do: "<", else: ">"

      # (each element gets its own if: an if gives a number, not a tuple)
      """
      {#{best}, _} =
        for #{i} <- 1..(len(#{s(src)}) - 1)//1, reduce: {#{s(src)}[0], #{key_at.(0)}} do
          {#{best}, #{k}} ->
            #{ki} = #{key_at.(i)}
            #{better} = #{ki} #{cmp} #{k}
            {if(#{better}, do: #{s(index(src, i))}, else: #{best}), if(#{better}, do: #{ki}, else: #{k})}
        end

      #{best}\
      """
    end
  end

  defp extreme_rewrite(_fun, _args), do: nil

  # Enum.find_index/2 over an array variable as Enum.reduce_while/3, with -1
  # for not found
  defp find_index_rewrite(:find_index, [src, {:fn, _, [{:->, _, [[x], pred]}]}]) do
    if var?(src) do
      [i] = fresh_names(~w(i), [src, pred])

      "Enum.reduce_while(0..(len(#{s(src)}) - 1)//1, -1, fn #{i}, _ ->\n  if #{s(subst(pred, x, index(src, i)))}, do: {:halt, #{i}}, else: {:cont, -1}\nend)"
    end
  end

  defp find_index_rewrite(_fun, _args), do: nil

  @doc false
  # Filling a new array with `body` for each element `x` of the array variable
  # `src`: the loop Enum.map/2 or a collecting for stands for. One candidate
  # per element type, or nil when `src` is not an array variable.
  def fill_rewrites(src, x, body, elems \\ [:i64, :f64]) do
    if var?(src) do
      [i, out] = fresh_names(~w(i out), [src, body])
      v = s(subst(body, x, index(src, i)))
      n = "len(#{s(src)})"

      for e <- elems,
          do:
            "#{out} = alloc(#{e}, #{n})\n\nfor #{i} <- 0..(#{n} - 1)//1 do\n  #{out}[#{i}] = #{v}\nend\n\n#{out}"
    end
  end

  @doc false
  # The rewrites of a collecting `for x <- src, into: into, do: body` (into is
  # nil without into:). `into: <<>>` with one native-endian segment per
  # element is an array of that element type; other into: have none.
  def collect_rewrites(src, x, body, nil), do: fill_rewrites(src, x, body)

  def collect_rewrites(src, x, {:<<>>, _, [seg]}, {:<<>>, _, []}) do
    case segment(seg) do
      {v, e} -> fill_rewrites(src, x, v, [e])
      nil -> nil
    end
  end

  def collect_rewrites(_src, _x, _body, _into), do: nil

  # {value, element type} of a binary segment with an array's layout
  defp segment({:"::", _, [v, spec]}) do
    parts = spec_parts(spec)

    size =
      Enum.find_value(parts, fn
        n when is_integer(n) -> n
        {:size, n} -> n
        _ -> nil
      end)

    names = for p <- parts, is_atom(p), do: p

    cond do
      :float in names ->
        if size in [nil, 64] and names -- [:float, :native] == [] and :native in names,
          do: {v, :f64}

      size == 64 ->
        if names -- [:integer, :signed, :unsigned, :native] == [] and :native in names,
          do: {v, :i64}

      size in [nil, 8] ->
        if names -- [:integer, :unsigned, :big, :little, :native] == [], do: {v, :u8}

      true ->
        nil
    end
  end

  defp segment(v), do: {v, :u8}

  defp spec_parts({:-, _, [a, b]}), do: spec_parts(a) ++ spec_parts(b)
  defp spec_parts({:size, _, [n]}) when is_integer(n), do: [{:size, n}]
  defp spec_parts({name, _, ctx}) when is_atom(name) and is_atom(ctx), do: [name]
  defp spec_parts(n) when is_integer(n), do: [n]
  defp spec_parts(_), do: [:unknown]

  defp s(ast), do: Macro.to_string(ast)
  defp var(name), do: {String.to_atom(name), [], nil}

  defp var?({v, _, ctx}) when is_atom(v) and is_atom(ctx), do: true
  defp var?(_), do: false

  # a[i] for the array variable `a` and an index name or literal
  defp index(a, i) do
    m = [from_brackets: true]
    {{:., m, [Access, :get]}, m, [a, if(is_integer(i), do: i, else: var(i))]}
  end

  # `bases`, each renamed (i2, i3, ...) if a variable in `asts` has its name
  defp fresh_names(bases, asts) do
    {_, used} =
      Macro.prewalk(asts, MapSet.new(), fn
        {n, _, ctx} = v, acc when is_atom(n) and is_atom(ctx) ->
          {v, MapSet.put(acc, Atom.to_string(n))}

        other, acc ->
          {other, acc}
      end)

    Enum.map(bases, fn b -> Enum.find([b | Enum.map(2..9, &"#{b}#{&1}")], &(&1 not in used)) end)
  end

  defp subst(ast, {x, _, ctx}, with) when is_atom(x) and is_atom(ctx) do
    Macro.prewalk(ast, fn
      {^x, _, c} when is_atom(c) -> with
      other -> other
    end)
  end

  defp subst(ast, _, _), do: ast
end
