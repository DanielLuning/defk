# Is a SAT solver a good defk example: simple_sat's job, or a picosat reimplementation?

Ticket: defk-dtw.21. Researched 2026-10-09.

## Question

Ash checks policy and filter satisfiability with a SAT solver, and two interchangeable
backends exist on Hex: `simple_sat` (pure Elixir) and `picosat_elixir` (a NIF over PicoSAT,
a CDCL solver in C). Decide whether this is a good defk example, and in which form:
(a) simple_sat's job as Ash uses it: formula sizes, calls per request, DPLL vs CDCL, and
whether the per-call size is so small that the boundary dominates; (b) a picosat-style CDCL
reimplementation: what it needs from the kernel subset, which needs are ticketed, which are
new; (c) what the agreement property should compare for SAT; (d) scheduling. End with a
ranked recommendation, expected verdicts, the minimal subset additions and sizes to
pre-register.

## Method and sources

- **Hex.pm API and tarballs** (primary), read 2026-10-09: `simple_sat-0.1.4`,
  `picosat_elixir-0.2.3`, `crux-0.1.4`, `ash-3.34.6`, unpacked and read; GitHub clones of
  the three solver repos for their tests (the NIF on GitHub matches the tarball).
- **PicoSAT** (primary): the vendored C source (`c_src/picosat.c`, 8,502 lines, API version
  953) and https://fmv.jku.at/picosat/ (release 965; it points to Biere, "PicoSAT
  Essentials", JSAT 4, 2008). Algorithm claims below are from the source.
- **Erlang docs** (`erl_nif`) and **this repo** (CONTEXT.md, README.md, examples/README.md,
  the two research docs, the tickets via `bw show`).

**Measured vs quoted.** *Measured* numbers come from four short `Mix.install` scripts in
`/tmp/defk-sat-bench` (not committed), M-series Mac, OTP 29, Elixir 1.20.2, picosat built
with MIX_ENV=prod (`-O3 -DNDEBUG`). The machine was shared with other agents and not quiet:
timings rank options, they are not results. Random 3-SAT uses fixed seeds; the
"Ash-shaped" formulas are generated for this study (Limits).

## Headline findings

