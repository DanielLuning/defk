# Elixir variants of the top-k Levenshtein search, measured against each other
# before the Elixir backend was chosen (defk-8i4):
#
#     NO_SERVER=1 mix run bench/elixir_variants.exs [rounds]
#
# Every variant must return what the first pass returns. Each query runs in a
# fresh process (Task), as a request would, and the catalog stays in
# :persistent_term. Variants marked "not in comparison" use a trick the defk
# kernel can't (yet) express, so they are reported but not used as the baseline.

defmodule Variants do
  alias FuzzySearch.Catalog
  import Bitwise

  @inf 1_000_000_000

  # ---------------------------------------------------------------- shared --

  # bounded top-k as an ascending list; returns the new k-th best distance as
  # the cut-off bound (@inf until the list is full). Indices ascend, so a tie
  # with the k-th best never enters, and the test is `d < bound`.
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

  defp scan(words, dist, q, k) do
    n = tuple_size(words)

    {top, _, _} =
      Enum.reduce(0..(n - 1)//1, {[], 0, @inf}, fn i, {top, count, bound} = acc ->
        case dist.(elem(words, i), q, bound) do
          :cut -> acc
          d -> insert(d, i, top, count, k, bound)
        end
      end)

    Enum.map(top, fn {d, i} -> {i, d} end)
  end

  # ------------------------------------------------- 0. first pass (main) --

  def first_pass(query, k), do: FuzzySearch.ElixirBackend.FirstPass.search(query, k)

  # -------------------------------- 1. list rows + cut-off, Enum.reduce_while --

  def enum_cut(query, k) do
    q = String.to_charlist(query)
    row0 = Enum.to_list(0..length(q))

    dist = fn word, q, bound ->
      Enum.reduce_while(word, {row0, 1}, fn ch, {prev, i} ->
        {row, mn} = row_min(q, ch, prev, [i], i, i)
        if mn >= bound, do: {:halt, :cut}, else: {:cont, {row, i + 1}}
      end)
      |> case do
        :cut -> :cut
        {row, _} -> List.last(row)
      end
    end

    scan(Catalog.get().charlists, dist, q, k)
  end

  defp row_min([], _ch, _prev, acc, _left, mn), do: {:lists.reverse(acc), mn}

  defp row_min([qc | qs], ch, [diag | [up | _] = rest], acc, left, mn) do
    cost = if qc == ch, do: 0, else: 1
    v = min(min(up + 1, left + 1), diag + cost)
    row_min(qs, ch, rest, [v | acc], v, min(mn, v))
  end

  # ------------------------- 2. list rows + cut-off, tail recursion (chosen) --

  def tail_cut(query, k) do
    q = String.to_charlist(query)
    row0 = Enum.to_list(0..length(q))
    scan(Catalog.get().charlists, fn word, q, bound -> tail_dist(word, q, row0, 1, bound) end, q, k)
  end

  defp tail_dist([], _q, prev, _i, _bound), do: List.last(prev)

  defp tail_dist([ch | rest], q, prev, i, bound) do
    case row_min(q, ch, prev, [i], i, i) do
      {_, mn} when mn >= bound -> :cut
      {row, _} -> tail_dist(rest, q, row, i + 1, bound)
    end
  end

  # ------------------- 3. as 2, but words read as binaries, not charlists --

  def binary_words(query, k) do
    q = String.to_charlist(query)
    row0 = Enum.to_list(0..length(q))
    scan(Catalog.get().words, fn word, q, bound -> bin_dist(word, q, row0, 1, bound) end, q, k)
  end

  defp bin_dist(<<>>, _q, prev, _i, _bound), do: List.last(prev)

  defp bin_dist(<<ch, rest::binary>>, q, prev, i, bound) do
    case row_min(q, ch, prev, [i], i, i) do
      {_, mn} when mn >= bound -> :cut
      {row, _} -> bin_dist(rest, q, row, i + 1, bound)
    end
  end

  # ---------------------- 4. as 2, but each row is a tuple read with elem --

  def tuple_rows(query, k) do
    q = String.to_charlist(query) |> List.to_tuple()
    m = tuple_size(q)
    row0 = List.to_tuple(Enum.to_list(0..m))

    dist = fn word, q, bound -> tup_dist(word, q, m, row0, 1, bound) end
    scan(Catalog.get().charlists, dist, q, k)
  end

  defp tup_dist([], _q, m, prev, _i, _bound), do: elem(prev, m)

  defp tup_dist([ch | rest], q, m, prev, i, bound) do
    {acc, mn} = tup_row(q, ch, prev, 1, m, [i], i, i)
    if mn >= bound, do: :cut, else: tup_dist(rest, q, m, List.to_tuple(:lists.reverse(acc)), i + 1, bound)
  end

  defp tup_row(_q, _ch, _prev, j, m, acc, _left, mn) when j > m, do: {acc, mn}

  defp tup_row(q, ch, prev, j, m, acc, left, mn) do
    cost = if elem(q, j - 1) == ch, do: 0, else: 1
    v = min(min(elem(prev, j) + 1, left + 1), elem(prev, j - 1) + cost)
    tup_row(q, ch, prev, j + 1, m, [v | acc], v, min(mn, v))
  end

  # ------------------------------ 5. as 2, but each row is an :array --

  def array_rows(query, k) do
    q = String.to_charlist(query)
    m = length(q)
    row0 = :array.from_list(Enum.to_list(0..m))
    dist = fn word, q, bound -> arr_dist(word, q, m, row0, 1, bound) end
    scan(Catalog.get().charlists, dist, q, k)
  end

  defp arr_dist([], _q, m, prev, _i, _bound), do: :array.get(m, prev)

  defp arr_dist([ch | rest], q, m, prev, i, bound) do
    {row, mn} = arr_row(q, ch, prev, 1, :array.set(0, i, prev), i, i)
    if mn >= bound, do: :cut, else: arr_dist(rest, q, m, row, i + 1, bound)
  end

  defp arr_row([], _ch, _prev, _j, row, _left, mn), do: {row, mn}

  defp arr_row([qc | qs], ch, prev, j, row, left, mn) do
    cost = if qc == ch, do: 0, else: 1
    v = min(min(:array.get(j, prev) + 1, left + 1), :array.get(j - 1, prev) + cost)
    arr_row(qs, ch, prev, j + 1, :array.set(j, v, row), v, min(mn, v))
  end

  # ------------- 6. as 2, but each row is a binary of u16, built by appending --

  def binary_rows(query, k) do
    q = String.to_charlist(query)
    row0 = for v <- 0..length(q), into: <<>>, do: <<v::16>>
    scan(Catalog.get().charlists, fn word, q, bound -> brow_dist(word, q, row0, 1, bound) end, q, k)
  end

  defp brow_dist([], _q, prev, _i, _bound) do
    s = byte_size(prev) - 2
    <<_::binary-size(s), last::16>> = prev
    last
  end

  defp brow_dist([ch | rest], q, prev, i, bound) do
    case brow(q, ch, prev, <<i::16>>, i, i) do
      {_, mn} when mn >= bound -> :cut
      {row, _} -> brow_dist(rest, q, row, i + 1, bound)
    end
  end

  defp brow([], _ch, _prev, acc, _left, mn), do: {acc, mn}

  defp brow([qc | qs], ch, <<diag::16, up::16, _::binary>> = prev, acc, left, mn) do
    cost = if qc == ch, do: 0, else: 1
    v = min(min(up + 1, left + 1), diag + cost)
    <<_::16, rest::binary>> = prev
    brow(qs, ch, rest, <<acc::binary, v::16>>, v, min(mn, v))
  end

  # -------------- 8. as 2, but the row minimum comes from :lists.min/1 --

  def lists_min(query, k) do
    q = String.to_charlist(query)
    row0 = Enum.to_list(0..length(q))
    scan(Catalog.get().charlists, fn word, q, bound -> lmin_dist(word, q, row0, 1, bound) end, q, k)
  end

  defp lmin_dist([], _q, prev, _i, _bound), do: List.last(prev)

  defp lmin_dist([ch | rest], q, prev, i, bound) do
    row = next_row(q, ch, prev, [i], i)
    if :lists.min(row) >= bound, do: :cut, else: lmin_dist(rest, q, row, i + 1, bound)
  end

  defp next_row([], _ch, _prev, acc, _left), do: :lists.reverse(acc)

  defp next_row([qc | qs], ch, [diag | [up | _] = rest], acc, left) do
    cost = if qc == ch, do: 0, else: 1
    v = min(min(up + 1, left + 1), diag + cost)
    next_row(qs, ch, rest, [v | acc], v)
  end

  # ------ 9. as 2, but the catalog walk is tail recursion, not Enum.reduce --

  def tail_scan(query, k) do
    q = String.to_charlist(query)
    row0 = Enum.to_list(0..length(q))
    words = Catalog.get().charlists
    top = walk(words, 0, tuple_size(words), q, row0, k, [], 0, @inf)
    Enum.map(top, fn {d, i} -> {i, d} end)
  end

  defp walk(_words, n, n, _q, _row0, _k, top, _count, _bound), do: top

  defp walk(words, i, n, q, row0, k, top, count, bound) do
    case tail_dist(elem(words, i), q, row0, 1, bound) do
      :cut ->
        walk(words, i + 1, n, q, row0, k, top, count, bound)

      d ->
        {top, count, bound} = insert(d, i, top, count, k, bound)
        walk(words, i + 1, n, q, row0, k, top, count, bound)
    end
  end

  # ---- 10. as 2, plus a length pre-filter (not in comparison: extra trick) --
  # |len(word) - len(q)| is a lower bound on the distance, so a word whose
  # length differs by at least the bound is skipped without a row.

  def length_filter(query, k) do
    q = String.to_charlist(query)
    m = length(q)
    row0 = Enum.to_list(0..m)

    dist = fn word, q, bound ->
      if abs(length(word) - m) >= bound, do: :cut, else: tail_dist(word, q, row0, 1, bound)
    end

    scan(Catalog.get().charlists, dist, q, k)
  end

  # ---- 7. Myers/Hyyrö bit-parallel distance, no cut-off (not in comparison) --
  # A different algorithm: one word-sized bit-vector step per character instead
  # of a row. defk kernels have no bitwise operators yet (defk-w38), so the
  # kernel cannot use it; this measures what it would be worth.

  def myers(query, k) do
    q = String.to_charlist(query)
    m = length(q)
    true = m in 1..58
    peq = for c <- 0..255, do: Enum.reduce(Enum.with_index(q), 0, fn {qc, j}, b -> if qc == c, do: b ||| 1 <<< j, else: b end)
    peq = List.to_tuple(peq)
    mask = (1 <<< m) - 1
    hi = 1 <<< (m - 1)

    dist = fn word, _q, _bound -> myers_dist(word, peq, mask, hi, mask, 0, m) end
    scan(Catalog.get().charlists, dist, q, k)
  end

  defp myers_dist([], _peq, _mask, _hi, _pv, _mv, score), do: score

  defp myers_dist([ch | rest], peq, mask, hi, pv, mv, score) do
    eq = elem(peq, ch)
    xv = eq ||| mv
    xh = bxor(band(eq, pv) + pv, pv) ||| eq
    ph = band(mv ||| bnot(xh ||| pv), mask)
    mh = pv &&& xh

    score =
      cond do
        (ph &&& hi) != 0 -> score + 1
        (mh &&& hi) != 0 -> score - 1
        true -> score
      end

    ph = band(ph <<< 1 ||| 1, mask)
    mh = band(mh <<< 1, mask)
    pv = band(mh ||| bnot(xv ||| ph), mask)
    mv = ph &&& xv
    myers_dist(rest, peq, mask, hi, pv, mv, score)
  end
