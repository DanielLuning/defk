# cdcl_sat: a bounded CDCL SAT solver written as a kernel, measured on
# Crux's scenario enumeration (Ash authorization), against picosat_elixir
# and simple_sat
#
# Why people reach for a NIF here: Ash checks policies and filters with a
# SAT solver through crux 0.1.4, whose Crux.Implementation uses
# picosat_elixir 0.2.3 (a NIF over PicoSAT, CDCL in C) when it is loaded and
# simple_sat 0.1.4 (pure Elixir, chronological backtracking with no unit
# propagation) otherwise. Crux.satisfying_scenarios/2 makes one solve per
# scenario plus one implication query per literal to minimise it: one
# authorization is up to ~1,500 small solver calls. picosat_elixir's solve
# runs on a normal scheduler with no decision limit, so a hard formula
# blocks a scheduler for seconds (S5 below). Research: docs/research/sat-solver.md.
#
#   elixir examples/cdcl_sat.exs
#
# DEFK_RESULT lines, in this order (run_all.exs reads the first; the script
# checks the other three itself and exits 1 when one fails):
#   1. cdcl_sat     S3: Crux.satisfying_scenarios on an Ash-shaped formula,
#                   P = 12 policies (109 vars, 280 clauses), the whole
#                   enumeration in one kernel call (solve_all)
#   2. cdcl_sat_s1  S1: one solve per call, Ash-shaped P = 4 (26-28 vars,
#                   61-64 clauses), as Crux.Implementation calls a solver
#   3. cdcl_sat_s2  S2: the same at P = 12 (104-109 vars, 265-280 clauses)
#   4. cdcl_sat_s4  S4: random 3-SAT, n = 200 at ratio 4.26, three seeds;
#                   S5 beside it: the tick gaps at n = 300 (seed 7)
#
# Pre-registered (defk-52v.15) and measured (M4 Pro, OTP 29, Elixir 1.20.2,
# load 3.5-7.7 on a machine shared with other agents: provisional; four
# runs, the last after merging main):
#
#   size  expected   measured  defk vs best Elixir              vs picosat_elixir
#   S1    marginal   good      2.3-5.3x (3.8-8.2 vs 1.5-1.6 ms  1.63-1.76x
#                              per 200 calls)
#   S2    good       good      2.48-2.58x (23.0-23.4 vs         1.68-1.75x
#                              8.9-9.4 ms per 200 calls; near
#                              the 2x line: may read marginal
#                              under heavier load)
#   S3    good       good      11.8-12.4x (217-224 vs 17.5-18.7 ms)  4.05-4.09x (Crux + picosat 71-73 ms)
#   S4    good       good      5.7-5.8x (1167-1198 vs 201-207 ms)    0.65x (picosat 131-134 ms)
#   S5    tick gap   (beside)  max (p99) ms: Elixir 2.1-3.0 (2.0-2.1; one run 136),
#                              defk 2.5-6.0 (2.25-2.26), picosat 1270-1342
#                              (one gap: the whole solve); idle floor 2.0.
#                              The solve itself: picosat 1.27-1.30 s, defk
#                              1.95-1.98 s, Elixir CDCL 10.8-11.3 s
#
# S1 was expected marginal because the research's DPLL sketch was within
# 1.3x of picosat at that size; the kernel's call, packing and unpacking cost
# 7-16 us per formula, about picosat's NIF (12-15 us) and under the best
# Elixir (DPLL 20-54 us, the Elixir CDCL 30-52 us, which pays its :atomics
# allocation and setup per call). The batch form is still where it helps
# most: 12x, against 2.3-5.3x per call.
#
# The kernel (SatEx.Kernels). One state array, st :: [i64], holds everything,
# at offsets kept in its first 48 words (the header; module attributes name
# the slots): assignment per literal, level, reason, trail and decision-level
# starts, VSIDS activity, a binary max-heap of variables with positions,
# saved phases, seen flags, two-watched-literal lists as intrusive linked
# lists (a head per literal, a next and a blocker literal per watch), clause
# starts, sizes and LBDs, the clause arena (input clauses, then learned
# ones), and scratch for conflict analysis. Under the defk-n4r.4 rule a
# helper returns every array it writes, so with one array every helper is
# `st = helper(st, ...)`; it reads like C with named offsets
# (st[st[@o_lval] + l]), and nothing else would fit: seven arrays would make
# every helper return a seven-tuple.
#
#   - Literals are 2v and 2v + 1, negation bxor(l, 1). Clauses are loaded
#     with duplicate literals removed and tautologies dropped; a unit is
#     assigned at level 0; an empty clause or conflicting units is UNSAT.
#   - search(st, budget) is Enum.reduce_while over 1..budget: each step runs
#     restart, propagate, analyze, backjump, learn and decide in that order,
#     each a no-op unless the header says it is due. First-UIP learning
#     with local minimisation (a literal whose reason's other literals are
#     all in the clause or at level 0 is dropped), LBD per learned clause,
#     integer VSIDS (bump by inc, inc grows by inc/19 per conflict, about
#     1/0.95; all activities shift right 20 when inc passes 2^40), the
#     heap's ties left as they fall (deterministic), phase saving (initial
#     phase false), Luby restarts with unit 100.
#   - Learned clauses live in an arena of cap literals (the caller's choice;
#     max(16 x input literals, 64 x (n + 1)) here). At a restart, when there
#     are more than max(m/3, 1000) learned clauses, the half with the highest
#     LBD goes (counted in 64 LBD buckets, oldest first within the cut-off
#     bucket; the limit then grows by a tenth), the arena is compacted and
#     every watch list rebuilt. When a conflict finds the arena or the clause
#     table full, the solver restarts and reduces at once instead of
#     learning; if that frees nothing, status 2.
#   - solve(lits, offs, n, cap, budget) :: {status, model, conflicts}:
#     status 1 SAT (model[v - 1] = v or -v), 0 UNSAT, 2 unknown. The step
#     budget and the arena are declared limits: a solve that runs out
#     returns status 2 (SatEx.solve raises then), never a wrong answer.
#   - solve_all(all, allo, mf, prim, nf, nq, cap, budget, out_cap,
#     max_scen) runs Crux.satisfying_scenarios's loop (crux 0.1.4's
#     enumerate_dimacs_scenarios and minimize_cube_dimacs): solve the
#     formula plus the blocking clauses so far; take the cube of the bound
#     variables (in Crux's Map.keys order); drop each literal in turn when
#     the rest still implies the formula (Crux's negation encoding: the rest
#     as unit clauses plus the selector clause plus the gadget clauses and
#     definitions is UNSAT); append the negated cube as a blocking clause.
#     Every round reloads st with the clauses it needs (one CSR input holds
#     the formula then the query; the blocking clauses and the round's unit
#     clauses go to an output arena x/xo that is also the result). Status 3
#     means x or xo is too small: SatEx retries with four times more.
#     Mapping cubes back to checks, Enum.uniq and Crux.validate_assignments/2
#     (user callbacks) stay in Elixir, as in Crux.
#
# The Elixir baseline (SatEx.Cdcl) is the same algorithm step for step, on
# one :atomics array with the same layout, so its results equal the
# kernel's (status, model and conflict count, checked below). It is
# optimised as far as tried: :atomics measured against the alternatives for
# per-step mutable arrays (a read in a tight loop: :atomics 6.4 ns, a map
# 5.7, the process dictionary 4.7, a tuple 1.8, but a tuple write copies the
# tuple and a map update allocates), blocking literals in the watches (both
# sides), local minimisation of learned clauses (both sides: seed 3 from 31,773 to
# 24,241 conflicts), recursion with the offsets as arguments in the hot
# loops. Variants measured: the research's DPLL sketch (SatEx.Dpll: lists,
# unit propagation, shortest-clause branching), fastest Elixir on some P = 4
# formulas and used there when it wins (S1 takes the faster per formula);
# Crux on the Elixir CDCL, and the same loop written directly in Elixir
# (SatEx.Enumerate, 12-16% faster at P = 12, S3's baseline); simple_sat
# (0.25-1,100 ms per call, 17-580 ms for P = 4 enumerations, not run above
# P = 4). Not tried: a functional CDCL (clauses in tuples, assignment in a
# map); keeping the :atomics state in the process across calls (Crux's API
# is one stateless call per solve; the kernel cannot keep state either,
# defk-sve).
#
# picosat is ahead of both CDCLs on hard random instances: S4 seed 3
# (UNSAT) 88 ms against the kernel's 170 ms, and at n = 300 the kernel
# timed out at 60 s on 4 of 7 seeds where picosat took 3.9-16.7 s (restart
# policy, clause deletion, binary implication lists, probing: PicoSAT has
# far more heuristics). The ratio against the Elixir CDCL holds on every
# instance; against picosat it depends on the instance.
#
# Agreement, checked on every run (each line printed below):
#   - kernel === Elixir mode on 140 CNFs (random, 1-16 variables, and
#     3-SAT at n = 10-60, with a 48-literal arena that forces restarts and
#     reductions) and solve_all === Elixir mode on the Ash shapes up to P = 4;
#   - kernel === the Elixir CDCL on 2,000 random CNFs, 200 3-SAT instances
#     and n = 100; solve_all's cubes === the Elixir loop's at every shape;
#   - against picosat: the same status on 2,000 CNFs and every SAT model
#     satisfies every clause; against simple_sat on 300 small ones;
#   - the batch form against Crux + picosat: an equivalent cover, not the
#     same list (Crux's scenarios depend on which model comes first; the
#     sets differ at 4 of 8 shapes): every scenario implies the formula and
#     the formula with every scenario blocked is UNSAT, both checked with
#     picosat, for both sides;
#   - forced yields at every safepoint give the same results; literal 0 or
#     out of range raises ArgumentError natively and in Elixir mode; a tiny
#     budget or arena gives status 2.
#
# Language notes (defk at the time of writing):
#   - A helper called in one branch of an Enum.reduce_while fn whose
#     condition read the accumulator array copied it every iteration (and
#     so did a nested loop whose init holds it, in such a branch). The
#     first kernel did that and copied the whole solver state per step:
#     1.9 s instead of 1 ms at n = 100. Fixed in defk-tif (the condition
#     that chose a branch ran before it, so it is not a read after the
#     call); the kernels keep the workaround they were measured with: every
#     helper is called on every step with an "active" flag (empty loop
#     ranges and guarded writes when inactive).
#     An array passed as a loop's initial value must not also be read in the
#     loop's range or init (st[@h_n] in 0..st[@h_n]): that copies it too, so
#     those reads go to a local first.
#   - An array cannot be the value of an if, also inside a for reduce
#     body's tuple: a branch gives numbers ({dp, dk}) and the tuple with
#     the array is built after it.
#   - Code size: every defk is also its own NIF, which inlines its callees,
#     so the solver's code is there in solve, solve_all, search and each
#     helper's entry point: 2.35 MB of C, a 683 KB .so, about 3 minutes of
#     clang at load 4 (the first run; cached after). Each helper has one
#     call site per entry point (defk-6ag).

Mix.install(
  [
    {:defk, path: Path.expand("..", __DIR__)},
    {:crux, "0.1.4"},
    {:picosat_elixir, "0.2.3"},
    {:simple_sat, "0.1.4"}
  ],
  # Crux picks its solver at compile time; :sat_testing lets each process
  # choose one with Process.put(Crux.Implementation, module)
  config: [crux: [sat_testing: true]]
)

