# The stability promise

From version `0.1.0`, defk makes a written promise about four surfaces: the
kernel subset, the runtime contract, the public API and the compile error
codes. This page says what the promise covers, what it does not, and how a
change that would break it is made.

## The promise

**Within a major version, a valid kernel keeps compiling and keeps its
meaning.** A change to the four surfaces below needs a deprecation first.

This is stricter than Semantic Versioning, which lets a `0.x` version break
anything in a minor release. defk counts `0` as a major version: a `0.y`
release never breaks a promised surface, and neither does a later `1.y`.
Only the next major version may remove what was deprecated.

A release may add. A construct, builtin, type or option that does not exist
yet may arrive in a minor release, so code that was a compile error may
become a valid kernel.

## What it covers

### The kernel subset

The language of `defk`: its types, the constructs it accepts, the builtins
with their names, arities and meaning, the kernel option `yield: false`, and
the `use Defk` options `elixir_mode:`, `report: :full` and
`max_owned_bytes:`. The [language reference](../language.md) describes it.

For a valid kernel, a release keeps:

- **Its result.** A call that returns a value returns the same value. A
  call that raises raises the same exception module, with the same
  [agreement reason](`Defk.Test.agreement_reason/1`) (for example
  `:overflow`, `:index` or `:non_finite`).
- **Its acceptance.** The kernel still compiles.

The one rule is part of this: a kernel gives the result Elixir would, or
raises where its types can't hold that result, or doesn't compile. Elixir
mode keeps computing what Elixir computes.

### The runtime contract

The four promises of [the runtime contract](runtime-contract.md):
preemption (a long kernel yields), isolation (an error is an exception in
the caller, and a fault in a kernel is contained), cleanup (a dead process
frees its kernel's memory) and hot code upgrade (a suspended kernel finishes
in its own code). The numbers that tune them are not promised: the length of
a slice, how often the clock is read, and the default owned-buffer budget
may change in any release.

### The public API

The modules and functions documented as public:

- `use Defk`, and the `defk` macro in its three forms
- for each kernel, a function with the kernel's name and arity, and its
  `@spec`
- the generated `__defk_elixir__/2` and `__defk_force_yields__/1`
- `Defk.Test.assert_agrees/4` and `Defk.Test.agreement_reason/1`
- `Defk.ElixirMode.with_mode/2`
- the functions of `Defk.Bits`
- `Defk.Report.print/1` and `Defk.Report.format/1` (the functions, not
  their text)
- `Defk.Errors.entries/0` (the codes in it, not the keys of an entry) and
  `Defk.Errors.explain!/1`
- the configuration `config :defk, mode:`, and the environment variables
  `CC` and `ERTS_INCLUDE_DIR`

Each function keeps its name, arity and meaning.

### The compile error codes

Each code in the [compile error catalogue](../compile-errors.md) keeps its
name, and a construct rejected with a code is rejected with the same code.
A code is never reused for another rejection. A code whose construct becomes
valid in a later release is retired: it stays in the catalogue, marked as
retired.

## What it does not cover

- **Speed.** Measured times, speedups, verdicts, and what the C compiler
  makes of a loop. A release may make a kernel faster or slower.
- **The fast-path report's facts.** Their topics, verdicts and text grow
  with the compiler.
- **The generated C** and everything about the build: the C source, the
  library's path and file name, the cache key, the compiler flags.
- **The text of a message.** The message of an exception and the text of a
  compile error (its sentence, why, hint and rewrite) may change; the
  exception module, the agreement reason and the error code don't.
- **Which compile error comes first** when a kernel has several.
- **The unstable API**: `Defk.Bench`, `Defk.Bench.TickGap`,
  `Defk.Errors.fetch!/1`, the types in `Defk.Report`, the `use Defk`
  option `adaptive_slice:`, the `DEFK_SANITIZE` modes, and the generated
  `__defk_c_source__/0`, `__defk_elixir_source__/0`, `__defk_report__/0`,
  `__defk_lib__/0`, `__defk_kernels__/0` and `__defk_stats__/0`. Their docs
  say they are unstable; they may change in any release.
- **Everything hidden**: modules and functions with `@doc false`, any other
  `__defk_*__` function, and module attributes whose names start with
  `@defk_`.
- **Supported versions and platforms.** A minor release may raise the
  minimum Elixir or OTP version, or change which C compilers and operating
  systems are tested; `CHANGELOG.md` says so when it does.
  [Deploying](deploying.md#where-defk-is-tested) lists what is tested now.

## Bugs

A kernel that gives a different result from Elixir breaks the one rule: that
is a bug, and fixing it changes the result to Elixir's. The fix is not a
breaking change, and `CHANGELOG.md` names it.

If the compiler accepts a kernel that it cannot compile correctly, a fix may
reject that kernel with a compile error. This is the only way a valid kernel
can stop compiling in a minor release, and `CHANGELOG.md` names each case.

## How a change is made

To rename or remove a promised name, a release first deprecates it. The old
name keeps working until the next major version, with a warning at compile
time that names the replacement, and `CHANGELOG.md` lists it. The next major
version may then remove it.

The names in `0.1.0` are the first ones the promise covers. The renames made
just before it are listed in `CHANGELOG.md`.
