# Relational range facts: one representation for bounds proofs

Ticket: defk-2mz. Written 2026-10-12. Design only; nothing here is
implemented. Draft decision: [ADR-0007](../adr/0007-symbolic-bounds.md)
(status proposed).

## Question

Four tickets keep a bounds check that a human proves in one line, because
the proof needs a relation between two values and the range facts only
relate a value to constants and to array lengths:

| ticket | kept check | the proof needs |
|---|---|---|
| defk-pic | `out[i]`, `out = alloc(i16, n)`, `n = min(len(a), len(b))` | `len(out) == n` |
| defk-siy (1) | `bufs[base + i]`, `i <= min(len(sums), len(bufs) - base) - 1` | `base + i <= len(bufs) - 1` from a bound with three terms |
| defk-siy (2) | `acc[i - m]`, `i <- m..(...)` | the range start as a lower bound: `i >= m` |
| defk-n7k | `m[r * dim + j]`, `out[r]` | `n * dim <= len(m)` from `n = div(len(m), dim)`; `len(out) == n` |
| defk-9za | `x[i - w]` under `if i >= w`, after a raise when `w < 1` | facts from a condition, in a branch and after a raising guard |

Adding each as its own fact kind would multiply special cases in
`in_bounds?/3`, `add_facts`/`sub_facts`, `with_acc_facts` and the report.
The question is whether one representation covers all four, how it is
derived, merged and invalidated, whether it is sound, and what it costs.

## Summary

- **Proposal: symbolic bounds over ranked atoms.** A fact is `q * x <= P`
  or `q * x >= P`, with `q >= 1` an integer and `P` a polynomial of degree
  at most 2 with integer coefficients over *atoms*: the C variable of an i64
  binding (a local, a parameter, a loop counter) or the length of an array
  binding. Atoms are ordered by when they were bound (the `fresh/2`
  counter), and a fact about atom `x` only mentions atoms bound before `x`.
  Today's `lo`/`hi`, `lb`/`ub`, `len_lo`/`len_lb` and defk-upc's scaled
  facts are all special cases.
- **One prover.** To show `D <= 0`, take the newest atom in `D` and
  replace it by one of its bounds (an upper bound where its coefficient is
  positive, a lower one where negative), and repeat until `D` is a
  constant. The ordering makes every step remove the newest atom, so the
  search terminates; a step budget (64) bounds it. This is symbolic range
  propagation (Blume and Eigenmann) restricted to what a bounds check needs.
- **Sources of facts:** exact arithmetic (`base + i` *is* `base + i`),
  `min`/`max`, range loop bounds (start and end, both directions), alloc
  and copy lengths (`len(out) == n`), `div(x, d)` (`q * d <= x`),
  conditions in `if`/`cond`/filters, raising guards (`if c, do: raise`),
  and the non-emptiness of a range (`0..(n - 1)` gives `n >= 1` in its
  body).
- **Coverage:** all checks in all five repros drop, including n7k's
  `m[r * dim + j]` through degree-2 monomials (the row-stride shape), and
  so does the real `pcm_mix` sum loop (`bufs[j * m + i]`, `all[hl + i]`),
  which is the n7k shape rather than the siy repro's. Out: degree 3
  (`(y * w + x) * ch + c`), facts across iterations (scalar accumulator
  invariants), facts about array contents, bitwise index shapes,
  disjunctions and `!=`.
- **Soundness** rests on four rules: facts describe exact integers
  (checked arithmetic is exact or raises; masked and u64 arithmetic give
  no forms); atoms are SSA-like C variables whose facts live in the
  lexically scoped env; an arm that used its own condition to drop a check
  is never computed speculatively (no select); and a condition narrows
  only when its operands are computed without a check that a flagged strip
  could let through.
- **Cost (provisional, shared machine):** the test suite compiles 1597
  modules with 9.5k `in_bounds?/3` calls and 8k checked i64 operations in
  8.6-10.7 s of `Defk.Compiler.compile/4`. The prototype prover answers a
  repro query in 1-4 us and a budget-exhausting one in ~26 us: about
  0.1-0.15 s (1-2%) on the whole suite, under 1 s (about 10%) if every
  query exhausted its budget.
- **Plan:** four tickets, core first, and an optional fifth: (1) atoms,
  forms, prover, and the existing facts moved onto them, generated C
  unchanged; (2) linear sources: pic and siy loop 1; (3) conditions and
  raising guards, and the report naming the missing fact: 9za and siy
  loop 2; (4) degree-2 monomials: n7k and `pcm_mix`; (5, later) `rem`,
  scalar accumulator invariants, `case` guards. defk-fun first (small,
  independent).

## 1. Facts today

All of this is in `lib/defk/compiler.ex`, section "range facts".

### Representation

A value is a map with its C expression (`c`) and type (`t`). An i64 value
may carry:

- `lo`, `hi`: constants, `lo <= v <= hi` (`nil` = unknown).
- `lb`, `ub`: `%{key => k}`, `v >= len(arr) + k` / `v <= len(arr) + k`,
  with `key` an array's C variable, or `{arr, p, q}` for defk-upc's scaled
  facts, `q * v <= p * len(arr) + k`.

