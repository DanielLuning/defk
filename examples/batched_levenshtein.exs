# batched_levenshtein: one query's Levenshtein distance to every word of a
# word list, against ex_strsim (Rust strsim via Rustler)
#
# The job: "did you mean" and typo-tolerant lookup score one query against
# every candidate and keep the close ones. ex_strsim 0.1.0 (exact
# Levenshtein, one NIF call per pair on a normal scheduler) is the Hex
# answer, called through Enum.map over the candidates as a user batches it.
# fuzler (normalised token-overlap similarity, rounded) is not Levenshtein,
# so it is not compared and not installed (its rustler_precompiled pin also
# conflicts with ex_strsim's).
#
# Realistic size (declared before the numbers): the fuzzy_search word list,
# 234,454 lowercase words of /usr/share/dict/words (a dictionary-sized
# vocabulary, which is when people look for a NIF), one 12-byte query
# ("accomodation"). The other size, 1k words (a did-you-mean over commands or
# field names), is the first point of the sweep.
#
# Expected verdict: poor (use Elixir). It was pre-registered as good; the
# optimised Elixir changed it.
#
#   elixir examples/batched_levenshtein.exs                 # agreement + report
#   LEV_VARIANTS=1 elixir examples/batched_levenshtein.exs  # also every variant
#
# All numbers below are PROVISIONAL, MEASURED UNDER LOAD (two other
# benchmark runs shared the machine; M-series Mac, 12 schedulers, OTP 29,
# Elixir 1.20). The quiet-machine run is defk-sgw.4.
#
# Elixir baseline: optimised. The anchor's Elixir version is the
# tail-recursive two-row DP of examples/per_pair_distance.exs, one call per
# pair. Best of 5, ms, distances of the whole list as an Elixir list:
#
#                                                     1k words   234k words
#   E0 anchor: per_pair_distance lev/2, Enum.map       0.68        179
#   E1 DP, query row built once, binary words          0.59        157
#   E2 DP, query row built once, charlist words        0.58        158
#   E3 Myers bit-parallel, binary words                0.11        28.1
#   E4 Myers, charlist words                           0.10        18.9
#   E5 Myers, binary comprehension (tuple acc)         0.23        56.9
#   E6 E4 + branch-free score step, Enum.map           0.083       16.3
#   E7 E6 over a :persistent_term tuple, one process   0.070       16.0
#   E8 E7 in 12 chunks on Task.async_stream            0.13        3.6-4.2  <- baseline from 10k words
#   ex_strsim per pair, Enum.map                       0.16        35-38
#
# Myers/Hyyro bit-parallel Levenshtein is the one big step (10x over the DP):
# the query's DP column is two bit vectors, advanced by ~15 bitwise ops per
# candidate byte, all small integers for a query up to 58 bytes. Charlists
# beat binaries (cheaper to walk than <<c, rest::binary>>), and the score step
# as `+ (ph >>> (m-1) &&& 1) - (mh >>> (m-1) &&& 1)` beats a cond. The
# baseline (Lev.Elixir.distances/3) is E7 below 10k words and E8 from 10k
# up; a query over 62 bytes falls back to the DP (E2). There is no early
# cut-off here: every distance is returned, so there is no bound to cut at
# (fuzzy_search's top-k has one). Not tried: the multi-word Myers for
# queries over 62 bytes (both sides use the DP there), and a length
# pre-filter (it only applies with a threshold).
#
# defk: the same algorithms. Lev.Kernels.lev_myers (branch-free score, words
# lo..hi - 1 of one packed blob plus [i64] offsets kept in
# :persistent_term, distances out as [u8], turned into a list with
# :binary.bin_to_list) and lev_dp (the DP, [i64] out) for a query over 62
# bytes or a candidate of 256+ bytes:
#
#                                                     1k words   234k words
#   D1 DP kernel, [i64] decoded to a list              0.13        31.3
#   D2 Myers with the cond score step, [u8] to list    0.024       6.8
#   D3 Myers branch-free, one call, [u8] to list       0.025       6.7
#   D3' D3, packed [u8] result, no list                0.025       5.7
#   D4 D3 in 12 chunks on Task.async_stream            0.056       4.3-4.7  <- defk side from 10k words
#
# The chunks do not scale: the 12 kernel calls (~0.5 ms each) ran on 2 of
# 12 schedulers (recorded with :erlang.system_info(:scheduler_id); the
# Elixir chunks spread over 10-12), which is defk-8qs. An :erlang.yield()
# or a 1 ms sleep before the call did not spread them.
#
# Result at 234k words: the best Elixir (Myers in 12 chunks) 3.9-4.2 ms,
# the best defk (Myers in 12 chunks) 4.3-4.6 ms: 0.86-0.99x, poor (a 1.0x
# run reads as marginal, defk-9p6.24; either way: use Elixir). This
# follows geo_nearest's rule (the verdict is the fastest each side can
# answer one query). In one process, the CPU cost of a query, the kernel is
# 2.4-2.8x (16-18 vs 6.6 ms), at every size from 1k to 234k; the script prints
# that line beside the verdict. The sweep shows defk at 2.1-4x up to 10k
# words (Elixir chunks don't pay there) and 0.8-1.2x from 30k up, so the
# crossover is 1k: at the 1k size defk saves ~0.07 ms per query.
#
# Native: ex_strsim per pair is 35-38 ms at 234k words, 2.2x slower than
# Elixir Myers in one process and 8x slower than defk: a DP per pair plus a
# NIF call per pair. It does not hurt responsiveness, because each call is
# short: max tick gap ~2.1 ms for Elixir, defk and ex_strsim alike (one
# scheduler, 234k words, one process each), the loaded machine's floor.
#
# Agreement, checked on every run (a mismatch exits 1): Elixir (Myers and
# DP, one process and chunked), defk (Myers and DP, one call and chunked),
# the anchor and ex_strsim give identical distances for 11 queries over the
# full list (misspellings, random words, "a" and ""), every query length
# 0..70 over the 1k sample (the Myers/DP switch is at 62), and odd candidates
# (empty, 64-200 bytes, one of 300 bytes that sends defk to the DP kernel).
# The kernels agree with their Elixir mode (__defk_elixir__/2).

