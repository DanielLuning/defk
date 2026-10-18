# Covenant trial: contracts for the compile error codes

The owner asked (2026-10-17) whether [Covenant](https://hex.pm/packages/covenant)
(0.2.0, MIT, an external Mix library) can carry the stability promise over
time and replace some unit tests, and to favour it where it is as good,
because someone else maintains it. This page records the trial on one
surface: the compile error codes (`docs/guides/stability.md`, "The compile
error codes"). Ticket defk-zet.

## What was built

- `test/contracts/defk/error_codes.obligations.md`: six obligations, I1 to
  I6, taken from the guide's promise (a code rejects its example, a released
  code stays, a code is never reused, a retired code stays in the catalogue,
  a frozen rejection keeps its code, `explain!/1` refuses an unknown code).
- `test/contracts/defk/error_codes.decisions.yml`: two records
  (`retire-never-remove`, `frozen-rejections-are-data`) with four
  machine-checked premises (`mix covenant.conditions`: all hold).
- `test/contracts/defk/error_codes_contract_test.exs`: one `Covenant.Case`
  module, every test tagged with its obligation. It replaces
  `test/stability_codes_test.exs`, `test/stability_rejections_test.exs` and
  the registry half of `test/compile_errors_test.exs` (194 + ~90 lines in
  three files became one file of ~300 lines; the checks are the same, plus
  the two fixes below).
- `mix ci` runs `covenant.check --no-run` after `test`:
  `Covenant.Formatter` (in `test/test_helper.exs`) records the results, so
  the coverage gate costs no second run.

Contract tests sit beside their obligations under `test/contracts/`
(owner's choice), set by `config :covenant` in `config/config.exs`.

## Results

### Coverage and tags

`mix covenant.check`: 6/6 obligations, 155 tests. An untagged test, or a tag
naming an unknown obligation, is a compile error; an obligation with no
passing test fails the check. defk had nothing that tied a promise in the
guide to the tests that prove it.

`--static` cannot credit tests generated in a `for` (a known limit of 0.2),
so it reports I1 uncovered; I1's tests are one per registry code. Use the
compiled check.

### An old contract against new code

It works. A release can freeze its contract and contract tests; a later
commit runs them with `mix covenant.check --contracts <dir> --test-path
<dir>`, and the frozen test module names its own contract with `use
Covenant.Case, contracts: "<dir>"`. Demonstrated in a scratch copy: the
contract frozen as a fake `9.9.9`, then the code `pipe` renamed to
`pipe-form` throughout `lib/`. The frozen contract failed I2 (the ledger) and
I5 (the frozen `pipe` rejection); the live contract passed, as the registry's
own example now agrees with the new name.

What the demonstration also showed:

- The catch came from frozen **data** (`test/stability/codes.txt`, the
  frozen rejection files), which the live tests read too. Freezing the test
  code adds one thing: the checker of a release is frozen with it, so
  weakening the live test cannot weaken an old release's check.
- A frozen test is code, and it calls live helpers (`Defk.TestKit.codes/1`,
  `Defk.StabilityCorpus`, `Defk.LanguageDoc`). A change to them changes an
  old release's check. Freezing tests needs a narrow, promised seam for
  them to call.
- `covenant.check` writes `coverage.json` into the contracts directory it
  checks, so a frozen directory gets a written file on every run (identical
  bytes while nothing changes; `ci/frozen.sh` would fail on a changed one).
- The exception lists (`@newly_supported`, `@fixed`) live in the test. A
  frozen copy cannot grow them, so they would move to a live file the
  frozen test reads.
- `mix test` would run every release's frozen copy (155 more tests per
  release here; the rejections stop before the C build, so seconds).

Covenant has no counterpart for the rest of the stability machinery:
`mix defk.stability.freeze` (kernels with results from the tag's own
compiler, rejections, the API snapshot), `ci/frozen.sh`, and the code ledger.
Those stay.

### Mutation testing

`MIX_ENV=test mix covenant.mutate defk.error_codes`, `Defk.Errors` only,
`--jobs 1`, on a laptop with other work running (provisional timings):

| Run | Tests | Mutants | Killed | Survived | Invalid | Time |
|---|---|---|---|---|---|---|
| 2, `--fail-fast` | as moved | 1197 | 414 | 692 | 91 | ~20 min |
| 3, full credit | registry read at run time | 1197 | 950 | 156 | 91 | ~25 min |
| `--only` the 72 rewrite survivors | rewrite must define a kernel | 72 | 72 | 0 | 0 | ~2 min |

(Run 1 stopped at mutant 550: moving the contracts directory mid-run broke
the next worker.) A full run takes 4 to 5 cores for its whole length.

Two real gaps in the moved tests, found by mutation and fixed:

1. **The tests checked a snapshot of the registry.** They read
   `Defk.Errors.entries/0` into module attributes when the test module
   compiled. Covenant swaps the mutated module in memory and does not
   compile the tests again, so most registry mutants were invisible (72
   removed examples survived: the loop never saw them). The same blindness
   applies to any change made without recompiling the tests. Now the tests
   read the registry when they run; only the test names come from the
   compile-time list.
2. **An empty rewrite passed.** I1 required the rewrite to compile, and an
   empty module body compiles. Now the rewrite must define a kernel; all 72
   such mutants are killed.

The 84 survivors left change text the contract does not promise: the
lines `explain!/1` prints, the doc generators `reference/0` and `scope/2`
(checked against the pages by `test/compile_errors_doc_test.exs` and
`test/scope_doc_test.exs`, outside the contract), `diagnostics/1`, and the
catalogue link. They are not sorted into a `survivors.yml`: an entry names
its mutant by `file:line:column`, and every edit to the 900-line registry
shifts the entries after it, so the file would need rewriting on most
registry changes.

Mutation-blind tests: the I2 test, two I3 tests and every I5 test catch no
mutant that another test does not. That is expected for `Defk.Errors`:
I5's frozen rejections guard the compiler (which code a construct gets),
and the compiler was not mutated. Mutating `lib/defk/compiler.ex` (~6,500
lines, C builds behind every kernel) was not tried; at this rate it would
not fit Covenant's one-hour default.

## Comparison

| Concern | Before | With Covenant |
|---|---|---|
| Which test proves which promise | comments | obligation ids, checked at compile time |
| A promise without a test | not detected | `covenant.check` fails |
| A test that proves nothing | not detected | does not compile (untagged) |
| Premises of decisions | ADR prose | records with machine-checked conditions |
| Do the tests catch a break | not measured | `covenant.mutate`, found two gaps |
| Frozen evidence per release | `test/stability/<version>/`, freeze task | none: keep ours |
| Frozen files never change | `ci/frozen.sh` | none: keep ours |
| Old checks against new code | frozen data, live harness | frozen contract and tests also possible |
| Maintained by | us | Covenant, plus our contracts |

## Recommendation

- Adopt Covenant for the promise surfaces: obligations, tagged contract
  tests and the coverage gate in `mix ci`. It is cheap (no second run), it is
  someone else's code, and it ties `docs/guides/stability.md` to its proof.
  Next surfaces: the public API (`test/stability_api_test.exs`), the kernel
  subset (`test/stability_kernels_test.exs`), the runtime contract.
- Keep the stability machinery: the freeze task, the frozen data, the
  ledger and `ci/frozen.sh`. Covenant does not replace them.
- Run `covenant.mutate` by hand on a component when its tests change, on
  mains power; not in `mix ci`, and without a committed survivors file for
  data-heavy modules.
- Freezing contract tests per release is possible but not yet worth it: it
  needs a promised helper seam, a live exception list and a coverage file
  kept outside the frozen directory. Decide at the 0.2.0 release.
- Contract tests read the code under test at run time, never into module
  attributes, or mutation (and any hot swap) cannot reach them.

## The full surface (defk-ksc)

The owner adopted the recommendation and asked for all four surfaces, for
contracts that run from one version against another, for the duplicated
tests to go, and for proof that nothing they covered was lost.

### What changed

- Four components under `test/contracts/defk/`: `error_codes` (I1-I6),
  `kernel_subset` (I1-I2), `public_api` (I1-I10, I7 a `kind: exception`
  naming `test/deprecations_test.exs`) and `runtime_contract` (I1-I6): 24
  obligations; the 23 that need a test are covered.
- `Defk.ContractKit` is the one helper a contract test may call besides the
  promised API; `test/contract_kit_test.exs` reads every contract test,
  frozen ones included, and fails on any other `Defk.*` reference or on a
  `__defk_*__` hook outside the promised ones.
- `test/stability/exceptions.exs` holds the exception lists (`fixed`,
  `newly_supported`) that the tests held; `ci/frozen.sh` lets it change but
  not lose an entry.
- `mix defk.stability.freeze` also writes `test/stability/<version>/contracts/`;
  `mix test` runs every frozen copy, `mix defk.contracts <version>` runs one
  through Covenant.
- Removed or moved: `stability_api_test`, `stability_kernels_test`,
  `upgrade_test`, `concurrent_test`, `raise_cleanup_test`, and five tests of
  `fault_containment_test` (what is left there is the handler's build, its
  chain, the faults that must kill the node, and the message's text). The
  error codes test lost its message-text checks to `compile_errors_test`.

### One version against another

Frozen as a made-up `9.9.9` in a scratch clone: the frozen contract held
alone (`mix defk.contracts 9.9.9`, 250 tests) and beside the live one in one
`mix test` (514 tests), once the kit compiled the frozen corpus once per run
(two copies compiling the same modules at once had failed). With the code
`pipe` renamed in `lib/`, the frozen contract failed I2 and I5.

### Line coverage

`mix test --cover` at 83c2e712 (before the trial) and at this branch, `lib/`
and `priv/` identical between them: covered lines 5,955 before, 6,010 after,
and no line covered before is uncovered after (the 11 the diff first named
are the freeze task's, moved 18 lines down by the new code, and covered).
Erlang's cover sees Elixir only, not the C runtime. One baseline test, a
forced-GC timing case, failed under cover's slowdown; it is unrelated.

### Mutation, contract tests only

`--fail-fast`, `--jobs 1`, a loaded laptop (provisional timings):

| Module | Contract | Mutants | Killed | Survived | Time |
|---|---|---|---|---|---|
| `Defk.Errors` | error_codes | 1197 | 679 | 427 | ~15 min |
| `Defk.Bits` | public_api, before I8 | 190 | 0 | 186 | <1 min |
| `Defk.Bits` | public_api, with I8 | 190 | 151 | 25 (+10 timeouts) | <1 min |
| `Defk.Report` | public_api | 197 | 44 | 144 | <1 min |
| `Defk.Test` | public_api, with I9 | 37 | 18 | 19 | <1 min |

What the runs found:

- **The public API contract proved names, not meaning.** `Defk.Bits` had no
  kill: the snapshot test checks that a function exists, and the promise
  says it keeps its meaning. I8 tests every function against a reference
  written bit by bit; the survivors left are type guards for non-integer
  arguments, error message text and range-check edges that change nothing
  observable, and the timeouts are mutants that loop forever.
- **`assert_agrees` could have stopped asserting.** Removing its comparison
  survived: the kernel subset contract uses it but never checks that it
  fails. I9 drives it with a module that has a kernel module's interface and
  answers that disagree on purpose; every behaviour mutant is now killed,
  and the survivors are failure-message text and `inspect` limits.
- **A shared compile must survive a purge.** Covenant unloads the modules
  each run loads; the kit's once-per-run compile now checks its modules are
  still loaded.
- `Defk.Errors`' 427 survivors are the registry's text (summary, why, hint)
  and the doc generators: promised by nothing, tested by
  `compile_errors_test`, `compile_errors_doc_test` and `scope_doc_test`,
  which mutation of a contract does not run. `Defk.Report`'s are its text,
  which the guide leaves open.

The compiler itself (`lib/defk/compiler.ex`) is a separate run on mains
power (defk-ksc.2).

## The compiler (defk-ksc.2)

`covenant.mutate --module Defk.Compiler`, `--fail-fast`, `--jobs 1`, against
two contracts, on a laptop on mains power (timings provisional): 5,418
mutants of `lib/defk/compiler.ex`, 572 of them invalid (the mutated code does
not compile), the same ids in both runs.

- **error_codes:** about 4 hours. It compiles every registry example and
  frozen rejection at run time, so it sees every mutant.
- **kernel_subset:** about 5.5 hours of running, plus about 2 hours lost to
  one hang (below). Only its frozen corpus sees a mutant: the agreement
  kernels in the test file are compiled once, when the test file compiles.
- The runtime contract was not run: its kernels, too, are compiled with the
  test file, so a mutation run there would measure almost nothing.

Detected = killed, or the call never returned (a hang, a watchdog stop or
a VM crash: each breaks a promise). Per section of `compiler.ex`, of the
4,846 valid mutants:

| Section | Valid | error_codes | kernel_subset | Either |
|---|---|---|---|---|
| (module top) | 41 | 59% | 73% | 80% |
| entry | 67 | 57% | 52% | 66% |
| rejections | 86 | 38% | 6% | 40% |
| parsing | 99 | 30% | 25% | 31% |
| kernels | 125 | 35% | 34% | 42% |
| blocks | 43 | 56% | 44% | 58% |
| statements | 262 | 35% | 29% | 43% |
| array values | 181 | 43% | 58% | 62% |
| expressions | 791 | 37% | 49% | 53% |
| bitwise | 170 | 23% | 41% | 44% |
| calls | 527 | 14% | 28% | 31% |
| alloc zeroing | 87 | 20% | 45% | 46% |
| range copies | 305 | 7% | 25% | 25% |
| bitstrings | 79 | 24% | 56% | 59% |
| loops | 201 | 33% | 44% | 51% |
| strip record | 171 | 33% | 56% | 56% |
| the record classifier | 506 | 25% | 42% | 43% |
| case | 313 | 27% | 46% | 49% |
| element types | 73 | 19% | 62% | 63% |
| emitting | 246 | 59% | 70% | 76% |
| helpers | 66 | 52% | 50% | 53% |
| more rejections | 225 | 20% | 28% | 36% |
| report | 182 | 13% | 15% | 16% |
| **total** | **4,846** | **29%** | **41%** | **46%** |

38 kernel_subset ids have no verdict (a log was overwritten; see below) and
count as not detected, so its column is a slight undercount.

### What the 2,627 survivors of both are

- **Unpromised output.** Message and hint text (`string_empty`, 453, and the
  argument-description table of `builtin-arguments`, about 50 entries such
  as `sin: "a number"`), error locations, the checking of rewrites, and the
  fast-path report (152 in `report`). The guide promises none of it.
- **Paths the corpus does not reach.** `range copies` (25%), `calls` (31%)
  and the rejection detection branches (`fn_argument!`,
  `generator_pattern!`): the frozen corpus and the registry hold one or a
  few kernels per feature, so they sample a feature rather than cover it.
  These are the places where the contracts lean on the unit tests
  (`range_copy_test`, the call and inlining tests), which a contract
  mutation run does not run.
- **Equivalent or near-equivalent mutants**, such as bounds on facts that
  only cost a check, or an `integer_shift` on a limit no kernel reaches.
  These were not sorted one by one.

### What broke during the runs

- **The kit's shared compile reused a mutated compiler's results.** The
  clean re-run after a worker group failed. The cache key now holds the md5
  of every loaded defk module (`Defk.ContractKit.compile_frozen/2`).
- **Hangs Covenant cannot stop.** Removing a loop's step (`i += k`, the
  `incr` of a range loop, `k += 1` of an array loop, a strip or flagged
  loop's body) makes a frozen kernel compiled with `yield: false` loop
  forever inside native code. No safepoint means the VM cannot stop the test
  process, so Covenant's per-test timeout and its watchdog never fire, and
  the worker hung for about 2 hours on the first one (`m3324`). A guard
  script in the session killed a run whose log was silent for 4 minutes,
  recorded the mutant and continued: 9 hangs in all, among them `m4796`,
  which removes the `sigsetjmp` guard of the emitted step function.
- **Watchdog stops end a focused run.** Under `--only`, a mutant the
  watchdog stopped ended the run (20 of them, loops again); the guard
  counts these as "no return" too.
- **VM crashes.** 3 mutants of the emitted step function (`m4811` removes
  the fetch of the suspended frame; `m4830` and `m4849` are beside it)
  crash the worker VM with a segmentation fault: the fault happens before
  the kernel's fault handler is armed, so the node dies, as
  `runtime-contract.md` says it would for a fault outside kernel code.
  Covenant reports only "worker exited with status 139", without the
  mutant's id.

In all, 32 mutants never returned (9 hangs, 20 watchdog stops, 3 crashes);
each counts as detected.

### What this says

- Together the two contracts detect about half of the compiler's mutants
  (46%); most of the rest change text the promise leaves open or paths the
  corpus samples thinly. The contracts are a promise-level check, not a
  replacement for the unit tests of the compiler's sections.
- To raise the contract's reach where it matters, grow the frozen corpus
  where it is thin: range copies, calls and inlining, and one kernel per
  rejection branch. `dev/stability/sample.exs` is where the next release's
  frozen sample is listed.
- A full compiler mutation costs about 10 hours of one laptop at 4–5 cores
  and needs a hang guard; it is an occasional audit, not a gate. Two limits
  are Covenant's: a non-preemptible native hang is never stopped, and a VM
  crash loses the mutant's id. Both are worth reporting upstream.
