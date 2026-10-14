# monte_carlo_rtp: Monte Carlo return-to-player simulation of a 5-reel slot,
# with the kernel running :rand's own exsss generator bit for bit
#
# Why people reach for a NIF here: RTP and volatility certification runs
# simulate a game hundreds of millions of times per build (draw reel stops
# from a PRNG, look symbols and paylines up in tables, add the win). This is
# where iGaming teams leave Elixir or write a NIF. The same loop shape covers
# path pricing and risk aggregation.
# Expected verdict: good
#
#   elixir examples/monte_carlo_rtp.exs                  # agreement + report
#   RTP_VARIANTS=1 elixir examples/monte_carlo_rtp.exs   # also every variant and the scaling
#
# Scope: this is the simulation and verification side. A certified production
# RNG is a compliance artifact (GLI-19 style): a kernel generator would need
# the same certification path as any other implementation, and nothing here
# changes that. Both sides use :rand's default algorithm so the kernel can be
# checked against :rand itself, not to propose it as a game RNG.
#
# The generator. :rand's default `exsss` (Xorshift116**, two 58-bit words) is
# pure Erlang in OTP's rand.erl (OTP 29.0.3, stdlib 8.0.2,
# https://github.com/erlang/otp/blob/OTP-29.0.3/lib/stdlib/src/rand.erl):
#
#   exsss_next([S1|S0]) ->
#       %% Note: members s0 and s1 are swapped here
#       S0_1 = ?MASK(58, S0),
#       NewS1 = ?exs_next(S0_1, S1, S1_b),
#       {?scramble_starstar(S0_1, V_1, V_2), [S0_1|NewS1]}.
#
#   exs_next(S0, S1, S1_b):
#       S1_b = ?MASK(58, S1) bxor ?BSL(58, S1, 24),
#       S1_b bxor S0 bxor (S1_b bsr 11) bxor (S0 bsr 41)
#   scramble_starstar(S, V_a, V_b):        %% ((S * 5) rotl 7) * 9 mod 2^58
#       V_a = S + ?BSL(58, S, 2),
#       V_b = ?BSL(58, V_a, 7) bor ?MASK(7, V_a bsr (58-7)),
#       ?MASK(58, V_b + ?BSL(58, V_b, 3))
#   (?BSL(Bits, X, N) is (X band (2^(Bits-N) - 1)) bsl N: masked before the shift)
#
#   exsss_uniform({AlgHandler, R0}) ->
#       {I, R1} = exsss_next(R0),
#       {(I bsr (58-53)) * ?TWO_POW_MINUS53, {AlgHandler, R1}}.
#
# The state is {AlgHandler, [S1 | S0]}, an improper list of two words; the
# kernel takes them as (h, t) = (S1, S0) and returns the new pair, so state
# travels as values. Every intermediate is below 2^59 and every bsl operand
# is masked first, so i64 holds it and bsl never overflows. The float is
# float(bsr(i, 5)) * 2^-53 (exact). Reel stops use :rand.uniform_s(n, st),
# whose range macro returns V + 1 when V < n, else I + 1 with I = V rem n
# when V - I =< 2^58 - n, else redraws; the kernel does the same, redraw
# included (stop = uniform_s(n) - 1).
#
# Agreement, checked on every run: for three seeds, 1M kernel draws equal
# :rand.uniform_s(2^58, st) - 1 (the raw word) and :rand.uniform_s/1 (the
# float) exactly, and the final state words are equal. A 31-stop model run
# from a constructed state whose next word is 2^58 - 1 forces the redraw
# (with 32 stops, a power of two, :rand never redraws), and the kernel equals
# :rand there too. The simulation totals (bet, win, hits, final state per
# chunk) of every Elixir variant equal the kernel's at 1M spins, and the
# reported pair at 10M. Elixir mode cannot be compiled in a Mix.install
# script (Defk.ElixirMode.setup! refuses a nil Mix env), so it was checked
# once with MIX_ENV=test mix run: draws, uniforms and simulate for the three
# seeds (2000 draws/spins) and the forced redraw, native === Elixir mode.
#
# The model: 5 reels of 32 stops (8 symbols, 7 of the commonest down to 1 of
# the rarest per reel, shuffled per reel with a fixed seed), 10 fixed
# paylines over a 3-row window (row offsets 0..2 from the stop), left-to-right
# runs of 3, 4 or 5 pay from a [i64] paytable (symbol * 6 + run), 1 credit a
# line. RTP 96.4-96.6%, hit rate 20.6%. A run of N spins is 48 chunks with
# independent seeds :rand.seed_s(:exsss, {42, i, 0}) under Task.async_stream
# on all schedulers, summed; both sides consume the generator identically, so
# their totals are equal, not just close.
#
# Elixir baseline: optimised. Measured on an M-series Mac (12 schedulers),
# OTP 29, Elixir 1.20; "1 process" is best of 3 over 1M spins in one process,
# "12 sched" best of 3 over 10M spins in 48 chunks:
#
#   variant                                              1 process   12 sched
#   :rand.uniform_s/2, model in flat tuples, rem/2        139 ns/spin  186 ms
#   :rand.uniform_s/2, reels and pays in :array           325 ns/spin  412 ms
#   :rand.uniform_s/2, precomputed windows (no rem/2)     111 ns/spin  152 ms
#   exsss inlined in Elixir (Bitwise), windows            109 ns/spin  140 ms  <- reported
#   defk                                                    34 ns/spin   45 ms
#
# The windows layout (per reel and stop, a tuple of the symbols at offsets
# 0..2; pays as one tuple per symbol) is the "precomputed table" variant; the
# kernel gets the same trick (each strip followed by its first stops, so no
# rem/2 per line). Inlining exsss saves the plug-in dispatch of :rand (about
# 2-8%, within noise between runs); it gives the same draws. Every variant
# uses tail recursion with integer arithmetic only, and a cond that stops at
# the first reel that differs (the kernel too: a branch-free run count was
# 45 vs 27 ns/spin in the kernel, slower).
#
# Verdict at the realistic size, 100M spins on all schedulers: Elixir
# 1.42-1.49 s, defk 0.43-0.47 s, 3.2-3.3x (three runs). Sweep 1M / 10M /
# 100M: 1.0-1.1x / 2.8-3.2x / 3.1-3.35x (crossover 10M). At 1M each chunk is ~0.7 ms of kernel work and
# the 48 kernel tasks ran on only 2-3 of 12 schedulers (scheduler_id per
# task), where Elixir tasks spread over all 12; balancing catches up on
# longer chunks. Scaling, 10M spins, 48 chunks:
#
#   schedulers   1        2       4       8       12
#   elixir       1854 ms  786 ms  351 ms  166 ms  139 ms
#   defk          347 ms  177 ms   93 ms   52 ms   48 ms
#   speedup      5.3x     4.5x    3.8x    3.2x    2.9x
#
# (Elixir on one scheduler is slower per spin than one process on a
# 12-scheduler VM, 185 vs 109 ns; not investigated.) The machine has
# performance and efficiency cores, so neither side scales linearly past 8.
#
# Responsiveness, one 100M run on one scheduler with a 1 ms ticker (over 10 s
# for Elixir, ~3.5 s for defk): Elixir max 2.9-3.3 ms (38 ms in one of three
# runs) / p99 2.0-2.2 ms, defk max 2.3-2.6 ms / p99 2.3 ms. One 100M run of
# the kernel on all schedulers yields 16-20k times with 48 promotions (one
# per chunk) and no frames left live (__defk_stats__).
#
# Not tried: a SIMD or multi-stream generator (several states per kernel
# call), `:rand.jump/1` for chunk seeds instead of independent seeds, Nx.

