# cosine_topk: the 10 nearest of 100k sentence embeddings (384 x f32) by cosine
#
# Why people reach for a NIF here: semantic search and RAG retrieval score a
# query embedding against every stored embedding on every request (an exact
# "flat" scan; approximate indexes like HNSW are a different job). Elixir has
# no SIMD, and each f32 decoded from a binary is a boxed float. vettore 0.3.5
# (the anchor package, a Rust NIF) has no pure-Elixir version, so the Elixir
# baseline below is written here.
# Expected verdict: good (against Elixir). The catalog's recommendation is
# still Nx with EXLA, which is faster than both NIFs (see below).
#
#   elixir examples/cosine_topk.exs
#   COSINE_VARIANTS=1 elixir examples/cosine_topk.exs   # + the Elixir variants
#
# Realistic size (declared before any numbers): 100k x 384 f32 rows, k = 10.
# 384 is all-MiniLM-L6-v2's dimension, the common small sentence-embedding
# model; 100k documents is a typical corpus for an exact flat scan (vettore's
# README configures a 384-dim flat index and only moves it to the GPU from 1M
# rows). The other size is 1k x 384 (a small document set); the sweep runs
# 1k to 100k.
#
# NUMBERS ARE PROVISIONAL: measured on a loaded machine (two other benchmark
# agents running, load average ~6-7 on 12 cores). A quiet-machine run was
# recorded separately. M-series Mac, OTP 29, Elixir 1.20.2.
#
# The job, the same on every side: the query arrives as a list of 384 floats
# (f32 values, not unit length, as the model returns it); normalise it, score
# every row by cosine, return [{row index, score}] for the 10 best, best
# first, ties to the lower index. Every row is stored pre-normalised (unit
# length, then rounded to f32), so cosine is a dot product: the standard
# trick, applied to every side (vettore's flat_new_cosine, which normalises
# inside, is shown beside). Each side's index is resident, built once as at
# application boot:
#
#   Elixir   the packed f32 binary in :persistent_term
#   defk     the same binary ([f32]) in :persistent_term
#   vettore  its flat index resource (flat_new_inner_product, or
#            flat_new_cosine; flat_insert_many in batches of 5000, searched
#            with Vettore.Nifs.flat_search), the resource in :persistent_term
#   Nx       an {n, 384} f32 tensor in :persistent_term, EXLA.Backend (or
#            Nx.BinaryBackend); one jitted defn: normalise, Nx.dot, Nx.top_k
#
# Top-k selection: the same k on every side. Elixir and defk keep a bounded
# top-k (reject in O(1) against the current worst, insert in O(k)); vettore
# keeps a bounded BinaryHeap (O(log k)); Nx uses Nx.top_k. Elixir and defk
# both scan in chunks on all schedulers and merge the chunk top-k lists
# (chunking is a trick both sides get; one-process numbers are shown too).
#
# Elixir baseline: optimised. Variants (COSINE_VARIANTS=1, best of 3, ms,
# loaded machine; every variant returns the same 10 indices):
#
#                                              1k       10k      100k
#   packed f32, one float per match            3.8      86-92    756-913
#   packed f32, eight per match, eight partial
#     sums (one process)                       3.7      37       366-372
#   packed f64 (index widened at boot, 2x
#     memory), eight per match                 3.3      32-34    582-646 (cache)
#   eight per match, every score kept and
#     sorted instead of a bounded top-k        3.8-3.9  38-41    790-818
#   tuple of 384 floats per row, elem/2        3.1-3.4  33-34    -
#   list of float lists, one per element       2.8      32       -
#   list of float lists, eight per match,
#     one process                              2.8-3.6  27-28    -
#   ... chunks on all schedulers (lists in
#     :persistent_term)                        1.7      7.1-8.4  does not fit: 1.2 GB
#                                                                of lists is over the
#                                                                literal area's 1 GB
#   ... lists in 12 shard processes' heaps     1.3-1.4  8.4      73
#   packed f32, eight per match, 2 / 4 chunks  3.4 / 2.9 20 / 13-14  188-192 / 99-106
#   ... 12 chunks (= schedulers)  <- baseline  2.5-2.8 10.6-10.8 50-57
#   ... 24 chunks                              2.7     10.2-10.5 50-54
#
#   Eight floats per match is 2.4x one per match; one binary of f32 beats f64
#   (less memory traffic at 100k); float lists are 1.3x faster per element
#   at 10k but 8x the memory, so at 100k they either do not fit in
#   :persistent_term or, held in shard processes, run slower than the binary
#   (73 vs 50-57 ms). The baseline is the packed f32 binary, eight per match,
#   12 chunks: the best Elixir at 100k. At 1k the list shards are faster
#   (1.3 ms vs 2.5 ms); the all-sides table prints them. Not tried: a
#   Cauchy-Schwarz early exit on partial dot products (needs stored suffix
#   norms; an algorithm change both sides would get), quantisation (changes
#   the answer).
#
# Verdict at 100k x 384 (provisional): Elixir 48-57 ms, defk 7.2-9.6 ms, so
# defk is 5.3-7.3x the best Elixir: good. At 1k: Elixir 2.4-2.8 ms (list
# shards 1.3), defk 0.23 ms (10-12x; 5.7x over the list shards). Sweep (one
# run): 1k 12x, 2.5k 7.4x, 6.3k 5.7x, 16k 3.9x, 40k 4.8x, 100k 7.3x;
# crossover (first size at 2x or more): 1k, the smallest measured.
#
# The other sides at 100k (and 1k), best of 5, ms:
#
#   defk, chunks on all schedulers             7.2-9.6   (0.23)
#   defk, one kernel call                      21.3-21.7 (0.23)
#   vettore, inner product on unit vectors     12.6-12.7 (0.14-0.16)  <- native
#   vettore flat_new_cosine                    33.6-34.2 (0.35-0.36)
#   Nx 0.13.1 + EXLA 0.13.1, CPU               1.0-1.22  (0.11-0.13)
#   Nx 0.13.1 BinaryBackend                    14 300-15 000, one run (85-87)
#   Elixir, one process                        366-368   (3.7)
#
#   defk's 12 chunks are only 2.8x its one call: kernel tasks under
#   Task.async_stream stay on 2-3 of 12 schedulers.
#   vettore runs one thread per call: defk with chunks is 1.6-1.7x faster
#   than it, defk in one call 1.7x slower. Its flat_new_cosine computes
#   three f64 dot products per row (the query's norm again on every row) and
#   clones the String id of every row, hence 2.7x its inner-product index.
#   Nx with EXLA (XLA's multithreaded SIMD dot, the CPU client) is 6-8x
#   faster than defk with chunks at 100k and 2x at 1k: for a pure
#   matrix-vector top-k, use Nx with EXLA. Nx on the BinaryBackend is Elixir
#   and ~300x slower than the Elixir baseline. EXLA 0.13.1 compiled here in
#   ~25 s with a precompiled XLA 0.10.0 (the EXLA 0.10.0 that matmul.exs
#   tried did not compile; matmul is to be re-measured with it). defk earns its place only where the loop is more
#   than a dot product (a custom score, a filter, a different top-k rule) or
#   where EXLA is not wanted as a dependency.
#
# Responsiveness at 100k, max / p99 gap of a 1 ms ticker on one scheduler
# (Defk.Bench.report): Elixir 2.2 / 2.2 ms, defk 2.2 / 2.2 ms, vettore 2.0 /
# 2.0 ms (its flat_search is a DirtyCpu NIF, so it never blocks a normal
# scheduler); Nx+EXLA 1.5 / 1.5 ms, vettore flat_new_cosine 2.0 / 2.0 ms
# (printed beside). On this loaded machine ~2 ms is the ticker's floor; no
# side blocks the scheduler.
#
# Agreement (the script fails otherwise): over 5 queries at 1k and 100k,
# every side returns the same 10 indices in the same order. Elixir and defk
# return bit-identical scores: both sum the eight partial sums in the same
# order, in f64, from the same widened f32 values. Every other side must be
# within 2e-6 absolute: they accumulate in f32 (Nx, vettore's inner product)
# or round an f64 result to f32 (flat_new_cosine), and f32's unit roundoff
# 2^-24 ~ 6e-8 over a 384-term dot of unit vectors gives a random-walk error
# of about sqrt(384) x 6e-8 ~ 1.2e-6 (the worst case, 384 x 6e-8 ~ 2.3e-5, is
# not reached: the largest difference seen is 1.6e-7). The script also
# checks that the smallest gap between consecutive reference scores (1.5e-5)
# exceeds twice the tolerance, so no order within tolerance could flip, the
# baseline against a plain one-dot-per-row reference (1e-12), the kernel
# against its Elixir mode on small inputs (fewer rows than k, k = 1, no
# rows), and that a 383-element query, a partial row and k = 0 raise.
#
# Kernel notes: @dim 384 is a literal, so m[r * 384 + 8 * j + c] needs no
# bounds check, and q is copied into a 384-element alloc for the same
# reason. With dim = length(q) the accesses are proven too
# (n = div(length(m), dim) bounds n * dim), but the literal is still faster
# in one call, 20-21 vs 25-26 ms (was 27-28 ms while those accesses kept
# their checks). The fast-path reports of the two match otherwise; the gap
# is presumably the literal's constant trip count (not profiled). A strict f64 sum cannot be vectorised by clang, so the dot product
# keeps eight partial sums; clang's SLP vectoriser then runs them as four
# 2 x f64 NEON lanes (fcvtl f32->f64, fmul.2d, fadd.2d) with the non-finite
# checks flagged once per strip. A dimension-major layout (an axpy into the
# score array) was tried: it does not vectorise, because the in-place
# out[r] = out[r] + x * q keeps per-operation float checks (~26 ms).