Mix.install([
  {:defk, path: Path.expand("..", __DIR__)},
  {:ex_strsim, "0.1.0"}
])

defmodule Lev.Kernels do
  use Defk, elixir_mode: true

  # Plain DP, one row, query along the row: candidate w is
  # blob[offs[w] .. offs[w + 1]). Any query length (0 included).
  defk lev_dp(q :: [u8], blob :: [u8], offs :: [i64]) :: [i64] do
    m = len(q)
    nw = len(offs) - 1
    out = alloc(i64, nw)
    row = alloc(i64, m + 1)

    for w <- 0..(nw - 1)//1 do
      s = offs[w]
      n = offs[w + 1] - s

      for j <- 0..m//1 do
        row[j] = j
      end

      for i <- 1..n//1 do
        ch = blob[s + i - 1]
        diag0 = row[0]
        row[0] = i

        for j <- 1..m//1, reduce: diag0 do
          diag ->
            up = row[j]
            cost = if q[j - 1] == ch, do: 0, else: 1
            row[j] = min(min(up + 1, row[j - 1] + 1), diag + cost)
            up
        end
      end

      out[w] = row[m]
    end

    out
  end

  # lev_myers below with the score step as a cond, as in the textbook (a
  # variant: the branch-free step measured faster on both sides).
  defk lev_myers_cond(q :: [u8], blob :: [u8], offs :: [i64]) :: [u8] do
    m = len(q)
    nw = len(offs) - 1
    out = alloc(u8, nw)
    peq = alloc(i64, 256)

    for j <- 0..(m - 1)//1 do
      c = q[j]
      peq[c] = bor(peq[c], bsl(1, j))
    end

    mask = bsl(1, m) - 1
    hi = bsl(1, m - 1)

    for w <- 0..(nw - 1)//1 do
      {_, _, score} =
        for i <- offs[w]..(offs[w + 1] - 1)//1, reduce: {mask, 0, m} do
          {pv, mv, score} ->
            eq = peq[blob[i]]
            xv = bor(eq, mv)
            xh = bor(bxor(band(eq, pv) + pv, pv), eq)
            ph = bor(mv, band(bnot(bor(xh, pv)), mask))
            mh = band(pv, xh)

            score =
              cond do
                band(ph, hi) != 0 -> score + 1
                band(mh, hi) != 0 -> score - 1
                true -> score
              end

            ph = band(bor(bsl(ph, 1), 1), mask)
            mh = band(bsl(mh, 1), mask)
            {bor(mh, band(bnot(bor(xv, ph)), mask)), band(ph, xv), score}
        end

      out[w] = score
    end

    out
  end

  # Myers/Hyyro bit-parallel Levenshtein for a query of 1..62 bytes: the DP
  # column of the query is two bit vectors (pv, mv: +1 and -1 vertical
  # deltas), advanced by one step of ~15 word operations per candidate byte.
  # Values stay below 2^63 (m <= 62), so no wrap is needed. Distances go out
  # as [u8], so the caller must keep every candidate under 256 bytes. Words
  # lo..hi - 1 only, so chunks of one index can run on several schedulers.
  defk lev_myers(q :: [u8], blob :: [u8], offs :: [i64], lo :: i64, hi :: i64) :: [u8] do
    m = len(q)
    out = alloc(u8, hi - lo)
    peq = alloc(i64, 256)

    for j <- 0..(m - 1)//1 do
      c = q[j]
      peq[c] = bor(peq[c], bsl(1, j))
    end

    mask = bsl(1, m) - 1

    for w <- lo..(hi - 1)//1 do
      {_, _, score} =
        for i <- offs[w]..(offs[w + 1] - 1)//1, reduce: {mask, 0, m} do
          {pv, mv, score} ->
            eq = peq[blob[i]]
            xv = bor(eq, mv)
            xh = bor(bxor(band(eq, pv) + pv, pv), eq)
            ph = bor(mv, band(bnot(bor(xh, pv)), mask))
            mh = band(pv, xh)

            score = score + band(bsr(ph, m - 1), 1) - band(bsr(mh, m - 1), 1)

            ph = band(bor(bsl(ph, 1), 1), mask)
            mh = band(bsl(mh, 1), mask)
            {bor(mh, band(bnot(bor(xv, ph)), mask)), band(ph, xv), score}
        end

      out[w - lo] = score
    end

    out
  end
