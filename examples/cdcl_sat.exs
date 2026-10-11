# cdcl_sat: a bounded CDCL SAT solver as a kernel, measured on Crux's
# scenario enumeration (Ash authorization), against picosat_elixir and
# simple_sat
#
# Work in progress (defk-52v.15): stage 1, the Elixir baselines.
#
#   elixir examples/cdcl_sat.exs

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

# ---- the Elixir baselines against the anchors ------------------------------------
alias SatEx.{Cdcl, Dpll, Gen}

with_timeout = fn f, ms ->
  t = Task.async(f)

  case Task.yield(t, ms) || Task.shutdown(t, :brutal_kill) do
    {:ok, r} -> r
    _ -> :timeout
  end
end

# status equal to picosat's, and a SAT model satisfies every clause
anchor_ok =
  Enum.all?(1..1000, fn seed ->
    {n, cnf} = Gen.cnf(seed, 40, 10)

    case {Cdcl.solve(cnf, n, nil), Picosat.solve(cnf)} do
      {{1, m, _}, {:ok, _}} -> Gen.satisfies?(cnf, m)
      {{0, _, _}, {:error, :unsatisfiable}} -> true
      _ -> false
    end
  end)

IO.puts(
  "Elixir CDCL vs picosat on 1,000 random CNFs (1-40 variables, 1-10 literals): #{anchor_ok}"
)

best = fn f, runs ->
  Enum.map(1..runs, fn _ -> elem(:timer.tc(f), 0) end) |> Enum.min()
end

for {label, cnf} <- [
      {"S1 Ash P=4", Gen.ash(4, 3, 8, 1).cnf},
      {"S2 Ash P=12", Gen.ash(12, 4, 16, 1).cnf},
      {"3-SAT n=100", Gen.k3(100, 4.26, 1)},
      {"3-SAT n=200", Gen.k3(200, 4.26, 1)}
    ] do
  t = fn f -> with_timeout.(fn -> best.(f, 3) end, 20_000) end

  IO.puts(
    "#{label}: picosat #{t.(fn -> Picosat.solve(cnf) end)} us, Elixir CDCL #{t.(fn -> Cdcl.solve(cnf) end)} us, " <>
      "DPLL #{t.(fn -> Dpll.solve(cnf) end)} us, simple_sat #{t.(fn -> SimpleSat.solve(cnf) end)} us"
  )
end