Mix.install([{:defk, path: Path.expand("..", __DIR__)}])

defmodule RTP.Kernels do
  use Defk

  # exsss state [h | t] (rand.erl's improper list [S1 | S0]). One step:
  # t1 = t band M58, output starstar(t1), new state [t1 | next_tail(h, t1)].
  # 2^58 - 1 = 288230376151711743, 2^34 - 1 = 17179869183,
  # 2^56 - 1 = 72057594037927935, 2^51 - 1 = 2251799813685247,
  # 2^55 - 1 = 36028797018963967.

  # exs_next: S1_b = mask58(S1) bxor BSL(58, S1, 24); S1_b bxor S0 bxor (S1_b bsr 11) bxor (S0 bsr 41)
  defk next_tail(h :: i64, t1 :: i64) :: i64 do
    s1b = bxor(band(h, 288_230_376_151_711_743), bsl(band(h, 17_179_869_183), 24))
    bxor(bxor(bxor(s1b, t1), bsr(s1b, 11)), bsr(t1, 41))
  end

  # scramble_starstar: ((S * 5) rotl 7) * 9 modulo 2^58
  defk starstar(s :: i64) :: i64 do
    va = s + bsl(band(s, 72_057_594_037_927_935), 2)
    vb = bor(bsl(band(va, 2_251_799_813_685_247), 7), band(bsr(va, 51), 127))
    band(vb + bsl(band(vb, 36_028_797_018_963_967), 3), 288_230_376_151_711_743)
  end

  # n raw 58-bit outputs of exsss_next/1, and the state after them
  defk draws(h :: i64, t :: i64, n :: i64) :: {[i64], i64, i64} do
    out = alloc(i64, n)

    {h1, t1} =
      for i <- 0..(n - 1)//1, reduce: {h, t} do
        {h, t} ->
          s = band(t, 288_230_376_151_711_743)
          out[i] = starstar(s)
          {s, next_tail(h, s)}
      end

    {out, h1, t1}
  end

  # n floats of :rand.uniform_s/1 (exsss_uniform/1: (I bsr 5) * 2^-53)
  defk uniforms(h :: i64, t :: i64, n :: i64) :: {[f64], i64, i64} do
    out = alloc(f64, n)

    {h1, t1} =
      for i <- 0..(n - 1)//1, reduce: {h, t} do
        {h, t} ->
          s = band(t, 288_230_376_151_711_743)
          out[i] = float(bsr(starstar(s), 5)) * 1.1102230246251565e-16
          {s, next_tail(h, s)}
      end

    {out, h1, t1}
  end

  # spins of the slot model. reels: 5 strips of length(reels)/5 symbols, lines:
  # 5 row offsets per payline, pays: symbol * 6 + run length -> credits.
  # Reel stops are :rand.uniform_s(n, state) - 1, rejection step included.
  defk simulate(reels :: [i64], lines :: [i64], pays :: [i64], h0 :: i64, t0 :: i64, spins :: i64) ::
         {i64, i64, i64, i64, i64} do
    n = div(length(reels), 5)
    nlines = div(length(lines), 5)
    limit = 288_230_376_151_711_744 - n

    # each strip followed by its first maxo stops, so a line reads
    # strips[r * w + stop + offset] without rem/2
    maxo =
      for o <- lines, reduce: 0 do
        m -> max(m, o)
      end

    w = n + maxo
    strips = alloc(i64, 5 * w)

    for r <- 0..4//1, j <- 0..(w - 1)//1 do
      strips[r * w + j] = reels[r * n + rem(j, n)]
    end

    stops = alloc(i64, 5)

    for _ <- 1..spins//1, reduce: {0, 0, 0, h0, t0} do
      {bet, win, hits, h, t} ->
        {h2, t2} =
          for r <- 0..4//1, reduce: {h, t} do
            {h, t} ->
              {h1, t1, stop} =
                Enum.reduce_while(0..4_611_686_018_427_387_903//1, {h, t, 0}, fn _, {h, t, _} ->
                  s = band(t, 288_230_376_151_711_743)
                  v = starstar(s)
                  i = rem(v, n)
                  nt = next_tail(h, s)

                  if v - i <= limit do
                    {:halt, {s, nt, i}}
                  else
                    {:cont, {s, nt, 0}}
                  end
                end)

              stops[r] = r * w + stop
              {h1, t1}
          end

        sw =
          for l <- 0..(nlines - 1)//1, reduce: 0 do
            acc ->
              o = l * 5
              first = strips[stops[0] + lines[o]]

              # run length from the left, stopping at the first reel that differs
              count =
                cond do
                  strips[stops[1] + lines[o + 1]] != first -> 1
                  strips[stops[2] + lines[o + 2]] != first -> 2
                  strips[stops[3] + lines[o + 3]] != first -> 3
                  strips[stops[4] + lines[o + 4]] != first -> 4
                  true -> 5
                end

              acc + pays[first * 6 + count]
          end

        {bet + nlines, win + sw, if(sw > 0, do: hits + 1, else: hits), h2, t2}
    end
  end