end

defmodule Lev.Anchor do
  # The first baseline, verbatim from examples/per_pair_distance.exs: the
  # tail-recursive two-row DP over the strings' bytes, one call per pair.
  def lev(a, b) do
    bl = :binary.bin_to_list(b)
    rows(a, bl, Enum.to_list(0..length(bl)), 1)
  end

  defp rows(<<>>, _b, row, _i), do: List.last(row)

  defp rows(<<c, rest::binary>>, b, [_ | _] = prev, i) do
    rows(rest, b, cells(b, prev, i, c, [i]), i + 1)
  end

  defp cells([], _prev, _left, _c, acc), do: :lists.reverse(acc)

  defp cells([bc | bt], [diag, up | prest], left, c, acc) do
    cost = if bc == c, do: 0, else: 1
    v = min(min(left + 1, up + 1), diag + cost)
    cells(bt, [up | prest], v, c, [v | acc])
  end
end

defmodule Lev.Elixir do
  import Bitwise

  # ---- DP with the query fixed: the query is the row (built once per batch),
  # the candidate the outer loop, so nothing is converted per pair.

  def dp_prepare(q) do
    ql = :binary.bin_to_list(q)
    {ql, Enum.to_list(0..length(ql))}
  end

  def dp_bin({ql, row0}, w), do: dp_rows(w, ql, row0, 1)

  defp dp_rows(<<>>, _q, row, _i), do: List.last(row)

  defp dp_rows(<<c, rest::binary>>, q, prev, i),
    do: dp_rows(rest, q, dp_cells(q, prev, i, c, [i]), i + 1)

  def dp_chars({ql, row0}, w), do: dp_crows(w, ql, row0, 1)

  defp dp_crows([], _q, row, _i), do: List.last(row)

  defp dp_crows([c | rest], q, prev, i),
    do: dp_crows(rest, q, dp_cells(q, prev, i, c, [i]), i + 1)

  defp dp_cells([], _prev, _left, _c, acc), do: :lists.reverse(acc)

  defp dp_cells([qc | qt], [diag, up | prest], left, c, acc) do
    cost = if qc == c, do: 0, else: 1
    v = min(min(left + 1, up + 1), diag + cost)
    dp_cells(qt, [up | prest], v, c, [v | acc])
  end

  # ---- Myers/Hyyro bit-parallel, the same algorithm as Lev.Kernels.lev_myers
  # (query of 1..62 bytes; masks to m bits, so every value is a small integer
  # up to m = 58 and a correct, slower bignum above).

  def myers_prepare(q) do
    m = byte_size(q)

    peq =
      q
      |> :binary.bin_to_list()
      |> Enum.with_index()
      |> Enum.reduce(:erlang.make_tuple(256, 0), fn {c, j}, t ->
        put_elem(t, c, elem(t, c) ||| 1 <<< j)
      end)

    {peq, (1 <<< m) - 1, 1 <<< (m - 1), m}
  end

  def myers_bin({peq, mask, hi, m}, w), do: mb(w, peq, mask, hi, mask, 0, m)

  defp mb(<<>>, _peq, _mask, _hi, _pv, _mv, score), do: score

  defp mb(<<c, rest::binary>>, peq, mask, hi, pv, mv, score) do
    eq = elem(peq, c)
    xv = eq ||| mv
    xh = bxor((eq &&& pv) + pv, pv) ||| eq
    ph = mv ||| (bnot(xh ||| pv) &&& mask)
    mh = pv &&& xh

    score =
      cond do
        (ph &&& hi) != 0 -> score + 1
        (mh &&& hi) != 0 -> score - 1
        true -> score
      end

    ph = (ph <<< 1 ||| 1) &&& mask
    mh = mh <<< 1 &&& mask
    mb(rest, peq, mask, hi, mh ||| (bnot(xv ||| ph) &&& mask), ph &&& xv, score)
  end

  def myers_chars({peq, mask, hi, m}, w), do: mc(w, peq, mask, hi, mask, 0, m)

  defp mc([], _peq, _mask, _hi, _pv, _mv, score), do: score

  defp mc([c | rest], peq, mask, hi, pv, mv, score) do
    eq = elem(peq, c)
    xv = eq ||| mv
    xh = bxor((eq &&& pv) + pv, pv) ||| eq
    ph = mv ||| (bnot(xh ||| pv) &&& mask)
    mh = pv &&& xh

    score =
      cond do
        (ph &&& hi) != 0 -> score + 1
        (mh &&& hi) != 0 -> score - 1
        true -> score
      end

    ph = (ph <<< 1 ||| 1) &&& mask
    mh = mh <<< 1 &&& mask
    mc(rest, peq, mask, hi, mh ||| (bnot(xv ||| ph) &&& mask), ph &&& xv, score)
  end

  def myers_chars_nb({peq, mask, _hi, m}, w), do: mcn(w, peq, mask, m - 1, mask, 0, m)

  defp mcn([], _peq, _mask, _s, _pv, _mv, score), do: score

  defp mcn([c | rest], peq, mask, s, pv, mv, score) do
    eq = elem(peq, c)
    xv = eq ||| mv
    xh = bxor((eq &&& pv) + pv, pv) ||| eq
    ph = mv ||| (bnot(xh ||| pv) &&& mask)
    mh = pv &&& xh
    score = score + (ph >>> s &&& 1) - (mh >>> s &&& 1)
    ph = (ph <<< 1 ||| 1) &&& mask
    mh = mh <<< 1 &&& mask
    mcn(rest, peq, mask, s, mh ||| (bnot(xv ||| ph) &&& mask), ph &&& xv, score)
  end

  # Myers over a binary comprehension instead of hand recursion.
  def myers_for({peq, mask, hi, m}, w) do
    {_, _, score} =
      for <<c <- w>>, reduce: {mask, 0, m} do
        {pv, mv, score} ->
          eq = elem(peq, c)
          xv = eq ||| mv
          xh = bxor((eq &&& pv) + pv, pv) ||| eq
          ph = mv ||| (bnot(xh ||| pv) &&& mask)
          mh = pv &&& xh

          score =
            cond do
              (ph &&& hi) != 0 -> score + 1
              (mh &&& hi) != 0 -> score - 1
              true -> score
            end

          ph = (ph <<< 1 ||| 1) &&& mask
          mh = mh <<< 1 &&& mask
          {mh ||| (bnot(xv ||| ph) &&& mask), ph &&& xv, score}
      end

    score
  end

  # ---- one query against a whole index (the timed job)

  # The Elixir index: a tuple of charlists kept in :persistent_term.
  def index(words), do: words |> Enum.map(&:binary.bin_to_list/1) |> List.to_tuple()

  # The optimised baseline: Myers with the branch-free score step for a
  # 1..62-byte query (the DP otherwise), the distances of words lo..hi - 1 as
  # a list. From `par_min` words up, one chunk per scheduler on
  # Task.async_stream; the same split as Lev.Defk.distances/3.
  def distances(q, key, par_min) do
    t = :persistent_term.get(key)
    n = tuple_size(t)
    step = step(q)

    if n < par_min do
      walk(t, n - 1, 0, step, [])
    else
      Lev.Chunks.map(n, fn lo, hi -> walk(:persistent_term.get(key), hi - 1, lo, step, []) end)
      |> :lists.append()
    end
  end

  defp step(q) when byte_size(q) in 1..62 do
    p = myers_prepare(q)
    &myers_chars_nb(p, &1)
  end

  defp step(q) do
    p = dp_prepare(q)
    &dp_chars(p, &1)
  end

  # builds the list back to front, so it needs no reverse
  defp walk(_t, i, lo, _f, acc) when i < lo, do: acc
  defp walk(t, i, lo, f, acc), do: walk(t, i - 1, lo, f, [f.(elem(t, i)) | acc])