Mix.install([
  {:defk, path: Path.expand("..", __DIR__)},
  {:nx, "== 0.13.1"},
  {:exla, "== 0.13.1"},
  {:vettore, "== 0.3.5"}
])

defmodule Cosine.Kernels do
  use Defk, elixir_mode: true

  # all-MiniLM-L6-v2 and friends: the dimension is fixed by the model, and a
  # literal makes the inner loop's trip count a constant (faster than
  # dim = length(q), see the kernel notes above)
  @dim 384

  # The k rows of m (row-major, @dim f32 per row, stored unit length) with the
  # largest dot product with q (@dim f64, unit length): a cosine top-k.
  # Returns {row indices + base, scores}, best first; ties go to the lower
  # index. Slots never filled (fewer than k rows) hold index -1.
  defk topk(m :: [f32], q :: [f64], k :: i64, base :: i64) :: {[i64], [f64]} do
    if length(q) != @dim or rem(length(m), @dim) != 0 or k < 1,
      do: raise(ArgumentError, "topk: q must have 384 elements, m whole 384-element rows, k >= 1")

    # a local copy of q: its length is a literal, so qq[j] needs no check
    qq = alloc(f64, @dim)
    for j <- 0..(@dim - 1)//1, do: qq[j] = q[j]

    best_s = alloc(f64, k)
    best_i = alloc(i64, k)

    for s <- 0..(k - 1)//1 do
      best_s[s] = -2.0
      best_i[s] = -1
    end

    n = div(length(m), @dim)

    _ =
      for r <- 0..(n - 1)//1, reduce: 0 do
        worst ->
          # eight partial sums: independent chains the CPU overlaps (a strict
          # f64 sum cannot be reassociated by the C compiler)
          {a0, a1, a2, a3, a4, a5, a6, a7} =
            for j <- 0..(div(@dim, 8) - 1)//1, reduce: {0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0} do
              {a0, a1, a2, a3, a4, a5, a6, a7} ->
                {a0 + m[r * @dim + 8 * j] * qq[8 * j],
                 a1 + m[r * @dim + 8 * j + 1] * qq[8 * j + 1],
                 a2 + m[r * @dim + 8 * j + 2] * qq[8 * j + 2],
                 a3 + m[r * @dim + 8 * j + 3] * qq[8 * j + 3],
                 a4 + m[r * @dim + 8 * j + 4] * qq[8 * j + 4],
                 a5 + m[r * @dim + 8 * j + 5] * qq[8 * j + 5],
                 a6 + m[r * @dim + 8 * j + 6] * qq[8 * j + 6],
                 a7 + m[r * @dim + 8 * j + 7] * qq[8 * j + 7]}
            end

          s = a0 + a1 + (a2 + a3) + (a4 + a5 + (a6 + a7))

          # rows come in index order, so an equal score never displaces
          if s > best_s[worst] do
            best_s[worst] = s
            best_i[worst] = base + r

            # the new worst slot: lowest score, the higher index on a tie
            for t <- 1..(k - 1)//1, reduce: 0 do
              w ->
                if best_s[t] < best_s[w] or (best_s[t] == best_s[w] and best_i[t] > best_i[w]),
                  do: t,
                  else: w
            end
          else
            worst
          end
      end

    # selection sort, best first
    for s <- 0..(k - 2)//1 do
      b =
        for t <- (s + 1)..(k - 1)//1, reduce: s do
          bb ->
            if best_s[t] > best_s[bb] or (best_s[t] == best_s[bb] and best_i[t] < best_i[bb]),
              do: t,
              else: bb
        end

      ts = best_s[s]
      ti = best_i[s]
      best_s[s] = best_s[b]
      best_i[s] = best_i[b]
      best_s[b] = ts
      best_i[b] = ti
    end

    {best_i, best_s}
  end
