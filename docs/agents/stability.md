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
and stay out (the rejection corpus is its own check).

Each file is Markdown in the form `Defk.LanguageDoc.extract/1` reads: a
comment naming the source, the kernel block, then its `iex>` block or a
`compiles:` annotation. `test/stability_kernels_test.exs` compiles each
kernel natively and in Elixir mode, runs each recorded step in both, and
requires the two to agree and the native result to be the recorded one.

## The rules

- **A frozen file is never edited.** Not for a typo, not for a renamed
  builtin, not to make a failing check pass. A release adds a directory;
  nothing changes an old one.
- **A failing frozen check is a broken promise**, to be fixed in the code,
  with one exception: a bug fix that changes a recorded result or
  acceptance, named in the CHANGELOG. Then the test's `@fixed` list gets an
  entry naming the file and words of the CHANGELOG entry, with a comment.
  The example must then keep failing, and the entry stays for as long as
  the file does.
- **Keep it fast.** Modules are named after their file and source, so an
  unchanged example hits the native build cache; a warm run takes well
  under a second. The task reads each file back before it finishes, so a
  frozen file always gives the example it was written from.

## Releasing

At the release commit, after tagging: `mix defk.stability.freeze
<version>`, then commit `test/stability/<version>/`. The task runs in the
`:test` environment (it needs `Defk.LanguageDoc`) and writes the version's
`kernels/` directory afresh.