An array value may carry `len_lo` (a constant lower bound of its length)
and `len_lb` (lower bounds of its length in the same keyed form), plus
`fin` (every element finite).

Every fact relates *one* value to constants and to array lengths. Nothing
relates two scalars: `n` in `alloc(i16, n)` is a value, not something a
later fact can name.

### Where facts are created

- literals (`lo = hi = k`); a narrow element read (`u8` gives `0..255`);
  a binary attribute's length (`len_lo`);
- `len(a)`: `lb = ub = {a => 0}`, `lo = len_lo`;
- `+`, `-` (`add_facts`, `sub_facts`: shift `lb`/`ub` by the other side's
  constant bound), `*` by a literal (`scaled`), `div` by a literal
  (`div_facts_of`), `min`/`max` (`minmax_facts`), `band`/`bor`/`bxor`/`bsr`
  (constant ranges only);
- a range loop with a positive literal step: the counter gets
  `lo`/`lb` from the start and `hi`/`ub` from the end (`range_loop`); a
  negative or variable step gives nothing;
- `alloc(e, n)`: `len_lo = lo(n)`, `len_lb = lb(n)`; a copy or a new
  binding of an array: `len_lb = {original => 0}`.

### How they are used

- `in_bounds?/3`: `lo_of(i) >= 0`, and `hi_of(i) < len_lo(a)` or some `ub`
  of `i` below `len(a)` (`below_len?/3`, through `a`'s `len_lb`).
  Reads, writes and word loads drop their check when it holds.
- `i64_arith/4`: no overflow check when `lo_of`/`hi_of` keep the result
  inside i64 (lengths are below 2^61, so an `ub` fact bounds a value).
- `range_limit/4`: drops the near-`INT64_MAX` test of a range end;
  `narrowed`/`int_stored`: drop the element range check of a store.
- `note_bounds/4`: the report. When a check stays, `in_bounds?/3` is asked
  again with each half supplied, and the report says
  `nothing proves 0 <= idx`, `nothing proves idx < len(arr)` or both.

### Merges, loops, invalidation

- **Bindings** copy the value's facts (`Map.take(v, @facts)`) onto a fresh
  C variable. Every Elixir binding gets its own C variable, so a rebinding
  never changes what an earlier fact describes.
- **Joins:** an `if`/`cond`/`case` value carries no facts at all
  (`val(tmp, t, tmp)`). A statement `if` gives back the env it was given:
  nothing learned in a branch survives it.
- **Conditions** narrow nothing: inside `if i >= w`, `i` has the facts it
  had before.
- **Loops:** the counter's facts are valid in the body only. A reduce
  accumulator starts with no facts if it is a scalar; an array accumulator
  is assumed to keep `fin` and `len_lo`, and `with_acc_facts/2` lowers the
  loop again without them when some iteration's new value lacks them
  (`lost_facts?/2`). `len_lb` is not carried (defk-fun).
- **Inlined calls:** a parameter binding copies the argument's facts; a
  returned array keeps `len_lo` but drops `len_lb`, which names the
  callee's C variables.
- **Invalidation** is by scope: facts live on values in `env.vars`, which
  is lexical, and name array C variables that never change length.

## 2. Options

**(a) One fact kind per ticket.** `len_eq` for pic, offsets for siy, a
row-stride kind for n7k, guard facts for 9za. Each needs its own case in
`in_bounds?/3`, the arithmetic rules, the accumulator carry and the report,
and they do not compose: siy's `base + i` needs the guard-free offset and
the `min` bound together. This is what the ticket wants to avoid.

**(b) Difference bounds, `x <= y + c` (ABCD, DBM).** Pairs of atoms with a
constant, solved as shortest paths. Covers pic and 9za and the range start
of siy loop 2. It does not cover siy loop 1: `i <= len(bufs) - base - 1`
relates three atoms, and so does the goal `base + i <= len(bufs) - 1`.
Naming the temporary `len(bufs) - base` does not help, because the goal is
a sum. n7k is a product. Two of the four tickets stay open.

**(c) Linear (and degree-2) symbolic bounds, proved by substitution.**
Recommended; the rest of this document. It is the smallest representation
that covers all four, and today's facts are special cases of it, so it
replaces them instead of sitting beside them.

**(d) A general solver** (Fourier-Motzkin over all facts, Presburger, an SMT
solver). Decides more, but costs more and less predictably, and a solver
dependency is out of proportion for a compiler pass that runs on every
`mix compile`. The search in (c) is a bounded, ordered special case.

For orientation, not checked against their sources for this ticket: ABCD
(Bodík, Gupta and Sarkar, PLDI 2000) is (b) on demand; symbolic range
propagation (Blume and Eigenmann, 1994-95) is (c); LLVM's
ConstraintElimination pass solves linear constraints from dominating
conditions by Fourier-Motzkin elimination, which is (d) with a cap.

## 3. Proposal

### Atoms, forms and facts

- **Atom:** the C variable of an i64 binding (`v_n_12`, a parameter
  `p_w`, a loop counter, a `case` subject), or `len(a)` for an array
  binding's C variable. Every atom has a **rank**: its binding's number
  from `fresh/2` (parameters first, by position); `len(a)` has `a`'s rank.
- **Monomial:** an atom or a product of two atoms (`r * dim`); its rank is
  the higher of its factors'.
- **Form:** a polynomial of degree at most 2 with integer coefficients over
  monomials, plus a constant (`len(bufs) - base - 1`, `n * dim`).
- **Fact:** `q * x <= P` (an upper bound) or `q * x >= P` (a lower bound)
  for a monomial `x`, with `q >= 1` and every monomial of `P` ranked below
  `x`. `lo`/`hi` stay as they are: the constant bounds every fact ends in.

Where facts live:

- A **value** carries `lo`/`hi` as today, an exact form `eq` when it is one
  (an atom, `len(a)`, a literal, and `+`, `-`, `*` of exact values computed
  exactly; see soundness), and `ubs`/`lbs`, lists of `{q, P}` (from
  `min`/`max`, `div`, a branch join). At most four of each, the newest
  kept.
- The **env** gets `facts`: `%{monomial => %{lo, hi, ubs, lbs}}`. Binding
  `x = v` records `v`'s facts under the atom `x` (its `eq` as both an upper
  and a lower bound), and reading `x` gives a value with `eq: x`.
  Narrowing adds to `env.facts`. Arrays: binding `a` records its length
  facts under `len(a)`; `len_lo` is `env.facts[len(a)].lo`.