end

defmodule Cosine.Elixir do
  @dim 384
  @row @dim * 4

  def normalize(q) do
    norm = :math.sqrt(Enum.reduce(q, 0.0, fn x, a -> a + x * x end))
    Enum.map(q, &(&1 / norm))
  end

  # The baseline. m: the packed f32 index (unit rows), query: a list of
  # floats as the embedding model returns it. Rows are split into `chunks`
  # binary_part slices (sub-binaries, no copy), each scanned in its own
  # process, and the per-chunk top-k lists merged.
  def search(m, query, k, chunks \\ nil) do
    q = normalize(query)
    n = div(byte_size(m), @row)
    chunks = chunks || chunks_for(n)

    if chunks == 1 do
      scan(m, q, k, 0)
    else
      per = div(n + chunks - 1, chunks)

      0..(chunks - 1)
      |> Enum.filter(&(&1 * per < n))
      |> Task.async_stream(
        fn c ->
          s = c * per
          scan(binary_part(m, s * @row, min(per, n - s) * @row), q, k, s)
        end,
        max_concurrency: chunks,
        timeout: :infinity
      )
      |> Enum.flat_map(fn {:ok, top} -> top end)
      |> merge(k)
    end
  end

  # one chunk per scheduler: from 1k rows up it beats one process
  # (COSINE_VARIANTS=1 measures 1, 2, 4, schedulers and 2x schedulers)
  def chunks_for(n), do: max(1, min(System.schedulers_online(), n))

  def merge(hits, k) do
    hits
    |> Enum.sort(fn {i1, s1}, {i2, s2} -> s1 > s2 or (s1 == s2 and i1 <= i2) end)
    |> Enum.take(k)
  end

  # one slice in one process: [{index, score}], best first
  def scan(m, q, k, base) do
    walk(m, base, q, -2.0, List.duplicate({-2.0, -1}, k))
    |> Enum.reverse()
    |> Enum.flat_map(fn {s, i} -> if i >= 0, do: [{i, s}], else: [] end)
  end

  # top: the k best so far as {score, index}, worst first. Rows arrive in
  # index order, so a new row with an equal score is the worse one: it goes in
  # front of its equals, and only a strictly better score displaces the head.
  defp walk(<<row::binary-size(@row), rest::binary>>, i, q, worst, top) do
    s = dot8(row, q, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0)

    if s > worst do
      [{w, _} | _] = top = insert(tl(top), {s, i})
      walk(rest, i + 1, q, w, top)
    else
      walk(rest, i + 1, q, worst, top)
    end
  end

  defp walk(<<>>, _i, _q, _worst, top), do: top

  defp insert([{hs, _} = h | t], {s, _} = e) when hs < s, do: [h | insert(t, e)]
  defp insert(l, e), do: [e | l]

  # eight floats per match, eight partial sums combined as the kernel does
  # (so the scores are bit-identical to defk's)
  def dot8(
        <<x0::float-32-native, x1::float-32-native, x2::float-32-native, x3::float-32-native,
          x4::float-32-native, x5::float-32-native, x6::float-32-native, x7::float-32-native,
          rest::binary>>,
        [q0, q1, q2, q3, q4, q5, q6, q7 | qs],
        a0,
        a1,
        a2,
        a3,
        a4,
        a5,
        a6,
        a7
      ) do
    dot8(
      rest,
      qs,
      a0 + x0 * q0,
      a1 + x1 * q1,
      a2 + x2 * q2,
      a3 + x3 * q3,
      a4 + x4 * q4,
      a5 + x5 * q5,
      a6 + x6 * q6,
      a7 + x7 * q7
    )
  end

  def dot8(<<>>, [], a0, a1, a2, a3, a4, a5, a6, a7),
    do: a0 + a1 + (a2 + a3) + (a4 + a5 + (a6 + a7))
end