end

defmodule Lev.Chunks do
  # Runs fun.(lo, hi) for one chunk of 0..n - 1 per scheduler, in order.
  def map(n, fun) do
    sched = System.schedulers_online()
    size = div(n + sched - 1, sched)

    0..(n - 1)//size
    |> Task.async_stream(fn lo -> fun.(lo, min(n, lo + size)) end,
      max_concurrency: sched,
      timeout: :infinity
    )
    |> Enum.map(fn {:ok, r} -> r end)
  end
end

defmodule Lev.Defk do
  alias Lev.Kernels, as: K

  # The defk index: all words in one binary plus n + 1 offsets, packed once
  # and kept in :persistent_term, as an app keeps an index.
  def index(words) do
    {offs, total} = Enum.map_reduce(words, 0, fn w, at -> {at, at + byte_size(w)} end)
    offs = for o <- offs ++ [total], into: <<>>, do: <<o::signed-64-native>>
    maxlen = Enum.reduce(words, 0, &max(byte_size(&1), &2))
    {IO.iodata_to_binary(words), offs, length(words), maxlen}
  end

  # Myers for a 1..62-byte query when every candidate is under 256 bytes (so
  # the [u8] distances are exact), the DP kernel otherwise. Returns the list
  # of distances in candidate order, like Enum.map with ex_strsim. From
  # `par_min` words up, one kernel call per scheduler chunk.
  def distances(q, key, par_min), do: run(q, :persistent_term.get(key), par_min)

  def run(q, {blob, offs, n, maxlen}, par_min) when byte_size(q) in 1..62 and maxlen < 256 do
    if n < par_min do
      :binary.bin_to_list(K.lev_myers(q, blob, offs, 0, n))
    else
      Lev.Chunks.map(n, fn lo, hi -> K.lev_myers(q, blob, offs, lo, hi) end)
      |> IO.iodata_to_binary()
      |> :binary.bin_to_list()
    end
  end

  def run(q, {blob, offs, _, _}, _par_min), do: dp(q, blob, offs)

  def dp(q, blob, offs), do: for(<<d::signed-64-native <- K.lev_dp(q, blob, offs)>>, do: d)