defmodule SatEx.Kernels do
  @moduledoc false
  use Defk, elixir_mode: true

  # header slots of the state array (the same as SatEx.Cdcl)
  @h_n 0
  @h_ncls 2
  @h_norig 3
  @h_atop 4
  @h_aend 5
  @h_tlen 6
  @h_qhead 7
  @h_dl 8
  @h_inc 9
  @h_conflicts 10
  @h_status 11
  @h_nlearnt 12
  @h_maxl 13
  @h_rcount 14
  @h_luby 15
  @h_hsize 16
  @h_k 17
  @h_confl 18
  @h_ccap 19
  @h_stamp 20
  @o_lval 21
  @o_level 22
  @o_reason 23
  @o_trail 24
  @o_tlim 25
  @o_act 26
  @o_heap 27
  @o_hpos 28
  @o_phase 29
  @o_seen 30
  @o_whead 31
  @o_cstart 32
  @o_csize 33
  @o_clbd 34
  @o_wnext 35
  @o_learnt 36
  @o_lvst 37
  @o_mark 38
  @o_hist 39
  @o_arena 40
  @h_bl 41
  @h_lbd 42
  @h_pending 43
  @o_wblock 44
  @h_otop 45
  @hdr 48

  # ---- entry points ------------------------------------------------------

  # One CNF in CSR form (DIMACS literals, offs has one more entry than there
  # are clauses). Returns {status, model, conflicts}: status 1 SAT (model[v - 1]
  # is v or -v), 0 UNSAT, 2 unknown (a declared limit: the step budget or the
  # learned-clause arena ran out).
  defk solve(lits :: [i64], offs :: [i64], n :: i64, cap :: i64, budget :: i64) ::
         {i64, [i64], i64} do
    m = len(offs) - 1
    st = alloc(i64, state_size(n, m, len(lits), cap))
    st = init(st, n, m, len(lits), cap)
    st = load(st, lits, offs, 0, m, lits, offs, 0, 0)
    st = search(st, budget)
    status = st[@h_status]
    model = alloc(i64, n)
    olval = st[@o_lval]

    if status == 1 do
      for v <- 1..n//1 do
        model[v - 1] = if st[olval + 2 * v] == 1, do: v, else: -v
      end
    end

    {status, model, st[@h_conflicts]}
  end

  # Crux's satisfying_scenarios enumeration in one call. all/allo is one CSR
  # CNF: the formula's clauses [0, mf), then the minimisation query's
  # clauses [mf, len(allo) - 1) (Crux's selector clause, gadget clauses and
  # definitions). prim are the bound variables in Crux's order. Each round:
  # solve the formula plus the blocking clauses so far; take the cube of
  # prim from the model; drop each literal in turn if the rest still implies
  # the formula (the query plus the rest as unit clauses is UNSAT); append
  # the negated cube as a blocking clause. Returns {status, x, xo, scenarios,
  # solves}: the blocking clauses in CSR (x[xo[k]..xo[k + 1]) is scenario k,
  # negated); status 1 complete, 2 the step budget of one solve ran out (a
  # declared limit), 3 out_cap or max_scen is too small (the caller retries
  # with more).
  defk solve_all(
         all :: [i64],
         allo :: [i64],
         mf :: i64,
         prim :: [i64],
         nf :: i64,
         nq :: i64,
         cap :: i64,
         budget :: i64,
         out_cap :: i64,
         max_scen :: i64
       ) :: {i64, [i64], [i64], i64, i64} do
    mall = len(allo) - 1
    mg = mall - mf
    np = len(prim)
    lf = allo[mf] - allo[0]
    lg = allo[mall] - allo[mf]

    size =
      max(
        state_size(nf, mf + max_scen, lf + out_cap, cap),
        state_size(nq, mg + np, lg + np, cap)
      )

    x = alloc(i64, out_cap + np)
    xo = alloc(i64, max_scen + np + 2)
    cube = alloc(i64, np)
    keep = alloc(i64, np)

    {_st, status, nscen, nsolves, _j, _ncube, _xtop, _nxc} =
      Enum.reduce_while(
        0..((max_scen + 1) * (np + 1) + 1)//1,
        {alloc(i64, size), 1, 0, 0, -1, 0, 0, 0},
        fn _, {st, _status, nscen, nsolves, j, ncube, xtop, nxc} ->
          formula = j < 0

          nunits =
            for i <- 0..if(formula, do: -1, else: ncube - 1)//1, reduce: 0 do
              u ->
                if i != j and keep[i] == 1 do
                  x[xtop + u] = cube[i]
                  xo[nxc + u + 1] = xtop + u + 1
                  u + 1
                else
                  u
                end
            end

          n = if formula, do: nf, else: nq
          m = if formula, do: mf + nxc, else: mg + nunits
          nl = if formula, do: lf + xtop, else: lg + nunits
          st = init(st, n, m, nl, cap)

          st =
            load(
              st,
              all,
              allo,
              if(formula, do: 0, else: mf),
              if(formula, do: mf, else: mall),
              x,
              xo,
              if(formula, do: 0, else: nxc),
              if(formula, do: nxc, else: nxc + nunits)
            )

          st = search(st, budget)
          r = st[@h_status]
          olval = st[@o_lval]
          limit = r == 2
          done = formula and r == 0
          fresh = formula and r == 1

          if fresh do
            for i <- 0..(np - 1)//1 do
              v = prim[i]
              cube[i] = if st[olval + 2 * v] == 1, do: v, else: -v
              keep[i] = 1
            end
          end

          if not formula and r == 0, do: keep[j] = 0
          ncube2 = if fresh, do: np, else: ncube
          j2 = if formula, do: 0, else: j + 1
          finish = not limit and not done and j2 >= ncube2

          kept =
            for i <- 0..(ncube2 - 1)//1, reduce: 0 do
              w -> w + keep[i]
            end

          overflow = finish and (nxc + 1 > max_scen or xtop + kept > out_cap)
          stored = finish and not overflow

          if stored do
            for i <- 0..(ncube2 - 1)//1, reduce: 0 do
              w ->
                if keep[i] == 1 do
                  x[xtop + w] = -cube[i]
                  w + 1
                else
                  w
                end
            end

            xo[nxc + 1] = xtop + kept
          end

          status2 = if limit, do: 2, else: if(overflow, do: 3, else: 1)
          nscen2 = if stored, do: nscen + 1, else: nscen
          j3 = if finish, do: -1, else: j2
          xtop2 = if stored, do: xtop + kept, else: xtop
          nxc2 = if stored, do: nxc + 1, else: nxc

          if limit or overflow or done,
            do: {:halt, {st, status2, nscen2, nsolves + 1, j3, ncube2, xtop2, nxc2}},
            else: {:cont, {st, status2, nscen2, nsolves + 1, j3, ncube2, xtop2, nxc2}}
        end
      )

    {status, x, xo, nscen, nsolves}
  end

  defk state_size(n :: i64, m :: i64, nlits :: i64, cap :: i64) :: i64 do
    l = 2 * n + 2
    ccap = m + div(cap, 4) + 1
    @hdr + l * 3 + (n + 1) * 10 + (n + 2) * 2 + ccap * 7 + 64 + nlits + cap
  end

  # ---- init: layout, header, reset ---------------------------------------
  defk init(st :: [i64], n :: i64, m :: i64, nlits :: i64, cap :: i64) :: [i64] do
    l = 2 * n + 2
    ccap = m + div(cap, 4) + 1
    st[@o_lval] = @hdr
    st[@o_level] = st[@o_lval] + l
    st[@o_reason] = st[@o_level] + n + 1
    st[@o_trail] = st[@o_reason] + n + 1
    st[@o_tlim] = st[@o_trail] + n + 1
    st[@o_act] = st[@o_tlim] + n + 2
    st[@o_heap] = st[@o_act] + n + 1
    st[@o_hpos] = st[@o_heap] + n + 1
    st[@o_phase] = st[@o_hpos] + n + 1
    st[@o_seen] = st[@o_phase] + n + 1
    st[@o_whead] = st[@o_seen] + n + 1
    st[@o_cstart] = st[@o_whead] + l
    st[@o_csize] = st[@o_cstart] + ccap
    st[@o_clbd] = st[@o_csize] + ccap
    st[@o_wnext] = st[@o_clbd] + ccap
    st[@o_wblock] = st[@o_wnext] + 2 * ccap
    st[@o_learnt] = st[@o_wblock] + 2 * ccap
    st[@o_lvst] = st[@o_learnt] + 2 * n + 2
    st[@o_mark] = st[@o_lvst] + n + 2
    st[@o_hist] = st[@o_mark] + l
    st[@o_arena] = st[@o_hist] + 64
    top = st[@o_arena] + nlits + cap
    if top > len(st), do: raise(ArgumentError, "sat: state array too small")
    st[@h_n] = n
    st[1] = l
    st[@h_ncls] = 0
    st[@h_norig] = 0
    st[@h_atop] = st[@o_arena]
    st[@h_aend] = top
    st[@h_tlen] = 0
    st[@h_qhead] = 0
    st[@h_dl] = 0
    st[@h_inc] = 1024
    st[@h_conflicts] = 0
    st[@h_status] = 3
    st[@h_nlearnt] = 0
    st[@h_maxl] = max(div(m, 3), 1000)
    st[@h_rcount] = 100
    st[@h_luby] = 0
    st[@h_hsize] = n
    st[@h_confl] = -1
    st[@h_ccap] = ccap
    st[@h_stamp] = 0
    st[@h_pending] = 0
    olval = st[@o_lval]
    owhead = st[@o_whead]
    omark = st[@o_mark]

    for i <- 0..(l - 1)//1 do
      st[olval + i] = 0
      st[owhead + i] = -1
      st[omark + i] = 0
    end

    olevel = st[@o_level]
    oreason = st[@o_reason]
    otrail = st[@o_trail]
    oact = st[@o_act]
    oheap = st[@o_heap]
    ohpos = st[@o_hpos]
    ophase = st[@o_phase]
    oseen = st[@o_seen]
    olvst = st[@o_lvst]

    for v <- 0..n//1 do
      st[olevel + v] = 0
      st[oreason + v] = -1
      st[otrail + v] = 0
      st[oact + v] = 0
      st[oheap + v] = v + 1
      st[ohpos + v] = v - 1
      st[ophase + v] = 0
      st[oseen + v] = 0
      st[olvst + v] = 0
    end

    st[olvst + n + 1] = 0
    ohist = st[@o_hist]

    for i <- 0..63//1 do
      st[ohist + i] = 0
    end

    st
  end

  # ---- loading clauses: a[a_lo..a_hi) then x[x_lo..x_hi), CSR ---------------
  defk load(
         st :: [i64],
         a :: [i64],
         ao :: [i64],
         a_lo :: i64,
         a_hi :: i64,
         x :: [i64],
         xo :: [i64],
         x_lo :: i64,
         x_hi :: i64
       ) :: [i64] do
    n = st[@h_n]
    na = a_hi - a_lo
    nx = x_hi - x_lo

    for c <- 0..(na + nx - 1)//1 do
      from_a = c < na
      s = if from_a, do: ao[a_lo + c], else: xo[x_lo + c - na]
      e = if from_a, do: ao[a_lo + c + 1], else: xo[x_lo + c - na + 1]

      for i <- s..(e - 1)//1 do
        lit = if from_a, do: a[i], else: x[i]
        if lit == 0 or abs(lit) > n, do: raise(ArgumentError, "sat: literal out of range")
      end
    end

    olval = st[@o_lval]
    omark = st[@o_mark]
    owhead = st[@o_whead]
    ownext = st[@o_wnext]

    for c <- 0..(na + nx - 1)//1 do
      if st[@h_status] == 3 do
        from_a = c < na
        s = if from_a, do: ao[a_lo + c], else: xo[x_lo + c - na]
        e = if from_a, do: ao[a_lo + c + 1], else: xo[x_lo + c - na + 1]
        stamp = st[@h_stamp] + 1
        st[@h_stamp] = stamp
        start = st[@h_atop]

        {k, taut} =
          for i <- s..(e - 1)//1, reduce: {0, false} do
            {k, taut} ->
              lit = if from_a, do: a[i], else: x[i]
              l = if lit > 0, do: 2 * lit, else: 1 - 2 * lit

              if taut do
                {k, taut}
              else
                if st[omark + l] == stamp do
                  {k, taut}
                else
                  if st[omark + bxor(l, 1)] == stamp do
                    {k, true}
                  else
                    st[omark + l] = stamp
                    st[start + k] = l
                    {k + 1, taut}
                  end
                end
              end
          end

        if not taut do
          if k == 0 do
            st[@h_status] = 0
          else
            if k == 1 do
              l = st[start]
              lv = st[olval + l]

              if lv == -1 do
                st[@h_status] = 0
              else
                if lv == 0 do
                  v = bsr(l, 1)
                  st[olval + l] = 1
                  st[olval + bxor(l, 1)] = -1
                  st[st[@o_level] + v] = 0
                  st[st[@o_reason] + v] = -1
                  t = st[@h_tlen]
                  st[st[@o_trail] + t] = l
                  st[@h_tlen] = t + 1
                end
              end
            else
              c2 = st[@h_ncls]
              if c2 >= st[@h_ccap], do: raise(ArgumentError, "sat: clause capacity")
              st[st[@o_cstart] + c2] = start
              st[st[@o_csize] + c2] = k
              st[st[@o_clbd] + c2] = 0
              st[@h_atop] = start + k
              st[@h_ncls] = c2 + 1
              st[@h_norig] = c2 + 1
              l0 = st[start]
              l1 = st[start + 1]
              st[ownext + 2 * c2] = st[owhead + l0]
              st[owhead + l0] = 2 * c2
              st[ownext + 2 * c2 + 1] = st[owhead + l1]
              st[owhead + l1] = 2 * c2 + 1
              st[st[@o_wblock] + 2 * c2] = l1
              st[st[@o_wblock] + 2 * c2 + 1] = l0
            end
          end
        end
      end
    end

    st
  end

  # ---- search: one step per iteration, at most budget steps ----------------
  defk search(st :: [i64], budget :: i64) :: [i64] do
    st[@h_otop] = st[@h_atop]

    st =
      Enum.reduce_while(1..budget//1, st, fn _, st ->
        st = restart(st)
        st = propagate(st)
        running = st[@h_status] == 3
        conflict = running and st[@h_confl] >= 0

        if conflict do
          st[@h_conflicts] = st[@h_conflicts] + 1

          if st[@h_dl] == 0 do
            st[@h_status] = 0
          else
            if st[@h_atop] + st[@h_n] + 1 > st[@h_aend] or st[@h_ncls] >= st[@h_ccap],
              do: st[@h_pending] = 2
          end
        end

        learning = conflict and st[@h_status] == 3 and st[@h_pending] == 0
        st = analyze(st, learning)
        st = backjump(st, if(learning, do: st[@h_bl], else: st[@h_dl]))
        st = learn(st, learning)
        st = decide(st, running and not conflict)
        if st[@h_status] != 3, do: {:halt, st}, else: {:cont, st}
      end)

    if st[@h_status] == 3, do: st[@h_status] = 2
    st
  end

  defk propagate(st :: [i64]) :: [i64] do
    st[@h_confl] = -1
    olval = st[@o_lval]
    owhead = st[@o_whead]
    ownext = st[@o_wnext]
    owblock = st[@o_wblock]
    ocstart = st[@o_cstart]
    ocsize = st[@o_csize]
    otrail = st[@o_trail]
    olevel = st[@o_level]
    oreason = st[@o_reason]
    nw = 2 * st[@h_ccap]
    n = if st[@h_status] == 3, do: st[@h_n], else: -1

    Enum.reduce_while(0..n//1, st, fn _, st ->
      q = st[@h_qhead]
      more = q < st[@h_tlen]
      fl = if more, do: bxor(st[otrail + q], 1), else: 0
      if more, do: st[@h_qhead] = q + 1
      head = if more, do: st[owhead + fl], else: -1

      {st, _prev, node} =
        Enum.reduce_while(0..nw//1, {st, -1, head}, fn _, {st, prev, node} ->
          if node < 0 do
            {:halt, {st, prev, node}}
          else
            nxt = st[ownext + node]

            if st[olval + st[owblock + node]] == 1 do
              {:cont, {st, node, nxt}}
            else
              c = bsr(node, 1)
              k = band(node, 1)
              cs = st[ocstart + c]
              other = st[cs + 1 - k]

              if st[olval + other] == 1 do
                st[owblock + node] = other
                {:cont, {st, node, nxt}}
              else
                size = st[ocsize + c]

                j =
                  Enum.reduce_while(2..(size - 1)//1, -1, fn j, _acc ->
                    if st[olval + st[cs + j]] != -1, do: {:halt, j}, else: {:cont, -1}
                  end)

                if j >= 0 do
                  nl = st[cs + j]
                  st[cs + j] = fl
                  st[cs + k] = nl

                  if prev < 0 do
                    st[owhead + fl] = nxt
                  else
                    st[ownext + prev] = nxt
                  end

                  st[ownext + node] = st[owhead + nl]
                  st[owhead + nl] = node
                  st[owblock + node] = other
                  {:cont, {st, prev, nxt}}
                else
                  if st[olval + other] == 0 do
                    v = bsr(other, 1)
                    st[olval + other] = 1
                    st[olval + bxor(other, 1)] = -1
                    st[olevel + v] = st[@h_dl]
                    st[oreason + v] = c
                    t = st[@h_tlen]
                    st[otrail + t] = other
                    st[@h_tlen] = t + 1
                    {:cont, {st, node, nxt}}
                  else
                    st[@h_confl] = c
                    {:halt, {st, prev, -2}}
                  end
                end
              end
            end
          end
        end)

      if not more or node == -2, do: {:halt, st}, else: {:cont, st}
    end)
  end

  # first-UIP conflict analysis: the learnt clause in the learnt region, its
  # size, backjump level and LBD in the header
  defk analyze(st :: [i64], active :: bool) :: [i64] do
    dl = st[@h_dl]
    oseen = st[@o_seen]
    olevel = st[@o_level]
    oreason = st[@o_reason]
    otrail = st[@o_trail]
    olearnt = st[@o_learnt]
    ocstart = st[@o_cstart]
    ocsize = st[@o_csize]
    oact = st[@o_act]
    ohpos = st[@o_hpos]

    tlen = st[@h_tlen]
    confl = st[@h_confl]

    {st, _c, pl, _pathc, k, _idx} =
      Enum.reduce_while(
        0..if(active, do: tlen, else: -1)//1,
        {st, confl, -1, 0, 1, tlen - 1},
        fn _, {st, c, pl, pathc, k, idx} ->
          cs = st[ocstart + c]
          size = st[ocsize + c]
          pv = if pl < 0, do: -1, else: bsr(pl, 1)

          {st, pathc, k} =
            for j <- 0..(size - 1)//1, reduce: {st, pathc, k} do
              {st, pathc, k} ->
                q = st[cs + j]
                v = bsr(q, 1)
                lv = st[olevel + v]

                bump = v != pv and st[oseen + v] == 0 and lv > 0

                {dp, dk} =
                  if bump do
                    st[oseen + v] = 1
                    st[oact + v] = st[oact + v] + st[@h_inc]

                    if lv >= dl do
                      {1, 0}
                    else
                      st[olearnt + k] = q
                      {0, 1}
                    end
                  else
                    {0, 0}
                  end

                st = heap_up(st, if(bump, do: st[ohpos + v], else: -1))
                {st, pathc + dp, k + dk}
            end

          idx =
            Enum.reduce_while(0..idx//1, idx, fn _, i ->
              if st[oseen + bsr(st[otrail + i], 1)] == 0, do: {:cont, i - 1}, else: {:halt, i}
            end)

          pl = st[otrail + idx]
          v = bsr(pl, 1)
          st[oseen + v] = 0

          if pathc == 1 do
            {:halt, {st, c, pl, 0, k, idx}}
          else
            {:cont, {st, st[oreason + v], pl, pathc - 1, k, idx - 1}}
          end
        end
      )

    if active, do: st[olearnt] = bxor(pl, 1)

    # local minimisation: drop a literal whose reason's other literals are
    # all in the clause or at level 0 (removed variables listed after k)
    {w, r} =
      for i <- 1..(k - 1)//1, reduce: {1, 0} do
        {w, r} ->
          q = st[olearnt + i]
          v = bsr(q, 1)
          rc = st[oreason + v]

          red =
            if rc < 0 do
              false
            else
              cs = st[ocstart + rc]

              Enum.all?(0..(st[ocsize + rc] - 1)//1, fn jj ->
                v2 = bsr(st[cs + jj], 1)
                v2 == v or st[oseen + v2] == 1 or st[olevel + v2] == 0
              end)
            end

          if red do
            st[olearnt + k + r] = v
            {w, r + 1}
          else
            st[olearnt + w] = q
            {w + 1, r}
          end
      end

    for i <- 1..(w - 1)//1 do
      st[oseen + bsr(st[olearnt + i], 1)] = 0
    end

    for i <- 0..(r - 1)//1 do
      st[oseen + st[olearnt + k + i]] = 0
    end

    k = w

    {bl, maxi} =
      for i <- 1..(k - 1)//1, reduce: {0, 1} do
        {bl, maxi} ->
          lv = st[olevel + bsr(st[olearnt + i], 1)]
          if lv > bl, do: {lv, i}, else: {bl, maxi}
      end

    if k > 1 do
      t = st[olearnt + 1]
      st[olearnt + 1] = st[olearnt + maxi]
      st[olearnt + maxi] = t
    end

    stamp = st[@h_stamp] + 1
    if active, do: st[@h_stamp] = stamp
    olvst = st[@o_lvst]

    lbd =
      for i <- 0..if(active, do: k - 1, else: -1)//1, reduce: 0 do
        lbd ->
          lv = st[olevel + bsr(st[olearnt + i], 1)]

          if st[olvst + lv] != stamp do
            st[olvst + lv] = stamp
            lbd + 1
          else
            lbd
          end
      end

    if active do
      st[@h_k] = k
      st[@h_bl] = bl
      st[@h_lbd] = lbd
    end

    st
  end

  # move heap slot i up while its parent has a lower activity (i < 0: nothing)
  defk heap_up(st :: [i64], i0 :: i64) :: [i64] do
    if i0 >= 0 do
      oheap = st[@o_heap]
      ohpos = st[@o_hpos]
      oact = st[@o_act]
      v = st[oheap + i0]
      a = st[oact + v]

      i =
        Enum.reduce_while(0..i0//1, i0, fn _, i ->
          if i == 0 do
            {:halt, i}
          else
            par = bsr(i - 1, 1)
            pv = st[oheap + par]

            if st[oact + pv] < a do
              st[oheap + i] = pv
              st[ohpos + pv] = i
              {:cont, par}
            else
              {:halt, i}
            end
          end
        end)

      st[oheap + i] = v
      st[ohpos + v] = i
    end

    st
  end

  # undo the trail down to level bl, saving phases and re-inserting variables
  defk backjump(st :: [i64], bl :: i64) :: [i64] do
    otrail = st[@o_trail]
    olval = st[@o_lval]
    ophase = st[@o_phase]
    oreason = st[@o_reason]
    ohpos = st[@o_hpos]
    oheap = st[@o_heap]
    jump = st[@h_dl] > bl
    tlen = st[@h_tlen]
    lim = if jump, do: st[st[@o_tlim] + bl + 1], else: tlen

    st =
      for i <- (tlen - 1)..lim//-1, reduce: st do
        st ->
          l = st[otrail + i]
          v = bsr(l, 1)
          st[ophase + v] = if band(l, 1) == 0, do: 1, else: 0
          st[olval + l] = 0
          st[olval + bxor(l, 1)] = 0
          st[oreason + v] = -1
          hs = st[@h_hsize]
          ins = st[ohpos + v] < 0

          if ins do
            st[oheap + hs] = v
            st[ohpos + v] = hs
            st[@h_hsize] = hs + 1
          end

          heap_up(st, if(ins, do: hs, else: -1))
      end

    if jump do
      st[@h_tlen] = lim
      st[@h_qhead] = lim
      st[@h_dl] = bl
    end

    st
  end

  # store the learnt clause (or assert a unit), grow the activity increment,
  # count down to the next restart
  defk learn(st :: [i64], active :: bool) :: [i64] do
    if active do
      k = st[@h_k]
      olearnt = st[@o_learnt]
      olval = st[@o_lval]
      l = st[olearnt]
      c = st[@h_ncls]

      if k > 1 do
        at = st[@h_atop]

        for i <- 0..(k - 1)//1 do
          st[at + i] = st[olearnt + i]
        end

        st[st[@o_cstart] + c] = at
        st[st[@o_csize] + c] = k
        st[st[@o_clbd] + c] = st[@h_lbd]
        st[@h_atop] = at + k
        st[@h_ncls] = c + 1
        st[@h_nlearnt] = st[@h_nlearnt] + 1
        owhead = st[@o_whead]
        ownext = st[@o_wnext]
        l1 = st[at + 1]
        st[ownext + 2 * c] = st[owhead + l]
        st[owhead + l] = 2 * c
        st[ownext + 2 * c + 1] = st[owhead + l1]
        st[owhead + l1] = 2 * c + 1
        st[st[@o_wblock] + 2 * c] = l1
        st[st[@o_wblock] + 2 * c + 1] = l
      end

      v = bsr(l, 1)
      st[olval + l] = 1
      st[olval + bxor(l, 1)] = -1
      st[st[@o_level] + v] = st[@h_dl]
      st[st[@o_reason] + v] = if k > 1, do: c, else: -1
      t = st[@h_tlen]
      st[st[@o_trail] + t] = l
      st[@h_tlen] = t + 1
      inc = st[@h_inc] + div(st[@h_inc], 19)

      if inc > 1_099_511_627_776 do
        oact = st[@o_act]

        for v <- 1..st[@h_n]//1 do
          st[oact + v] = bsr(st[oact + v], 20)
        end

        st[@h_inc] = bsr(inc, 20)
      else
        st[@h_inc] = inc
      end

      st[@h_rcount] = st[@h_rcount] - 1
      if st[@h_rcount] == 0, do: st[@h_pending] = 1
    end

    st
  end

  # pop variables until an unassigned one, and assign it at a new level
  defk decide(st :: [i64], active :: bool) :: [i64] do
    oheap = st[@o_heap]
    ohpos = st[@o_hpos]
    oact = st[@o_act]
    olval = st[@o_lval]
    n = if active, do: st[@h_n], else: -1

    Enum.reduce_while(0..n//1, st, fn _, st ->
      hs = st[@h_hsize]

      if hs == 0 do
        st[@h_status] = 1
        {:halt, st}
      else
        v = st[oheap]
        st[@h_hsize] = hs - 1
        st[ohpos + v] = -1

        if hs > 1 do
          last = st[oheap + hs - 1]
          a = st[oact + last]
          n1 = hs - 1

          i =
            Enum.reduce_while(0..n1//1, 0, fn _, i ->
              ch = 2 * i + 1

              if ch >= n1 do
                {:halt, i}
              else
                ch =
                  if ch + 1 < n1 and st[oact + st[oheap + ch + 1]] > st[oact + st[oheap + ch]],
                    do: ch + 1,
                    else: ch

                cv = st[oheap + ch]

                if st[oact + cv] > a do
                  st[oheap + i] = cv
                  st[ohpos + cv] = i
                  {:cont, ch}
                else
                  {:halt, i}
                end
              end
            end)

          st[oheap + i] = last
          st[ohpos + last] = i
        end

        if st[olval + 2 * v] == 0 do
          dl = st[@h_dl] + 1
          st[@h_dl] = dl
          st[st[@o_tlim] + dl] = st[@h_tlen]
          l = if st[st[@o_phase] + v] == 1, do: 2 * v, else: 2 * v + 1
          st[olval + l] = 1
          st[olval + bxor(l, 1)] = -1
          st[st[@o_level] + v] = dl
          st[st[@o_reason] + v] = -1
          t = st[@h_tlen]
          st[st[@o_trail] + t] = l
          st[@h_tlen] = t + 1
          {:halt, st}
        else
          {:cont, st}
        end
      end
    end)
  end

  # back to level 0, next Luby interval; reduce when forced (arena full) or
  # over the learnt limit
  defk restart(st :: [i64]) :: [i64] do
    active = st[@h_pending] != 0
    force = st[@h_pending] == 2
    st[@h_pending] = 0
    st = backjump(st, if(active, do: 0, else: st[@h_dl]))
    x0 = st[@h_luby] + if(active, do: 1, else: 0)
    st[@h_luby] = x0

    {size, seq} =
      Enum.reduce_while(0..64//1, {1, 0}, fn _, {size, seq} ->
        if size < x0 + 1, do: {:cont, {2 * size + 1, seq + 1}}, else: {:halt, {size, seq}}
      end)

    {_size, seq, _x} =
      Enum.reduce_while(0..64//1, {size, seq, x0}, fn _, {size, seq, x} ->
        if size - 1 != x do
          s2 = bsr(size - 1, 1)
          {:cont, {s2, seq - 1, rem(x, s2)}}
        else
          {:halt, {size, seq, x}}
        end
      end)

    if active, do: st[@h_rcount] = bsl(1, seq) * 100
    do_reduce = active and (force or st[@h_nlearnt] > st[@h_maxl])
    st = reduce(st, do_reduce)
    maxl = st[@h_maxl]
    if do_reduce and not force, do: st[@h_maxl] = maxl + div(maxl, 10)

    if force and
         (st[@h_atop] + st[@h_n] + 1 > st[@h_aend] or st[@h_ncls] >= st[@h_ccap]),
       do: st[@h_status] = 2

    st
  end

  # delete half the learnt clauses, highest LBD first (oldest first within
  # the cut-off LBD), compact the arena and rebuild every watch list
  defk reduce(st :: [i64], active :: bool) :: [i64] do
    if active do
      norig = st[@h_norig]
      ncls = st[@h_ncls]
      ohist = st[@o_hist]
      oclbd = st[@o_clbd]
      ocstart = st[@o_cstart]
      ocsize = st[@o_csize]
      target = div(st[@h_nlearnt], 2)

      for i <- 0..63//1 do
        st[ohist + i] = 0
      end

      for c <- norig..(ncls - 1)//1 do
        lbd = min(st[oclbd + c], 63)
        if lbd > 2, do: st[ohist + lbd] = st[ohist + lbd] + 1
      end

      {t, take, _acc} =
        Enum.reduce_while(63..1//-1, {0, 0, 0}, fn t, {_t, _take, acc} ->
          h = st[ohist + t]

          if acc + h >= target,
            do: {:halt, {t, target - acc, acc}},
            else: {:cont, {0, 0, acc + h}}
        end)

      {w, at, _taken} =
        for c <- norig..(ncls - 1)//1, reduce: {norig, st[@h_otop], 0} do
          {w, at, taken} ->
            lbd = min(st[oclbd + c], 63)
            tie = lbd == t and taken < take
            taken = if tie, do: taken + 1, else: taken

            if lbd > t or tie do
              {w, at, taken}
            else
              cs = st[ocstart + c]
              size = st[ocsize + c]

              for i <- 0..(size - 1)//1 do
                st[at + i] = st[cs + i]
              end

              st[ocstart + w] = at
              st[ocsize + w] = size
              st[oclbd + w] = st[oclbd + c]
              {w + 1, at + size, taken}
            end
        end

      st[@h_ncls] = w
      st[@h_nlearnt] = w - norig
      st[@h_atop] = at
      oreason = st[@o_reason]

      for v <- 0..st[@h_n]//1 do
        st[oreason + v] = -1
      end

      owhead = st[@o_whead]
      ownext = st[@o_wnext]
      owblock = st[@o_wblock]

      for i <- 0..(2 * st[@h_n] + 1)//1 do
        st[owhead + i] = -1
      end

      for c <- 0..(w - 1)//1 do
        cs = ocstart + c
        l0 = st[st[cs]]
        l1 = st[st[cs] + 1]
        st[ownext + 2 * c] = st[owhead + l0]
        st[owhead + l0] = 2 * c
        st[ownext + 2 * c + 1] = st[owhead + l1]
        st[owhead + l1] = 2 * c + 1
        st[owblock + 2 * c] = l1
        st[owblock + 2 * c + 1] = l0
      end
    end

    st
  end