defmodule Cosine.Variants do
  # Elixir variants measured with COSINE_VARIANTS=1 (header table)
  @dim 384
  @row @dim * 4

  # 1. one float per match, one running sum
  def bin32_simple(m, query, k) do
    q = Cosine.Elixir.normalize(query)
    top(rows(m, @row, fn row -> dot1(row, q, 0.0) end), k)
  end

  defp dot1(<<x::float-32-native, rest::binary>>, [q | qs], a), do: dot1(rest, qs, a + x * q)
  defp dot1(<<>>, [], a), do: a

  # 2. the index widened to f64 at boot (twice the memory), eight per match
  def bin64(m64, query, k) do
    q = Cosine.Elixir.normalize(query)
    top(rows(m64, @dim * 8, fn row -> dot64(row, q, 0.0) end), k)
  end

  defp dot64(
         <<x0::float-64-native, x1::float-64-native, x2::float-64-native, x3::float-64-native,
           x4::float-64-native, x5::float-64-native, x6::float-64-native, x7::float-64-native,
           rest::binary>>,
         [q0, q1, q2, q3, q4, q5, q6, q7 | qs],
         a
       ),
       do:
         dot64(
           rest,
           qs,
           a + x0 * q0 + x1 * q1 + x2 * q2 + x3 * q3 + x4 * q4 + x5 * q5 + x6 * q6 + x7 * q7
         )

  defp dot64(<<>>, [], a), do: a

  # 3. a list of float lists, every score kept and sorted (40 bytes per float
  #    on the heap, ten times the binary)
  def lists(vecs, query, k) do
    q = Cosine.Elixir.normalize(query)

    {scored, _} =
      Enum.map_reduce(vecs, 0, fn v, i -> {{i, dotl(v, q, 0.0)}, i + 1} end)

    top(scored, k)
  end

  defp dotl([x | xs], [q | qs], a), do: dotl(xs, qs, a + x * q)
  defp dotl([], [], a), do: a

  # 3b. float lists split into chunks, as {rows, base} in a tuple under one
  #     :persistent_term key, so a task reads its chunk without a copy; eight
  #     elements per match and the baseline's bounded top-k
  def lists_chunks(key, query, k, parallel?) do
    q = Cosine.Elixir.normalize(query)
    chunks = tuple_size(:persistent_term.get(key))

    scan = fn c ->
      {rows, base} = elem(:persistent_term.get(key), c)
      scan_lists(rows, base, q, k)
    end

    if parallel? do
      0..(chunks - 1)
      |> Task.async_stream(scan, max_concurrency: chunks, timeout: :infinity)
      |> Enum.flat_map(fn {:ok, t} -> t end)
      |> top(k)
    else
      0..(chunks - 1) |> Enum.flat_map(scan) |> top(k)
    end
  end

  def scan_lists(rows, base, q, k) do
    walk_l(rows, base, q, -2.0, List.duplicate({-2.0, -1}, k))
    |> Enum.reverse()
    |> Enum.flat_map(fn {s, i} -> if i >= 0, do: [{i, s}], else: [] end)
  end

  defp walk_l([v | rest], i, q, worst, top) do
    s = dotl8(v, q, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0)

    if s > worst do
      [{w, _} | _] = top = insert(tl(top), {s, i})
      walk_l(rest, i + 1, q, w, top)
    else
      walk_l(rest, i + 1, q, worst, top)
    end
  end

  defp walk_l([], _i, _q, _worst, top), do: top

  defp insert([{hs, _} = h | t], {s, _} = e) when hs < s, do: [h | insert(t, e)]
  defp insert(l, e), do: [e | l]

  defp dotl8(
         [x0, x1, x2, x3, x4, x5, x6, x7 | xs],
         [q0, q1, q2, q3, q4, q5, q6, q7 | qs],
         a0,
         a1,
         a2,
         a3,
         a4,
         a5,
         a6,
         a7
       ) do
    dotl8(
      xs,
      qs,
      a0 + x0 * q0,
      a1 + x1 * q1,
      a2 + x2 * q2,
      a3 + x3 * q3,
      a4 + x4 * q4,
      a5 + x5 * q5,
      a6 + x6 * q6,
      a7 + x7 * q7
    )
  end

  defp dotl8([], [], a0, a1, a2, a3, a4, a5, a6, a7),
    do: a0 + a1 + (a2 + a3) + (a4 + a5 + (a6 + a7))

  # 3c. float lists held by shard processes, one per scheduler, each on its
  #     own heap (no :persistent_term literal-area limit: 100k rows of float
  #     lists are 1.2 GB, over its 1 GB default); a query is sent to every
  #     shard (384 floats copied each) and the replies merged
  def start_shards(m, shards) do
    n = div(byte_size(m), @row)
    per = div(n + shards - 1, shards)

    for c <- 0..(shards - 1), c * per < n do
      base = c * per
      part = binary_part(m, base * @row, min(per, n - base) * @row)
      parent = self()

      pid =
        spawn(fn ->
          rows = Cosine.Data.rows(part)
          :erlang.garbage_collect()
          send(parent, {:ready, self()})
          shard_loop(rows, base)
        end)

      receive do
        {:ready, ^pid} -> pid
      end
    end
  end

  defp shard_loop(rows, base) do
    receive do
      {:search, from, ref, q, k} ->
        send(from, {ref, scan_lists(rows, base, q, k)})
        shard_loop(rows, base)

      :stop ->
        :ok
    end
  end

  def shards_search(pids, query, k) do
    q = Cosine.Elixir.normalize(query)
    ref = make_ref()
    for pid <- pids, do: send(pid, {:search, self(), ref, q, k})

    pids
    |> Enum.flat_map(fn _ ->
      receive do
        {^ref, top} -> top
      end
    end)
    |> top(k)
  end

  # builds the chunk tuple for lists_chunks/3
  def list_chunks(m, chunks) do
    rows = Cosine.Data.rows(m)
    per = div(length(rows) + chunks - 1, chunks)

    rows
    |> Enum.chunk_every(per)
    |> Enum.with_index()
    |> Enum.map(fn {rs, c} -> {rs, c * per} end)
    |> List.to_tuple()
  end

  # 4. a tuple of 384 floats per row, the query as a tuple, elem/2 per element
  def tuples(vecs, query, k) do
    q = query |> Cosine.Elixir.normalize() |> List.to_tuple()

    {scored, _} =
      Enum.map_reduce(vecs, 0, fn v, i -> {{i, dott(v, q, 0, 0.0)}, i + 1} end)

    top(scored, k)
  end

  defp dott(_v, _q, @dim, a), do: a
  defp dott(v, q, j, a), do: dott(v, q, j + 1, a + elem(v, j) * elem(q, j))

  # 5. the baseline's dot8 and scan, but every score kept and the list sorted
  def sort_all(m, query, k) do
    q = Cosine.Elixir.normalize(query)

    top(
      rows(m, @row, fn row ->
        Cosine.Elixir.dot8(row, q, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0)
      end),
      k
    )
  end

  defp rows(m, size, f) do
    for <<row::binary-size(^size) <- m>>, reduce: {[], 0} do
      {acc, i} -> {[{i, f.(row)} | acc], i + 1}
    end
    |> elem(0)
  end

  defp top(scored, k), do: Cosine.Elixir.merge(scored, k)