end

defmodule RTP.Elixir do
  import Bitwise

  @m58 (1 <<< 58) - 1

  # the state words of a :rand exsss state ([h | t], rand.erl's [S1 | S0]), and back
  def words({%{type: :exsss}, [h | t]}), do: {h, t}
  def state({h, t}), do: {elem(:rand.seed_s(:exsss, 1), 0), [h | t]}

  # ---- variant 1 (reported): :rand.uniform_s/2, model in flat tuples -------
  # model: {reels, n, lines, pays}, reels a flat tuple of 5 * n symbols, lines
  # a list of {o0, o1, o2, o3, o4} row offsets, pays a flat tuple sym * 6 + run
  def simulate({reels, n, lines, pays}, st, spins),
    do: loop(reels, n, lines, length(lines), pays, st, spins, 0, 0, 0)

  defp loop(_reels, _n, _lines, _nl, _pays, st, 0, bet, win, hits),
    do: {bet, win, hits, words(st)}

  defp loop(reels, n, lines, nl, pays, st, k, bet, win, hits) do
    {a, st} = :rand.uniform_s(n, st)
    {b, st} = :rand.uniform_s(n, st)
    {c, st} = :rand.uniform_s(n, st)
    {d, st} = :rand.uniform_s(n, st)
    {e, st} = :rand.uniform_s(n, st)
    w = wins(lines, reels, n, pays, a - 1, b - 1, c - 1, d - 1, e - 1, 0)
    hits = if w > 0, do: hits + 1, else: hits
    loop(reels, n, lines, nl, pays, st, k - 1, bet + nl, win + w, hits)
  end

  defp wins([], _reels, _n, _pays, _a, _b, _c, _d, _e, acc), do: acc

  defp wins([{o0, o1, o2, o3, o4} | rest], reels, n, pays, a, b, c, d, e, acc) do
    s = elem(reels, rem(a + o0, n))

    run =
      cond do
        elem(reels, n + rem(b + o1, n)) != s -> 1
        elem(reels, 2 * n + rem(c + o2, n)) != s -> 2
        elem(reels, 3 * n + rem(d + o3, n)) != s -> 3
        elem(reels, 4 * n + rem(e + o4, n)) != s -> 4
        true -> 5
      end

    wins(rest, reels, n, pays, a, b, c, d, e, acc + elem(pays, s * 6 + run))
  end

  # ---- variant 2: :array for reels and pays ---------------------------------
  def simulate_array({reels, n, lines, pays}, st, spins) do
    ra = :array.from_list(Tuple.to_list(reels))
    pa = :array.from_list(Tuple.to_list(pays))
    loop_a(ra, n, lines, length(lines), pa, st, spins, 0, 0, 0)
  end

  defp loop_a(_reels, _n, _lines, _nl, _pays, st, 0, bet, win, hits),
    do: {bet, win, hits, words(st)}

  defp loop_a(reels, n, lines, nl, pays, st, k, bet, win, hits) do
    {a, st} = :rand.uniform_s(n, st)
    {b, st} = :rand.uniform_s(n, st)
    {c, st} = :rand.uniform_s(n, st)
    {d, st} = :rand.uniform_s(n, st)
    {e, st} = :rand.uniform_s(n, st)
    w = wins_a(lines, reels, n, pays, a - 1, b - 1, c - 1, d - 1, e - 1, 0)
    hits = if w > 0, do: hits + 1, else: hits
    loop_a(reels, n, lines, nl, pays, st, k - 1, bet + nl, win + w, hits)
  end

  defp wins_a([], _reels, _n, _pays, _a, _b, _c, _d, _e, acc), do: acc

  defp wins_a([{o0, o1, o2, o3, o4} | rest], reels, n, pays, a, b, c, d, e, acc) do
    s = :array.get(rem(a + o0, n), reels)

    run =
      cond do
        :array.get(n + rem(b + o1, n), reels) != s -> 1
        :array.get(2 * n + rem(c + o2, n), reels) != s -> 2
        :array.get(3 * n + rem(d + o3, n), reels) != s -> 3
        :array.get(4 * n + rem(e + o4, n), reels) != s -> 4
        true -> 5
      end

    wins_a(rest, reels, n, pays, a, b, c, d, e, acc + :array.get(s * 6 + run, pays))
  end

  # ---- variant 3: precomputed windows -----------------------------------------
  # per reel a tuple of n stops, each the tuple of symbols at every offset a
  # line uses (offsets 0..2), so a line lookup is two elem/2 and no rem/2;
  # pays as one tuple per symbol, indexed by run length
  def windows({reels, n, lines, pays}) do
    reel = fn r ->
      List.to_tuple(
        for s <- 0..(n - 1) do
          List.to_tuple(for o <- 0..2, do: elem(reels, r * n + rem(s + o, n)))
        end
      )
    end

    pt =
      List.to_tuple(
        for s <- 0..(div(tuple_size(pays), 6) - 1),
            do: List.to_tuple(for k <- 0..5, do: elem(pays, s * 6 + k))
      )

    {{reel.(0), reel.(1), reel.(2), reel.(3), reel.(4)}, n, lines, pt}
  end

  def simulate_windows({{r0, r1, r2, r3, r4}, n, lines, pt}, st, spins),
    do: loop_w(r0, r1, r2, r3, r4, n, lines, length(lines), pt, st, spins, 0, 0, 0)

  defp loop_w(_, _, _, _, _, _n, _lines, _nl, _pt, st, 0, bet, win, hits),
    do: {bet, win, hits, words(st)}

  defp loop_w(r0, r1, r2, r3, r4, n, lines, nl, pt, st, k, bet, win, hits) do
    {a, st} = :rand.uniform_s(n, st)
    {b, st} = :rand.uniform_s(n, st)
    {c, st} = :rand.uniform_s(n, st)
    {d, st} = :rand.uniform_s(n, st)
    {e, st} = :rand.uniform_s(n, st)

    w =
      wins_w(
        lines,
        elem(r0, a - 1),
        elem(r1, b - 1),
        elem(r2, c - 1),
        elem(r3, d - 1),
        elem(r4, e - 1),
        pt,
        0
      )

    hits = if w > 0, do: hits + 1, else: hits
    loop_w(r0, r1, r2, r3, r4, n, lines, nl, pt, st, k - 1, bet + nl, win + w, hits)
  end

  defp wins_w([], _a, _b, _c, _d, _e, _pt, acc), do: acc

  defp wins_w([{o0, o1, o2, o3, o4} | rest], a, b, c, d, e, pt, acc) do
    s = elem(a, o0)

    run =
      cond do
        elem(b, o1) != s -> 1
        elem(c, o2) != s -> 2
        elem(d, o3) != s -> 3
        elem(e, o4) != s -> 4
        true -> 5
      end

    wins_w(rest, a, b, c, d, e, pt, acc + elem(elem(pt, s), run))
  end

  # ---- variant 4: exsss inlined in Elixir (no :rand plug-in dispatch) --------
  # the same arithmetic as rand.erl's exsss_next/1 and the uniform_range macro,
  # on the two state words, with the windows layout of variant 3
  def simulate_inline({{r0, r1, r2, r3, r4}, n, lines, pt}, {h, t}, spins),
    do: loop_i(r0, r1, r2, r3, r4, n, lines, length(lines), pt, h, t, spins, 0, 0, 0)

  defp loop_i(_, _, _, _, _, _n, _lines, _nl, _pt, h, t, 0, bet, win, hits),
    do: {bet, win, hits, {h, t}}

  defp loop_i(r0, r1, r2, r3, r4, n, lines, nl, pt, h, t, k, bet, win, hits) do
    {a, h, t} = range(n, h, t)
    {b, h, t} = range(n, h, t)
    {c, h, t} = range(n, h, t)
    {d, h, t} = range(n, h, t)
    {e, h, t} = range(n, h, t)
    w = wins_w(lines, elem(r0, a), elem(r1, b), elem(r2, c), elem(r3, d), elem(r4, e), pt, 0)
    hits = if w > 0, do: hits + 1, else: hits
    loop_i(r0, r1, r2, r3, r4, n, lines, nl, pt, h, t, k - 1, bet + nl, win + w, hits)
  end

  # :rand.uniform_s(n, st) - 1 for n =< 2^58
  defp range(n, h, t) do
    s = t &&& @m58
    v = starstar(s)
    nt = next_tail(h, s)
    i = rem(v, n)
    if v - i <= @m58 + 1 - n, do: {i, s, nt}, else: range(n, s, nt)
  end

  def next_tail(h, s) do
    s1b = bxor(h &&& @m58, (h &&& (1 <<< 34) - 1) <<< 24)
    s1b |> bxor(s) |> bxor(s1b >>> 11) |> bxor(s >>> 41)
  end

  def starstar(s) do
    va = s + ((s &&& (1 <<< 56) - 1) <<< 2)
    vb = (va &&& (1 <<< 51) - 1) <<< 7 ||| (va >>> 51 &&& 127)
    vb + ((vb &&& (1 <<< 55) - 1) <<< 3) &&& @m58
  end