Today's facts map directly: `ub: {a => k}` is `{1, len(a) + k}`,
defk-upc's `{{a, p, q}, k}` is `{q, p * len(a) + k}`, `len_lb: {b => d}`
is a lower bound `len(b) + d` on `len(a)`.

### The prover

`le?(D, env)` decides `D <= 0` for a form `D`:

1. If `D` is a constant `k`, the answer is `k <= 0`.
2. Otherwise take the newest monomial `x` in `D` (highest rank; a product
   before a plain atom of the same rank) with coefficient `c`. Its
   candidate replacements, tried in order:
   - each of its own bounds in the direction of `c` (`c > 0`: `q * x <= P`
     gives `q * D - q * c * x + c * P`; `c < 0`: a lower bound, same
     formula);
   - for a product `y * z` with `y` the newer factor: a bound of `y`
     times `z` when `z`'s sign is known from its constant bounds (degree
     stays at most 2), or `y`'s constant bound times `z`;
   - its constant bound (`hi` for `c > 0`, `lo` for `c < 0`); `len(a)` is
     always in `0..2^61 - 1`.
3. Recurse on each candidate, depth first; the first success proves it.
   Each step replaces the newest monomial by older ones, so the search
   ends; a budget of 64 steps per query bounds it, and an exhausted budget
   answers "not proven" (the check stays).

`a[i]` is in bounds when `le?(-i, env)` and `le?(i - len(a) + 1, env)`,
with `i`'s `eq` form when it has one, else each of its bounds. `i64_arith`
asks the same prover for `v <= 2^63 - 1` and `v >= -2^63` before keeping
an overflow check. The newest-first order is what lets terms cancel: in
`base + i - len(bufs) + 1`, substituting `i` first brings in
`len(bufs) - base - 1` and both `base` and `len(bufs)` drop out.

### Sources of facts

- **Exact arithmetic:** `+`, `-`, `*` of exact values have an exact `eq`
  (a product of two atoms is a monomial; a product that would exceed degree
  2 has none). The constant bounds are computed as today.
- **`min`/`max`:** `min(a, b)` has the upper bounds `eq(a)` and `eq(b)`
  (and those of `a` and `b`); `max` the lower ones.
- **`div(x, d)`**, `x >= 0` proven: for a literal `d` as today
  (defk-upc); for any `d`, the result `q` has `q * d <= x` (true for every
  non-zero `d`: for `d < 0` the quotient truncates towards zero), and when
  `d >= 1` is proven also `0 <= q <= x`. The fact goes on the monomial
  `q * d`, ranked by `q`.
- **Range loops** `s..e//k`: for `k > 0` the counter has `lbs` from `s`
  (its `eq`: defk-siy's `i >= m`) and `ubs` from `e`; for `k < 0` the
  mirror. The body also narrows by `s <= e` (`k > 0`): a non-empty range
  `0..(n - 1)//1` gives `n >= 1` inside it.
- **Lengths:** `alloc(e, n)` gives `len(out)` the bounds `eq(n)` or `n`'s
  own bounds both ways (`len(out) == n`); a copy has the original's length;
  a binary attribute its byte size.
- **Conditions** (narrowing): in the taken branch of an `if`, a `cond`
  arm, a `for` filter, and the right operand of `and`, each comparison
  `x < y`, `x <= y`, `x == y`, `x >= y`, `x > y` between exact forms holds.
  `and` gives both, `not` swaps the branch, `not (a or b)` gives both
  negations; `or` in a taken branch and `!=` give nothing. A comparison
  becomes `D <= 0` and is recorded on `D`'s newest monomial (or as `lo`/`hi`
  when `D` has one atom). Later `cond` arms see the negations of the
  earlier conditions when those are conjunctions.
- **Raising guards:** after a statement `if c, do: <raises>` (every path
  of the arm raises), the rest of the block sees `not c`. This is the
  ordinary branch rule: the raising arm never reaches the join. The
  `_ = alloc(u8, if(c, do: 0, else: -1))` idiom in `decode16` could become
  `if not c, do: raise ArgumentError`.