end

defmodule Cosine.Defk do
  @dim 384
  @row @dim * 4

  # the same chunking and merge as the Elixir baseline, one kernel call per chunk
  def search(m, query, k, chunks \\ nil) do
    q = Cosine.Elixir.normalize(query)
    qb = for x <- q, into: <<>>, do: <<x::float-64-native>>
    n = div(byte_size(m), @row)
    chunks = chunks || chunks_for(n)

    if chunks == 1 do
      call(m, qb, k, 0)
    else
      per = div(n + chunks - 1, chunks)

      0..(chunks - 1)
      |> Enum.filter(&(&1 * per < n))
      |> Task.async_stream(
        fn c ->
          s = c * per
          call(binary_part(m, s * @row, min(per, n - s) * @row), qb, k, s)
        end,
        max_concurrency: chunks,
        timeout: :infinity
      )
      |> Enum.flat_map(fn {:ok, top} -> top end)
      |> Cosine.Elixir.merge(k)
    end
  end

  # the kernel is ~17x faster per row than Elixir, so chunks pay only from
  # ~8k rows each (COSINE_VARIANTS=1)
  def chunks_for(n), do: max(1, min(System.schedulers_online(), div(n, 8192)))

  def call(m, qb, k, base) do
    {ib, sb} = Cosine.Kernels.topk(m, qb, k, base)

    for {<<i::signed-64-native>>, <<s::float-64-native>>} <- Enum.zip(chunks(ib), chunks(sb)),
        i >= 0,
        do: {i, s}
  end

  defp chunks(b), do: for(<<x::binary-size(8) <- b>>, do: x)
end

defmodule Cosine.NxSearch do
  import Nx.Defn

  # normalise the query, one matrix-vector product, Nx's own top_k
  defn search(m, q, opts \\ []) do
    opts = keyword!(opts, k: 10)
    q = q / Nx.sqrt(Nx.sum(q * q))
    Nx.top_k(Nx.dot(m, q), k: opts[:k])
  end

  def to_hits({scores, idx}),
    do: Enum.zip(Nx.to_flat_list(idx), Nx.to_flat_list(scores))
end

defmodule Cosine.Data do
  @dim 384

  # Clustered unit vectors, like real sentence embeddings (not isotropic):
  # 64 topic centroids, each row a centroid plus Gaussian noise of about the
  # same norm, normalised, then rounded to f32. Built in parallel chunks of
  # 1000 rows, each from its own seed, so the data does not depend on
  # scheduling.
  def index(n, seed) do
    cs = centroids(seed)

    0..div(n - 1, 1000)
    |> Task.async_stream(
      fn c ->
        :rand.seed(:exsss, {seed, c, 7})

        for i <- (c * 1000)..min(c * 1000 + 999, n - 1)//1, into: <<>> do
          pack(noisy(elem(cs, rem(i * 7919, 64)), 1.0))
        end
      end,
      timeout: :infinity
    )
    |> Enum.map(fn {:ok, b} -> b end)
    |> IO.iodata_to_binary()
  end

  # a raw query as the model returns it: not unit length, f32 values
  def query(seed, topic) do
    cs = centroids(1)
    :rand.seed(:exsss, {seed, 99, 5})
    v = noisy(elem(cs, topic), 0.8) |> Enum.map(&(&1 * 3.7))
    for <<x::float-32-native <- pack(v)>>, do: x
  end

  def pack(v), do: for(x <- v, into: <<>>, do: <<x::float-32-native>>)

  defp centroids(seed) do
    :rand.seed(:exsss, {seed, 0, 1})
    List.to_tuple(for _ <- 1..64, do: unit(for(_ <- 1..@dim, do: :rand.normal())))
  end

  defp noisy(c, scale) do
    sigma = scale / :math.sqrt(@dim)
    unit(Enum.map(c, &(&1 + sigma * :rand.normal())))
  end

  defp unit(v) do
    norm = :math.sqrt(Enum.reduce(v, 0.0, &(&1 * &1 + &2)))
    Enum.map(v, &(&1 / norm))
  end

  def rows(m),
    do: for(<<row::binary-size(@dim * 4) <- m>>, do: for(<<x::float-32-native <- row>>, do: x))
end