end

defmodule RTP do
  # 8 symbols, 0 the commonest; each reel holds every symbol this many times
  @counts [7, 6, 5, 4, 4, 3, 2, 1]
  # credits per line for a run of 3, 4, 5 of a symbol from the left reel
  @pays [
    {12, 35, 115},
    {17, 58, 230},
    {23, 86, 345},
    {35, 140, 575},
    {46, 210, 860},
    {70, 350, 1700},
    {115, 700, 3500},
    {290, 2300, 11500}
  ]
  # 10 fixed paylines: the row (0..2 below the stop) on each of the 5 reels
  @lines [
    {1, 1, 1, 1, 1},
    {0, 0, 0, 0, 0},
    {2, 2, 2, 2, 2},
    {0, 1, 2, 1, 0},
    {2, 1, 0, 1, 2},
    {0, 0, 1, 2, 2},
    {2, 2, 1, 0, 0},
    {1, 0, 0, 0, 1},
    {1, 2, 2, 2, 1},
    {1, 0, 1, 2, 1}
  ]

  # the model as Elixir terms ({reels, n, lines, pays}, see RTP.Elixir)
  # 32 stops; 31 (one symbol 0 fewer) for the rejection-step check
  def model(stops \\ 32) do
    [c0 | rest] = @counts
    counts = [c0 - (32 - stops) | rest]
    strip = Enum.flat_map(Enum.with_index(counts), fn {c, s} -> List.duplicate(s, c) end)

    {reels, _} =
      Enum.flat_map_reduce(0..4, :rand.seed_s(:exsss, 2026), fn _, st ->
        {tagged, st} =
          Enum.map_reduce(strip, st, fn s, st ->
            {r, st} = :rand.uniform_s(st)
            {{r, s}, st}
          end)

        {tagged |> Enum.sort() |> Enum.map(&elem(&1, 1)), st}
      end)

    pays = Enum.flat_map(@pays, fn {p3, p4, p5} -> [0, 0, 0, p3, p4, p5] end)
    {List.to_tuple(reels), length(strip), @lines, List.to_tuple(pays)}
  end

  # the same model as the kernel's packed arrays
  def packed({reels, _n, lines, pays}) do
    pack = fn l -> for x <- l, into: <<>>, do: <<x::signed-native-64>> end

    {pack.(Tuple.to_list(reels)), pack.(Enum.flat_map(lines, &Tuple.to_list/1)),
     pack.(Tuple.to_list(pays))}
  end

  # K independently seeded chunks of a run: one :rand exsss state each
  def chunks(seed, spins, k) do
    per = div(spins, k)

    for i <- 0..(k - 1),
        do: {:rand.seed_s(:exsss, {seed, i, 0}), per + if(i < rem(spins, k), do: 1, else: 0)}
  end

  # run every chunk on all schedulers and sum: {bet, win, hits, [final words]}
  def run(chunks, f) do
    chunks
    |> Task.async_stream(fn {st, spins} -> f.(st, spins) end,
      max_concurrency: System.schedulers_online(),
      timeout: :infinity
    )
    |> Enum.reduce({0, 0, 0, []}, fn {:ok, {b, w, h, s}}, {tb, tw, th, ss} ->
      {tb + b, tw + w, th + h, [s | ss]}
    end)
    |> then(fn {b, w, h, ss} -> {b, w, h, Enum.reverse(ss)} end)
  end