end

# ---------------------------------------------------------------- data --

# The fuzzy_search word list: lowercase a-z words of /usr/share/dict/words,
# deduplicated (234,454 on this Mac). Without the file, a deterministic list
# of the same size stands in, so the script still runs.
words_all =
  case File.read(System.get_env("WORDS", "/usr/share/dict/words")) do
    {:ok, text} ->
      text
      |> String.split("\n")
      |> Enum.map(&(&1 |> String.trim() |> String.downcase()))
      |> Enum.filter(&(&1 =~ ~r/^[a-z]+$/))
      |> Enum.uniq()

    {:error, _} ->
      :rand.seed(:exsss, {7, 7, 7})

      for _ <- 1..234_454 do
        for _ <- 1..(3 + :rand.uniform(12)), into: <<>>, do: <<?a + :rand.uniform(26) - 1>>
      end
  end

n_all = length(words_all)
:rand.seed(:exsss, {1, 2, 3})

# smaller lists are random samples, kept in word-list order
sample = fn n ->
  words_all
  |> Enum.with_index()
  |> Enum.take_random(n)
  |> Enum.sort_by(&elem(&1, 1))
  |> Enum.map(&elem(&1, 0))
end

sizes = [1_000, 3_000, 10_000, 30_000, 100_000, n_all]