defmodule Cosine.Vettore do
  # vettore's flat index: ids are zero-padded so its id tie-break (string
  # order) is index order, like the other sides
  def build(m, metric) do
    idx =
      case metric do
        :cosine -> Vettore.Nifs.flat_new_cosine()
        :inner_product -> Vettore.Nifs.flat_new_inner_product()
      end

    rows = Cosine.Data.rows(m)

    rows
    |> Enum.with_index()
    |> Enum.chunk_every(5000)
    |> Enum.each(fn batch ->
      :ok = ok(Vettore.Nifs.flat_insert_many(idx, Enum.map(batch, fn {v, i} -> {id(i), v} end)))
    end)

    idx
  end

  def id(i), do: i |> Integer.to_string() |> String.pad_leading(7, "0")

  # flat_new_cosine normalises inside (three f64 dot products per row), so
  # the raw query goes in; the inner-product index gets the normalised query
  def search(idx, query, k, :cosine), do: hits(Vettore.Nifs.flat_search(idx, query, k))

  def search(idx, query, k, :inner_product),
    do: hits(Vettore.Nifs.flat_search(idx, Cosine.Elixir.normalize(query), k))

  defp hits(res), do: for({id, s} <- ok(res), do: {String.to_integer(id), s})

  defp ok(:ok), do: :ok
  defp ok({:ok, {}}), do: :ok
  defp ok({:ok, v}), do: v
  defp ok(v) when is_list(v), do: v
  defp ok({:error, e}), do: raise("vettore: #{inspect(e)}")
end

# ---------------------------------------------------------------- setup --

k = 10
n_large = 100_000
n_small = 1_000
row = 384 * 4

{gen_us, m_large} = :timer.tc(fn -> Cosine.Data.index(n_large, 1) end)

IO.puts(
  "index: #{n_large} x 384 f32 (#{div(byte_size(m_large), 1_000_000)} MB) built in #{div(gen_us, 1000)} ms"
)

m_small = binary_part(m_large, 0, n_small * row)

# every side's index is resident, built once as at application boot
:persistent_term.put({:cosine, :f32, :large}, m_large)
:persistent_term.put({:cosine, :f32, :small}, m_small)

nx_index = fn m, backend ->
  t = m |> Nx.from_binary(:f32) |> Nx.reshape({div(byte_size(m), row), 384})
  Nx.backend_transfer(t, backend)
end

for size <- [:small, :large] do
  m = :persistent_term.get({:cosine, :f32, size})
  :persistent_term.put({:cosine, :exla, size}, nx_index.(m, EXLA.Backend))
  :persistent_term.put({:cosine, :nx_bin, size}, nx_index.(m, Nx.BinaryBackend))
  :persistent_term.put({:cosine, :vettore_cos, size}, Cosine.Vettore.build(m, :cosine))
  :persistent_term.put({:cosine, :vettore_ip, size}, Cosine.Vettore.build(m, :inner_product))
end

exla_search = Nx.Defn.jit(&Cosine.NxSearch.search(&1, &2, k: 10), compiler: EXLA)
:persistent_term.put({:cosine, :exla_fun}, exla_search)

query = Cosine.Data.query(2, 17)

side = fn
  :elixir, size, q ->
    Cosine.Elixir.search(:persistent_term.get({:cosine, :f32, size}), q, k)

  :elixir_1, size, q ->
    Cosine.Elixir.search(:persistent_term.get({:cosine, :f32, size}), q, k, 1)

  :defk, size, q ->
    Cosine.Defk.search(:persistent_term.get({:cosine, :f32, size}), q, k)

  :defk_1, size, q ->
    Cosine.Defk.search(:persistent_term.get({:cosine, :f32, size}), q, k, 1)

  :vettore_cos, size, q ->
    Cosine.Vettore.search(:persistent_term.get({:cosine, :vettore_cos, size}), q, k, :cosine)

  :vettore_ip, size, q ->
    Cosine.Vettore.search(
      :persistent_term.get({:cosine, :vettore_ip, size}),
      q,
      k,
      :inner_product
    )

  :exla, size, q ->
    f = :persistent_term.get({:cosine, :exla_fun})
    m = :persistent_term.get({:cosine, :exla, size})
    Cosine.NxSearch.to_hits(f.(m, Nx.tensor(q, type: :f32, backend: EXLA.Backend)))

  :nx_bin, size, q ->
    m = :persistent_term.get({:cosine, :nx_bin, size})

    Cosine.NxSearch.to_hits(
      Cosine.NxSearch.search(m, Nx.tensor(q, type: :f32, backend: Nx.BinaryBackend), k: 10)
    )
end

best_ms = fn f, runs ->
  f.()

  1..runs
  |> Enum.map(fn _ ->
    :erlang.garbage_collect()
    elem(:timer.tc(f), 0)
  end)
  |> Enum.min()
  |> Kernel./(1000)
  |> Float.round(3)
end