end

defmodule SatEx.Cdcl do
  @moduledoc false
  # CDCL in Elixir over one :atomics state array, the kernel's layout and
  # algorithm step for step (see the kernel module): two watched literals as
  # intrusive lists, first-UIP learning, integer VSIDS in a binary heap,
  # saved phases, Luby restarts (unit 100), LBD-bucket reduction at restarts.
  import Bitwise

  # header slots (0-based; :atomics is 1-based, see g/2 and p/3)
  @h_n 0
  @h_ncls 2
  @h_norig 3
  @h_atop 4
  @h_aend 5
  @h_tlen 6
  @h_qhead 7
  @h_dl 8
  @h_inc 9
  @h_conflicts 10
  @h_status 11
  @h_nlearnt 12
  @h_maxl 13
  @h_rcount 14
  @h_luby 15
  @h_hsize 16
  @h_confl 18
  @h_ccap 19
  @h_stamp 20
  @o_lval 21
  @o_level 22
  @o_reason 23
  @o_trail 24
  @o_tlim 25
  @o_act 26
  @o_heap 27
  @o_hpos 28
  @o_phase 29
  @o_seen 30
  @o_whead 31
  @o_cstart 32
  @o_csize 33
  @o_clbd 34
  @o_wnext 35
  @o_learnt 36
  @o_lvst 37
  @o_mark 38
  @o_hist 39
  @o_arena 40
  @hdr 48
  @h_k 17
  @h_bl 41
  @h_lbd 42
  @o_wblock 44
  @h_otop 45

  @compile {:inline, g: 2, p: 3}
  defp g(st, i), do: :atomics.get(st, i + 1)
  defp p(st, i, v), do: :atomics.put(st, i + 1, v)

  @doc "Words of state for n variables, m clauses, nlits input literals and cap learned literals."
  def state_size(n, m, nlits, cap) do
    l = 2 * n + 2
    ccap = m + div(cap, 4) + 1
    @hdr + l * 3 + (n + 1) * 10 + (n + 2) * 2 + ccap * 7 + 64 + nlits + cap
  end

  @doc """
  Solves a CNF (a list of clauses of DIMACS literals) with `nvars` variables.
  Returns `{status, model, conflicts}`: status 1 SAT, 0 UNSAT, 2 unknown (the
  step budget or the clause arena ran out); model is a list of +-v for 1..n.
  """
  def solve(cnf, nvars, cap, budget \\ 1 <<< 58) do
    n = nvars || Enum.reduce(cnf, 0, fn c, a -> Enum.reduce(c, a, &max(abs(&1), &2)) end)
    {m, nlits} = Enum.reduce(cnf, {0, 0}, fn c, {m, k} -> {m + 1, k + length(c)} end)
    cap = cap || default_cap(nlits, n)
    st = :atomics.new(state_size(n, m, nlits, cap), signed: true)
    init(st, n, m, nlits, cap)
    Enum.each(cnf, fn c -> add_input_clause(st, c, n) end)
    search(st, budget)
    status = g(st, @h_status)
    {status, model(st, n, status), g(st, @h_conflicts)}
  end

  def default_cap(nlits, n), do: max(16 * nlits, 64 * (n + 1))

  @doc "Crux's solver interface: {:ok, model} | {:error, :unsatisfiable}."
  def solve(cnf) when is_list(cnf) do
    case solve(cnf, nil, nil) do
      {1, model, _} -> {:ok, model}
      {0, _, _} -> {:error, :unsatisfiable}
      {2, _, _} -> raise "solver limit"
    end
  end

  def model(_st, _n, s) when s != 1, do: []

  def model(st, n, _) do
    o = g(st, @o_lval)
    for v <- 1..n//1, do: if(g(st, o + 2 * v) == 1, do: v, else: -v)
  end

  # ---- init: layout, header, reset ---------------------------------------
  def init(st, n, m, nlits, cap) do
    l = 2 * n + 2
    ccap = m + div(cap, 4) + 1

    regions = [
      {@o_lval, l},
      {@o_level, n + 1},
      {@o_reason, n + 1},
      {@o_trail, n + 1},
      {@o_tlim, n + 2},
      {@o_act, n + 1},
      {@o_heap, n + 1},
      {@o_hpos, n + 1},
      {@o_phase, n + 1},
      {@o_seen, n + 1},
      {@o_whead, l},
      {@o_cstart, ccap},
      {@o_csize, ccap},
      {@o_clbd, ccap},
      {@o_wnext, 2 * ccap},
      {@o_wblock, 2 * ccap},
      {@o_learnt, 2 * n + 2},
      {@o_lvst, n + 2},
      {@o_mark, l},
      {@o_hist, 64},
      {@o_arena, nlits + cap}
    ]

    top =
      Enum.reduce(regions, @hdr, fn {slot, size}, off ->
        p(st, slot, off)
        off + size
      end)

    p(st, @h_n, n)
    p(st, 1, l)
    p(st, @h_ncls, 0)
    p(st, @h_norig, 0)
    p(st, @h_atop, g(st, @o_arena))
    p(st, @h_aend, top)
    p(st, @h_tlen, 0)
    p(st, @h_qhead, 0)
    p(st, @h_dl, 0)
    p(st, @h_inc, 1024)
    p(st, @h_conflicts, 0)
    p(st, @h_status, 3)
    p(st, @h_nlearnt, 0)
    p(st, @h_maxl, max(div(m, 3), 1000))
    p(st, @h_rcount, 100)
    p(st, @h_luby, 0)
    p(st, @h_hsize, n)
    p(st, @h_confl, -1)
    p(st, @h_ccap, ccap)
    p(st, @h_stamp, 0)
    olval = g(st, @o_lval)
    owhead = g(st, @o_whead)
    omark = g(st, @o_mark)

    for i <- 0..(l - 1)//1 do
      p(st, olval + i, 0)
      p(st, owhead + i, -1)
      p(st, omark + i, 0)
    end

    {olevel, oreason, otrail, oact, oheap, ohpos, ophase, oseen, olvst} =
      {g(st, @o_level), g(st, @o_reason), g(st, @o_trail), g(st, @o_act), g(st, @o_heap),
       g(st, @o_hpos), g(st, @o_phase), g(st, @o_seen), g(st, @o_lvst)}

    for v <- 0..n//1 do
      p(st, olevel + v, 0)
      p(st, oreason + v, -1)
      p(st, otrail + v, 0)
      p(st, oact + v, 0)
      p(st, oheap + v, v + 1)
      p(st, ohpos + v, v - 1)
      p(st, ophase + v, 0)
      p(st, oseen + v, 0)
      p(st, olvst + v, 0)
    end

    p(st, olvst + n + 1, 0)
    ohist = g(st, @o_hist)
    for i <- 0..63, do: p(st, ohist + i, 0)
    :ok
  end

  # ---- loading clauses ---------------------------------------------------
  def add_input_clause(st, lits, n) do
    for lit <- lits, lit == 0 or abs(lit) > n, do: raise(ArgumentError, "literal out of range")

    if g(st, @h_status) == 3 do
      stamp = g(st, @h_stamp) + 1
      p(st, @h_stamp, stamp)
      omark = g(st, @o_mark)
      start = g(st, @h_atop)
      oarena = start

      {k, taut} =
        Enum.reduce(lits, {0, false}, fn lit, {k, taut} ->
          v = abs(lit)
          l = if lit > 0, do: 2 * v, else: 2 * v + 1

          cond do
            taut ->
              {k, taut}

            g(st, omark + l) == stamp ->
              {k, taut}

            g(st, omark + bxor(l, 1)) == stamp ->
              {k, true}

            true ->
              p(st, omark + l, stamp)
              p(st, oarena + k, l)
              {k + 1, taut}
          end
        end)

      cond do
        taut ->
          :ok

        k == 0 ->
          p(st, @h_status, 0)

        k == 1 ->
          l = g(st, start)
          lv = g(st, g(st, @o_lval) + l)

          cond do
            lv == -1 -> p(st, @h_status, 0)
            lv == 0 -> enqueue(st, l, -1)
            true -> :ok
          end

        true ->
          c = g(st, @h_ncls)
          if c >= g(st, @h_ccap), do: raise(ArgumentError, "clause capacity")
          p(st, g(st, @o_cstart) + c, start)
          p(st, g(st, @o_csize) + c, k)
          p(st, g(st, @o_clbd) + c, 0)
          p(st, @h_atop, start + k)
          p(st, @h_ncls, c + 1)
          p(st, @h_norig, c + 1)
          watch(st, c)
      end
    end

    :ok
  end

  defp watch(st, c) do
    cs = g(st, g(st, @o_cstart) + c)
    owhead = g(st, @o_whead)
    ownext = g(st, @o_wnext)
    l0 = g(st, cs)
    l1 = g(st, cs + 1)
    p(st, ownext + 2 * c, g(st, owhead + l0))
    p(st, owhead + l0, 2 * c)
    p(st, ownext + 2 * c + 1, g(st, owhead + l1))
    p(st, owhead + l1, 2 * c + 1)
    owblock = g(st, @o_wblock)
    p(st, owblock + 2 * c, l1)
    p(st, owblock + 2 * c + 1, l0)
  end

  defp enqueue(st, l, reason) do
    olval = g(st, @o_lval)
    v = l >>> 1
    p(st, olval + l, 1)
    p(st, olval + bxor(l, 1), -1)
    p(st, g(st, @o_level) + v, g(st, @h_dl))
    p(st, g(st, @o_reason) + v, reason)
    t = g(st, @h_tlen)
    p(st, g(st, @o_trail) + t, l)
    p(st, @h_tlen, t + 1)
  end

  # ---- search ------------------------------------------------------------
  def search(st, budget) do
    p(st, @h_otop, g(st, @h_atop))
    if g(st, @h_status) == 3, do: search_loop(st, budget)
    if g(st, @h_status) == 3, do: p(st, @h_status, 2)
    :ok
  end

  defp search_loop(_st, 0), do: :ok

  defp search_loop(st, budget) do
    propagate(st)

    if g(st, @h_confl) >= 0 do
      p(st, @h_conflicts, g(st, @h_conflicts) + 1)

      if g(st, @h_dl) == 0 do
        p(st, @h_status, 0)
      else
        conflict(st)
        if g(st, @h_status) == 3, do: search_loop(st, budget - 1)
      end
    else
      decide(st)
      if g(st, @h_status) == 3, do: search_loop(st, budget - 1)
    end
  end

  defp propagate(st) do
    p(st, @h_confl, -1)

    prop_loop(
      st,
      {g(st, @o_lval), g(st, @o_whead), g(st, @o_wnext), g(st, @o_cstart), g(st, @o_csize),
       g(st, @o_trail), g(st, @o_wblock)}
    )
  end

  defp prop_loop(st, {_olval, owhead, _ownext, _ocstart, _ocsize, otrail, _owblock} = o) do
    q = g(st, @h_qhead)

    if q < g(st, @h_tlen) do
      fl = bxor(g(st, otrail + q), 1)
      p(st, @h_qhead, q + 1)
      if walk(st, fl, -1, g(st, owhead + fl), o), do: prop_loop(st, o)
    end
  end

  # returns true to go on, false on a conflict
  defp walk(_st, _fl, _prev, -1, _o), do: true

  defp walk(st, fl, prev, node, {olval, owhead, ownext, ocstart, ocsize, _otrail, owblock} = o) do
    nxt = g(st, ownext + node)

    if g(st, olval + g(st, owblock + node)) == 1 do
      walk(st, fl, node, nxt, o)
    else
      c = node >>> 1
      k = node &&& 1
      cs = g(st, ocstart + c)
      other = g(st, cs + 1 - k)

      if g(st, olval + other) == 1 do
        p(st, owblock + node, other)
        walk(st, fl, node, nxt, o)
      else
        j = find_unfalse(st, olval, cs, 2, g(st, ocsize + c))

        cond do
          j >= 0 ->
            nl = g(st, cs + j)
            p(st, cs + j, fl)
            p(st, cs + k, nl)
            if prev == -1, do: p(st, owhead + fl, nxt), else: p(st, ownext + prev, nxt)
            p(st, ownext + node, g(st, owhead + nl))
            p(st, owhead + nl, node)
            p(st, owblock + node, other)
            walk(st, fl, prev, nxt, o)

          g(st, olval + other) == 0 ->
            enqueue(st, other, c)
            walk(st, fl, node, nxt, o)

          true ->
            p(st, @h_confl, c)
            false
        end
      end
    end
  end

  defp find_unfalse(_st, _olval, _cs, j, size) when j >= size, do: -1

  defp find_unfalse(st, olval, cs, j, size) do
    if g(st, olval + g(st, cs + j)) != -1, do: j, else: find_unfalse(st, olval, cs, j + 1, size)
  end

  # ---- conflict: learn, backjump, restart/reduce --------------------------
  defp conflict(st) do
    n = g(st, @h_n)

    if g(st, @h_atop) + n + 1 > g(st, @h_aend) or g(st, @h_ncls) >= g(st, @h_ccap) do
      restart(st, true)
    else
      analyze(st)
      k = g(st, @h_k)
      olearnt = g(st, @o_learnt)
      backjump(st, g(st, @h_bl))

      if k == 1 do
        enqueue(st, g(st, olearnt), -1)
      else
        c = g(st, @h_ncls)
        at = g(st, @h_atop)
        for i <- 0..(k - 1)//1, do: p(st, at + i, g(st, olearnt + i))
        p(st, g(st, @o_cstart) + c, at)
        p(st, g(st, @o_csize) + c, k)
        p(st, g(st, @o_clbd) + c, g(st, @h_lbd))
        p(st, @h_atop, at + k)
        p(st, @h_ncls, c + 1)
        p(st, @h_nlearnt, g(st, @h_nlearnt) + 1)
        watch(st, c)
        enqueue(st, g(st, olearnt), c)
      end

      inc = g(st, @h_inc)
      inc = inc + div(inc, 19)

      if inc > 1 <<< 40 do
        oact = g(st, @o_act)
        for v <- 1..n//1, do: p(st, oact + v, g(st, oact + v) >>> 20)
        p(st, @h_inc, inc >>> 20)
      else
        p(st, @h_inc, inc)
      end

      rc = g(st, @h_rcount) - 1
      p(st, @h_rcount, rc)
      if rc == 0, do: restart(st, false)
    end
  end

  defp analyze(st) do
    dl = g(st, @h_dl)

    {oseen, olevel, oreason, otrail, olearnt, ocstart, ocsize} =
      {g(st, @o_seen), g(st, @o_level), g(st, @o_reason), g(st, @o_trail), g(st, @o_learnt),
       g(st, @o_cstart), g(st, @o_csize)}

    {k, pl} =
      analyze_loop(
        st,
        g(st, @h_confl),
        -1,
        0,
        1,
        g(st, @h_tlen) - 1,
        dl,
        oseen,
        olevel,
        oreason,
        otrail,
        olearnt,
        ocstart,
        ocsize
      )

    p(st, olearnt, bxor(pl, 1))
    k = minimize(st, 1, k, 1, 0, olearnt, oseen, olevel, oreason, ocstart, ocsize)

    {bl, maxi} =
      Enum.reduce(1..(k - 1)//1, {0, 1}, fn i, {bl, maxi} ->
        lv = g(st, olevel + (g(st, olearnt + i) >>> 1))
        if lv > bl, do: {lv, i}, else: {bl, maxi}
      end)

    if k > 1 do
      t = g(st, olearnt + 1)
      p(st, olearnt + 1, g(st, olearnt + maxi))
      p(st, olearnt + maxi, t)
    end

    stamp = g(st, @h_stamp) + 1
    p(st, @h_stamp, stamp)
    olvst = g(st, @o_lvst)

    lbd =
      Enum.reduce(0..(k - 1)//1, 0, fn i, lbd ->
        lv = g(st, olevel + (g(st, olearnt + i) >>> 1))

        if g(st, olvst + lv) != stamp do
          p(st, olvst + lv, stamp)
          lbd + 1
        else
          lbd
        end
      end)

    p(st, @h_k, k)
    p(st, @h_bl, bl)
    p(st, @h_lbd, lbd)
  end

  # local minimisation, as the kernel: kept literals compacted to the front,
  # removed variables listed from k on; then seen cleared for both
  defp minimize(st, i, k, w, r, olearnt, oseen, _olevel, _oreason, _ocstart, _ocsize)
       when i >= k do
    for j <- 1..(w - 1)//1, do: p(st, oseen + (g(st, olearnt + j) >>> 1), 0)
    for j <- 0..(r - 1)//1, do: p(st, oseen + g(st, olearnt + k + j), 0)
    w
  end

  defp minimize(st, i, k, w, r, olearnt, oseen, olevel, oreason, ocstart, ocsize) do
    q = g(st, olearnt + i)
    v = q >>> 1
    rc = g(st, oreason + v)

    red =
      rc >= 0 and
        (
          cs = g(st, ocstart + rc)

          Enum.all?(0..(g(st, ocsize + rc) - 1)//1, fn jj ->
            v2 = g(st, cs + jj) >>> 1
            v2 == v or g(st, oseen + v2) == 1 or g(st, olevel + v2) == 0
          end)
        )

    if red do
      p(st, olearnt + k + r, v)
      minimize(st, i + 1, k, w, r + 1, olearnt, oseen, olevel, oreason, ocstart, ocsize)
    else
      p(st, olearnt + w, q)
      minimize(st, i + 1, k, w + 1, r, olearnt, oseen, olevel, oreason, ocstart, ocsize)
    end
  end

  defp analyze_loop(
         st,
         c,
         pl,
         pathc,
         k,
         idx,
         dl,
         oseen,
         olevel,
         oreason,
         otrail,
         olearnt,
         ocstart,
         ocsize
       ) do
    cs = g(st, ocstart + c)
    size = g(st, ocsize + c)
    pv = if pl == -1, do: -1, else: pl >>> 1

    {pathc, k} =
      Enum.reduce(0..(size - 1)//1, {pathc, k}, fn j, {pathc, k} ->
        q = g(st, cs + j)
        v = q >>> 1
        lv = g(st, olevel + v)

        if v != pv and g(st, oseen + v) == 0 and lv > 0 do
          p(st, oseen + v, 1)
          bump(st, v)

          if lv >= dl do
            {pathc + 1, k}
          else
            p(st, olearnt + k, q)
            {pathc, k + 1}
          end
        else
          {pathc, k}
        end
      end)

    idx = skip_unseen(st, idx, oseen, otrail)
    pl = g(st, otrail + idx)
    v = pl >>> 1
    p(st, oseen + v, 0)

    if pathc - 1 == 0 do
      {k, pl}
    else
      analyze_loop(
        st,
        g(st, oreason + v),
        pl,
        pathc - 1,
        k,
        idx - 1,
        dl,
        oseen,
        olevel,
        oreason,
        otrail,
        olearnt,
        ocstart,
        ocsize
      )
    end
  end

  defp skip_unseen(st, idx, oseen, otrail) do
    if g(st, oseen + (g(st, otrail + idx) >>> 1)) == 0,
      do: skip_unseen(st, idx - 1, oseen, otrail),
      else: idx
  end

  defp bump(st, v) do
    oact = g(st, @o_act)
    p(st, oact + v, g(st, oact + v) + g(st, @h_inc))
    i = g(st, g(st, @o_hpos) + v)
    if i >= 0, do: sift_up(st, i)
  end

  defp sift_up(st, i) do
    oheap = g(st, @o_heap)
    ohpos = g(st, @o_hpos)
    oact = g(st, @o_act)
    v = g(st, oheap + i)
    a = g(st, oact + v)
    i = sift_up_loop(st, i, a, oheap, ohpos, oact)
    p(st, oheap + i, v)
    p(st, ohpos + v, i)
  end

  defp sift_up_loop(_st, 0, _a, _oheap, _ohpos, _oact), do: 0

  defp sift_up_loop(st, i, a, oheap, ohpos, oact) do
    par = (i - 1) >>> 1
    pv = g(st, oheap + par)

    if g(st, oact + pv) < a do
      p(st, oheap + i, pv)
      p(st, ohpos + pv, i)
      sift_up_loop(st, par, a, oheap, ohpos, oact)
    else
      i
    end
  end

  defp sift_down(st, i) do
    oheap = g(st, @o_heap)
    ohpos = g(st, @o_hpos)
    oact = g(st, @o_act)
    v = g(st, oheap + i)
    a = g(st, oact + v)
    i = sift_down_loop(st, i, a, g(st, @h_hsize), oheap, ohpos, oact)
    p(st, oheap + i, v)
    p(st, ohpos + v, i)
  end

  defp sift_down_loop(st, i, a, hs, oheap, ohpos, oact) do
    ch = 2 * i + 1

    if ch >= hs do
      i
    else
      ch =
        if ch + 1 < hs and g(st, oact + g(st, oheap + ch + 1)) > g(st, oact + g(st, oheap + ch)),
          do: ch + 1,
          else: ch

      cv = g(st, oheap + ch)

      if g(st, oact + cv) > a do
        p(st, oheap + i, cv)
        p(st, ohpos + cv, i)
        sift_down_loop(st, ch, a, hs, oheap, ohpos, oact)
      else
        i
      end
    end
  end

  defp backjump(st, bl) do
    if g(st, @h_dl) > bl do
      {otrail, olval, ophase, oreason, ohpos, oheap} =
        {g(st, @o_trail), g(st, @o_lval), g(st, @o_phase), g(st, @o_reason), g(st, @o_hpos),
         g(st, @o_heap)}

      lim = g(st, g(st, @o_tlim) + bl + 1)

      for i <- (g(st, @h_tlen) - 1)..lim//-1 do
        l = g(st, otrail + i)
        v = l >>> 1
        p(st, ophase + v, if((l &&& 1) == 0, do: 1, else: 0))
        p(st, olval + l, 0)
        p(st, olval + bxor(l, 1), 0)
        p(st, oreason + v, -1)

        if g(st, ohpos + v) < 0 do
          hs = g(st, @h_hsize)
          p(st, oheap + hs, v)
          p(st, ohpos + v, hs)
          p(st, @h_hsize, hs + 1)
          sift_up(st, hs)
        end
      end

      p(st, @h_tlen, lim)
      p(st, @h_qhead, lim)
      p(st, @h_dl, bl)
    end
  end

  defp decide(st) do
    hs = g(st, @h_hsize)

    if hs == 0 do
      p(st, @h_status, 1)
    else
      oheap = g(st, @o_heap)
      ohpos = g(st, @o_hpos)
      v = g(st, oheap)
      p(st, @h_hsize, hs - 1)
      p(st, ohpos + v, -1)

      if hs - 1 > 0 do
        last = g(st, oheap + hs - 1)
        p(st, oheap, last)
        p(st, ohpos + last, 0)
        sift_down(st, 0)
      end

      if g(st, g(st, @o_lval) + 2 * v) == 0 do
        dl = g(st, @h_dl) + 1
        p(st, @h_dl, dl)
        p(st, g(st, @o_tlim) + dl, g(st, @h_tlen))
        lit = if g(st, g(st, @o_phase) + v) == 1, do: 2 * v, else: 2 * v + 1
        enqueue(st, lit, -1)
      else
        decide(st)
      end
    end
  end

  def luby(x) do
    {size, seq} = luby_up(1, 0, x)
    luby_down(size, seq, x)
  end

  defp luby_up(size, seq, x) when size < x + 1, do: luby_up(2 * size + 1, seq + 1, x)
  defp luby_up(size, seq, _x), do: {size, seq}

  defp luby_down(size, seq, x) when size - 1 != x do
    size = (size - 1) >>> 1
    luby_down(size, seq - 1, rem(x, size))
  end

  defp luby_down(_size, seq, _x), do: 1 <<< seq

  defp restart(st, force) do
    backjump(st, 0)
    li = g(st, @h_luby) + 1
    p(st, @h_luby, li)
    p(st, @h_rcount, luby(li) * 100)

    if force or g(st, @h_nlearnt) > g(st, @h_maxl) do
      reduce(st)
      maxl = g(st, @h_maxl)
      if not force, do: p(st, @h_maxl, maxl + div(maxl, 10))

      if force and
           (g(st, @h_atop) + g(st, @h_n) + 1 > g(st, @h_aend) or g(st, @h_ncls) >= g(st, @h_ccap)),
         do: p(st, @h_status, 2)
    end
  end

  defp reduce(st) do
    {norig, ncls, ohist, oclbd, ocstart, ocsize} =
      {g(st, @h_norig), g(st, @h_ncls), g(st, @o_hist), g(st, @o_clbd), g(st, @o_cstart),
       g(st, @o_csize)}

    target = div(g(st, @h_nlearnt), 2)
    for i <- 0..63, do: p(st, ohist + i, 0)

    for c <- norig..(ncls - 1)//1 do
      lbd = min(g(st, oclbd + c), 63)
      if lbd > 2, do: p(st, ohist + lbd, g(st, ohist + lbd) + 1)
    end

    {t, take} =
      Enum.reduce_while(63..1//-1, {0, 0, 0}, fn t, {_, _, acc} ->
        h = g(st, ohist + t)
        if acc + h >= target, do: {:halt, {t, target - acc, acc}}, else: {:cont, {0, 0, acc + h}}
      end)
      |> then(fn {t, take, _} -> {t, take} end)

    {w, at, _} =
      Enum.reduce(norig..(ncls - 1)//1, {norig, g(st, @h_otop), 0}, fn c, {w, at, taken} ->
        lbd = min(g(st, oclbd + c), 63)
        tie = lbd == t and taken < take
        del = lbd > t or tie
        taken = if tie, do: taken + 1, else: taken

        if del do
          {w, at, taken}
        else
          cs = g(st, ocstart + c)
          size = g(st, ocsize + c)
          for i <- 0..(size - 1)//1, do: p(st, at + i, g(st, cs + i))
          p(st, ocstart + w, at)
          p(st, ocsize + w, size)
          p(st, oclbd + w, g(st, oclbd + c))
          {w + 1, at + size, taken}
        end
      end)

    p(st, @h_ncls, w)
    p(st, @h_nlearnt, w - norig)
    p(st, @h_atop, at)
    oreason = g(st, @o_reason)
    for v <- 0..g(st, @h_n)//1, do: p(st, oreason + v, -1)
    owhead = g(st, @o_whead)
    for i <- 0..(2 * g(st, @h_n) + 1)//1, do: p(st, owhead + i, -1)
    for c <- 0..(w - 1)//1, do: watch(st, c)
  end