for n <- sizes do
  ws = if n == n_all, do: words_all, else: sample.(n)
  :persistent_term.put({:lev_words, n}, ws)
  :persistent_term.put({:lev_ex, n}, Lev.Elixir.index(ws))
  :persistent_term.put({:lev_dk, n}, Lev.Defk.index(ws))
end

words = fn n -> :persistent_term.get({:lev_words, n}) end

# Both sides split a list across the schedulers from this many words up
# (below it, one process or one kernel call is faster; see the header).
par_min = 10_000

# The timed query: a common misspelling, 12 bytes.
query = "accomodation"

elixir_run = fn n -> fn -> Lev.Elixir.distances(query, {:lev_ex, n}, par_min) end end
defk_run = fn n -> fn -> Lev.Defk.distances(query, {:lev_dk, n}, par_min) end end
native_run = fn n -> fn -> Enum.map(words.(n), &ExStrsim.levenshtein(query, &1)) end end

# ----------------------------------------------------------- agreement --
# Elixir (Myers and DP), defk (Myers and DP, one call and chunked), the
# anchor and ex_strsim must give identical distances; a mismatch stops the
# script with exit 1.

fail = fn what ->
  IO.puts("DISAGREEMENT: #{what}")
  System.halt(1)
end

agree = fn q, ws ->
  :persistent_term.put(:lev_check, Lev.Elixir.index(ws))
  {blob, offs, _, _} = dk = Lev.Defk.index(ws)
  ref = Enum.map(ws, &ExStrsim.levenshtein(q, &1))
  edp = Lev.Elixir.dp_prepare(q)

  sides = [
    elixir: Lev.Elixir.distances(q, :lev_check, 1_000_000),
    elixir_chunked: Lev.Elixir.distances(q, :lev_check, 0),
    elixir_dp: Enum.map(ws, &Lev.Elixir.dp_bin(edp, &1)),
    defk: Lev.Defk.run(q, dk, 1_000_000),
    defk_chunked: Lev.Defk.run(q, dk, 0),
    defk_dp: Lev.Defk.dp(q, blob, offs),
    anchor: Enum.map(ws, &Lev.Anchor.lev(q, &1))
  ]

  for {name, got} <- sides, got != ref do
    fail.("#{name} vs ex_strsim for query #{inspect(q)} over #{length(ws)} candidates")
  end

  true
end

# Queries: misspellings and random words over the full list; every length
# 0..70 (the Myers/DP switch is at 62 bytes) over the 1k sample.
:rand.seed(:exsss, {9, 9, 9})
long = fn n -> for _ <- 1..n//1, into: <<>>, do: <<?a + :rand.uniform(26) - 1>> end
picks = for _ <- 1..6, do: Enum.at(words_all, :rand.uniform(n_all) - 1)