end

# the first pass, kept verbatim as the reference (it was ElixirBackend before defk-8i4)
defmodule FuzzySearch.ElixirBackend.FirstPass do
  alias FuzzySearch.Catalog

  def search(query, k) do
    q = String.to_charlist(query)
    row0 = Enum.to_list(0..length(q))
    words = Catalog.get().charlists

    {_, top} =
      Enum.reduce(0..(tuple_size(words) - 1)//1, {0, []}, fn i, {count, top} ->
        d = distance(elem(words, i), q, row0)
        insert({d, i}, top, count, k)
      end)

    Enum.map(top, fn {d, i} -> {i, d} end)
  end

  defp distance(word, q, row0) do
    word
    |> Enum.reduce({row0, 1}, fn ch, {prev, i} -> {next_row(q, ch, prev, [i], i), i + 1} end)
    |> elem(0)
    |> List.last()
  end

  defp next_row([], _ch, _prev, acc, _left), do: :lists.reverse(acc)

  defp next_row([qc | qs], ch, [diag | [up | _] = rest], acc, left) do
    cost = if qc == ch, do: 0, else: 1
    v = min(min(up + 1, left + 1), diag + cost)
    next_row(qs, ch, rest, [v | acc], v)
  end

  defp insert(key, top, count, k) when count < k, do: {count + 1, :lists.merge([key], top)}

  defp insert(key, top, count, _k) do
    if key < List.last(top), do: {count, :lists.merge([key], List.delete_at(top, -1))}, else: {count, top}
  end