end

# ---- setup -----------------------------------------------------------------
model = RTP.model()
win_model = RTP.Elixir.windows(model)
{reels_b, lines_b, pays_b} = RTP.packed(model)

defk_chunk = fn st, spins ->
  {h, t} = RTP.Elixir.words(st)
  {b, w, hits, h1, t1} = RTP.Kernels.simulate(reels_b, lines_b, pays_b, h, t, spins)
  {b, w, hits, {h1, t1}}
end

variants = [
  rand_tuples: fn st, spins -> RTP.Elixir.simulate(model, st, spins) end,
  rand_array: fn st, spins -> RTP.Elixir.simulate_array(model, st, spins) end,
  rand_windows: fn st, spins -> RTP.Elixir.simulate_windows(win_model, st, spins) end,
  inline_exsss: fn st, spins ->
    RTP.Elixir.simulate_inline(win_model, RTP.Elixir.words(st), spins)
  end
]

# the reported Elixir side: the fastest variant measured (see the header)
elixir_chunk = variants[:inline_exsss]

# a run of `spins` spins as 48 seeded chunks on all schedulers
k = 48
elixir_run = fn spins -> RTP.run(RTP.chunks(42, spins, k), elixir_chunk) end
defk_run = fn spins -> RTP.run(RTP.chunks(42, spins, k), defk_chunk) end

