# Contracts

The Contract of a defk component, in the layout [Covenant](https://hex.pm/packages/covenant)
reads: what the component promises, as numbered obligations, each proved by
a tagged contract test beside it. Covenant's own convention
([docs/contract-convention.md](https://github.com/tools4imps/covenant/blob/main/docs/contract-convention.md))
is the rule book; this page says only what is defk's.

This is a trial (`docs/agents/covenant-trial.md`): one component,
`defk.error_codes`, the compile error codes surface of the stability promise
(`docs/guides/stability.md`).

```
test/contracts/
  defk/
    error_codes.obligations.md       # light form: Purpose and obligations I1-I6
    error_codes.decisions.yml        # the records the obligations cite
    error_codes_contract_test.exs    # the tagged contract tests
  coverage.json                      # written by mix covenant.check, committed
```

- `mix test` runs the contract tests with the rest of the suite.
- `mix covenant.check` runs them alone and fails when an active obligation
  has no passing test; a test without an obligation tag does not compile.
- `mix covenant.conditions` re-checks the premises of the records.
- `MIX_ENV=test mix covenant.mutate defk.error_codes --fail-fast` mutates
  `Defk.Errors` and shows which obligation's tests notice; it takes about
  20 minutes, so it is a manual run, not part of `mix ci`.

An obligation's id is never reused; a retired one keeps its number with
`status: retired`. A contract test belongs here only when a reimplementation
of defk would have to keep it: the text of a message is not promised, so a
test on it stays in `test/`.