if System.get_env("COSINE_VARIANTS") do
  m64 = for <<x::float-32-native <- m_large>>, into: <<>>, do: <<x::float-64-native>>
  :persistent_term.put({:cosine, :f64}, m64)
  IO.puts("\nElixir variants (best of 3, ms)")

  for n <- [1_000, 10_000, 100_000] do
    m = binary_part(m_large, 0, n * row)
    m6 = binary_part(:persistent_term.get({:cosine, :f64}), 0, n * row * 2)

    vs = [
      {"bin32, 1 per match", fn -> Cosine.Variants.bin32_simple(m, query, k) end},
      {"bin32, 8 per match (one process)", fn -> Cosine.Elixir.search(m, query, k, 1) end},
      {"bin64, 8 per match", fn -> Cosine.Variants.bin64(m6, query, k) end},
      {"bin32, 8 per match, sort all scores", fn -> Cosine.Variants.sort_all(m, query, k) end},
      {"bin32, 8 per match, 2 chunks", fn -> Cosine.Elixir.search(m, query, k, 2) end},
      {"bin32, 8 per match, 4 chunks", fn -> Cosine.Elixir.search(m, query, k, 4) end},
      {"bin32, 8 per match, schedulers chunks",
       fn -> Cosine.Elixir.search(m, query, k, System.schedulers_online()) end},
      {"bin32, 8 per match, 2x schedulers chunks",
       fn -> Cosine.Elixir.search(m, query, k, 2 * System.schedulers_online()) end},
      {"defk, one call", fn -> Cosine.Defk.search(m, query, k, 1) end},
      {"defk, 4 chunks", fn -> Cosine.Defk.search(m, query, k, 4) end},
      {"defk, schedulers chunks",
       fn -> Cosine.Defk.search(m, query, k, System.schedulers_online()) end}
    ]

    lists_key = {:cosine, :lists_par, n}
    shards = Cosine.Variants.start_shards(m, System.schedulers_online())

    vs =
      vs ++
        [
          {"float lists, shard processes",
           fn -> Cosine.Variants.shards_search(shards, query, k) end}
        ]

    vs =
      if n <= 10_000 do
        :persistent_term.put(
          lists_key,
          Cosine.Variants.list_chunks(m, System.schedulers_online())
        )

        vs ++
          [
            {"float lists, 8 per match (one process)",
             fn -> Cosine.Variants.lists_chunks(lists_key, query, k, false) end},
            {"float lists, 8 per match, schedulers chunks",
             fn -> Cosine.Variants.lists_chunks(lists_key, query, k, true) end}
          ]
      else
        vs
      end

    vs =
      if n <= 10_000 do
        lists = Cosine.Data.rows(m)
        tuples = Enum.map(lists, &List.to_tuple/1)
        :persistent_term.put({:cosine, :lists}, lists)
        :persistent_term.put({:cosine, :tuples}, tuples)

        vs ++
          [
            {"float lists, 1 per match, sort all",
             fn -> Cosine.Variants.lists(:persistent_term.get({:cosine, :lists}), query, k) end},
            {"tuple of floats per row",
             fn -> Cosine.Variants.tuples(:persistent_term.get({:cosine, :tuples}), query, k) end}
          ]
      else
        vs
      end

    ref = Cosine.Elixir.search(m, query, k, 1)
    IO.puts("  n = #{n}")

    for {label, f} <- vs do
      same = Enum.map(f.(), &elem(&1, 0)) == Enum.map(ref, &elem(&1, 0))

      IO.puts(
        "    #{String.pad_trailing(label, 44)} #{best_ms.(f, 3)}#{if same, do: "", else: "  DISAGREES"}"
      )
    end

    for pid <- shards, do: send(pid, :stop)
    :persistent_term.erase(lists_key)
    :persistent_term.erase({:cosine, :lists})
    :persistent_term.erase({:cosine, :tuples})
  end

  :persistent_term.erase({:cosine, :f64})
end

# ------------------------------------------------------------ agreement --

# Identical top-k indices on every side; scores: Elixir and defk bit-identical
# (the same eight partial sums, in the same order, in f64); every other side
# within @tol of them (see the header).
tol = 2.0e-6
queries = for t <- [17, 3, 41, 58, 9], do: Cosine.Data.query(2 + t, t)

agree_sides = fn size, q ->
  ref = side.(:elixir, size, q)
  ids = Enum.map(ref, &elem(&1, 0))

  others =
    [:elixir_1, :defk, :defk_1, :vettore_cos, :vettore_ip, :exla] ++
      if(size == :small, do: [:nx_bin], else: [])

  # gaps between consecutive reference scores (k + 1 deep): an order the
  # tolerance could flip would make the index check meaningless
  deep = Cosine.Elixir.search(:persistent_term.get({:cosine, :f32, size}), q, k + 1)

  gap =
    deep
    |> Enum.map(&elem(&1, 1))
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.map(fn [a, b] -> a - b end)
    |> Enum.min()

  rows =
    for s <- others do
      hits = side.(s, size, q)
      same_ids = Enum.map(hits, &elem(&1, 0)) == ids

      diff =
        hits
        |> Enum.zip(ref)
        |> Enum.map(fn {{_, a}, {_, b}} -> abs(a - b) end)
        |> Enum.max(fn -> 1.0 end)

      exact = s in [:elixir_1, :defk, :defk_1] and hits == ref

      ok =
        same_ids and length(hits) == k and
          if(s in [:elixir_1, :defk, :defk_1], do: exact, else: diff <= tol)

      {s, ok, diff}
    end

  {gap, rows}
end

checks = for size <- [:small, :large], q <- queries, do: {size, agree_sides.(size, q)}

max_diff =
  for {_size, {_gap, rows}} <- checks, {s, _ok, d} <- rows, reduce: %{} do
    acc -> Map.update(acc, s, d, &max(&1, d))
  end

min_gap = checks |> Enum.map(fn {_, {g, _}} -> g end) |> Enum.min()
sides_ok = Enum.all?(for {_, {_, rows}} <- checks, {_, ok, _} <- rows, do: ok)

# the kernel against its Elixir mode, on small and bad inputs
mode_ok =
  for {n, kk, base} <- [{50, 10, 0}, {3, 10, 7}, {200, 1, 0}, {0, 5, 0}] do
    m = binary_part(m_large, 0, n * row)
    qb = for x <- Cosine.Elixir.normalize(hd(queries)), into: <<>>, do: <<x::float-64-native>>

    Cosine.Kernels.topk(m, qb, kk, base) ==
      Cosine.Kernels.__defk_elixir__(:topk, [m, qb, kk, base])
  end
  |> Enum.all?()

raises? = fn f ->
  try do
    f.()
    false
  rescue
    ArgumentError -> true
  end
end

q383 = for _ <- 1..383, into: <<>>, do: <<0.05::float-64-native>>
q384 = for _ <- 1..384, into: <<>>, do: <<0.05::float-64-native>>