time_ms = fn f, runs ->
  f.()

  Enum.min(
    for _ <- 1..runs do
      :erlang.garbage_collect()
      elem(:timer.tc(f), 0)
    end
  ) / 1000
end

# ---- 1. the generator: kernel vs :rand itself, 3 seeds x 1M draws ----------
# raw 58-bit words (:rand.uniform_s(2^58, st) - 1 is exsss_next/1's word: the
# range macro takes V < Range and returns V + 1), floats (:rand.uniform_s/1),
# and the state after the last draw
draws_n = 1_000_000

gen_ok =
  for seed <- [1, 4711, 20_261_009] do
    st = :rand.seed_s(:exsss, seed)
    {h, t} = RTP.Elixir.words(st)
    {raw, kh, kt} = RTP.Kernels.draws(h, t, draws_n)
    {fl, fh, ft} = RTP.Kernels.uniforms(h, t, draws_n)

    {ints, st_end} =
      Enum.map_reduce(1..draws_n, st, fn _, s ->
        {v, s} = :rand.uniform_s(288_230_376_151_711_744, s)
        {v - 1, s}
      end)

    {floats, _} = Enum.map_reduce(1..draws_n, st, fn _, s -> :rand.uniform_s(s) end)

    ok =
      for(<<x::signed-native-64 <- raw>>, do: x) == ints and
        for(<<x::float-native-64 <- fl>>, do: x) == floats and
        {kh, kt} == RTP.Elixir.words(st_end) and {fh, ft} == {kh, kt}

    IO.puts("seed #{seed}: #{draws_n} draws, ints, floats and final state equal :rand: #{ok}")
    ok
  end
  |> Enum.all?()

