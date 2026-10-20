# Generated docs

Every generated region of the repository's docs is written by one task and
checked by its `--check`, which `mix ci` runs:

    mix defk.docs           # rewrite every region that is out of date
    mix defk.docs --check   # exit 1 when a region is out of date

The regions are listed in `Defk.Docs` (`dev/defk/docs.ex`). A region is a
whole file, or the lines between `<!-- NAME:start -->` and
`<!-- NAME:end -->` in a Markdown file; the comments render as nothing, in
HexDocs and in a dependent's AGENTS.md. Nothing outside a region is
generated: edit that text by hand. Never edit a generated line: change its
source and run the task.

| Region | File | Source |
|---|---|---|
| `codes` | `docs/compile-errors.md`, from the "Codes" heading to the end | `Defk.Errors.reference/0` |
| `planned`, `subset` | `docs/scope.md`, the list under each of "Not yet" and "Won't be" | `Defk.Errors.scope/1` |
| `planned-hexdocs`, `subset-hexdocs` | `usage-rules.md`, `usage-rules/language.md` | `Defk.Errors.scope/2` with the error footer's HexDocs URLs, as the rules are read inside another project |
| the whole file | `priv/defk_messages.h` | `Defk.Messages.header/0` |
| `scoreboard`, `summary` | `examples/README.md`, `README.md` | `Defk.Examples.Tables` from `examples/scoreboard.json` |

## The compile-error registry

`docs/compile-errors.md` is the error catalogue (its own HexDocs page; the
compile error footer links `<page>#<code>`). The generated region ends with
the "Retired" section, one heading per retired code, so a retired code keeps
its anchor. The headings are the codes (plain `[a-z0-9-]` slugs), so the
anchors are the same on GitHub and on ex_doc; keep it that way for any new
code. To retire a code, set its entry's `kind` to `:retired` and give it
`retired: %{version:, why:}`; `test/stability/codes.txt`, the ledger of
released codes, grows only at release time.

Where the footer of a compile error points (a path or a URL) is set in one
place, `@url_base` in `lib/defk/errors.ex`. The usage rules' other links are
typed with the version in them (`https://hexdocs.pm/defk/<version>/...`);
after a version bump, `test/usage_rules_test.exs` names each one to update.

The usage rules are a condensed view of the docs, not generated text, apart
from those lists: `test/usage_rules_test.exs` also checks that each row of
the main file's "Write this instead" table is a row of the cheatsheet's,
and every example runs (`test/language_doc_examples_test.exs`).
`test/compile_errors_doc_test.exs` and `test/scope_doc_test.exs` check the
hand-written parts of their pages: the anchors, and that "Not yet" names
every planned code.

`reference/0` and `scope/1`/`scope/2` are `@doc false` (ADR-0006): they
exist for this task, not for users.

## The runtime's message defines

`priv/defk_messages.h` is generated from the message templates in
`Defk.Messages` (`lib/defk/messages.ex`): one `DEFK_MSG_<NAME>` define per
template a runtime header site raises, each hole as its C conversion. The
runtime header includes it and never carries a message literal; Elixir mode
(`Defk.ElixirMode.Ops`, `Defk.Bits`) interpolates the same templates with
`Defk.Messages.text/2`; `Defk.Test.agreement_reason/1` maps a message back
to its template's reason.

- After changing a template, run `mix defk.docs` and commit both files. The
  task compiles `lib/defk/messages.ex` on its own when the project is not
  compiled, so a renamed define reaches the header before the C of any
  kernel is built. `test/messages_test.exs` fails while the header is out
  of date, when a runtime header site raises with a literal, or when a
  define is unused.
- A message's text is part of what the stability corpus pins
  (`test/stability/`): a template change is a change to the runtime
  contract.

## The catalog's result tables

Two tables hold the measured catalog numbers: the scoreboard in
`examples/README.md` and the summary in `README.md`. Each sits between its
marker comments and is generated; nothing else in either file is.

- The numbers come from `examples/scoreboard.json`, which
  `mix defk.examples --bench --all --snapshot --fresh` writes after a run in
  which every example behaved as claimed; `--bench --only a,b --snapshot`
  replaces only those rows. Measure only what the owner or the ticket asks
  for (`docs/agents/runs.md`). Run it on a quiet machine: before each
  report the bench waits for other processes to use at most one core, each
  report's stamp records that test, and a row with a report that failed it
  is marked provisional in the tables.
- The text around the numbers (each row's job, the native comparison, the
  one-line note, the summary's groups) is in `examples/_tables.exs`. A
  number a report measures is a placeholder there (`{speedup:crc16}`), never
  typed.
- `mix defk.docs` rewrites both tables; without a stored scoreboard the
  task stops and says so. `test/scoreboard_doc_test.exs` tests the
  renderer's rules on a made-up scoreboard.
- A new example needs an entry in `examples/_tables.exs` before the tables
  render.
