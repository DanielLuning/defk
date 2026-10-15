# Generated docs

Two HexDocs pages and the usage rules hold text generated from the
compile-error registry (`Defk.Errors`, `lib/defk/errors.ex`). After changing
the registry,
regenerate and paste. Run `mix compile` first: otherwise `mix run` prints
"Compiling N files (.ex)" into the output, and that line ends up in the page.

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
- The usage rules (`usage-rules.md`, `usage-rules/*.md`), the lists between
  `<!-- generated: ... -->` and `<!-- end generated -->`: the opening
  comment holds the command (`Defk.Errors.scope(:planned, :hexdocs)` in the
  main file, `:subset` in `usage-rules/language.md`); replace the lines
  between the comments with its output. The links are the error footer's
  HexDocs URLs, as the rules are read inside another project.
  `test/usage_rules_test.exs` fails until they match.

Where the footer of a compile error points (a path or a URL) is set in one
place, `@url_base` in `lib/defk/errors.ex`. The usage rules' other links are
typed with the version in them (`https://hexdocs.pm/defk/<version>/...`);
after a version bump, `test/usage_rules_test.exs` names each one to update.

The usage rules are a condensed view of the docs, not generated text, apart
from those lists: the test also checks that each row of the main file's
"Write this instead" table is a row of the cheatsheet's, and that every
example runs (`test/language_doc_examples_test.exs`).

`reference/0` and `scope/1`/`scope/2` are `@doc false` (ADR-0006): they exist for this
step and the tests, not for users.

## The catalog's result tables

Two tables hold the measured catalog numbers: the scoreboard in
`examples/README.md` and the summary in `README.md`. Each sits between
`<!-- scoreboard:start -->`/`<!-- scoreboard:end -->` (and `summary:`)
comments and is generated; nothing else in either file is.

- The numbers come from `examples/scoreboard.json`, which
  `mix defk.examples --bench --all --snapshot --fresh` writes after a run in
  which every example behaved as claimed. Run it on a quiet machine: the
  file records the load before and after, and a loaded run is marked
  provisional in the tables.
- The text around the numbers (each row's job, the native comparison, the
  one-line note, the summary's groups) is in `examples/_tables.exs`. A
  number a report measures is a placeholder there (`{speedup:crc16}`), never
  typed.
- `mix defk.examples.tables` rewrites both tables; `--check` only reports.
  `test/scoreboard_doc_test.exs` fails when a table and the JSON disagree.
- A new example needs an entry in `examples/_tables.exs` before the tables
  render.
