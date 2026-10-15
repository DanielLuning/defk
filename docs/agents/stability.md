# Stability corpus: the promise, checked on every commit

`docs/guides/stability.md` promises that, within a major version, a valid
kernel keeps compiling and keeps its meaning. `test/stability/` holds the
evidence, one directory per release, and `mix test` (so `mix ci`) checks
every commit against it.

## What is frozen

`test/stability/<version>/kernels/` holds every valid kernel the release
shipped, one example per file, written by `mix defk.stability.freeze
<version>` from the release's tag:

- the kernels of the doc pages `mix test` checks (the HexDocs extras,
  `docs/performance.md`, the usage rules), with the `iex>` results the
  pages document, and the `compiles:` examples;
- the catalog's example kernels (`test/support/examples.ex`) and the kernel
  modules of the catalog scripts `mix test` compiles, acceptance only
  (a module that names another module of its script stays out; the task
  prints which).

Rejected examples, sketches, test files and scripts are not valid kernels
and stay out (the rejections are their own corpus, below).

Each file is Markdown in the form `Defk.LanguageDoc.extract/1` reads: a
comment naming the source, the kernel block, then its `iex>` block or a
`compiles:` annotation. `test/stability_kernels_test.exs` compiles each
kernel natively and in Elixir mode, runs each recorded step in both, and
requires the two to agree and the native result to be the recorded one.

### Rejections

`test/stability/<version>/rejections/` holds every rejected example the
release shipped, written by the same task, one example per file with the
code it was rejected with (`<!-- defk-example error: <code> -->` above the
kernel block):

- the `example` of every entry of the error registry (`lib/defk/errors.ex`
  at the tag), named after its code (`lib-defk-errors-<code>.md`); an entry
  without an example (its code comes from the build environment, not from a
  kernel) stays out, and the task says so;
- the `error:` examples of the same doc pages.

`test/stability_rejections_test.exs` compiles each and requires one of:

- it is still rejected, and the recorded code is among the error codes
  raised (which error comes first is not promised; a rejection with other
  codes only is a failure);
- it compiles now, and its code is retired in the registry (`kind:
  :retired`, see `docs/agents/generated-docs.md`): the construct became
  valid and the code covers nothing else;
- it compiles now under a code that stays active (the code covers other
  constructs: say `enum-reduce` once `Enum.reduce/3` is valid but
  `Enum.reduce/2` is not), and the file is listed in the test's
  `@newly_supported` with words of the CHANGELOG entry that names the
  change.

A frozen rejection that compiles with neither is a broken promise, as is one
listed in `@newly_supported` that is still rejected. A compile error stops
before the C build, so the corpus costs well under a second.

## The rules

- **A frozen file is never edited.** Not for a typo, not for a renamed
  builtin, not to make a failing check pass. A release adds a directory;
  nothing changes an old one.
- **A failing frozen check is a broken promise**, to be fixed in the code,
  with one exception: a bug fix that changes a recorded result or
  acceptance, named in the CHANGELOG. Then the test's `@fixed` list gets an
  entry naming the file and words of the CHANGELOG entry, with a comment.
  The example must then keep failing, and the entry stays for as long as
  the file does. A frozen rejection that becomes valid is not a failure of
  the promise but a change to record: retire its code, or list the file in
  `@newly_supported` the same way (see "Rejections").
- **Keep it fast.** Modules are named after their file and source, so an
  unchanged example hits the native build cache; a warm run takes well
  under a second. The task reads each file back before it finishes, so a
  frozen file always gives the example it was written from.

## Releasing

At the release commit, after tagging: `mix defk.stability.freeze
<version>`, then commit `test/stability/<version>/`. The task runs in the
`:test` environment (it needs `Defk.LanguageDoc`) and writes the version's
`kernels/` and `rejections/` directories afresh. Rerun for a version
already frozen, it reproduces that version's files byte for byte.
