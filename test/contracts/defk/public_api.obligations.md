---
modules: [Defk, Defk.Build, Defk.Bits, Defk.Test, Defk.ElixirMode]
---

## Purpose

The public API is one of the four surfaces of the stability promise
(`docs/guides/stability.md`, "The public API"). Each release freezes what it
promised as data, `test/stability/<version>/api.exs` (written by `mix
defk.stability.freeze`): the public modules with their documented macros and
functions, the functions `use Defk` generates, the `use Defk` options, the
kernel option, the configuration key and the environment variables. Every
later commit must still provide each item: containment, so an addition
passes and a removal, a rename or an arity change fails.

Not promised, and so not obligations here: the unstable tier (the guide's
"What it does not cover"), anything `@doc false`, the text of messages and
reports.

### defk.public_api.I1 — Every promised macro and function stays, exported and documented, at its arity
- **scope:** the `modules` of every `test/stability/<version>/api.exs`
- **must:** each listed macro or function is exported by its module at the listed arity and has a doc entry covering that arity
- **why:** a caller's code names these; a removal or a rename breaks it, and needs a deprecation first
- **kind:** functional
- **status:** active

### defk.public_api.I2 — A kernel module gets its generated functions, and a function per kernel with its @spec
- **scope:** `use Defk`; the `generated` and `kernel_function` items of every snapshot
- **must:** a module that uses `Defk` exports each listed generated function; each kernel is a function of the module with the kernel's name and arity and a `@spec`; `__defk_elixir__/2` returns the kernel's result computed in Elixir; `__defk_force_yields__/1` leaves results unchanged
- **why:** callers, tests and tools call kernels as functions and read their specs
- **kind:** functional
- **status:** active

### defk.public_api.I3 — Each promised `use Defk` option is accepted and honoured
- **scope:** the `use_defk_options` of every snapshot
- **must:** a module compiles with each option at its listed value and its kernels run; `elixir_mode: true` compiles Elixir mode, `report: :full` yields a report for the module (its text is not promised), `max_owned_bytes:` bounds a call's owned buffers with an `ArgumentError`
- **why:** an option a release accepted keeps working until the next major version
- **kind:** functional
- **status:** active

### defk.public_api.I4 — The kernel option `yield: false` is accepted
- **scope:** the `kernel_options` of every snapshot
- **must:** a kernel compiles with each listed option and runs
- **why:** an option a release accepted keeps working until the next major version
- **kind:** functional
- **status:** active

### defk.public_api.I5 — `config :defk, mode:` picks the call path
- **scope:** the `config` of every snapshot
- **must:** each listed value is accepted when a module compiles; `:elixir` makes kernel calls run in Elixir, `:native` natively
- **why:** applications switch the path in config; the key and its values are API
- **kind:** functional
- **status:** active

### defk.public_api.I6 — The build reads the promised environment variables
- **scope:** the `env` of every snapshot (`CC`, `ERTS_INCLUDE_DIR`)
- **must:** the kernel build takes the C compiler from `CC` and the ERTS headers from `ERTS_INCLUDE_DIR` when they are set
- **why:** release builds and cross builds set them, in the elixir_make convention
- **kind:** functional
- **status:** active

### defk.public_api.I7 — A rename goes through a deprecation
- **scope:** deprecated builtins, `use Defk` options, config keys and public functions (`Defk.Deprecations`)
- **must:** proven by `test/deprecations_test.exs`: the old name keeps working as the new one, natively and in Elixir mode, and warns once per use site naming the replacement
- **why:** the mechanism is exercised with test-only entries that `config/config.exs` names, so its test cannot be frozen with the contract; this records where the promise is proven
- **kind:** exception
- **target:** test/deprecations_test.exs
- **status:** active

### defk.public_api.I8 — Each `Defk.Bits` function keeps its meaning
- **scope:** every promised function of `Defk.Bits`, over the full range of its arguments
- **must:** each returns what its documentation defines, computed here bit by bit by an independent reference: `wrap64/1` the low 64 bits as a signed value, `mulhi/2` the high half of the unsigned 128-bit product, `clz`, `ctz`, `popcount`, `rotl` and `rotr` on the 64-bit pattern or on a `width`-bit value, `f64_bits/1` the IEEE 754 bits, `crc32c/3` the reflected Castagnoli step without inversion; and the width forms raise `ArgumentError` for a width or a value out of their range
- **why:** a kernel calls the same names as builtins and Elixir mode calls these functions, so their meaning is the meaning of those kernels; a function that kept its name and changed its value would break callers silently
- **kind:** functional
- **status:** active

### defk.public_api.I9 — `Defk.Test` detects a disagreement
- **scope:** `Defk.Test.assert_agrees/3,4`, `Defk.Test.agreement_reason/1`
- **must:** `assert_agrees` returns the native outcome (`{:ok, value}` or `{:raise, exception}`) when the native call and Elixir mode agree (identical values, or the same exception module with the same agreement reason), and fails the test when they differ in value, in raising, in exception module or in reason, when the function is not exported, under `forced_yields: true` when only the forced run differs, and under `message: :exact` when only the message differs; it leaves forced yields off afterwards; `agreement_reason/1` names what went wrong (`:overflow`, `:index`, `:clause`)
- **why:** users test their kernels with it; an `assert_agrees` that passed on a disagreement would hide the bugs it exists to find
- **kind:** functional
- **status:** active

### defk.public_api.I10 — `Defk.ElixirMode.with_mode/2` switches the calling process only
- **scope:** `Defk.ElixirMode.with_mode/2`
- **must:** inside `fun`, kernel calls of the calling process run in the given mode (for modules compiled with Elixir mode); `with_mode` returns what `fun` returns; other processes keep their mode; the previous mode comes back afterwards, also when `fun` raises
- **why:** tests and debugging switch one process to Elixir mode while the rest of the node runs natively
- **kind:** functional
- **status:** active