for q <- [query, "seperate", "definately", "a", "" | picks], do: agree.(q, words_all)
for len <- 0..70, do: agree.(long.(len), words.(1_000))

# Odd candidates: empty, one byte, repeats, 64-200 bytes (still Myers: only
# the query is a bit vector), and one of 300 bytes (defk falls back to the
# DP kernel, whose distances may exceed 255).
odd = ["", "a", "aaaa", "accommodation", long.(64), long.(200), String.duplicate("ab", 40)]

for q <- ["", "a", "ab", query, long.(62), long.(63)], extra <- [[], [long.(300)]] do
  agree.(q, odd ++ extra)
end

# Every kernel against its Elixir mode (__defk_elixir__/2) on small inputs.
mode_ok =
  Enum.all?(
    for q <- ["", "a", query, long.(62), long.(70)], ws <- [odd, Enum.take(words_all, 300)] do
      {blob, offs, n, _} = Lev.Defk.index(ws)
      em = &Lev.Kernels.__defk_elixir__/2

      Lev.Kernels.lev_dp(q, blob, offs) == em.(:lev_dp, [q, blob, offs]) and
        (byte_size(q) not in 1..62 or
           (Lev.Kernels.lev_myers(q, blob, offs, 0, n) == em.(:lev_myers, [q, blob, offs, 0, n]) and
              Lev.Kernels.lev_myers(q, blob, offs, 2, n - 1) ==
                em.(:lev_myers, [q, blob, offs, 2, n - 1]) and
              Lev.Kernels.lev_myers_cond(q, blob, offs) == em.(:lev_myers_cond, [q, blob, offs])))
    end
  )

mode_ok || fail.("a kernel differs from its Elixir mode")

IO.puts(
  "agreement: Elixir, defk and ex_strsim identical (#{n_all} words x 11 queries; 1k words x query lengths 0..70; odd candidates); Elixir mode ok"
)

# ------------------------------------------------------------ variants --
# LEV_VARIANTS=1 also times every Elixir and defk variant (best of 5) at 1k
# and the full list, and one process against chunks at every sweep size.

best = fn fun, runs ->
  fun.()

  1..runs
  |> Enum.map(fn _ ->
    :erlang.garbage_collect()
    elem(:timer.tc(fun), 0)
  end)
  |> Enum.min()
  |> Kernel./(1000)
  |> Float.round(3)
end

