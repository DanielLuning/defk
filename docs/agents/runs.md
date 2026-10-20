# Which run fits which change

Compiling and timing kernels is the slow part of a change. A compile with
`cc` takes minutes for some examples (argon2 more than 7, cdcl_sat about 5),
and a timed run needs a quiet machine. So run what the change touches, and
no more.

## The runs, cheapest first

- **The unit tests of the area** (`mix test test/<area>_test.exs`): always.
- **The generated C, without `cc`** (`DEFK_DUMP_C=<dir> mix dump_c [file ...]`,
  `dev/dump_c.exs`): the kernels compile, their C goes to `<dir>`, and no
  library is built (`DEFK_NO_CC=1`, set by the alias). Every test file and
  example took 68 s on 2026-10-19 with a cold library cache; named files take
  seconds. Diff two dumps to see which modules' C changed. Beside each
  `<Module>.c` the dump writes `<Module>.report`, the compiler's report notes
  (`__defk_report__/0` without `report: :full`'s clang part), so the same
  diff shows a change to the report; its notes name absolute paths only for
  a note in another file, so dump both sides from the same directory when a
  report diff matters.
- **An example's check** (`mix defk.examples --only a,b`): builds the
  libraries and runs the example's `:check`, defk against Elixir. No timing.
- **`mix test`, `mix ci`**: before the PR, as `AGENTS.md` says.
- **A timed run** (`mix defk.examples --bench --only a`, `elixir
  examples/a.exs`): only when the owner or the ticket asks for that example.

## By kind of change

- **A refactor that must keep the C**: dump without `cc` on `main` and on the
  branch, and diff. The whole set costs about a minute, so dump everything
  when the refactor could reach any kernel. A diff that is not empty is the
  finding; no example run adds to it.
- **A change in one area of the compiler** (a prover rule, one builtin, one
  section of the generated C): the area's unit tests; then dump without
  `cc` on both sides. The modules whose C changed name the examples to
  check with `--only`. An example whose C did not change gives the same
  answer as before: do not run it.
- **A change to the runtime header or the cflags**: it reaches every
  library. Run `mix test`, which builds and checks the catalog kernels in
  it; check other examples only when the change is about them.
- **A change to an example script**: check that example with `--only`.

## Measurements

A measured result stands until the owner or a ticket asks for a new
measurement of that example. A change to its C does not by itself call for
one. Never sweep the catalog with `--bench`, `--all` or `--fresh` unless
asked. The examples we know are poor fits (the ❌ and 🟡 rows of
`examples/README.md`) are never measured again unless asked.

Each measured result carries a stamp (`Defk.Bench`): the commit, defk's
version, the time and the MD5 of each kernel module's C. To store a new
measurement of one example, run `mix defk.examples --bench --only <name>
--snapshot` on a quiet machine: it replaces that row of
`examples/scoreboard.json` and keeps the others with their stamps. `--bench`
refuses to run without `--only` or `--all`.

`mix defk.examples --stale` lists the stored rows whose kernels' C changed
since they were measured, with the date and commit of each measurement. It
compiles the kernels without `cc` and measures nothing; the list is for the
owner to choose from, not a queue to run. The C holds the kernels' line
numbers, so an edit that only moves a kernel's lines shows up too.

Before a run of more than a few minutes, say how long it takes and how many
cores it uses.

## Compiler time

The compiler-time rounds measure defk's compile, not `cc`, so they run
without `cc` too. With `DEFK_COMPILE_TIME=<file>` set, every module compiles
once more in a fresh process and logs that compile's microseconds and
reductions (`Defk.__before_compile__`, `timed_compile/2`). Run interleaved
rounds on both sides and compare them:

    DEFK_COMPILE_TIME=tmp/base1.log DEFK_DUMP_C=tmp/c_base mix dump_c   # base checkout
    DEFK_COMPILE_TIME=tmp/new1.log  DEFK_DUMP_C=tmp/c_new  mix dump_c   # branch
    ... base2, new2 ...
    elixir dev/compile_time.exs --reductions tmp/base*.log -- tmp/new*.log
    elixir dev/compile_time.exs tmp/base*.log -- tmp/new*.log

Two rounds a side are enough for reductions, which repeat to about 0.1%;
microseconds drift with the machine (about 25% between runs on a laptop
on battery), so report them with the conditions. A full round takes about
a minute and a half. Name the files when the change touches only some
kernels, and report `SatEx.Kernels` (`examples/cdcl_sat.exs`) on its own:
it dominates the prover's cost. Do not time a module's first compile: under
`mix compile` it waits for the compiler's own modules (`docs/performance.md`
6.38).