end

rounds =
  case System.argv() do
    [r] -> String.to_integer(r)
    [] -> 3
  end

variants = [
  {"0 first pass (no cut-off)", &Variants.first_pass/2},
  {"1 list rows, Enum.reduce_while", &Variants.enum_cut/2},
  {"2 list rows, tail recursion", &Variants.tail_cut/2},
  {"3 = 2, binary words", &Variants.binary_words/2},
  {"4 = 2, tuple rows", &Variants.tuple_rows/2},
  {"5 = 2, :array rows", &Variants.array_rows/2},
  {"6 = 2, u16 binary rows", &Variants.binary_rows/2},
  {"8 = 2, :lists.min for the row min", &Variants.lists_min/2},
  {"9 = 2, tail-recursive catalog walk", &Variants.tail_scan/2},
  {"10 = 2 + length pre-filter*", &Variants.length_filter/2},
  {"7 Myers bit-parallel*", &Variants.myers/2},
  {"  ElixirBackend (shipped)", &FuzzySearch.ElixirBackend.search/2}
]

:rand.seed(:exsss, {1, 2, 3})
words = FuzzySearch.Catalog.get().words
qs = for _ <- 1..20, do: elem(words, :rand.uniform(tuple_size(words)) - 1) <> "x"
run = fn f, q -> Task.await(Task.async(fn -> :timer.tc(fn -> f.(q, 10) end) end), :infinity) end

reference = Enum.map(qs, &Variants.first_pass(&1, 10))

for {name, f} <- variants do
  ^reference = Enum.map(qs, &f.(&1, 10))
end

IO.puts("all variants agree with the first pass on #{length(qs)} queries (k = 10)\n")

# interleaved: every round runs every variant on every query, so load noise hits all alike
times =
  for _ <- 1..rounds, q <- qs, {name, f} <- variants, reduce: %{} do
    acc ->
      {us, _} = run.(f, q)
      Map.update(acc, name, [us], &[us | &1])
  end

med = fn l -> Enum.at(Enum.sort(l), div(length(l), 2)) end

for {name, _} <- variants do
  t = times[name]
  IO.puts("  #{String.pad_trailing(name, 34)} median #{Float.round(med.(t) / 1000, 1)} ms/query  mean #{Float.round(Enum.sum(t) / length(t) / 1000, 1)}")
end

IO.puts("\n* not used as the baseline: 7 is a different algorithm the kernel cannot express yet (no bitwise ops, defk-w38); 10 adds a trick the kernel does not have")