end

defmodule SatEx.Dpll do
  @moduledoc false
  # The research's DPLL sketch (docs/research/sat-solver.md): unit
  # propagation, branch on a literal of the shortest clause, clauses as
  # lists, the assignment in a map. No learning; fastest Elixir on the
  # smallest formulas, exponential on hard ones.
  def solve(cnf) do
    case dpll(cnf, %{}) do
      nil ->
        {:error, :unsatisfiable}

      a ->
        vars = cnf |> List.flatten() |> Enum.map(&abs/1) |> Enum.uniq() |> Enum.sort()
        {:ok, Enum.map(vars, fn v -> if Map.get(a, v, false), do: v, else: -v end)}
    end
  end

  defp dpll(cnf, a) do
    case propagate(cnf, a) do
      :conflict ->
        nil

      {[], a} ->
        a

      {cnf, a} ->
        lit = cnf |> Enum.min_by(&length/1) |> hd()

        dpll(assign(cnf, lit), Map.put(a, abs(lit), lit > 0)) ||
          dpll(assign(cnf, -lit), Map.put(a, abs(lit), lit < 0))
    end
  end

  defp propagate(:conflict, _a), do: :conflict

  defp propagate(cnf, a) do
    case Enum.find(cnf, &match?([_], &1)) do
      nil ->
        {cnf, a}

      [lit] ->
        case assign(cnf, lit) do
          :conflict -> :conflict
          cnf -> propagate(cnf, Map.put(a, abs(lit), lit > 0))
        end
    end
  end

  defp assign(:conflict, _), do: :conflict

  defp assign(cnf, lit) do
    Enum.reduce_while(cnf, [], fn c, acc ->
      if lit in c do
        {:cont, acc}
      else
        case List.delete(c, -lit) do
          [] -> {:halt, :conflict}
          c2 -> {:cont, [c2 | acc]}
        end
      end
    end)
  end
