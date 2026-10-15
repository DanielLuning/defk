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

### The API snapshot

`test/stability/<version>/api.exs` holds the public API the release
promised (`docs/guides/stability.md`, "The public API"), as data, written
by the same task:

- the public modules with their documented macros and functions, at every
  arity each is callable at: `Code.fetch_docs/1` on the modules compiled
  at the tag (the task checks the tag out into a temporary git worktree,
  compiles it there in `:prod`, which compiles `lib/` alone, reads the docs
  from its beams and removes the worktree), minus everything `@doc false`
  and the unstable tier. The unstable tier is a list in code: the modules
  and functions in the task, the `use Defk` options in `Defk.__options__/0`,
  the environment variables in `Defk.Build.env_vars/0`, and the generated
  functions as the `Defk` moduledoc's table marks them.
  `test/docs_checks_test.exs` requires the guide's "What it does not cover"
  to name every item of it;
- the generated functions the same table marks public, the public `use
  Defk` options (each with a value a kernel module accepts, the task's),
  the kernel option, the configuration key and the public environment
  variables.

The modules and the generated functions are the tag's; the options, the
environment variables, the kernel option and the configuration key are the
code's the task runs in, so the task runs at the release commit (as it does
for the page list and the catalog). `test/stability_api_test.exs` requires
every listed item to exist, exported and documented, with its arity, and
every option, key and variable to be honoured: containment, so an addition
passes and a removal, a rename or an arity change fails.

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

The stability checks are part of `mix test`, so every label of the CI
matrix runs them (`ci/README.md`, "Release evidence"). A pull request runs
one label; the full matrix runs on a release tag or by hand. Before a
version is published, the release commit needs a passing run of every
label, with the previous versions' frozen files in place: a kernel that
compiles on one platform and not on another breaks the promise there.

The release's own files are frozen from its tag, after the matrix has
passed on the release commit, in a commit that follows the tag:

1. `mix defk.stability.freeze <version>` writes
   `test/stability/<version>/kernels/`, `rejections/` and `api.exs` from
   the tag. The task runs in the `:test` environment (it needs
   `Defk.LanguageDoc`); for the API snapshot it checks the tag out into a
   temporary git worktree, compiles it there and removes it. Rerun for a
   version already frozen, it reproduces that version's files byte for
   byte. Compare the new `api.exs` with the previous version's: nothing is
   removed from one release to the next, as a removal needs a deprecation
   first, and the next major version is where it happens.
2. `test/stability/codes.txt`: append a `# <version>` line and, under it,
   the codes the release added, in registry order. Nothing is removed or
   reordered.
3. Commit `test/stability/<version>/` and the ledger, and open the pull
   request. `mix test` passes on it when the new files agree with the tag;
   the owner reviews every change under `test/stability/` (CODEOWNERS).

The frozen files of a version are evidence about that version. A later
commit that fails one of them has broken the promise, whichever version the
file belongs to.
