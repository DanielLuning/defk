defmodule Defk.Errors do
  @moduledoc """
  Kernel compile errors: the registry of error codes and the error format.

  Every rejection the compiler makes has a stable code, a readable slug that
  is also its heading on the [compile errors](compile-errors.md) page
  (`docs/compile-errors.md#<code>`). From 0.1.0, codes are never renamed.
  `explain!/1` prints a code's entry. `entries/0` lists them, each with a
  one-line summary, whether
  the construct is outside the kernel subset for good (`:subset`), planned
  (`:planned`), or a mistake in a construct that is in it (`:error`), the
  default `why`/`hint`, and a failing `example` with its `rewrite` (both
  module bodies; the test suite checks the example is rejected with that code
  and the rewrite compiles).

  The codes are the stable part: `entries/0` and `explain!/1` are public. The
  keys of an entry map may change in any version, and so may `fetch!/1`,
  which is unstable. The rest of this module is the compiler's.

  A compile error prints in Elixir's diagnostic frame, then why and how to fix:

      error: maps are not in the kernel subset
         │
      12 │     m = %{a: x}
         │         ^^^^^^^
         │
         └─ lib/my_app/kernels.ex:12:9: MyApp.Kernels.f/1

      why: a kernel works on numbers, booleans, tuples and packed arrays; ...
      hint: pass the values as separate arguments, ...
      (defk unsupported-map: https://github.com/DanielLuning/defk/blob/main/docs/compile-errors.md#unsupported-map)

  The footer is a link that opens wherever you read the error. In a project
  that depends on defk (from a path, git or Hex) it is a URL; the same entry
  is on the [compile errors](compile-errors.md) page of these docs, under the
  code's heading. The URL points at the `main` branch on GitHub until defk is
  released on Hex; the release switches it to HexDocs for the installed
  version (see `@url_base`). Only when you compile inside the defk repository
  itself is the footer the page's path (`docs/compile-errors.md#unsupported-map`).
  The page is generated from this registry, so the two never differ.
  """

  # Where an error footer points (defk-djy.6, defk-djy.9). Inside the defk
  # repository the page's relative path opens in an editor. In a project that
  # depends on defk the path would lead into deps/ or another checkout (a
  # path dependency's absolute path), which a reader of HexDocs cannot open,
  # so the footer is a URL there, whether or not the file is on disk. defk is
  # not on Hex yet, so the URL is the GitHub blob on main, which resolves
  # today and keeps every code's anchor (codes are never renamed). At the Hex
  # release (defk-djy.8) change the one line below to
  #   "https://hexdocs.pm/defk/#{Mix.Project.config()[:version]}/compile-errors.html#"
  # (the version of the install, for an anchor that matches that version).
  @url_base "https://github.com/DanielLuning/defk/blob/main/docs/compile-errors.md#"
  @catalogue Path.expand("../../docs/compile-errors.md", __DIR__)

  # Rejections reported per module; later ones are counted, not shown.

  @calls Enum.join(Defk.Builtins.all() -- [:alloc], ", ")
  @forms "=, if, cond, case, for, Enum.reduce_while/3, Enum.all?/2 and Enum.any?/2"

  # ------------------------------------------------------------- registry --
  # Retired codes, never reused: "bitwise" (the operators are supported since
  # defk-w38), "module-attribute" (attributes are constants since defk-ivt),
  # "read-only-array" (an input array is copied before a write since
  # defk-auo), "tuple-return-call" (a kernel returning a tuple is called from
  # kernels since defk-auo), "array-accumulator" (an owned array is threaded
  # through a reduce accumulator since defk-n4r.10).

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
        "Kernel types are i64, u64, f64, bool, arrays of f64, f32, i64, i32, i16, u8 and u64 ([f64], [f32], [i64], [i32], [i16], [u8], [u64]) and tuples of them for results; bitstring is a result type too, and a parameter type of a kernel other kernels call (the bitstring accumulator).",
      why: "a kernel works on native numbers and packed arrays, and these are the types it has",
      hint:
        "use i64, u64, f64, bool, [f64], [f32], [i64], [i32], [i16], [u8] or [u64] (a tuple of them for a result)",
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
      kind: :error,
      summary:
        "A kernel name and arity is defined once: one typed definition with a body, or one bodiless head and its clauses.",
      why:
        "a kernel has one typed head; several bodies are clauses, which follow a bodiless head without types, as in Elixir",
      hint:
        "for several clauses, write the typed head once without a body, then the clauses without types",
      example: "defk f(x :: i64) :: i64 do\n  x\nend\n\ndefk f(x :: i64) :: i64 do\n  x + 1\nend",
      rewrite: "defk f(x :: i64) :: i64 do\n  x + 1\nend"
    },
    %{
      code: "builtin-name",
      kind: :error,
      summary:
        "A kernel cannot take the name and arity of a builtin: the builtin would answer its calls.",
      why:
        "`copy_back/4` is a builtin, so calls to it would reach the builtin, not this kernel; a builtin added later would change what a module computes without a warning",
      hint:
        "rename the kernel and its calls (my_copy_back/4, say); the same name at another arity is fine",
      example: "defk abs(x :: i64) :: i64 do\n  if x < 0, do: -x, else: x\nend",
      rewrite: "defk my_abs(x :: i64) :: i64 do\n  if x < 0, do: -x, else: x\nend"
    },
    %{
      code: "clause-head",
      kind: :error,
      summary: "A multi-clause kernel starts with a bodiless typed head, before its clauses.",
      why:
        "a clause has patterns, not types; the head gives the kernel its parameter and return types, and Elixir reads the head first too",
      hint:
        "write `defk name(param :: type, ...) :: return_type` without a body above the first clause",
      example: "defk f(0), do: 1\ndefk f(x), do: x * 2",
      rewrite: "defk f(x :: i64) :: i64\ndefk f(0), do: 1\ndefk f(x), do: x * 2"
    },
    %{
      code: "clause-types",
      kind: :error,
      summary: "Only the head of a multi-clause kernel has types; its clauses have patterns.",
      why: "the head declares each parameter's type and the result once, for every clause",
      hint: "remove the types from the clause",
      example: "defk f(x :: i64) :: i64\ndefk f(0 :: i64) :: i64, do: 1\ndefk f(x), do: x * 2",
      rewrite: "defk f(x :: i64) :: i64\ndefk f(0), do: 1\ndefk f(x), do: x * 2"
    },
    %{
      code: "clause-pattern",
      kind: :subset,
      summary:
        "A clause parameter is an integer literal (i64), true/false (bool), a variable or _, each variable once, with an optional guard.",
      why:
        "the clauses compile to a case over the parameters, which matches single i64 and bool values: a kernel has no binaries, lists or maps to take apart in a head, and a function head has no variables to pin",
      hint: "match a literal, a variable or _, and test the rest in the guard",
      example: "defk f(x :: i64, y :: i64) :: i64\ndefk f(x, x), do: 0\ndefk f(x, y), do: x - y",
      rewrite:
        "defk f(x :: i64, y :: i64) :: i64\ndefk f(x, y) when x == y, do: 0\ndefk f(x, y), do: x - y"
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
      kind: :error,
      summary:
        "The arms of an if, cond or case that gives a tuple are all tuples of the same size.",
      why: "a tuple from a branch is one branch per element, so every arm gives every element",
      hint:
        "give every arm a tuple of the same size; compute an element in a block before the tuple",
      example:
        "defk f(x :: i64) :: i64 do\n  {a, b} = if x > 0, do: {x, 1}, else: x\n  a + b\nend",
      rewrite:
        "defk f(x :: i64) :: i64 do\n  {a, b} = if x > 0, do: {x, 1}, else: {x, 0}\n  a + b\nend"
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
      summary: "Integer literals fit in i64 or u64 (-2^63..2^64 - 1).",
      why:
        "kernel integers are i64 (-2^63..2^63 - 1) or u64 (0..2^64 - 1, a literal from 2^63 up); a kernel never uses bignums",
      hint: "use a value that fits, or compute in f64",
      example: "defk f(x :: i64) :: i64 do\n  x + 18_446_744_073_709_551_616\nend",
      rewrite: "defk f(x :: i64) :: f64 do\n  x + 1.8446744073709552e19\nend"
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
        "Arithmetic takes numbers, bitwise operators take integers, and/or/not take booleans, comparisons take two numbers or two booleans.",
      why: "booleans are not numbers in Elixir, and defk keeps that",
      hint: "turn the value into the type the operator takes",
      example: "defk f(x :: i64, b :: bool) :: i64 do\n  x + b\nend",
      rewrite: "defk f(x :: i64, b :: bool) :: i64 do\n  if b, do: x + 1, else: x\nend"
    },
    %{
      code: "u64-with-i64",
      kind: :subset,
      summary:
        "Outside a mask, + - * band bor bxor div rem min max mix a u64 only with a u64 or an i64 known to be >= 0.",
      why:
        "outside a mask a kernel computes a u64 operation exactly in 0..2^64 - 1 and an i64 one in i64, and with an i64 that may be negative no type holds every result Elixir gives; inside band(..., 2^k - 1) only the low bits count, so i64 and u64 mix freely there",
      hint:
        "to wrap, as hashes do, move the arithmetic inside band(..., 0xFFFFFFFFFFFFFFFF); to stay exact, make the i64 a u64 first with band(x, 0xFFFFFFFFFFFFFFFF), or keep both i64",
      example: "defk f(h :: u64, x :: i64) :: u64 do\n  h * 31 + x\nend",
      rewrite: "defk f(h :: u64, x :: i64) :: u64 do\n  band(h * 31 + x, 0xFFFFFFFFFFFFFFFF)\nend"
    },
    %{
      code: "not-an-array",
      kind: :error,
      summary: "Only arrays can be indexed with a[i].",
      why:
        "a[i] reads an element of an array ([f64], [f32], [i64], [i32], [i16] or [u8]), and this value is not one",
      hint: "index an array",
      example: "defk f(x :: i64) :: i64 do\n  x[0]\nend",
      rewrite: "defk f(x :: [i64]) :: i64 do\n  x[0]\nend"
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
      code: "undefined-function",
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
      summary: "alloc/2 takes an element type (f64, f32, i64, i32, i16, u8 or u64) and a length.",
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
        "defk f(a :: [f64]) :: [f64] do\n  out = alloc(f64, length(a))\n\n  for i <- 0..(length(a) - 1)//1 do\n    out[i] = a[i] * 2.0\n  end\n\n  out\nend"
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
        "defk f(a :: [f64], t :: f64) :: i64 do\n  Enum.reduce_while(0..(length(a) - 1)//1, -1, fn i, _ ->\n    if a[i] > t, do: {:halt, i}, else: {:cont, -1}\n  end)\nend"
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
        "defk f(a :: [f64]) :: [f64] do\n  out = alloc(f64, length(a))\n\n  for i <- 0..(length(a) - 1)//1 do\n    out[i] = a[i] * 2.0\n  end\n\n  out\nend"
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
        "defk f(a :: [f64]) :: f64 do\n  for i <- 0..(length(a) - 1)//1, reduce: 0.0 do\n    acc -> acc + a[i] * i\n  end\nend"
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
        "A case guard uses guard-safe expressions: variables, literals, arithmetic, comparisons, and/or/not, in with a literal list or a range, div, rem, abs, trunc, round, min and max.",
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
      hint:
        "pass the values as separate arguments, or pack them into an array before the call; for a count per key, index an array by the key (counts = alloc(i64, 256), then counts[b] = counts[b] + 1)",
      example: "defk f(x :: i64) :: i64 do\n  m = %{a: x}\n  x\nend",
      rewrite: "defk f(a :: i64) :: i64 do\n  a\nend"
    },
    %{
      code: "unsupported-string",
      kind: :subset,
      summary:
        "String concatenation with <> and the ~s sigil are not in the kernel subset; a string literal is a [u8].",
      why:
        "kernels see bytes, not text: there are no UTF-8 or grapheme operations, and a kernel cannot build a string at run time",
      hint:
        "write one string literal, or pass the bytes as a [u8] argument and do text work in Elixir before or after the call",
      example: "defk f(x :: i64) :: i64 do\n  s = \"ab\" <> \"cd\"\n  length(s) + x\nend",
      rewrite: "defk f(x :: i64) :: i64 do\n  s = \"abcd\"\n  length(s) + x\nend"
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
        "pass the values as an array, a binary such as `for x <- list, into: <<>>, do: <<x::float-native-64>>`; build a result of unknown length by appending to a bitstring, `<<acc::bitstring, x::64>>`",
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
      code: "unsupported-construct",
      kind: :subset,
      summary:
        "A kernel uses the Elixir forms #{@forms}; others such as unless, with, try, receive and throw are not in the kernel subset.",
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
    },
    # -- build environment (no kernel source triggers this; see test/build_test.exs)
    %{
      code: "no-c-compiler",
      kind: :error,
      summary: "No C compiler could be run to build the kernels.",
      why:
        "a kernel is compiled to native code at build time, so a C toolchain is needed on the build machine, as for elixir_make packages",
      hint:
        "install one (macOS: `xcode-select --install`; Debian/Ubuntu: `apt install build-essential`; Alpine: `apk add build-base`), or set `CC` to a compiler path",
      example: nil,
      rewrite: nil
    },
    # -- bitwise
    %{
      code: "shift-overflow",
      kind: :error,
      summary: "A shift of two integer literals whose result does not fit in i64.",
      why:
        "bsl/<<< gives the exact result as Elixir does, and raises ArithmeticError when it does not fit in i64; with literal operands it would raise every time",
      hint:
        "write a value past 2^63 - 1 as a u64 literal (0x8000000000000000); a mask (1 <<< k) - 1 directly in band(x, mask) is computed at compile time, for k up to 64",
      example: "defk f(x :: i64) :: i64 do\n  band(x, 1 <<< 63)\nend",
      rewrite: "defk f(x :: u64) :: u64 do\n  band(x, 0x8000000000000000)\nend"
    },
    # -- module attributes
    %{
      code: "undefined-attribute",
      kind: :error,
      summary: "A module attribute read in a kernel is defined before the kernel.",
      why:
        "a kernel reads @name as a def does: the attribute's value where the kernel is defined, inlined as a constant",
      hint: "define the attribute above the kernel, or pass the value as a parameter",
      example: "defk f(x :: i64) :: i64 do\n  x * @scale\nend",
      rewrite: "@scale 3\n\ndefk f(x :: i64) :: i64 do\n  x * @scale\nend"
    },
    %{
      code: "attribute-value",
      kind: :subset,
      summary:
        "A module attribute read in a kernel holds an integer (in i64 or u64), a float, a boolean or a binary.",
      why:
        "a kernel inlines an attribute as a constant: a number or boolean as its literal, a binary as a [u8] that a write copies first; other terms such as lists, tuples, maps and atoms are BEAM terms it cannot hold",
      hint: "pass the value as a parameter; pack a list of bytes into a binary attribute",
      example: "@table [1, 2, 4, 8]\n\ndefk f(i :: i64) :: i64 do\n  i + @table\nend",
      rewrite: "@table <<1, 2, 4, 8>>\n\ndefk f(i :: i64) :: i64 do\n  @table[i]\nend"
    },
    %{
      code: "binary-literal",
      kind: :subset,
      summary:
        "A binary literal in a kernel is a string or <<...>> of integer bytes (0..255); anything else is built in Elixir.",
      why:
        "a binary literal is a read-only [u8] in static storage, so every byte must be known when the kernel compiles: no interpolation, charlists, floats, other segment types or sizes, and no value over 255",
      hint: "build it in Elixir and pass it as a [u8] parameter, or use a module attribute",
      example: "defk f(i :: i64) :: i64 do\n  t = <<1, 2, 300>>\n  t[i]\nend",
      rewrite: "defk f(i :: i64) :: i64 do\n  t = <<1, 2, 44>>\n  t[i]\nend"
    },
    # -- the bitstring accumulator
    %{
      code: "bitstring-segment",
      kind: :planned,
      summary:
        "An append to a bitstring accumulator takes big-endian integer segments, unsigned or `signed`: `v::size(n)`, `v::k` or `v`.",
      why:
        "a kernel appends integer bits; little-endian, float and binary segments are not supported until a workload needs them",
      hint:
        "write big-endian integer segments: v::size(n), v::k or v (8 bits), optionally signed",
      example:
        "defk f(x :: i64) :: bitstring do\n  acc = <<>>\n  <<acc::bitstring, x::little-16>>\nend",
      rewrite:
        "defk f(x :: i64) :: bitstring do\n  acc = <<>>\n  <<acc::bitstring, band(x, 255)::8, band(bsr(x, 8), 255)::8>>\nend"
    },
    %{
      code: "bitstring-use",
      kind: :planned,
      summary:
        "A bitstring accumulator starts from `<<>>`, is appended to (also in a kernel it is passed to), measured with `bit_size/1` and returned; nothing else.",
      why:
        "a bitstring is a kernel's output: reading it or starting from an input binary is not supported yet, and only a kernel can pass one to a kernel (Elixir cannot pass one to an entry kernel)",
      hint:
        "measure it with bit_size/1, and keep what the kernel needs to read in variables or an array",
      example:
        "defk f(n :: i64) :: i64 do\n  acc = <<>>\n  acc = <<acc::bitstring, n::8>>\n  length(acc)\nend",
      rewrite:
        "defk f(n :: i64) :: i64 do\n  acc = <<>>\n  acc = <<acc::bitstring, n::8>>\n  bit_size(acc)\nend"
    },
    # -- raise
    %{
      code: "raise-value",
      kind: :error,
      summary:
        "`raise` in a kernel is a statement: it cannot be a value, the last expression of a kernel or of a branch that gives one.",
      why:
        "a kernel's values are numbers, booleans, tuples and arrays; a raise has no value to give, so it goes where a statement goes",
      hint:
        "raise is a statement; put it before the value: `if not ok, do: raise(...)` on its own line, then the value",
      example:
        "defk f(x :: i64) :: i64 do\n  if x >= 0, do: x * 2, else: raise(ArgumentError, \"x must not be negative\")\nend",
      rewrite:
        "defk f(x :: i64) :: i64 do\n  if x < 0, do: raise(ArgumentError, \"x must not be negative\")\n  x * 2\nend"
    },
    %{
      code: "raise-message",
      kind: :subset,
      summary:
        "A kernel's `raise` message is a string literal: no interpolation or computed value.",
      why:
        "the message is a C string in the kernel's static storage, so it is known when the kernel compiles; formatting a value would need a BEAM binary",
      hint:
        "a kernel raises with a literal message: put the value in Elixir, before or after the call",
      example:
        "defk f(n :: i64) :: i64 do\n  if n < 1, do: raise(ArgumentError, \"bad length \#{n}\")\n  n\nend",
      rewrite:
        "defk f(n :: i64) :: i64 do\n  if n < 1, do: raise(ArgumentError, \"length must be positive\")\n  n\nend"
    },
    %{
      code: "raise-module",
      kind: :subset,
      summary: "A kernel raises ArgumentError, ArithmeticError or RuntimeError.",
      why:
        "the runtime builds the exception natively, for the modules whose only field is the message",
      hint: "use ArgumentError, ArithmeticError or RuntimeError",
      example:
        "defk f(n :: i64) :: i64 do\n  if n < 1, do: raise(KeyError, \"no such key\")\n  n\nend",
      rewrite:
        "defk f(n :: i64) :: i64 do\n  if n < 1, do: raise(ArgumentError, \"no such key\")\n  n\nend"
    },
    %{
      code: "array-rebind-in-loop",
      kind: :error,
      summary:
        "An array variable read after a loop is not bound again inside the loop body; write its elements, or carry it as a reduce accumulator.",
      why:
        "as in Elixir, a variable bound inside a loop body is gone after the loop, so the array after the loop is still the one from before it; an element write `a[i] = v` changes the array for the rest of the kernel, and a reduce accumulator carries a rebound array to the next iteration and out of the loop",
      hint:
        "write the array's elements in the loop (a[i] = v); to bind it again, as {a, k} = helper(a, ...) does, make it a reduce accumulator: {a, n} = for ..., reduce: {a, 0} do {a, n} -> ... end; or give the array bound inside the loop a new name",
      example:
        "defk f(n :: i64) :: [i64] do\n  a = alloc(i64, n)\n\n  for i <- 0..(n - 1)//1 do\n    a = alloc(i64, n)\n    a[i] = i\n  end\n\n  a\nend",
      rewrite:
        "defk f(n :: i64) :: [i64] do\n  a = alloc(i64, n)\n\n  for i <- 0..(n - 1)//1 do\n    a[i] = i\n  end\n\n  a\nend"
    },
    %{
      code: "write-not-returned",
      kind: :error,
      summary: "A kernel called from another kernel returns every array parameter it writes.",
      why:
        "arrays are values: a write gives the callee's parameter a new array, and the caller sees it only if the callee returns it and the caller binds it",
      hint:
        "return the array (in a tuple with the other results) and bind it again at the call: {out, n} = fill(out, ...)",
      example:
        "defk fill(out :: [i64], v :: i64) :: i64 do\n  out[0] = v\n  v\nend\n\ndefk f(n :: i64) :: [i64] do\n  out = alloc(i64, n)\n  _ = fill(out, 7)\n  out\nend",
      rewrite:
        "defk fill(out :: [i64], v :: i64) :: {[i64], i64} do\n  out[0] = v\n  {out, v}\nend\n\ndefk f(n :: i64) :: [i64] do\n  out = alloc(i64, n)\n  {out, _} = fill(out, 7)\n  out\nend"
    }
  ]

  @by_code Map.new(@codes, &{&1.code, &1})

  @typedoc """
  A registry entry. The code is stable; the keys of the map are not, and may
  change in any version.
  """
  @type entry :: %{
          required(:code) => String.t(),
          required(:kind) => :error | :subset | :planned,
          optional(atom()) => term()
        }

  @doc """
  Every error code's entry, in documentation order: `code`, `kind`
  (`:error`, `:subset` or `:planned`), `summary`, `why`, `hint`, and a failing
  `example` with its `rewrite`.

  The codes are stable; the keys of the entries are not.

      iex> "unsupported-map" in Enum.map(Defk.Errors.entries(), & &1.code)
      true
  """
  @spec entries() :: [entry()]
  def entries, do: @codes

  @doc """
  The registry entry for `code`. Raises `KeyError` for an unknown code.

  Unstable: the shape of the entry may change in any version.

      iex> Defk.Errors.fetch!("unsupported-map").kind
      :subset
  """
  @spec fetch!(String.t()) :: entry()
  def fetch!(code), do: Map.fetch!(@by_code, code)

  @doc false
  # The link for `code` in the error footer: the catalogue's path when
  # compiling inside the defk repository (`in_repo?`), else its URL.
  def docs(code, in_repo? \\ in_repo?()) do
    if in_repo?,
      do: Path.relative_to_cwd(@catalogue) <> "#" <> code,
      else: @url_base <> code
  end

  # the working directory is the root of the defk checkout this module is from
  defp in_repo?,
    do: File.exists?(@catalogue) and Path.relative_to_cwd(@catalogue) == "docs/compile-errors.md"

  @doc """
  Prints the registry entry for `code`: summary, why, hint, example and rewrite.

  Raises `ArgumentError` for an unknown code. The footer of a compile error
  names this command when the language reference is not at hand:

  ```bash
  mix run -e 'Defk.Errors.explain!("unsupported-map")'
  ```

      iex> Defk.Errors.explain!("no-such-code")
      ** (ArgumentError) unknown defk error code "no-such-code"
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

  @doc false
  def indent_block(text), do: text |> String.split("\n") |> Enum.map_join("\n", &indent/1)

  defp indent(""), do: ""
  defp indent(line), do: "    " <> line

  @doc false
  # The entries of the "Codes" section of docs/compile-errors.md, one
  # `### <code>` heading per code (the anchor the error footer links), in
  # registry order. Maintainer note: docs/agents/generated-docs.md. The test
  # suite checks the document contains this text verbatim.
  @spec reference() :: String.t()
  def reference, do: Enum.map_join(@codes, "\n", &reference_entry/1)

  @doc false
  # The generated lists of docs/scope.md: every code of `kind` (:planned or
  # :subset), one Markdown bullet per code linking its entry in
  # docs/compile-errors.md, with its summary, in registry order. Maintainer note:
  # docs/agents/generated-docs.md. The test suite checks the page contains
  # this text verbatim.
  @spec scope(:planned | :subset) :: String.t()
  def scope(kind) when kind in [:planned, :subset] do
    for %{kind: ^kind} = e <- @codes, into: "" do
      "- [`#{e.code}`](compile-errors.md##{e.code}): #{e.summary}\n"
    end
  end

  @kinds %{
    subset: "outside the kernel subset (permanent)",
    planned: "not supported yet (planned)",
    error: "a mistake to fix (in the kernel or the build)"
  }

  defp reference_entry(e) do
    example =
      if e.example,
        do: [
          "\nRejected:\n\n```elixir\n",
          e.example,
          "\n```\n\nWrite instead:\n\n```elixir\n",
          e.rewrite,
          "\n```\n"
        ],
        else: []

    IO.iodata_to_binary([
      "### #{e.code}\n\n",
      "#{e.summary}\n\n",
      "- kind: #{@kinds[e.kind]}\n",
      "- why: #{e.why}\n",
      "- hint: #{e.hint}\n",
      example
    ])
  end

  @doc false
  # A literal code in the compiler's err!/attempt_err! is checked here when
  # the compiler itself compiles (defk-vlf): a typo fails mix compile.
  def validate_code!(code) do
    if is_binary(code) and not Map.has_key?(@by_code, code) do
      raise ArgumentError,
            "unknown defk error code #{inspect(code)}: not in Defk.Errors.entries/0"
    end

    :ok
  end

  @doc false
  def footer(code), do: "(defk #{code}: #{docs(code)})"
end