if System.get_env("LEV_VARIANTS") do
  for n <- [1_000, n_all] do
    ws = words.(n)
    cs = Enum.map(ws, &:binary.bin_to_list/1)
    {blob, offs, _, _} = :persistent_term.get({:lev_dk, n})
    dpp = Lev.Elixir.dp_prepare(query)
    myp = Lev.Elixir.myers_prepare(query)
    one = 1_000_000_000

    variants = [
      {"E0 anchor: per_pair_distance lev/2, Enum.map",
       fn -> Enum.map(ws, &Lev.Anchor.lev(query, &1)) end},
      {"E1 DP, query row built once, binary words",
       fn -> Enum.map(ws, &Lev.Elixir.dp_bin(dpp, &1)) end},
      {"E2 DP, query row built once, charlist words",
       fn -> Enum.map(cs, &Lev.Elixir.dp_chars(dpp, &1)) end},
      {"E3 Myers, binary words", fn -> Enum.map(ws, &Lev.Elixir.myers_bin(myp, &1)) end},
      {"E4 Myers, charlist words", fn -> Enum.map(cs, &Lev.Elixir.myers_chars(myp, &1)) end},
      {"E5 Myers, binary comprehension", fn -> Enum.map(ws, &Lev.Elixir.myers_for(myp, &1)) end},
      {"E6 E4 + branch-free score, Enum.map",
       fn -> Enum.map(cs, &Lev.Elixir.myers_chars_nb(myp, &1)) end},
      {"E7 E6 over a :persistent_term tuple, one process",
       fn -> Lev.Elixir.distances(query, {:lev_ex, n}, one) end},
      {"E8 E7 in #{System.schedulers_online()} chunks",
       fn -> Lev.Elixir.distances(query, {:lev_ex, n}, 0) end},
      {"D1 defk DP kernel, [i64] decoded", fn -> Lev.Defk.dp(query, blob, offs) end},
      {"D2 defk Myers (cond score), [u8] to list",
       fn -> :binary.bin_to_list(Lev.Kernels.lev_myers_cond(query, blob, offs)) end},
      {"D3 defk Myers (branch-free), one call",
       fn -> Lev.Defk.distances(query, {:lev_dk, n}, one) end},
      {"D3' D3, packed [u8] result, no list",
       fn -> Lev.Kernels.lev_myers(query, blob, offs, 0, n) end},
      {"D4 D3 in #{System.schedulers_online()} chunks",
       fn -> Lev.Defk.distances(query, {:lev_dk, n}, 0) end},
      {"N  ex_strsim per pair, Enum.map", native_run.(n)}
    ]

    ref = Enum.map(ws, &ExStrsim.levenshtein(query, &1))

    for {name, f} <- variants, not String.starts_with?(name, "D3'"), f.() != ref do
      fail.("variant #{name}")
    end

    IO.puts("\nvariants, #{n} words, query #{inspect(query)} (best of 5, ms):")

    for {name, f} <- variants do
      IO.puts("  #{String.pad_trailing(name, 52)} #{best.(f, 5)}")
    end
  end

  IO.puts("\none process / chunks per scheduler (best of 5, ms):")

  for n <- sizes do
    e1 = best.(fn -> Lev.Elixir.distances(query, {:lev_ex, n}, 1_000_000_000) end, 5)
    ep = best.(fn -> Lev.Elixir.distances(query, {:lev_ex, n}, 0) end, 5)
    d1 = best.(fn -> Lev.Defk.distances(query, {:lev_dk, n}, 1_000_000_000) end, 5)
    dp = best.(fn -> Lev.Defk.distances(query, {:lev_dk, n}, 0) end, 5)

    IO.puts(
      "  #{String.pad_trailing(to_string(n), 7)} Elixir #{e1} / #{ep}   defk #{d1} / #{dp}   (one-process ratio #{Float.round(e1 / d1, 2)}x)"
    )
  end
end

# Beside the verdict: one query in one process on each side (the CPU cost of
# a query, which is what counts when many queries run at once).
one = 1_000_000_000
e1 = best.(fn -> Lev.Elixir.distances(query, {:lev_ex, n_all}, one) end, 5)
d1 = best.(fn -> Lev.Defk.distances(query, {:lev_dk, n_all}, one) end, 5)

IO.puts(
  "one process, #{n_all} words: Elixir #{e1} ms, defk #{d1} ms (#{Float.round(e1 / d1, 2)}x)"
)

# -------------------------------------------------------------- report --

Defk.Bench.report(
  name: "batched_levenshtein",
  expected: :poor,
  baseline: :optimized,
  realistic_size: "#{n_all} words (a dictionary), one 12-byte query",
  elixir: elixir_run.(n_all),
  defk: defk_run.(n_all),
  native: {native_run.(n_all), "ex_strsim 0.1.0 (Rust strsim), per pair via Enum.map"},
  check: fn ->
    ref = native_run.(n_all).()
    elixir_run.(n_all).() == ref and defk_run.(n_all).() == ref
  end,
  sweep: {sizes, fn n -> {elixir_run.(n), defk_run.(n)} end},
  responsiveness: [
    elixir: fn -> Lev.Elixir.distances(query, {:lev_ex, n_all}, 1_000_000_000) end,
    defk: fn -> Lev.Defk.distances(query, {:lev_dk, n_all}, 1_000_000_000) end,
    native: native_run.(n_all)
  ],
  reason:
    "Myers bit-parallel in Elixir over charlists, split across schedulers, is as fast as defk (whose chunks stay on 2 schedulers, defk-8qs); in one process the kernel is ~2.5x, and ex_strsim per pair is 2x slower than Elixir"
)