# ---- 2. the rejection step of :rand.uniform_s/2 ------------------------------
# with 32 stops (a power of two) :rand never redraws. With 31 it redraws when
# the word lands in the top 2^58 rem 31 = 8 values, about once in 2^55 draws,
# so build a state whose next word is 2^58 - 1 (starstar inverted with the
# multiplicative inverses noted in rand.erl) and compare 1000 spins of a
# 31-stop model against :rand from that state.
m58 = 288_230_376_151_711_743
v = m58
v9 = rem(v * 0x238E38E38E38E39, m58 + 1)
rot = Bitwise.bor(Bitwise.bsr(v9, 7), Bitwise.bsl(Bitwise.band(v9, 127), 51))
s0 = rem(rot * 0xCCCCCCCCCCCCCD, m58 + 1)
true = RTP.Kernels.starstar(s0) == v
{_, 31, _, _} = model31 = RTP.model(31)
{r31, l31, p31} = RTP.packed(model31)
st31 = RTP.Elixir.state({12_345, s0})

reject_ok =
  RTP.Elixir.simulate(model31, st31, 1000) ==
    (fn ->
       {b, w, hi, h, t} = RTP.Kernels.simulate(r31, l31, p31, 12_345, s0, 1000)
       {b, w, hi, {h, t}}
     end).() and
    RTP.Elixir.simulate_inline(RTP.Elixir.windows(model31), {12_345, s0}, 1000) ==
      RTP.Elixir.simulate(model31, st31, 1000)

