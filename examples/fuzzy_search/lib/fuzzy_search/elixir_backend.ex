defmodule FuzzySearch.ElixirBackend do
  @moduledoc """
  Pure Elixir Levenshtein top-k search, with the same algorithm and early
  cut-off as the defk kernel.

  Written to be fair, not a strawman: top-k is a bounded sorted list instead
  of sorting all distances, and the catalog is kept in `:persistent_term` in
  the shapes each path reads.

  Distance: for a query of 1..62 bytes, Myers' bit-parallel algorithm (one
  step of a few bitwise operations per byte of the candidate word, the query
  held as bit masks). Up to 62 bits every value stays a small integer, never a
  bignum. Longer and empty queries take the classic DP, one row per character
  of the word, rows built by tail recursion over charlists.

  Cut-off: once the top k is full, a word stops as soon as a lower bound on
  its distance reaches the k-th best distance (`bound`): it can no longer get
  in. Words are scanned in index order, so a word that only ties the k-th
  best would lose the tie-break and is cut too. The lower bounds:

    * Myers: `|n - m|` before the word starts, and `score - (n - i)` after
      `i` of its `n` bytes (each remaining byte lowers the distance by at
      most one).
    * DP: the row minimum, which never decreases from one row to the next.

  `bench/elixir_variants.exs` measures the alternatives that were tried; this
  combination was the fastest.
  """

  import Bitwise

  alias FuzzySearch.Catalog

  @inf 1_000_000_000

  @doc "Returns up to `k` `{index, distance}` pairs, best first (ties: lower index)."
  def search(query, k, opts \\ []) do
    dist = distance_fun(query)
    n = tuple_size(Catalog.get().words)

    if Keyword.get(opts, :parallel, true) do
      parallel(dist, n, k)
    else
      {top, _, _} = scan(dist, 0, n - 1, k)
      Enum.map(top, fn {d, i} -> {i, d} end)
    end
  end

  # fn index, bound -> distance or :cut
  defp distance_fun(query) when byte_size(query) in 1..62 do
    m = byte_size(query)

    peq =
      query
      |> :binary.bin_to_list()
      |> Enum.with_index()
      |> Enum.reduce(Tuple.duplicate(0, 256), fn {ch, j}, t -> put_elem(t, ch, elem(t, ch) ||| 1 <<< j) end)

    mask = (1 <<< m) - 1
    words = Catalog.get().words

    fn i, bound ->
      word = elem(words, i)
      n = byte_size(word)
      if abs(n - m) >= bound, do: :cut, else: myers(word, peq, mask, m - 1, mask, 0, m, n, bound)
    end
  end

  defp distance_fun(query) do
    q = String.to_charlist(query)
    row0 = Enum.to_list(0..length(q))
    words = Catalog.get().charlists
    fn i, bound -> dp(elem(words, i), q, row0, 1, bound) end
  end

  defp scan(dist, first, last, k) do
    Enum.reduce(first..last//1, {[], 0, @inf}, fn i, {top, count, bound} = acc ->
      case dist.(i, bound) do
        :cut -> acc
        d -> insert(d, i, top, count, k, bound)
      end
    end)
  end

  # one chunk of the catalog per scheduler, then merge the chunks' top k
  defp parallel(dist, n, k) do
    sched = System.schedulers_online()
    chunk_size = div(n + sched - 1, sched)

    0..(sched - 1)
    |> Task.async_stream(fn idx -> scan(dist, idx * chunk_size, min((idx + 1) * chunk_size, n) - 1, k) end,
      max_concurrency: sched,
      ordered: false
    )
    |> Enum.flat_map(fn {:ok, {top, _, _}} -> top end)
    |> Enum.sort()
    |> Enum.take(k)
    |> Enum.map(fn {d, i} -> {i, d} end)
  end

  # Myers/Hyyrö: pv and mv hold the +1 and -1 vertical deltas of the DP
  # column, `score` the distance to the whole query so far (bit `top` of ph
  # and mh is its +1 or -1 step); `left` bytes remain
  defp myers(<<>>, _peq, _mask, _top, _pv, _mv, score, _left, _bound), do: score

  defp myers(<<ch, rest::binary>>, peq, mask, top, pv, mv, score, left, bound) do
    eq = elem(peq, ch)
    xv = eq ||| mv
    xh = bxor((eq &&& pv) + pv, pv) ||| eq
    ph = mv ||| band(bnot(xh ||| pv), mask)
    mh = pv &&& xh
    score = score + (ph >>> top &&& 1) - (mh >>> top &&& 1)
    ph = band(ph <<< 1 ||| 1, mask)
    mh = band(mh <<< 1, mask)
    pv = mh ||| band(bnot(xv ||| ph), mask)
    mv = ph &&& xv
    left = left - 1

    if score - left >= bound, do: :cut, else: myers(rest, peq, mask, top, pv, mv, score, left, bound)
  end

  # classic two-row DP: one new row per character of the candidate word;
  # `:cut` once the row minimum reaches `bound`
  defp dp([], _q, prev, _i, _bound), do: List.last(prev)

  defp dp([ch | rest], q, prev, i, bound) do
    case next_row(q, ch, prev, [i], i, i) do
      {_, min} when min >= bound -> :cut
      {row, _} -> dp(rest, q, row, i + 1, bound)
    end
  end

  defp next_row([], _ch, _prev, acc, _left, min), do: {:lists.reverse(acc), min}

  defp next_row([qc | qs], ch, [diag | [up | _] = rest], acc, left, row_min) do
    cost = if qc == ch, do: 0, else: 1
    v = min(min(up + 1, left + 1), diag + cost)
    next_row(qs, ch, rest, [v | acc], v, min(row_min, v))
  end

  # keep the k smallest {distance, index} keys in ascending order; returns the
  # new bound (the k-th best distance, or @inf while fewer than k are kept).
  # Indices ascend, so a newcomer gets in only with a strictly smaller distance.
  defp insert(d, i, top, count, k, _bound) when count < k do
    top = :lists.merge([{d, i}], top)
    count = count + 1
    {top, count, if(count == k, do: elem(List.last(top), 0), else: @inf)}
  end

  defp insert(d, i, top, count, _k, bound) when d < bound do
    top = :lists.merge([{d, i}], :lists.droplast(top))
    {top, count, elem(List.last(top), 0)}
  end

  defp insert(_d, _i, top, count, _k, bound), do: {top, count, bound}
end