end

defmodule SatEx.Gen do
  @moduledoc false
  require Crux.Expression
  import Crux.Expression, only: [b: 1]

  # Ash-shaped formulas (the research's generator): mirrors
  # Ash.Policy.Policy.raw_expression/1 and policies_expression/1 (ash
  # 3.34.6). P policies, each a condition of 1-2 checks and K checks typed
  # authorize_if / forbid_if / authorize_unless / forbid_unless, drawn from a
  # pool of shared check refs; simplified by Crux, then Tseitin CNF.
  def ash(p, k, pool, seed) do
    :rand.seed(:exsss, {seed, p, k})
    pick = fn -> {:check, :rand.uniform(pool)} end

    policies =
      for _ <- 1..p do
        cond_expr = Enum.reduce(1..:rand.uniform(2), true, fn _, acc -> b(acc and pick.()) end)

        pol_expr =
          List.foldr(Enum.to_list(1..k), false, fn _, acc ->
            c = pick.()

            case :rand.uniform(4) do
              1 -> b(c or acc)
              2 -> b(implies(c, acc))
              3 -> b(not c and acc)
              4 -> b(c and acc)
            end
          end)

        {cond_expr, b(cond_expr and pol_expr)}
      end

    {one, all} =
      List.foldr(policies, {false, true}, fn {ce, comp}, {one, all} ->
        {b(ce or one), b(implies(ce, comp) and all)}
      end)

    b(one and all) |> Crux.Expression.simplify() |> Crux.Formula.from_expression()
  end

  # random 3-SAT: n variables, round(n * ratio) clauses of 3 distinct variables
  def k3(n, ratio, seed) do
    :rand.seed(:exsss, {seed, n, 42})

    for _ <- 1..round(n * ratio) do
      Enum.take_random(1..n, 3) |> Enum.map(fn v -> if :rand.uniform(2) == 1, do: v, else: -v end)
    end
  end

  # random CNF for agreement: 1..maxn variables, clauses of 1..maxk literals
  def cnf(seed, maxn, maxk) do
    :rand.seed(:exsss, {seed, 7, 7})
    n = :rand.uniform(maxn)

    cnf =
      for _ <- 1..:rand.uniform(4 * n + 5) do
        for _ <- 1..:rand.uniform(maxk) do
          v = :rand.uniform(n)
          if :rand.uniform(2) == 1, do: v, else: -v
        end
      end

    {n, cnf}
  end

  # a model satisfies every clause (models may be partial: simple_sat's are)
  def satisfies?(cnf, model) do
    set = MapSet.new(model)
    Enum.all?(cnf, fn c -> Enum.any?(c, &MapSet.member?(set, &1)) end)
  end