IO.puts("rejection step (31 stops, forced redraw): kernel and Elixir equal :rand: #{reject_ok}")

# ---- 3. the model: every Elixir variant and the kernel give the same totals -
spins_check = 1_000_000
chunks = RTP.chunks(7, spins_check, k)
ref = RTP.run(chunks, defk_chunk)

model_ok =
  Enum.all?(variants, fn {name, f} ->
    ok = RTP.run(chunks, f) == ref
    unless ok, do: IO.puts("variant #{name} disagrees")
    ok
  end)

{bet, win, hits, _} = ref

IO.puts(
  "#{spins_check} spins: RTP #{Float.round(win / bet * 100, 2)}%, hit rate #{Float.round(hits / spins_check * 100, 2)}%, all #{length(variants)} Elixir variants equal the kernel: #{model_ok}"
)

# ---- variants and scaling (RTP_VARIANTS=1) ----------------------------------
if System.get_env("RTP_VARIANTS") do
  n = 10_000_000
  online = System.schedulers_online()

  for {name, f} <- variants ++ [defk: defk_chunk] do
    [{st, _}] = RTP.chunks(1, 1_000_000, 1)
    one = time_ms.(fn -> f.(st, 1_000_000) end, 3)
    all = time_ms.(fn -> RTP.run(RTP.chunks(42, n, k), f) end, 3)

    IO.puts(
      "  #{String.pad_trailing(to_string(name), 13)} 1 process #{Float.round(one, 1)} ns/spin   #{n} spins on #{online} schedulers #{round(all)} ms"
    )
  end

  for sched <- [1, 2, 4, 8, online] |> Enum.uniq() do
    :erlang.system_flag(:schedulers_online, sched)
    e = time_ms.(fn -> elixir_run.(n) end, 3)
    d = time_ms.(fn -> defk_run.(n) end, 3)

    IO.puts(
      "  #{sched} schedulers: elixir #{round(e)} ms, defk #{round(d)} ms, #{Float.round(e / d, 2)}x"
    )
  end

  :erlang.system_flag(:schedulers_online, online)
end

# ---- report ------------------------------------------------------------------
realistic = 100_000_000
before = RTP.Kernels.__defk_stats__()
{us_r, _} = :timer.tc(fn -> defk_run.(realistic) end)
after_ = RTP.Kernels.__defk_stats__()

IO.puts(
  "one #{realistic}-spin run, defk #{round(us_r / 1000)} ms: yields #{after_.yields - before.yields}, promotions #{after_.promotions - before.promotions}, frames live #{after_.frames_live}"
)

Defk.Bench.report(
  name: "monte_carlo_rtp",
  expected: :good,
  baseline: :optimized,
  runs: 3,
  realistic_size: "100M spins",
  elixir: fn -> elixir_run.(realistic) end,
  defk: fn -> defk_run.(realistic) end,
  check: fn ->
    gen_ok and reject_ok and model_ok and elixir_run.(10_000_000) == defk_run.(10_000_000)
  end,
  sweep:
    {[1_000_000, 10_000_000, 100_000_000],
     fn n -> {fn -> elixir_run.(n) end, fn -> defk_run.(n) end} end},
  responsiveness: true,
  reason:
    "a seeded PRNG and table lookups per spin; the kernel runs :rand's own exsss bit for bit, so totals equal Elixir's exactly"
)
