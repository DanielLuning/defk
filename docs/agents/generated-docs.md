# Generated docs

Two HexDocs pages hold text generated from the compile-error registry
(`Defk.Errors`, `lib/defk/errors.ex`). After changing the registry,
regenerate and paste:

- `docs/language.md`, the "Compile errors" section: run
  `mix run -e 'IO.write(Defk.Errors.reference())'` and replace everything from
  the section's first `###` heading to the end of the section with the output.
  `test/language_doc_test.exs` fails until they match.
- `docs/scope.md`, the two generated lists: run
  `mix run -e 'IO.write(Defk.Errors.scope(:planned))'` and
  `mix run -e 'IO.write(Defk.Errors.scope(:subset))'`, and replace each list
  with its output. `test/scope_doc_test.exs` fails until they match.

`reference/0` and `scope/1` are `@doc false` (ADR-0006): they exist for this
step and the tests, not for users.
