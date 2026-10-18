# Contracts

The Contract of defk's stability promise, in the layout [Covenant](https://hex.pm/packages/covenant)
reads: what each surface promises, as numbered obligations, each proved by
tagged contract tests beside it. Covenant's own convention
([docs/contract-convention.md](https://github.com/tools4imps/covenant/blob/main/docs/contract-convention.md))
is the rule book; this page says only what is defk's.

The four components are the four surfaces of `docs/guides/stability.md`:

```
test/contracts/
  defk/
    error_codes.*        # the compile error codes (I1-I6)
    kernel_subset.*      # frozen kernels keep their results; the one rule (I1-I2)
    public_api.*         # the promised modules, options, config and env (I1-I7)
    runtime_contract.*   # preemption, isolation, faults, cleanup, upgrade (I1-I6)
    *_contract_test.exs  # the tagged contract tests
  system/decisions.yml   # records that hold for every component
  coverage.json          # written by mix covenant.check, committed
```

- `mix test` runs the contract tests with the rest of the suite, and every
  release's frozen copy of them (`test/stability/<version>/contracts/`).
- `mix ci` runs `covenant.check --no-run`: every active obligation has a
  passing test, read from the test run's results.
- `mix defk.contracts <version>` runs a released version's frozen contract
  against the working tree (`docs/agents/stability.md`, "Frozen contracts").
- `mix covenant.conditions` re-checks the premises of the records.
- `MIX_ENV=test mix covenant.mutate <component>` mutates a component's
  modules and shows which obligation's tests notice. It takes tens of
  minutes on several cores, so it is a manual run, not part of `mix ci`.

Rules for a contract test:

- It calls only defk's promised API (as the API snapshots list it), ExUnit,
  StreamData, Covenant and `Defk.ContractKit`. A release freezes it, so a
  call into anything else would tie an old release's check to code that may
  change; `test/contract_kit_test.exs` enforces this.
- Its module is `Defk.Contract.<Name>` and its kernel modules are nested in
  it, so the frozen copy renames one name per file.
- It reads the code under test when it runs, never into a module attribute
  when it compiles: mutation testing swaps modules in memory without
  compiling the tests again.
- It belongs here only when a reimplementation of defk would have to keep
  it: the text of a message is not promised, so a test on it stays in
  `test/`.

Contracts are for the promise, unit tests for the rest (owner,
2026-10-18). A contract test proves an obligation and is frozen with the
release; it is not where the compiler's sections, the messages, the report
or the generated C get their tests, and the mutation runs show why: the
contracts detect about half of the compiler's mutants, and what they miss
is mostly unpromised text and paths the frozen corpus samples thinly
(`docs/agents/covenant-trial.md`, "The compiler"). A change to a section
of the compiler gets a unit test beside that section's others; a change to
a promise gets an obligation and a contract test. Do not move a unit test
here to raise a contract's count, and do not add an obligation for
behaviour the guide leaves open.

An obligation's id is never reused; a retired one keeps its number with
`status: retired`. A promise proven by a test that cannot be frozen is an
obligation of `kind: exception` naming that test as its `target`.