### Joins and loops

- **Statement `if`**: facts learned in an arm stay in the arm, except
  that an arm that always raises does not reach the join.
- **`if`/`cond`/`case` values:** the result keeps the hull of the arms'
  `lo`/`hi` and the bounds every arm has (same `{q, P}` after
  normalising), restricted to atoms in scope at the join. Today it keeps
  nothing; this is cheap and helps `x = if ..., do: i - 1, else: 0`.
- **Range loop bodies:** the counter's facts and the non-empty narrowing
  are in the body's env only.
- **Accumulators:** an array accumulator keeps the length facts of its
  initial value whose atoms are ranked below the loop (invariant across
  iterations), if every new value is proven to imply them (the prover
  instead of `lost_facts?/2`'s comparison); otherwise `with_acc_facts/2`
  lowers again without them. This is defk-fun generalised. A scalar
  accumulator stays without facts.
- **Inlined calls:** parameters take the arguments' facts (their `eq`);
  a result keeps the facts over caller atoms only.

### What stays out

- **Degree 3 and nested products:** `out[(y * out_w + x) * ch + c]`
  (resize_bilinear, defk-i5r shape 3) expands to `y * out_w * ch`. A row
  stride `r * dim + j` is in (degree 2).
- **Facts across iterations:** invariants of scalar accumulators, such as
  `start <= i` in `pcm_mix`'s sign scan (`for k <- start..(i - 1)`). The
  same assume-check-retry scheme as array accumulators could add them
  later; none of the four tickets needs it.
- **Array contents** (indices read from an array, CSR offsets), bitwise
  index shapes beyond today's constant ranges, u64 values, `case` guards,
  disjunctions, `!=`, symbolic steps, `rem` (an easy later source:
  `rem(x, d)` in `0..d - 1` for `x >= 0`, `d >= 1`, the ring-buffer
  index).
- Anything across the kernel boundary: a fact about an argument comes from
  a guard in the kernel.

## 4. Soundness

A dropped bounds check is an unchecked load or store: an unsound fact is
memory corruption, worse than any slowdown. The argument has four parts.

**Facts are about exact integers.** A fact is a statement about the
mathematical values the C variables hold, and every coefficient and
constant is an Elixir integer, so nothing in the compiler overflows.
Checked i64 arithmetic either computes the exact result or raises, so a
value computed by `defk_add_i64` and friends has its exact `eq`. An
operation whose overflow check is dropped is dropped because the prover
bounded its exact result inside i64 (from operand facts that hold
independently of the result), so it is exact too. Masked arithmetic
(`band(..., 2^k - 1)`, which wraps) and u64 arithmetic give no `eq` and no
bounds. An intermediate of an index needs its own proof: proving
`0 <= (a + b) - c < len(x)` does not show that `a + b` did not overflow,
so each operation keeps or drops its own overflow check.

**Atoms are fixed where their facts are visible.** Each Elixir binding is
a fresh C variable, so a rebinding (`x = x + 1`) makes a new atom and the
old facts keep describing the old value. Facts live in `env`, which is
lexical: a fact made in a loop body or a branch is gone at its end. The C
variables that are assigned more than once are loop counters (their facts
live in the body, re-established by the loop test every iteration),
reduce accumulators (reassigned at the end of an iteration, after every
use of facts about them in that iteration; across iterations only facts
over atoms bound before the loop are carried, and only when each new value
is proven to keep them), and an array copied in place (same length).
An array's length never changes; aliasing changes nothing because arrays
are values. Facts about an atom mention only older atoms, so no cycle can
make the search circular.

**Resume after a yield.** A yield spills the locals that are live where it
resumes and re-binds input arrays to the same binaries, so every value the
kernel reads after a resume is the value it had before, and every length
is the same. A fact may mention an atom that is not spilled (it is dead
there): that is harmless, because the fact was a true statement about
values when it was derived, and the values it constrains that are still
read are unchanged. A comparison that narrows reads its operands, which
makes them live. Resume enters loops through their headers, which re-test
the range (forced-yield tests cover each resume path, see
`test/resume_test.exs`).

**Speculation and flagged strips.** Two lowerings compute code whose
facts do not hold:

- *A select computes both arms.* Narrowing makes facts that hold only when
  the arm is taken. Array reads are never speculated today (`speculate?/1`
  is syntactic), but an arm like `if i >= w, do: i - w, else: 0` is, and a
  dropped overflow check there would be plain C `-` on the untaken path
  (undefined behaviour on overflow). Rule: a proof that used a fact from an
  arm's own condition marks the arm, and a marked arm is not a select. The
  report says so: `not a select: arm 1 relies on its condition to drop a
  check`.
- *A flagged strip computes on after a failed check* (`flag_strip/3`), so a
  value assigned in the strip from a checked operation may be wrong there.
  `fixed_indices?/3` already lets an unchecked access into such a strip
  only when its index uses the counter and values not assigned in the
  strip. The rank order extends that to the proof: a proof for such an
  index substitutes only older atoms, which are bound before the counter
  and are not assigned in the strip. A narrowing fact on such an atom comes
  from a comparison whose other atoms are older still; its operands must
  also be computed without a check that can fail and run on (atoms,
  literals, lengths, and arithmetic whose overflow check was dropped), so
  `if i + 1 < w` with a checked `i + 1` narrows nothing. defk-5qk would
  admit indices assigned in the strip from fixed values; then the proof's
  support (the atoms it substituted) has to be fixed too, so the core
  ticket should leave the support in the C as a marker that
  `fixed_indices?/3` reads (for example `/* defk:by v_n_3 v_dim_5 */`).

Elixir mode is untouched: facts only remove checks that cannot fail, so
agreement holds whenever the facts are sound, and the tests below are
there to show they are.

**Tests that would catch an unsound fact:** each implementation ticket
adds generated-kernel soundness properties in the style of
`test/scaled_facts_test.exs`: random linear index shapes, offsets, guards
and loop bounds, inputs on the boundaries (empty arrays, `n = 0`, a range
end one past the last index, negative parameters), every dropped check
compared with the arithmetic, plus agreement under forced yields.

## 5. Cost

**Measured (provisional: other agents ran test suites on the machine).**
A counting build of the compiler (branch `defk-2mz-proto`, not for merge)
on the test suite: 1597 module compiles, 8.6-10.7 s summed inside
`Defk.Compiler.compile/4` (two runs; async tests overlap, so this is CPU
time spread over cores, not wall time), 9.5k `in_bounds?/3` calls (2.5k of
them from `note_bounds/4`), 8.0k `i64_arith/4` calls and 695
`lower_cond/2` calls. clang is not included; it dominates a real build.

**Prototype prover** (`proto/prover.exs` on that branch: the forms,
ranks and substitution search above, run on hand-built fact tables that
mirror what the compiler would record for each repro):

| query | proven | steps | us per query |
|---|---|---|---|
| pic `out[i]` | yes | 5 | 1.4 |
| siy 1 `bufs[base + i]` | yes | 6 | 2.1-3.4 |
| siy 2 `acc[i - m]` (with `m >= 0`) | yes | 5 | 1.9 |
| siy 2 without `m >= 0` | no | 7 | 2.6 |
| n7k `m[r * dim + j]` | yes | 7 | 3.7 |
| n7k `r * dim <= len(m)` (overflow) | yes | 5 | 2.4 |
| n7k `out[r]` | yes | 5 | 1.4 |
| 9za `x[i - w]` | yes | 5 | 1.6 |
| 9za without the guard on `w` | no | 4 | 1.6 |
| 12 chained atoms, 4 bounds each, unprovable | no | 64 (budget) | 26 |

**Estimate.** Two queries per `in_bounds?/3` and at most two per checked
i64 operation is about 35k queries on the suite: 0.05-0.15 s at the
measured 1-4 us (1-2% of the compiler's own time); if every query used its
whole budget, about 0.9 s (about 10%). Most queries never reach the prover:
constant bounds settle them as today. Not measured: the cost of keeping
`env.facts` (a map update per i64 binding), and a full compiler
integration; ticket 1's acceptance criteria include a measured bound.

## 6. The repros walked through

Ranks in parentheses where they matter. "Today" is the report from
compiling each repro on `47a3bb1`.

### defk-pic

```elixir
n = min(len(a), len(b))
out = alloc(i16, n)
for i <- 0..(n - 1)//1 do
  out[i] = div(a[i] + b[i], 2)
end
```

Today: `a[i]`, `b[i]` dropped; `out[i]: bounds check kept; nothing proves
i < len(out)`.

- `n`: `ubs [len(a), len(b)]`, `lo 0`. `len(out)`: bounds `n` both ways.
- `i`: `lo 0`, `ubs [n - 1]`.
- `out[i]` upper half: `i - len(out) + 1`; `i` (newest) by `n - 1`
  gives `n - len(out)`; `len(out)` (coefficient -1) by its lower bound `n`
  gives `0`. Dropped. Lower half from `lo 0`.

All three checks drop; the loop has no check left and can vectorise.

### defk-siy, loop 1

```elixir
m = div(len(bufs), n)
sums = alloc(i64, m)
for j <- 0..(n - 1)//1 do
  base = max(j * m, 0)
  for i <- 0..(min(len(sums), len(bufs) - base) - 1)//1 do
    sums[i] = sums[i] + bufs[base + i]
  end
end
```

Today: `sums[i]` dropped; `bufs[base + i]: bounds check kept; nothing
proves base + i < len(bufs)`.

- `base`: `lo 0` (and `lbs [j * m, 0]`). `i`: `lo 0`,
  `ubs [len(sums) - 1, len(bufs) - base - 1]` (from `min`).
- `bufs[base + i]` upper half: `base + i - len(bufs) + 1`; `i` by
  `len(bufs) - base - 1` gives `0`. Dropped. Lower half: `base`, `i` both
  `>= 0`.
- The add `base + i` loses its overflow check: the same substitution
  bounds it by `len(bufs) - 1`.

Both checks drop. `n`'s sign is unknown, so `m` has no bounds, and none of
these proofs needs them.

### defk-siy, loop 2

```elixir
for i <- m..(min(len(acc), len(bufs)) - 1)//1 do
  acc[i] = acc[i - m] + bufs[i]
end
```

Today (the repro with `m = div(len(bufs), n)`, `n` unchecked): every
access keeps its check; `acc[i - m]: nothing proves 0 <= i - m and i - m <
len(acc)`, `acc[i]`, `bufs[i]: nothing proves 0 <= i`. The ticket's
kernel knew `m >= 0`; then only `0 <= i - m` was missing.

- `i`: `lbs [m]` (the range start, new), `ubs [len(acc) - 1, len(bufs) - 1]`.
- `acc[i - m]` lower half: `m - i`; `i` by its lower bound `m` gives `0`.
  Upper half: `i - m - len(acc) + 1`; `i` by `len(acc) - 1` gives `-m`,
  which needs `m >= 0`.
- `acc[i]`, `bufs[i]` lower halves: `-i`, by `m`, needs `m >= 0` too.

With `m >= 0` known (as in the ticket's kernel, or after
`if n < 1, do: raise ArgumentError`, which with the `div` rule gives
`m >= 0`), all four checks drop. Without it they stay, and the report
names the fact (section 7): `nothing proves i - m < len(acc) (it would
follow from m >= 0)`. That is a true gap, not a weakness: with `n < 0`,
`m` is negative and `acc[i]` would be out of bounds.

### The real `pcm_mix` sum loop

```elixir
hl = len(held)
m = div(len(bufs), n)
all = alloc(i64, hl + m)
for j <- 0..(n - 1)//1 do
  base = j * m
  for i <- 0..(m - 1)//1 do
    all[hl + i] = all[hl + i] + bufs[base + i]
  end
end
```

Today: `all[hl + i]: nothing proves hl + i < len(all)` (one check for the
read and the write) and `bufs[base + i]: nothing proves 0 <= base + i and
base + i < len(bufs)`.

This is the n7k shape, not the siy repro's. `all[hl + i]`: `len(all)` is
`hl + m` both ways and `i <= m - 1`, so `hl + i - len(all) + 1` goes to
`0`. `bufs[base + i]`: `base` is `j * m` exactly; `m * n <= len(bufs)`
from the `div` rule (for any non-zero `n`); in the inner body `m >= 1`
(non-empty range) and `j <= n - 1`, so `j * m + i - len(bufs) + 1` goes
`i -> m - 1`, then `j * m -> (n - 1) * m`, then `n * m -> len(bufs)`: `0`.
Both checks drop with degree-2 monomials (ticket 4); the example's header
comment then needs updating.

### defk-n7k

```elixir
dim = len(q)
n = div(len(m), dim)
out = alloc(f64, n)
for r <- 0..(n - 1)//1 do
  out[r] = for j <- 0..(dim - 1)//1, reduce: 0.0 do
    acc -> acc + m[r * dim + j] * q[j]
  end
end
```

Today: `q[j]` dropped; `out[r]: nothing proves r < len(out)`;
`m[r * dim + j]: nothing proves 0 <= r * dim + j and r * dim + j < len(m)`.
`out[r]` is surprising only because `alloc` records lower bounds of `n`
relative to arrays, and `div(len(m), dim)` with a non-literal `dim` has
none.

- `dim`: `len(q)` both ways, `lo 0`; `>= 1` in the inner body (non-empty).
- `n`: `lo 0`, `ubs [len(m)]`; the monomial `n * dim` (ranked by `n`) has
  the upper bound `len(m)`.
- `len(out)`: `n` both ways. `r`: `lo 0`, `ubs [n - 1]`. `j`: `lo 0`,
  `ubs [dim - 1]`.
- `out[r]`: as pic. Dropped.
- `m[r * dim + j]` upper half: `r * dim + j - len(m) + 1`; `j` (newest)
  by `dim - 1` gives `r * dim + dim - len(m)`; the monomial `r * dim`,
  newest factor `r`, other factor `dim >= 0`: `r` by `n - 1` gives
  `n * dim - len(m)`; `n * dim` by `len(m)` gives `0`. Dropped. Lower
  half: `j >= 0`, `r >= 0` times `dim >= 0`.
- The product `r * dim` and the sum lose their overflow checks:
  `r * dim <= n * dim - dim <= len(m) < 2^61`.

All checks drop, with degree-2 monomials; the inner loop is the flagged
strip the report shows today, and its indices stay fixed (`r`, `dim` are
not assigned in it; the proof's support `n`, `n * dim`, `len(m)` is older
than `j`). The guarded variant with `n` and `dim` as parameters:

```elixir
if not (n > 0 and dim > 0 and len(m) == n * dim and len(q) == dim),
  do: raise(ArgumentError, "shape")
```

gives, after the statement, `n >= 1`, `dim >= 1`, the monomial `n * dim`
equal to `len(m)` (it is ranked above `len(m)`: parameters by position),
and `dim` equal to `len(q)`. The same proofs go through, and `q[j]`, which
today keeps its check in this variant, drops too.

### defk-9za

```elixir
if w < 1, do: raise(ArgumentError, "w")
out = alloc(f64, len(x))
for i <- 0..(len(x) - 1)//1 do
  old = if i >= w, do: x[i - w], else: 0.0
  out[i] = x[i] - old
end
```

Today: `x[i - w]: nothing proves 0 <= i - w and i - w < len(x)`.

- After the raising guard: `w >= 1` (one atom: `lo` of `w`).
- In the `do` arm: `i >= w`, recorded on `i` (newer than `w`) as
  `lbs [w]`.
- Lower half: `w - i`; `i` by `w` gives `0`. Upper half:
  `i - w - len(x) + 1`; `i` by `len(x) - 1` gives `-w`; `w` by `lo 1`
  gives `-1`. Dropped. `i - w` loses its overflow check.
- The arm used its condition, so it is never a select; it is not one
  today either (array reads are not speculated).

Without the guard on `w`, the upper half stops at `-w` and the report
says `nothing proves i - w < len(x) (it would follow from w >= 0)`, which
is what the ticket asks for.

## 7. The report

`note_bounds/4` keeps its two halves (`0 <= idx`, `idx < len(arr)`) and
asks the prover for each. When a half fails, the search keeps its best
leaf: the residual `D` with the fewest monomials, if it has at most two
atoms and no product. The report then names it, with source names (`v_w_3`
is `w`, `p_n` is `n`, `len(v_out_7)` is `len(out)`):

- `x[i - w]: bounds check kept; nothing proves i - w < len(x) (it would
  follow from w >= 0)`;
- `acc[i - m]: ...; nothing proves i - m < len(acc) (it would follow from
  m >= 0)`;
- with no useful residual (a product left, or many atoms), the text is
  today's.

The parenthesis is a hint, not a promise: another fact could also do. The
fast-path report doc (`docs/fast-path-report.md`) and `docs/language.md`'s
bounds section describe the new sources when ticket 2 lands, and
`docs/performance.md` section 6.2 moves pic, siy, n7k and 9za from "kept" to
"proven".

## 8. Implementation plan

In order; each ticket ends with `mix test`, `mix docs`, `mix credo
--strict`, agreement under forced yields, and soundness properties for
what it adds.

1. **Symbolic bounds core, no behaviour change.** Atoms and ranks, forms,
   `env.facts`, the prover with its budget; `lo`/`hi` stay, and
   `lb`/`ub`/`len_lo`/`len_lb` and the scaled facts become forms and
   facts. `in_bounds?/3` (now with `env`), `i64_arith`, `range_limit`,
   stores and `with_acc_facts/2` (implication by the prover instead of
   `lost_facts?/2`) use the prover; the proof support goes into the C as a
   marker for `fixed_indices?/3`. Acceptance: the generated C of every test
   kernel and example is byte-identical before and after (a dump-all-C
   switch for the comparison), and the compile time of the suite within 5%.
   This is the risky ticket; it is also the one that keeps the later ones
   small. *Landed as `defk-u1u` (2026-10-17): the representation and the
   prover live in `Defk.Facts`; today's only atoms are array lengths, whose
   facts sit on the array bindings, so `env.facts` and the support marker
   wait for the first scalar source (step 2); the strip record already
   carries each proof's support. The compiler states facts through
   `len_value`, `len_from`, `len_like`, `len_facts_of` and `between`.
   `with_acc_facts/2` keeps `covers?/2`, which compares bounds of the same
   shape; the prover takes it over when bounds of other shapes can imply
   one (step 2). Gate: byte-identical over 101 files.*
2. **Linear sources (defk-pic, defk-siy loop 1).** Exact `eq` forms
   through `+`, `-`, `*` by atoms and literals; `min`/`max` bounds from
   `eq`; range counters bounded by the start and end forms (both step
   signs); `alloc` and copy length equality; joins of `if`/`cond`/`case`
   values. Done when pic and siy loop 1 compile without checks (both
   modes), with soundness properties over random linear shapes.
   *Landed as `defk-qdz` (2026-10-17). An i64 binding is the atom
   `{:var, c}`; a value records `eq`, and an i64 value whose C is a C
   variable is that atom. Instead of `env.facts` keyed by monomial, the env
   keeps `atoms` (an i64 binding's facts by its C variable, set in
   `put_var/3` and for inlined parameters); array lengths are still found
   on the array bindings. `len_ubs` is new (`len(out) == n`). A case
   guard's checked arithmetic gives no `eq` (it flags and computes on).
   The strip classifier requires each proof's support to be fixed
   (`sr_fixed_indices?/2`). Not in it: `*` of two atoms (step 4), and
   `pcm_mix`'s sum loop keeps `bufs[j * m + i]` for that reason. Cost and
   counts: `docs/performance.md` 6.33.*
3. **Conditions and raising guards (defk-9za, defk-siy loop 2).** Narrowing
   in `if`/`cond` arms (statement and value), `for` filters and `and`;
   raising guards; non-empty ranges; the select rule; the exact-operand
   rule for flagged strips; the report's residual hint. Done when 9za's and
   siy loop 2's kernels (with `m >= 0`) are check-free and the report names
   `w >= 0` / `m >= 0` when the guard is missing.
   *Landed as `defk-b38` (2026-10-17). A comparison's bool value carries
   its relation (`Defk.Facts.relation/3`, from operands whose C calls no
   checked helper, judged before `in_order/3` may move one into a local);
   `Facts.holds/2` turns it into forms `D <= 0`, and `narrow/3` records
   each on its newest atom, in `env.atoms` and in the i64 or array binding,
   so a read of the binding sees it too. Arms see their condition and the
   earlier ones' negations (`lower_arms`, `branch_chain`, the statement
   `if`); a statement `if` one of whose arms raises (`raises?/1`) narrows
   the rest of the block. A plain variable read now also tries its own atom
   in `value_le`, as a newer atom's fact may name it (`length(x) >= k + 1`
   after `k < length(x)`). The select rule lowers each narrowed arm (and
   later condition) again in the branch's own env under `probe/1` and
   compares the C. In a case guard the right side of `and` is not narrowed:
   an overflowed left side may run it. The report's hint
   (`Facts.residual/5`) leaves out residuals reached through a limit no
   fact states (an i64 or length limit, a length >= 0), as "k <= -1" for
   `x[k]` was the usual result otherwise. `decode16` changed no check.
   Soundness: `test/condition_facts_test.exs`; cost: `docs/performance.md`
   6.34.*