1. **Ash no longer calls the solver directly. Crux does, and Crux makes many small calls.**
   `Ash.SatSolver` (ash 3.34.6) is deprecated in favour of `Crux` (ash-project/crux,
   first released 2025-10-15, 746k downloads). Ash calls it in two places.
   `Ash.Policy.Policy.solve/1` calls `Crux.satisfying_scenarios/2` once per authorization
   that static simplification can't settle. `Ash.Filter.strict_subset/2` calls
   `Crux.satisfiable?/1` up to twice. `satisfying_scenarios` makes 1 + V calls per
   scenario found (V = the scenario's variables) and one more at the end: a solve, then
   one implication query per literal to minimise the cube (`minimize_cube_dimacs`), then
   a blocking clause and a re-solve. Measured on Ash-shaped formulas: 7 to 1,548 solver
   calls per authorization, each on 6–109 variables and 13–371 clauses.
2. **simple_sat is not DPLL in the usual sense.** It branches on variables in a fixed
   order and simplifies every clause list at each node (`guess_value` + `simplify`). It has
   no unit propagation, no pure literals, no learning and no heuristic. Its outer
   `Enum.find_value(all_vars, ...)` restarts the full search from each variable in turn, so
   an UNSAT formula is searched once per variable. Measured: it timed out at 10 s on 1 of 3
   random 3-SAT instances at n = 30 and on 2 of 3 at n = 50, where picosat took 25–73 µs.
   It is a correct first-pass baseline (its own property test checks it against Picosat),
   not an optimized one.
3. **At Ash sizes the per-call work is close to the cost of crossing the boundary.**
   picosat solves an Ash-shaped formula in 4–82 µs (measured). Its fixed cost per call is
   about 1 µs (`[[1]]`). Packing a 350-clause CNF from lists into `[i64]` literals plus
   offsets costs about 31 µs in Elixir (measured), which is as much as the solve. A
   20-line Elixir DPLL with unit propagation (measured) came within 1.3–1.4× of picosat at
   26–28 variables, 2.5–5× at 45–50, and 3–7× at 104–109. This is the `poor_tiny_calls`
   lesson again: per call, a kernel can win only on the larger formulas.
4. **There is a batch form, and it is Crux's own loop.** Every call in one
   `satisfying_scenarios` run solves the same base CNF plus a few unit, selector or
   blocking clauses. Run as one kernel call (pack once, then enumerate, minimise and block
   inside the kernel), the 1,548 boundary crossings become one. Measured for the whole
   enumeration at the largest shape: Crux + picosat 101–108 ms, Crux + Elixir DPLL
   588–953 ms, Crux + simple_sat over 30 s (timed out).
5. **A bounded CDCL kernel needs no growable storage and no kernel-owned state.** PicoSAT
   itself caps learned clauses: the limit starts at 1,000 (`init_reduce`), grows about as
   √conflicts (`backtrack`'s comment), and `reduce(ps, 50)` deletes half when the limit is
   reached. Its watch lists are intrusive linked lists (`Cls *next[2]`, `htps[lit]`), so
   they fit fixed arrays. A learned clause has at most n literals. So every CDCL structure
   is a fixed-capacity `alloc` sized from the input. Most of it can be written today in one
   kernel body. What it really needs is `defk-n4r.4` (helpers that write arrays), and
   `defk-ivt` would make it read better.
6. **The yield story is strong.** `picosat_elixir` registers `{"solve", 1, solve_nif}` with
   no flags, so it runs on a normal scheduler. It calls `picosat_sat(sat, -1)`, which has
   no decision limit, never calls `enif_consume_timeslice`, and never sets PicoSAT's
   interrupt callback. Measured with `+S 1`: a random 3-SAT instance (n = 300) blocked a
   1 ms ticker for 3,870 ms, and n = 250 instances blocked it for 509–729 ms. The `erl_nif`
   docs ask a NIF to return within 1 millisecond.

## (a) simple_sat's job: what Ash solves, how big, how often

**Packages** (Hex, 2026-10-09; all-time / last 90 days): `picosat_elixir` 1,136,421 /
225,927; `crux` 746,211 / 359,213; `simple_sat` 229,262 / 78,400; `ash` 2,123,885 /
452,687. Ash lists `crux` as a required dependency and both solvers as optional.
`Crux.Implementation` picks Picosat if it is loaded and falls back to SimpleSat. Its error
message calls `:picosat_elixir` "(recommended) ... Fast, production ready, battle tested"
and `:simple_sat` "Slower than PicoSAT, but no NIF dependency". simple_sat's moduledoc says
it "was created for folks having trouble running `picosat_elixir`". Both take the same
input, a list of clauses, each a list of non-zero integers (DIMACS literals).

**How formulas are built.** `Ash.Policy.Policy.raw_expression/1` folds each policy into
`cond or ...` and `implied_by(cond and checks, cond) and ...`. Each policy's
`authorize_if` / `forbid_if` / `authorize_unless` / `forbid_unless` chain becomes nested
`or` / `and not` / `implies` / `and`. Each check `{module, opts}` is one variable. Static
checks (action, actor absent) are simplified away first, the expression is cached at
compile time (`static_expression/3`), and `expand_invariants` adds `implies` / `nand`
clauses between related checks. `Crux.Formula.from_expression/1` turns it into CNF with
the Tseitin transform (auxiliary variables). Most real formulas are therefore a few
runtime checks plus their Tseitin auxiliaries.

**Ash-shaped formulas (measured).** A generator that mirrors `raw_expression` and
`policies_expression` (P policies, each with 1–2 condition checks and K checks of random
type, drawn from a shared pool), run through `Crux.Expression.simplify` and
`Formula.from_expression`. Two seeds per shape:

| Shape (P, K, pool) | CNF vars / clauses | one solve: picosat / Elixir DPLL / simple_sat | `satisfying_scenarios`: calls, scenarios | enumeration: picosat / DPLL / simple_sat |
|---|---|---|---|---|
| 2, 2, 4 | 6–8 / 13–16 | 4 µs / — / 9–120 µs | 1–7, 0–2 | 0.01–0.06 ms / — / 0.15–0.2 ms |
| 4, 3, 8 | 26–28 / 61–64 | 12–15 µs / 17–20 µs / 247–267 µs | 8–41, 1–5 | 0.15–0.84 ms / 0.22–0.9 ms / 17–592 ms |
| 8, 3, 12 | 45–50 / 106–121 | 22–29 µs / 54–147 µs / 2.2–4.8 ms | 133–210, 12–19 | 3.7–7.3 ms / 6.9–24 ms / 21 s to >30 s |
| 12, 4, 16 | 104–109 / 265–280 | 73–82 µs / 252–575 µs / 0.24–1.2 s | 1,548, 91 | 101–108 ms / 588–953 ms / >30 s |

The largest query in an enumeration had up to 371 clauses (blocking and gadget clauses
added). The "Elixir DPLL" column is a 20-line DPLL written for this study (unit
propagation, branching on the shortest clause, clauses as lists). It is a sketch of what an
optimized baseline would start from, not one.

**Random 3-SAT, clause/variable ratio 4.26 (measured; picosat median of 5, simple_sat
median of 3 with a 10 s timeout, DPLL best of 3):**

| n / clauses | picosat | Elixir DPLL | simple_sat |
|---|---|---|---|
| 20 / 85 | 13–21 µs | 26–42 µs | 0.16–3.6 ms |
| 30 / 128 | 24–42 µs | — | 40–67 ms; 1 of 3 >10 s (the UNSAT one) |
| 50 / 213 | 45–73 µs | 0.46–6.7 ms | 178 ms; 2 of 3 >10 s |
| 100 / 426 | 0.58–1.1 ms | 23–314 ms | >10 s (all 3) |
| 200 / 852 | 25–88 ms | not run | not run |
| 250–300 / 1,065–1,278 | 0.1–3.9 s | not run | not run |

**DPLL or CDCL.** simple_sat is chronological backtracking with simplification (finding
2). PicoSAT is CDCL (from the source): two watched literals (`htps`, `Cls *next[2]`), binary
clauses in implication lists; first-UIP `analyze` with clause minimisation; scores in a
binary heap (`Rnk`) as a 32-bit deterministic soft float (`Flt`), not `double`; a random
decision once per 1000 from a seeded LCG; geometric restarts (`NLUBY`, 100 × 1.1); learned
clause `reduce` by glue and activity; top-level simplification and failed-literal probing.

**Is the per-call size so small that the boundary dominates?** It depends on the size.
Below about 30 variables, an Elixir DPLL is within 1.4× of picosat. Packing the input
alone costs about as much as a picosat solve. So a per-call kernel lands `marginal` or
`poor`. At 100+ variables the solve dominates and the gap to Elixir is 3–7×. The batch form
(finding 4) removes the boundary for everything in one `satisfying_scenarios`, which is
also the expensive case.

## (b) A picosat-style CDCL kernel: what it needs

### Kernel signature and data layout

```elixir
# Input: clauses in CSR form, DIMACS literals (±v, v in 1..nvars).
# Returns {status, model, conflicts}: status 1 = SAT, 0 = UNSAT, 2 = budget exhausted;
# model[v] = v or -v for v in 1..nvars (model[0] unused).
defk cdcl(lits :: [i64], offs :: [i64], nvars :: i64,
          max_learned_lits :: i64, max_conflicts :: i64) :: {i64, [i64], i64}
```

Inside the kernel, a literal is `2*v` (positive) or `2*v + 1` (negative). The negation of
`l` is `l + 1 - 2 * rem(l, 2)`. With `defk-w38` it becomes `l ^^^ 1`. Every structure is
`alloc`'d once, sized from the input:

| Structure | Arrays | Size bound |
|---|---|---|
| Clause arena | `cl :: [i64]` literals; `cstart`, `csize :: [i64]` per clause; `cact :: [f64]` per learned clause | `len(lits) + max_learned_lits` literals; clauses ≤ originals + `max_learned_lits / 2` |
| Watches (two per clause, intrusive like PicoSAT's `next[2]`) | `whead :: [i64]` per literal (first clause, -1 = none); `wnext :: [i64]` per clause slot (`2*c + k`) | `2*nvars + 2`; `2 * clause capacity` |
| Assignment | `val :: [i64]` (-1/0/1) per literal or var; `level`, `reason :: [i64]` per var; `phase :: [i64]` saved phase | `nvars + 1` |
| Trail | `trail :: [i64]`, `trail_lim :: [i64]` (start of each decision level), scalar `qhead` | `nvars` each |
| VSIDS | `act :: [f64]` per var; `heap :: [i64]`, `hpos :: [i64]`; scalar `inc` (×1/0.95 per conflict, all activities rescaled by 1e-100 above 1e100) | `nvars + 1` |
| Conflict analysis | `seen :: [i64]`, `learnt :: [i64]` buffer, explicit `stack :: [i64]` for minimisation | `nvars` each (a learned clause has at most `nvars` literals) |

The main loop is `Enum.reduce_while(0..max_conflicts//1, state, ...)`, whose accumulator
is a tuple of scalars (`qhead`, decision level, `inc`, restart counters, learned count).
Propagation is an inner `reduce_while` over a literal's watch list that halts on conflict.
Backjumping walks the trail down to `trail_lim[level]`. Restarts use a geometric limit
(PicoSAT's 100 × 1.1) or Luby, which is plain arithmetic. Decisions pop the heap, with a
fixed tie-break (lowest variable index) so the run is reproducible.

**Bounding the learned clauses.** When the arena is full, `reduce` deletes the less active
half of the unlocked learned clauses (those not the reason for a current assignment):
heapsort an index array by `cact` in the kernel (as `sort_u64_keys` does), compact the
arena and rebuild `whead`/`wnext`. That is PicoSAT's policy with the limit fixed by
`max_learned_lits` instead of growing with √conflicts. A fixed limit loses the theoretical
completeness guarantee, hence the conflict budget and `status = 2`: a tiny bound ends in
status 2, never a wrong answer. `max(16 * len(lits), 2^20)` literals (8 MB) is far above
what the sizes below need. With `max_conflicts` near the top of the i64 range, the kernel
runs to an answer and relies on yielding.

**Batch form** (`satisfying_scenarios` in one call): the same arrays plus `nprimary`
(non-Tseitin variables). The kernel runs Crux's loop: solve, take the cube over primary
variables, minimise it with one solve per literal under assumptions (forced as the first
decision levels, as `picosat_assume` does) against selector/gadget clauses written once,
append the blocking clause, repeat. Cubes go out as `out_lits`/`out_offs :: [i64]` with a
capacity passed in; on overflow it returns status 2 and Elixir retries with double the
capacity (the two-pass pattern of `string-workloads.md`). Mapping variables back to check
refs and `validate_assignments/2` (user callbacks) stay in Elixir.

### What the subset has, what is ticketed, what is new

| Need | Today | Ticket |
|---|---|---|
| CSR input as `[i64]` literals + offsets; `alloc`'d `[i64]`/`[f64]` working arrays written in place | yes | — |
| Bit-exact f64 activity bumping, decay and rescaling | yes (`-ffp-contract=off`, no reassociation) | — |
| Iterative search with explicit stacks; no recursion | yes (the trail, `trail_lim` and `stack` are arrays) | — |
| Early exit: halt propagation on a conflict, halt the search on SAT/UNSAT, nested | yes (`Enum.reduce_while`, `{:halt, acc}` ends only its own loop) | — |
| Return a tuple of status, model array and counters | yes (`:: {i64, [i64], i64}`, as `fft` returns `{[f64], [f64]}`) | — |
| Helper kernels (`propagate`, `analyze`, `backjump`, `heap_up/down`, `reduce`) that write the caller's arrays | no: today the whole solver is one kernel body | `defk-n4r.4` (decided: a helper writes a parameter array only if it returns it, and the caller rebinds) |
| Named constants (decay 0.95, restart base 100, factor 1.1, rescale 1e100) | literals inline | `defk-ivt` |
| Literal negation, random decisions | arithmetic works (`rem`); an LCG mod 2^31 fits i64 without overflow | `defk-w38` (bitwise) makes `l ^^^ 1` and PicoSAT's LCG verbatim; nice to have, not required |
| Choosing between arrays in `if`/`cond` | not allowed; not needed, every write is in place | `defk-gqk` (not needed) |
| Sub-array views | not needed (CSR offsets index the arena) | `defk-n4r.3` (not needed) |
| Output whose size depends on the data | not needed: the model is `nvars`; batch cubes are bounded and use two passes | `defk-cmr` (not needed) |
| Solver state kept between Elixir calls (incremental SAT, as Crux's loop would want) | not needed if the loop runs inside one kernel; across calls the clause database grows | `defk-sve`: a growing structure, which its epic files under "probably not" |

**New findings, not ticketed.** (1) With the `defk-n4r.4` rule, a CDCL helper returns
every array it writes. `propagate` writes `val`, `level`, `reason`, `trail`, `whead`,
`wnext` and `cl`, so it would return a 7-tuple, rebound at each call site. The workable
layout is one `[i64]` state arena with fixed offsets per field (plus `act :: [f64]`), so
helpers return one or two arrays. That is worth a line in the `defk-n4r.4` docs when it
lands. (2) There is no `while`. A search with no natural bound is written as
`reduce_while` over a huge range, which works but reads like a workaround. (3) Every
helper is inlined, so `propagate`, called from search, from assumption handling and from
the batch loop, is copied at each call site. The code-size guard (`defk-6ag`) is relevant.
None of these blocks the kernel.

**Tier.** By the constructs it needs (`defk-n4r.4`, optionally `defk-ivt`/`defk-w38`), the
CDCL kernel sits with `defk-52v` Tier 1. By size (about 400 lines of kernel, the largest
in the catalog, with the inlining risk above) it belongs with Tier 2. It needs nothing from
Tier 3 (`defk-sve`).

## (c) The one rule and the agreement property for SAT

Three different comparisons apply. Only the first is agreement in CONTEXT.md's sense.

1. **Kernel vs its Elixir mode: exact.** The algorithm is pinned: heap tie-break by lowest
   variable, a deterministic restart and reduce schedule, an LCG with a fixed seed if
   random decisions are used, and f64 arithmetic evaluated as written. So both modes must
   return `===` results: the same status, the same model, the same conflict count (and in
   batch form the same cubes in the same order). It is the standard agreement property,
   with random CNFs as input (StreamData, 1–40 variables, clauses of 1–10 literals) and
   forced yields (`__defk_force_yields__/1`) to cover resuming.
2. **Kernel vs the anchors and the Elixir baseline (picosat_elixir, simple_sat, an Elixir
   DPLL/CDCL): "same answer" means the same satisfiability, and a valid model when SAT.**
   The status must be identical, and when SAT the model must satisfy every clause (check:
   `Enum.all?(cnf, &Enum.any?(&1, fn l -> l in model end))`). The model itself need not
   match. simple_sat's own property test already defines exactly this against Picosat:
   `{:ok, solution} -> assert {:ok, _} = Picosat.solve(statements ++ [solution])`. Note the
   difference in model shape: picosat returns every variable `1..max_var`, while simple_sat
   returns only the variables it assigned before the formula became true (`[var | trail]`).
   The kernel returns a full assignment, and the check allows partial models. Status 2
   (budget) is a Limit: the kernel stops where Elixir would keep going. In tests the budget
   is set high enough never to trigger, and a status 2 there fails the test.
3. **Batch form vs Crux + picosat: an equivalent cover, not the same list.** Crux's
   scenarios depend on which model the solver happens to find first. Measured: picosat and
   simple_sat produced different scenario sets on 2 of 6 shapes, and the DPLL and picosat
   on 4 of 6. Each set was valid. The property is: every scenario implies the formula
   (`cube ∧ ¬F` UNSAT, which Crux's own `implies_formula?` tests), and the scenarios
   together cover it (`F ∧ ¬(s1 ∨ … ∨ sk)` UNSAT). Both are checked with picosat in the
   test. Whether Ash's authorization result can differ between two valid covers was not
   checked (Limits).

## (d) Scheduling

`picosat_nif.c` registers `{"solve", 1, solve_nif}`: no dirty flag, no
`enif_schedule_nif`, no `enif_consume_timeslice`. It runs `picosat_sat(sat, -1)` (no
decision limit) and never sets PicoSAT's interrupt callback, which the source would check
every `INTERRUPTLIM` = 1024 decisions. Each call builds and frees a fresh solver, so the
incremental API (`picosat_assume`) is unused. Literals go through `enif_get_int`: one over
2^31-1 is a `badarg`, and that path returns without `picosat_reset`, leaking the solver.
Measured with `+S 1` and a 1 ms ticker: worst gaps of 105, 509, 729 and 3,870 ms on four
n = 250–300 random instances, about the solve time. At Ash sizes (under 0.1 ms per call)
this is harmless; on a hard formula one call blocks a scheduler for seconds. simple_sat is
preemptible but exponential, so it burns a process for as long or longer. A defk kernel
yields every 250 µs, frees its frame when the caller is killed (so a timeout really
cancels a solve) and runs picosat's algorithm: neither anchor has all three.

## Ranked recommendation

1. **A bounded CDCL kernel as a `defk-52v` rewrite (Tier 2 by size), anchored on
   `picosat_elixir` (native) and `simple_sat` (pure Elixir), measured on Ash's job in batch
   form.** The catalog entry has two parts. (i) `satisfying_scenarios` in one kernel call
   on Ash-shaped formulas, against Crux + an optimized Elixir solver, with Crux + picosat
   reported beside. (ii) A single solve of random 3-SAT at n = 100–300, which carries the
   yield story. The baseline must be optimized first. simple_sat is the anchor's first
   pass, and beating it says nothing: it is exponential where a DPLL is not. The baseline
   is an Elixir DPLL with unit propagation at least, ideally a CDCL in Elixir with watches
   in `:atomics` or tuples, as the examples' "better algorithms count on both sides" rule
   requires.
2. **simple_sat's job per call (a drop-in for `Crux.Implementation`) as a guidance entry.**
   It is expected `marginal` at typical Ash sizes, because the solve costs about as much as
   packing the input (finding 3). The entry teaches the batch lesson on a real library,
   alongside `per_pair_distance` and `poor_tiny_calls`. It is worth writing only as part
   of 1, since it shares the kernel.
3. **Not "neither".** The job is real (picosat_elixir 1.1M downloads and a pure-Elixir
   twin made because the NIF is hard to build), the data is defk's shape (integers in, a
   fixed-size integer array out) and the anchor blocks schedulers for seconds. The risk is
   size of effort, not fit.

## Sizes to pre-register and expected verdicts

Verdicts are against the optimized Elixir baseline (≥ 2× = `good`). The picosat comparison
and responsiveness are reported beside them and never change the verdict.

| # | Size | Elixir reference (measured, this study) | picosat (measured) | Expected verdict |
|---|---|---|---|---|
| S1 | Per call, Ash-shaped P = 4: ~27 vars / ~63 clauses | DPLL 17–20 µs | 12–15 µs | `marginal` (packing costs as much as the solve) |
| S2 | Per call, Ash-shaped P = 12: ~105 vars / ~270 clauses | DPLL 252–575 µs | 73–82 µs | `good`, provisional: 2–5× expected; may fall to `marginal` against an Elixir CDCL |
| S3 | Batch: whole `satisfying_scenarios`, P = 12 (1,548 solves, 91 scenarios) | Crux + DPLL 588–953 ms | Crux + picosat 101–108 ms | `good` (≥ 10× expected; the kernel should also beat Crux + picosat) |
| S4 | Random 3-SAT, ratio 4.26, n = 200 (852 clauses), 3 seeds | DPLL at n = 100: 23–314 ms; n = 200 not run (expected seconds to minutes) | 25–88 ms | `good` (CDCL vs DPLL; a kernel within 1–3× of picosat, reported beside) |
| S5 | Responsiveness: random 3-SAT n = 300, `+S 1`, 1 ms ticker | (Elixir is preemptible) | 3,870 ms worst gap | worst gap ≈ 2–3 ms with the kernel (README's yielding numbers), against seconds for picosat |

S1–S3 use this study's generator (mirrors `raw_expression`; seeds go in the script).

## The minimal subset additions

In order: **`defk-n4r.4`** (helper kernels that write their caller's arrays by returning
them). Without it the whole solver is one kernel body, which is possible but hard to read
and review. Then **`defk-ivt`** (named constants). Optional: **`defk-w38`** for `l ^^^ 1`
and PicoSAT's LCG verbatim. Nothing from `defk-n4r.3`, `defk-cmr` or `defk-sve`. Not
ticketed, but worth noting: the multi-array return cost of the `defk-n4r.4` rule (one state
arena per solver is the pattern to document), the lack of a plain `while`, and inlining
size (`defk-6ag`).

## Sources

- Hex.pm API `https://hex.pm/api/packages/{simple_sat,picosat_elixir,crux,ash}` (2026-10-09)
  and tarballs `https://repo.hex.pm/tarballs/<name>-<version>.tar`, files read:
  `simple_sat-0.1.4/lib/simple_sat.ex` (all of it); `picosat_elixir-0.2.3/c_src/picosat_nif.c`,
  `Makefile`, `lib/solver/picosat.ex`, `c_src/picosat.c` (`Flt`, `Rnk`, `Cls`, `analyze`,
  `bcp`, `backtrack`, `restart`, `rdecide`/`rng`, `init_reduce`, `reduce`, `sat`, the
  defines), `picosat.h`; `crux-0.1.4/lib/crux.ex`, `lib/crux/implementation.ex`,
  `lib/crux/formula.ex`; `ash-3.34.6/lib/ash/sat_solver.ex`, `lib/ash/policy/policy.ex`,
  `lib/ash/policy/checker.ex`, `lib/ash/filter/filter.ex`, `mix.exs`.
- GitHub: https://github.com/ash-project/simple_sat (`test/simple_sat_test.exs`),
  https://github.com/ash-project/crux, https://github.com/bitwalker/picosat_elixir
  (`test/picosat_test.exs`).
- PicoSAT: https://fmv.jku.at/picosat/. Erlang: https://www.erlang.org/doc/apps/erts/erl_nif.html.
- This repo: CONTEXT.md, README.md, examples/README.md, `docs/research/nif-workloads.md`,
  `docs/research/string-workloads.md`, and the tickets named above via `bw show`.

## Limits

- The Ash-shaped formulas are synthetic: they follow Ash's expression builder, but no
  production app's formulas or call rates were observed. Many real policies simplify to a
  boolean before Crux is called, so the call counts are a shape, not a distribution.
- Timings are single sessions on a shared, busy laptop. The Elixir DPLL is a 20-line
  sketch; an Elixir CDCL may narrow S2 and S4.
- Whether Ash's authorization can differ between two valid scenario covers was not tested.
- PicoSAT was read from the vendored source (API 953), not the paper; release 965 may differ.
- S2–S5 for the kernel are extrapolations from picosat's speed and defk's yield costs; no
  kernel was written.
