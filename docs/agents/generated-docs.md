# Generated docs

Two HexDocs pages hold text generated from the compile-error registry
(`Defk.Errors`, `lib/defk/errors.ex`). After changing the registry,
regenerate and paste:

- `docs/compile-errors.md`, the error catalogue (its own HexDocs page; the
  compile error footer links `<page>#<code>`): run
  `mix run -e 'IO.write(Defk.Errors.reference())'` and replace everything from
  the "Codes" section's first `###` heading to the end of the file with the
  output. `test/compile_errors_doc_test.exs` fails until they match. The
  headings are the codes (plain `[a-z0-9-]` slugs), so the anchors are the same
  on GitHub and on ex_doc; keep it that way for any new code.
- `docs/scope.md`, the two generated lists: run
  `mix run -e 'IO.write(Defk.Errors.scope(:planned))'` and
  `mix run -e 'IO.write(Defk.Errors.scope(:subset))'`, and replace each list
  with its output. `test/scope_doc_test.exs` fails until they match.

Where the footer of a compile error points (a path or a URL) is set in one
place, `@url_base` in `lib/defk/errors.ex`.

`reference/0` and `scope/1` are `@doc false` (ADR-0006): they exist for this
step and the tests, not for users.