4. **Degree-2 monomials (defk-n7k, `pcm_mix`).** Products of atoms in
   forms, the `div` rule with a symbolic divisor, equality guards with
   products, substitution into a product with a known-sign factor, the
   product's overflow check. Done when both n7k variants and the
   `pcm_mix` sum loop are check-free; measure `cosine_topk.exs` with a
   runtime `dim` and `pcm_mix.exs` (record in `docs/performance.md`).
   *Landed as `defk-pvt` (2026-10-18). A product is the monomial
   `{:mul, x, y}`, `x` the newer factor; it ranks with `x`, before `x`
   alone, so each replacement still leads to older monomials. A value's
   exact form is the operands' multiplied while of degree 2
   (`Facts.form_mul/2`). Product facts live on the newer factor's binding
   (`mubs`, `mlbs`: bounds on the binding times an older atom): the `div`
   rule puts `q * d <= x` there (`Facts.div_by_facts/2`, `x >= 0`; with
   `d >= 0` also `0 <= q <= x`, as a zero divisor raises), and a condition
   whose newest monomial is a product narrows it there. The prover's
   candidates for a product are its own bounds, then the newer factor's
   bounds (its exact form and stated constants included) times the older
   factor when that one's constant sign is known, a degree-2 bound of the
   newer factor left out. One rule changed: outside every loop a condition
   also narrows from checked operands, since no flagged strip runs there
   and a failed check raises, so the guard `length(m) == n * dim` (a
   checked product) states the shape. `pcm_mix`'s `j * m` keeps its
   overflow check (the outer body does not know `m >= 0`); the bounds
   checks go. Soundness: `test/product_facts_test.exs`; cost and
   measurements: `docs/performance.md` 6.36.*