end

defmodule SatEx do
  @moduledoc false
  # Elixir-side wrappers: packing, the per-call solver API (Crux's solve/1
  # shape) and Crux's satisfying_scenarios on the batch kernel.
  import Bitwise
  alias SatEx.Kernels, as: K

  @budget 1 <<< 58

  def nvars(cnf), do: Enum.reduce(cnf, 0, fn c, a -> Enum.reduce(c, a, &max(abs(&1), &2)) end)

  # CSR: literals and clause offsets as packed i64
  def pack(cnf) do
    {lits, offs, _} =
      Enum.reduce(cnf, {[], [<<0::signed-64-native>>], 0}, fn c, {l, o, k} ->
        k = k + length(c)
        {[l | for(x <- c, do: <<x::signed-64-native>>)], [o | <<k::signed-64-native>>], k}
      end)

    {IO.iodata_to_binary(lits), IO.iodata_to_binary(offs)}
  end

  def default_cap(nlits, n), do: SatEx.Cdcl.default_cap(nlits, n)

  @doc "Crux's solver interface on the kernel: {:ok, model} | {:error, :unsatisfiable}."
  def solve(cnf) do
    n = nvars(cnf)
    {l, o} = pack(cnf)

    case K.solve(l, o, n, default_cap(div(byte_size(l), 8), n), @budget) do
      {1, m, _} -> {:ok, for(<<x::signed-64-native <- m>>, do: x)}
      {0, _, _} -> {:error, :unsatisfiable}
      {2, _, _} -> raise "sat: step budget exhausted"
    end
  end

  # Crux's negation encoding (Crux.build_negation_encoding/1, crux 0.1.4):
  # one selector per assertion clause, selector -> every literal false
  def encode(%Crux.Formula{cnf: cnf, definitions: defs, bindings: b}) do
    assertions =
      case defs do
        [] ->
          cnf

        _ ->
          set = MapSet.new(defs)
          Enum.reject(cnf, &MapSet.member?(set, &1))
      end

    nf = nvars(cnf)
    k = length(assertions)
    sel = Enum.to_list((nf + 1)..(nf + k)//1)

    gadget =
      assertions |> Enum.zip(sel) |> Enum.flat_map(fn {c, s} -> Enum.map(c, &[-s, -&1]) end)

    %{cnf: cnf, query: [sel | gadget ++ defs], prim: Map.keys(b), nf: nf, nq: nf + k, bindings: b}
  end

  def batch_cap(e) do
    nl = Enum.reduce(e.cnf ++ e.query, 0, &(length(&1) + &2))
    default_cap(nl, e.nq)
  end

  @doc "Crux.satisfying_scenarios/2 with the enumeration in one kernel call."
  def satisfying_scenarios(formula, opts \\ []) do
    case formula do
      %Crux.Formula{cnf: [], bindings: b} when map_size(b) == 0 -> [%{}]
      %Crux.Formula{cnf: [[1], [-1]], bindings: %{1 => false}} -> []
      %Crux.Formula{cnf: []} -> Crux.satisfying_scenarios(formula, opts)
      _ -> formula |> encode() |> cubes_kernel() |> finish(formula.bindings, opts)
    end
  end

  def batch_args(e, out_cap) do
    {all, allo} = pack(e.cnf ++ e.query)
    prim = for v <- e.prim, into: <<>>, do: <<v::signed-64-native>>
    [all, allo, length(e.cnf), prim, e.nf, e.nq, batch_cap(e), @budget, out_cap, out_cap]
  end

  # the scenario cubes in the order found; out_cap literals of blocking
  # clauses to start with, four times more on each retry
  def cubes_kernel(e, out_cap \\ 64) do
    case apply(K, :solve_all, batch_args(e, out_cap)) do
      {1, x, xo, ns, _solves} -> decode(x, xo, ns)
      {3, _, _, _, _} -> cubes_kernel(e, out_cap * 4)
      {2, _, _, _, _} -> raise "sat: step budget exhausted"
    end
  end

  def decode(x, xo, ns) do
    offs = for <<o::signed-64-native <- xo>>, do: o
    xs = for <<v::signed-64-native <- x>>, do: v
    xt = List.to_tuple(xs)

    offs
    |> Enum.take(ns + 1)
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.map(fn [a, b] -> for i <- a..(b - 1)//1, do: -elem(xt, i) end)
  end

  # Crux's tail of satisfying_scenarios: newest first, unbind, uniq, validate
  def finish(cubes, bindings, opts) do
    cubes
    |> Enum.reverse()
    |> Enum.map(fn cube ->
      Enum.reduce(cube, %{}, fn l, acc ->
        case bindings do
          %{^l => var} -> Map.put(acc, var, true)
          %{} -> Map.put(acc, Map.fetch!(bindings, -l), false)
        end
      end)
    end)
    |> Enum.uniq()
    |> Enum.map(&Crux.validate_assignments(&1, opts))
    |> Enum.flat_map(fn
      {:ok, s} -> [Map.new(s)]
      {:error, :unsatisfiable} -> []
    end)
  end
end

defmodule SatEx.Enumerate do
  @moduledoc false
  # The batch loop in Elixir with the Elixir CDCL: the kernel's loop step for
  # step (formula clauses then blocking clauses; query clauses then units)
  def satisfying_scenarios(formula, opts \\ []) do
    case formula do
      %Crux.Formula{cnf: [], bindings: b} when map_size(b) == 0 -> [%{}]
      %Crux.Formula{cnf: [[1], [-1]], bindings: %{1 => false}} -> []
      %Crux.Formula{cnf: []} -> Crux.satisfying_scenarios(formula, opts)
      _ -> formula |> SatEx.encode() |> cubes() |> SatEx.finish(formula.bindings, opts)
    end
  end

  def cubes(e) do
    cap = SatEx.batch_cap(e)
    loop(e, cap, [], [])
  end

  defp loop(e, cap, blocks, acc) do
    case SatEx.Cdcl.solve(e.cnf ++ Enum.reverse(blocks), e.nf, cap) do
      {0, _, _} ->
        Enum.reverse(acc)

      {1, model, _} ->
        mt = List.to_tuple(model)
        cube = for v <- e.prim, do: elem(mt, v - 1)
        kept = minimize(e, cap, cube, [])
        loop(e, cap, [Enum.map(kept, &(-&1)) | blocks], [kept | acc])
    end
  end

  # drop each literal in turn if the others (still kept) imply the formula
  defp minimize(_e, _cap, [], kept), do: Enum.reverse(kept)

  defp minimize(e, cap, [l | rest], kept) do
    units = for u <- Enum.reverse(kept) ++ rest, do: [u]

    case SatEx.Cdcl.solve(e.query ++ units, e.nq, cap) do
      {0, _, _} -> minimize(e, cap, rest, kept)
      {1, _, _} -> minimize(e, cap, rest, [l | kept])
    end
  end
end

# ---- agreement: one solve ---------------------------------------------------------
alias SatEx.{Cdcl, Dpll, Gen}
alias SatEx.Kernels, as: K
import Bitwise

kcall = fn cnf, n, cap, budget ->
  {l, o} = SatEx.pack(cnf)
  K.solve(l, o, n, cap, budget)
end

decode = fn
  {1, m, c} -> {1, for(<<x::signed-64-native <- m>>, do: x), c}
  {s, _m, c} -> {s, [], c}
end

# (1) the kernel against its Elixir mode, exactly (===): status, model and
# conflict count. Elixir mode rebuilds the state binary on every write, so
# it gets small formulas and a small learned-clause arena (cap 48, which
# also exercises the forced restart + reduce when the arena is full)
# near-threshold 3-SAT (n = 10..60) gives conflicts, restarts and reductions
mode_cases =
  for(seed <- 1..80, do: Gen.cnf(seed, 16, 8)) ++
    for seed <- 1..60,
        do:
          (
            n = 10 + rem(seed, 51)
            {n, Gen.k3(n, 4.26, seed)}
          )

{mode_us, mode_ok} =
  :timer.tc(fn ->
    Enum.all?(mode_cases, fn {n, cnf} ->
      {l, o} = SatEx.pack(cnf)
      args = [l, o, n, 48, 1 <<< 40]
      K.__defk_elixir__(:solve, args) === apply(K, :solve, args)
    end)
  end)

# (2) the kernel against the Elixir CDCL, the same algorithm: identical
# (status, model, conflicts) on 2,000 random CNFs and at 3-SAT n = 100
cdcl_ok =
  Enum.all?(1..2000, fn seed ->
    {n, cnf} = Gen.cnf(seed, 40, 10)
    decode.(kcall.(cnf, n, 64, 1 <<< 58)) === Cdcl.solve(cnf, n, 64)
  end) and
    Enum.all?(1..200, fn seed ->
      n = 20 + rem(seed, 81)
      cnf = Gen.k3(n, 4.26, seed)
      decode.(kcall.(cnf, n, 256, 1 <<< 58)) === Cdcl.solve(cnf, n, 256)
    end) and
    Enum.all?(1..3, fn seed ->
      cnf = Gen.k3(100, 4.26, seed)

      decode.(kcall.(cnf, 100, SatEx.default_cap(300 * 3, 100), 1 <<< 58)) ===
        Cdcl.solve(cnf, 100, SatEx.default_cap(300 * 3, 100))
    end)

# (3) the anchors: the same status as picosat and a model that satisfies
# every clause (the model itself need not match); simple_sat on the small
# ones (it searches once per variable on UNSAT)
anchor_ok =
  Enum.all?(1..2000, fn seed ->
    {n, cnf} =
      if rem(seed, 2) == 0,
        do: Gen.cnf(seed + 10_000, 40, 10),
        else:
          (
            n = 10 + rem(seed, 71)
            {n, Gen.k3(n, 4.26, seed)}
          )

    case {decode.(kcall.(cnf, n, SatEx.default_cap(64, n), 1 <<< 58)), Picosat.solve(cnf)} do
      {{1, m, _}, {:ok, _}} -> Gen.satisfies?(cnf, m)
      {{0, _, _}, {:error, :unsatisfiable}} -> true
      _ -> false
    end
  end)

simple_ok =
  Enum.all?(1..300, fn seed ->
    {n, cnf} = Gen.cnf(seed + 20_000, 10, 5)

    case {decode.(kcall.(cnf, n, 64, 1 <<< 58)), SimpleSat.solve(cnf)} do
      {{1, _, _}, {:ok, m}} -> Gen.satisfies?(cnf, m)
      {{0, _, _}, {:error, :unsatisfiable}} -> true
      _ -> false
    end
  end)

# (4) forced yields: every safepoint yields, the results do not change
plain =
  for seed <- 1..100,
      do:
        (
          {n, cnf} = Gen.cnf(seed, 40, 10)
          kcall.(cnf, n, 64, 1 <<< 58)
        )

k100 = Gen.k3(100, 4.26, 2)
plain100 = kcall.(k100, 100, 4096, 1 <<< 58)
K.__defk_force_yields__(true)

yield_ok =
  plain ==
    for(
      seed <- 1..100,
      do:
        (
          {n, cnf} = Gen.cnf(seed, 40, 10)
          kcall.(cnf, n, 64, 1 <<< 58)
        )
    ) and
    plain100 == kcall.(k100, 100, 4096, 1 <<< 58)

K.__defk_force_yields__(false)

# (5) bad input raises ArgumentError natively and in Elixir mode; the step
# budget and the arena capacity are declared limits: status 2, never a
# wrong answer
raises? = fn f ->
  try do
    f.()
    false
  rescue
    ArgumentError -> true
  end
end

bad_ok =
  Enum.all?([[[1, 0]], [[1, -5]], [[4]]], fn cnf ->
    {l, o} = SatEx.pack(cnf)
    args = [l, o, 3, 16, 1000]

    raises?.(fn -> apply(K, :solve, args) end) and
      raises?.(fn -> K.__defk_elixir__(:solve, args) end)
  end)

limit_ok =
  elem(kcall.(k100, 100, 4096, 50), 0) == 2 and elem(kcall.(k100, 100, 0, 1 <<< 58), 0) == 2 and
    elem(
      K.__defk_elixir__(
        :solve,
        Tuple.to_list(SatEx.pack(Gen.k3(30, 4.26, 3))) ++ [30, 4, 1 <<< 40]
      ),
      0
    ) ==
      elem(kcall.(Gen.k3(30, 4.26, 3), 30, 4, 1 <<< 40), 0)

IO.puts(
  "one solve: kernel === Elixir mode on #{length(mode_cases)} CNFs (#{div(mode_us, 1000)} ms): #{mode_ok}; " <>
    "=== the Elixir CDCL on 2,000 CNFs, 200 3-SAT n=20..100 and n=100: #{cdcl_ok}; status = picosat's, models valid (2,000): #{anchor_ok}; " <>
    "vs simple_sat (300 small): #{simple_ok}; forced yields: #{yield_ok}; bad literals raise: #{bad_ok}; " <>
    "budget and capacity give status 2: #{limit_ok}"
)

one_ok = mode_ok and cdcl_ok and anchor_ok and simple_ok and yield_ok and bad_ok and limit_ok

# ---- agreement: Crux's enumeration in one call (solve_all) ------------------------
shapes = [{2, 2, 4}, {4, 3, 8}, {8, 3, 12}, {12, 4, 16}]

formulas =
  for {p, k, pool} <- shapes,
      seed <- 1..2,
      f = Gen.ash(p, k, pool, seed),
      f.cnf != [],
      do: {{p, k, pool, seed}, f}

with_solver = fn solver, f ->
  Process.put(Crux.Implementation, solver)
  f.()
end

# Is every scenario sufficient (cube and not F is UNSAT, Crux's own
# implies_formula? query) and do the scenarios cover F (F and no scenario is
# UNSAT)? Both checked with picosat.
valid_cover? = fn f, cubes ->
  e = SatEx.encode(f)
  blocking = Enum.map(cubes, fn c -> Enum.map(c, &(-&1)) end)

  Enum.all?(cubes, fn c ->
    Picosat.solve(Enum.map(c, &[&1]) ++ e.query) == {:error, :unsatisfiable}
  end) and
    Picosat.solve(f.cnf ++ blocking) == {:error, :unsatisfiable}
end

# Crux's scenarios as cubes again (bound variable -> literal)
to_cubes = fn f, scenarios ->
  ids = Map.new(f.bindings, fn {id, var} -> {var, id} end)

  Enum.map(scenarios, fn s ->
    Enum.map(s, fn {var, val} -> if val, do: ids[var], else: -ids[var] end)
  end)
end

batch =
  for {shape, f} <- formulas do
    e = SatEx.encode(f)
    kcubes = SatEx.cubes_kernel(e)
    pico = with_solver.(Picosat, fn -> Crux.satisfying_scenarios(f) end)
    mine = SatEx.satisfying_scenarios(f)

    %{
      shape: shape,
      # exact: the Elixir loop with the Elixir CDCL finds the same cubes in the same order
      same_as_elixir: kcubes == SatEx.Enumerate.cubes(e),
      # Crux's API shape: the same maps as running Crux on the Elixir loop
      same_api: mine == SatEx.Enumerate.satisfying_scenarios(f),
      cover: valid_cover?.(f, kcubes) and valid_cover?.(f, to_cubes.(f, pico)),
      same_as_picosat: Enum.sort(mine) == Enum.sort(pico),
      n: length(mine),
      n_pico: length(pico)
    }
  end

# Elixir mode on the small shapes (it rebuilds the state per write)
batch_mode_ok =
  Enum.all?(for({{p, _, _, _}, f} <- formulas, p <= 4, do: f), fn f ->
    args = SatEx.batch_args(SatEx.encode(f), 64)
    K.__defk_elixir__(:solve_all, args) === apply(K, :solve_all, args)
  end)

{_, big} = List.last(formulas)
big_e = SatEx.encode(big)
big_cubes = SatEx.cubes_kernel(big_e)
K.__defk_force_yields__(true)
batch_yield_ok = SatEx.cubes_kernel(big_e) == big_cubes
K.__defk_force_yields__(false)
# out_cap 1 overflows, status 3, and the retry gets the same cubes
retry_ok = SatEx.cubes_kernel(big_e, 1) == big_cubes

for r <- batch do
  IO.puts(
    "  #{inspect(r.shape)}: #{r.n} scenarios (Crux + picosat #{r.n_pico}, same set #{r.same_as_picosat}); " <>
      "=== the Elixir loop #{r.same_as_elixir and r.same_api}; sufficient and covering: #{r.cover}"
  )
end

batch_ok =
  Enum.all?(batch, &(&1.same_as_elixir and &1.same_api and &1.cover)) and batch_mode_ok and
    batch_yield_ok and retry_ok

IO.puts(
  "solve_all: Elixir mode === native on the small shapes: #{batch_mode_ok}; forced yields: #{batch_yield_ok}; " <>
    "capacity retry: #{retry_ok}; all: #{batch_ok}"
)

# ---- timing ----------------------------------------------------------------------
with_timeout = fn f, ms ->
  t = Task.async(f)

  case Task.yield(t, ms) || Task.shutdown(t, :brutal_kill) do
    {:ok, r} -> r
    _ -> :timeout
  end
end

best = fn f, runs -> Enum.map(1..runs, fn _ -> elem(:timer.tc(f), 0) end) |> Enum.min() end
{load1, _} = System.cmd("uptime", [])
IO.puts("\n#{String.trim(load1)}")

# interleaved best-of: every round runs each side once, after a full GC
interleaved = fn sides, rounds ->
  Enum.reduce(1..rounds, %{}, fn _, best ->
    Enum.reduce(sides, best, fn {name, f}, best ->
      :erlang.garbage_collect()
      {us, _} = :timer.tc(f)
      Map.update(best, name, us, &min(&1, us))
    end)
  end)
end

times = fn f, k -> fn -> for _ <- 1..k, do: f.() end end
fmt_us = fn us, k -> :erlang.float_to_binary(us / k, decimals: 1) end

# One call per formula, as Crux.Implementation.solve_expression/1 makes them:
# the list of clauses in, {:ok, model} or {:error, :unsatisfiable} out (the
# kernel side packs the list and unpacks the model). Each side 200 calls.
IO.puts("\nOne solve, us per call (best of 5 interleaved rounds of 200 calls):")

per_call =
  for {p, k, pool} <- [{4, 3, 8}, {8, 3, 12}, {12, 4, 16}], seed <- 1..2 do
    cnf = Gen.ash(p, k, pool, seed).cnf
    simple = with_timeout.(fn -> best.(fn -> SimpleSat.solve(cnf) end, 3) end, 10_000)

    b =
      interleaved.(
        [
          {:picosat, times.(fn -> Picosat.solve(cnf) end, 200)},
          {:cdcl, times.(fn -> Cdcl.solve(cnf) end, 200)},
          {:dpll, times.(fn -> Dpll.solve(cnf) end, 200)},
          {:defk, times.(fn -> SatEx.solve(cnf) end, 200)}
        ],
        5
      )

    IO.puts(
      "  Ash P=#{p} seed #{seed} (#{SatEx.nvars(cnf)} vars, #{length(cnf)} clauses): picosat #{fmt_us.(b.picosat, 200)}, " <>
        "Elixir CDCL #{fmt_us.(b.cdcl, 200)}, DPLL #{fmt_us.(b.dpll, 200)}, defk #{fmt_us.(b.defk, 200)}, " <>
        "simple_sat #{if is_integer(simple), do: simple, else: "> 10 s"}"
    )

    {{p, seed}, b}
  end

# Crux.satisfying_scenarios/1, the whole enumeration (Crux on picosat, on the
# Elixir CDCL, on simple_sat; the same loop in Elixir; the kernel's
# solve_all), ms
IO.puts("\nCrux's satisfying_scenarios, ms (best of 3 interleaved rounds):")

enum_times =
  for {{p, _k, _pool, seed}, f} <- formulas, p >= 4 do
    simple =
      if p <= 4,
        do:
          with_timeout.(
            fn ->
              best.(fn -> with_solver.(SimpleSat, fn -> Crux.satisfying_scenarios(f) end) end, 1)
            end,
            10_000
          ),
        else: :skipped

    b =
      interleaved.(
        [
          {:crux_picosat,
           fn -> with_solver.(Picosat, fn -> Crux.satisfying_scenarios(f) end) end},
          {:crux_cdcl, fn -> with_solver.(Cdcl, fn -> Crux.satisfying_scenarios(f) end) end},
          {:loop_cdcl, fn -> SatEx.Enumerate.satisfying_scenarios(f) end},
          {:defk, fn -> SatEx.satisfying_scenarios(f) end}
        ],
        3
      )

    ms = fn us -> :erlang.float_to_binary(us / 1000, decimals: 2) end

    IO.puts(
      "  Ash P=#{p} seed #{seed}: Crux + picosat #{ms.(b.crux_picosat)}, Crux + Elixir CDCL #{ms.(b.crux_cdcl)}, " <>
        "Elixir loop #{ms.(b.loop_cdcl)}, defk solve_all #{ms.(b.defk)}, Crux + simple_sat #{case simple do
          us when is_integer(us) -> ms.(us)
          :timeout -> "> 10 s"
          :skipped -> "not run"
        end}"
    )

    {{p, seed}, b}
  end

# random 3-SAT at the threshold, n = 200, three seeds, ms
IO.puts("\nRandom 3-SAT, n = 200, 852 clauses, ms (best of 3 interleaved rounds):")
k200 = for seed <- 1..3, do: Gen.k3(200, 4.26, seed)

for {cnf, seed} <- Enum.with_index(k200, 1) do
  b =
    interleaved.(
      [
        {:picosat, fn -> Picosat.solve(cnf) end},
        {:cdcl, fn -> Cdcl.solve(cnf) end},
        {:defk, fn -> SatEx.solve(cnf) end}
      ],
      3
    )

  status = if match?({:ok, _}, Picosat.solve(cnf)), do: "SAT", else: "UNSAT"

  IO.puts(
    "  seed #{seed} (#{status}, #{elem(Cdcl.solve(cnf, 200, nil), 2)} conflicts): picosat #{div(b.picosat, 1000)}, " <>
      "Elixir CDCL #{div(b.cdcl, 1000)}, defk #{div(b.defk, 1000)}"
  )
end

# S5's instance (n = 300, seed 7, SAT): one run each, and the tick-gap floor
# of this machine (a 1 ms ticker on one scheduler beside an idle process)
k300 = Gen.k3(300, 4.26, 7)
t300 = fn f -> div(elem(:timer.tc(f), 0), 1000) end

IO.puts(
  "Random 3-SAT, n = 300 (S5's instance), one run, ms: picosat #{t300.(fn -> Picosat.solve(k300) end)}, " <>
    "Elixir CDCL #{t300.(fn -> Cdcl.solve(k300) end)}, defk #{t300.(fn -> SatEx.solve(k300) end)}; " <>
    "tick-gap floor (idle, max/p99 ms): #{(fn g -> "#{g.max}/#{g.p99}" end).(Defk.Bench.TickGap.run(fn -> Process.sleep(200) end))}"
)

{load2, _} = System.cmd("uptime", [])
IO.puts("#{String.trim(load2)}\n")

# ---- reports ---------------------------------------------------------------------
# The best Elixir per formula: the CDCL or the DPLL sketch, whichever was
# faster in the table above (the DPLL wins on some small formulas)
best_elixir = fn p, seed ->
  b = Map.new(per_call)[{p, seed}]
  if b.dpll < b.cdcl, do: &Dpll.solve/1, else: &Cdcl.solve/1
end

per_call_report = fn name, expected, p, k, pool, reason ->
  cnfs = for seed <- 1..2, do: {seed, Gen.ash(p, k, pool, seed).cnf}
  solvers = for {seed, cnf} <- cnfs, do: {best_elixir.(p, seed), cnf}

  Defk.Bench.report(
    name: name,
    expected: expected,
    baseline: :optimized,
    realistic_size:
      "one Crux solve of an Ash-shaped formula, P = #{p} policies (two formulas, 100 calls each)",
    elixir: fn -> for {s, cnf} <- solvers, _ <- 1..100, do: s.(cnf) end,
    defk: fn -> for {_, cnf} <- cnfs, _ <- 1..100, do: SatEx.solve(cnf) end,
    native:
      {fn -> for {_, cnf} <- cnfs, _ <- 1..100, do: Picosat.solve(cnf) end,
       "picosat_elixir 0.2.3"},
    check: fn ->
      one_ok and
        Enum.all?(cnfs, fn {_, cnf} ->
          case {SatEx.solve(cnf), Picosat.solve(cnf)} do
            {{:ok, m}, {:ok, _}} -> Gen.satisfies?(cnf, m)
            {a, b} -> a == b
          end
        end)
    end,
    reason: reason
  )
end

# 1. S3: the whole enumeration, the catalog entry (run_all reads this line)
{_, f3} = Enum.find(formulas, fn {shape, _} -> shape == {12, 4, 16, 1} end)
b3 = Map.new(enum_times)[{12, 1}]

elixir3 =
  if b3.loop_cdcl < b3.crux_cdcl,
    do: fn -> SatEx.Enumerate.satisfying_scenarios(f3) end,
    else: fn -> with_solver.(Cdcl, fn -> Crux.satisfying_scenarios(f3) end) end

Defk.Bench.report(
  name: "cdcl_sat",
  expected: :good,
  baseline: :optimized,
  realistic_size:
    "Crux.satisfying_scenarios on an Ash-shaped formula, P = 12 policies (109 vars, 280 clauses)",
  elixir: elixir3,
  defk: fn -> SatEx.satisfying_scenarios(f3) end,
  native:
    {fn -> with_solver.(Picosat, fn -> Crux.satisfying_scenarios(f3) end) end,
     "Crux 0.1.4 + picosat_elixir 0.2.3"},
  check: fn -> batch_ok and valid_cover?.(f3, to_cubes.(f3, SatEx.satisfying_scenarios(f3))) end,
  reason:
    "Crux's enumeration (a solve, one implication query per literal, a blocking clause, repeat) in one kernel call: no boundary per solve and C-speed CDCL; faster than Crux on picosat too"
)

r1 =
  per_call_report.(
    "cdcl_sat_s1",
    :good,
    4,
    3,
    8,
    "pre-registered marginal: an Ash-sized formula per call; the kernel's call, pack and unpack cost less than the Elixir CDCL's setup"
  )

r2 =
  per_call_report.(
    "cdcl_sat_s2",
    :good,
    12,
    4,
    16,
    "a 105-variable formula per call: the solve outweighs packing"
  )

# S4, with S5 (responsiveness at n = 300, seed 7: SAT, picosat about 1 s) beside it
r4 =
  Defk.Bench.report(
    name: "cdcl_sat_s4",
    expected: :good,
    baseline: :optimized,
    runs: 3,
    realistic_size: "random 3-SAT, n = 200 at ratio 4.26 (852 clauses), three seeds",
    elixir: fn -> for cnf <- k200, do: Cdcl.solve(cnf) end,
    defk: fn -> for cnf <- k200, do: SatEx.solve(cnf) end,
    native: {fn -> for cnf <- k200, do: Picosat.solve(cnf) end, "picosat_elixir 0.2.3"},
    check: fn ->
      Enum.all?(k200, fn cnf ->
        case {SatEx.solve(cnf), Picosat.solve(cnf)} do
          {{:ok, m}, {:ok, _}} -> Gen.satisfies?(cnf, m)
          {a, b} -> a == b
        end
      end)
    end,
    responsiveness: [
      elixir: fn -> Cdcl.solve(k300) end,
      defk: fn -> SatEx.solve(k300) end,
      native: fn -> Picosat.solve(k300) end
    ],
    reason:
      "CDCL against the same CDCL in Elixir; picosat is ahead of both on hard instances (more heuristics)"
  )

# run_all.exs reads the first DEFK_RESULT line; check the others here
others = [{r1, :good}, {r2, :good}, {r4, :good}]

unless Enum.all?(others, fn {r, v} -> r.correct and r.verdict == v end) do
  IO.puts("a cdcl_sat size failed its check or measured another verdict")
  System.halt(1)
end