bad_ok =
  raises?.(fn -> Cosine.Kernels.topk(m_small, q383, k, 0) end) and
    raises?.(fn -> Cosine.Kernels.__defk_elixir__(:topk, [m_small, q383, k, 0]) end) and
    raises?.(fn -> Cosine.Kernels.topk(binary_part(m_small, 0, 1000), q384, k, 0) end) and
    raises?.(fn -> Cosine.Kernels.topk(m_small, q384, 0, 0) end)

# the Elixir baseline against a plain reference (one dot product per row,
# sorted): same indices, scores within 1e-12 (summation order differs)
plain = fn m, q ->
  qn = Cosine.Elixir.normalize(q)

  m
  |> Cosine.Data.rows()
  |> Enum.with_index()
  |> Enum.map(fn {v, i} -> {i, Enum.zip_with(v, qn, &*/2) |> Enum.sum()} end)
  |> Cosine.Elixir.merge(k)
end

ref_ok =
  Enum.all?(
    for q <- queries do
      a = plain.(m_small, q)
      b = side.(:elixir, :small, q)

      Enum.map(a, &elem(&1, 0)) == Enum.map(b, &elem(&1, 0)) and
        Enum.all?(Enum.zip(a, b), fn {{_, x}, {_, y}} -> abs(x - y) < 1.0e-12 end)
    end
  )

agree = sides_ok and mode_ok and bad_ok and ref_ok and min_gap > 2 * tol

IO.puts("""

agreement over #{length(queries)} queries at 1k and 100k rows: #{agree}
  every side, identical top-#{k} indices: #{sides_ok}; Elixir mode: #{mode_ok}; bad inputs raise: #{bad_ok}; plain reference: #{ref_ok}
  smallest gap between consecutive reference scores: #{Float.round(min_gap, 6)} (must exceed 2 x tolerance #{tol})
  largest score difference from the Elixir baseline: #{Enum.map_join(max_diff, ", ", fn {s, d} -> "#{s} #{:erlang.float_to_binary(d * 1.0, scientific: 1)}" end)}
""")

agree || System.halt(1)

# ------------------------------------------------------------ all sides --

lists_shards = Cosine.Variants.start_shards(m_small, System.schedulers_online())

table = [
  {"Elixir baseline (packed f32, chunks on all schedulers)", :elixir, 5},
  {"Elixir, the same in one process", :elixir_1, 3},
  {"defk (chunks on all schedulers from 8k rows)", :defk, 5},
  {"defk, one kernel call", :defk_1, 5},
  {"vettore flat, inner product on unit vectors", :vettore_ip, 5},
  {"vettore flat_new_cosine", :vettore_cos, 5},
  {"Nx 0.13.1 + EXLA 0.13.1 (CPU)", :exla, 5}
]

IO.puts("all sides, k = #{k}, best of N (ms):          1k x 384     100k x 384")

for {label, s, runs} <- table do
  a = best_ms.(fn -> side.(s, :small, query) end, runs)
  b = best_ms.(fn -> side.(s, :large, query) end, runs)

  IO.puts(
    "  #{String.pad_trailing(label, 56)} #{String.pad_leading(to_string(a), 8)} #{String.pad_leading(to_string(b), 12)}"
  )
end

nx_small = best_ms.(fn -> side.(:nx_bin, :small, query) end, 3)
{nx_large_us, _} = :timer.tc(fn -> side.(:nx_bin, :large, query) end)
shard_small = best_ms.(fn -> Cosine.Variants.shards_search(lists_shards, query, k) end, 5)

IO.puts(
  "  #{String.pad_trailing("Nx 0.13.1 BinaryBackend (100k: one run)", 56)} #{String.pad_leading(to_string(nx_small), 8)} #{String.pad_leading(to_string(Float.round(nx_large_us / 1000, 1)), 12)}"
)

IO.puts(
  "  #{String.pad_trailing("Elixir float lists in shard processes (best Elixir at 1k)", 56)} #{String.pad_leading(to_string(shard_small), 8)}            -"
)

exla_gap = Defk.Bench.TickGap.run(fn -> side.(:exla, :large, query) end)
vettore_cos_gap = Defk.Bench.TickGap.run(fn -> side.(:vettore_cos, :large, query) end)

IO.puts("""
  tick gap at 100k, one scheduler (max / p99 ms): Nx+EXLA #{exla_gap.max} / #{exla_gap.p99}, vettore flat_new_cosine #{vettore_cos_gap.max} / #{vettore_cos_gap.p99}
""")

# --------------------------------------------------------------- report --

sweep_fun = fn n ->
  m = binary_part(:persistent_term.get({:cosine, :f32, :large}), 0, n * row)
  {fn -> Cosine.Elixir.search(m, query, k) end, fn -> Cosine.Defk.search(m, query, k) end}
end

result =
  Defk.Bench.report(
    name: "cosine_topk",
    expected: :good,
    baseline: :optimized,
    realistic_size: "100k x 384 f32, k = 10",
    elixir: fn -> side.(:elixir, :large, query) end,
    defk: fn -> side.(:defk, :large, query) end,
    native:
      {fn -> side.(:vettore_ip, :large, query) end,
       "vettore 0.3.5 flat, inner product on unit vectors"},
    check: fn -> agree and side.(:elixir, :large, query) == side.(:defk, :large, query) end,
    sweep: {[1_000, 2_500, 6_300, 16_000, 40_000, 100_000], sweep_fun},
    responsiveness: true,
    reason:
      "f32 widen-multiply-add over a resident packed index, 5-7x the best Elixir and 1.7x vettore's single-threaded NIF, but Nx with EXLA (multithreaded SIMD) is 6-8x faster than defk: for a plain dot-product top-k use Nx+EXLA"
  )

result.correct || System.halt(1)