5. **Later, only if wanted:** `rem` bounds, scalar accumulator invariants
   (assume, check each new value, retry), `case` guards. Not needed by the
   four tickets.

Interactions:

- **defk-fun** (ready for an agent) carries `len_lb` into reduce
  accumulators within today's representation. It is small and independent;
  doing it first gives the win now, and ticket 1 then re-expresses its
  implication check through the prover. If ticket 1 starts first, fold
  defk-fun into it.
- **defk-i5r** (unzeroed allocs) stays a syntactic shape analysis and does
  not depend on this. Its shape 3 is degree 3 and stays out here too. Later
  it could ask the prover "does this loop cover `0..len(x) - 1`" (both
  bounds, so an equality), which would accept equivalent spellings such as
  `alloc(e, n)` with a loop to `len(out) - 1`.
- **defk-5qk** (strip-assigned fixed indices in flagged strips): with
  relational facts, a fixed index's proof may substitute atoms that are not
  in its text. Ticket 1's support marker lets `fixed_indices?/3` require
  the support to be fixed too. Whichever of 5qk and ticket 3 lands second
  checks this interaction with a test (a guard on a strip-assigned value
  must not make a flagged access fixed).

## 9. Open questions for the maintainer

Answered 2026-10-12 (grilling of defk-2mz; recorded in ADR-0007): migrate
first; degree 2 in, as step 4; raising guards recommended, with the docs and
the `decode16` rewrite in step 3; the report hint wanted; budgets measured in
step 1 within 5% more compiler time. defk-fun lands before step 1. Step 5
is not filed until a workload needs it.

1. **Migrate first or add beside?** Ticket 1 moves today's facts onto the
   new representation before adding anything, with a byte-identical C
   check. The alternative adds forms beside `lb`/`ub` (prover as a
   fallback) and deletes the old facts last: earlier wins, two
   representations for a while. Recommended: migrate first.
2. **Degree 2 in or out?** Products (ticket 4) are what n7k and the real
   `pcm_mix` loop need, and they cost one more case in the prover. Leaving
   them out keeps the representation linear and leaves n7k with the literal
   `@dim` workaround.
3. **Raising guards as the way to state preconditions.** The design makes
   `if w < 1, do: raise ArgumentError, "..."` the idiom for facts about
   arguments. Should `docs/language.md` recommend it (and should
   `decode16`'s `alloc(u8, -1)` trick become one)?
4. **The report hint** (`it would follow from w >= 0`): wanted, or is the
   plain "nothing proves" enough?
5. **Budget and caps:** 64 steps per query and four bounds per atom are
   guesses that cover the repros with room; ticket 1 should measure them on
   the examples before fixing them.
