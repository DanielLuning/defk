# geo_nearest: the 10 closest of 500k locations to a point
#
# Why people reach for a NIF here: "nearest driver / store / vehicle" queries
# compute a great-circle distance to every candidate on every request.
# Expected verdict: good
#
#   elixir examples/geo_nearest.exs
#
# Both versions keep their index in :persistent_term, built once at boot as a
# real app would (with 500k tuples on the benchmark process's heap instead,
# GC copying them tripled the Elixir time). Candidates are ranked by the
# haversine term `a` (monotonic in distance), so no asin/sqrt per candidate;
# kilometres are computed for the 10 winners only. Ties break by index, and
# both sides return the 10 indices in rank order, so they agree exactly.
#
# Elixir baseline: optimised. Best of 5 timed runs, 500k points, 12 schedulers;
# the full scan, every variant returns the same 10 indices:
#
#   first pass: list of {lat, lon, cos_lat} tuples, Enum.reduce,
#     bounded top-k list                                           ~24 ms
#   index as 3 packed f64 binaries walked in lockstep with
#     <<x::float-64-native, rest::binary>>, sorted-list top-k      ~31 ms (slower)
#   same, bounded top-k as a tuple / as :gb_trees                  ~30 / ~30 ms
#   one interleaved binary of 24-byte records (one match per
#     point), sorted-list top-k                                    ~22 ms
#   + early exit: a >= sdlat^2, so once sdlat^2 reaches the
#     current k-th best the second :math.sin is skipped (exact;
#     the kernel gets the same exit)                               ~14 ms
#   + parallel: Task.async_stream over one binary_part per
#     scheduler, merging the per-chunk top-k                       ~3.7-4.7 ms  <- baseline
#   parallel without the early exit                                ~6.5 ms
#   trig-free product formula (sin(x-y) from stored sin/cos
#     halves, 5 floats per point), early exit                      ~17.6 ms single, ~5.1 ms
#                                                                  parallel: wider records cost more than the sin saved
#   precomputed cos(lat), as the kernel does, was already in the first pass.
#   Packed binaries alone were slower than tuples (binary matching of three
#   columns); only one interleaved binary plus the early exit and parallel
#   chunks paid off. Per-point :math.sin calls dominate a single process.
#
# defk: the same algorithm in one kernel call (single thread; 2.4 ms before the
# early exit, ~1.0-1.3 ms with it). K kernel calls over binary_part chunks on
# Task.async_stream (K = 2..24, merging by recomputing `a` for the K*10
# winners) took 0.9-1.3 ms: no gain, so the catalog uses one call. The verdict
# compares it with the parallel Elixir, which uses every scheduler where defk
# uses one; the script also prints single-process Elixir (~14 ms).
#
# Coarse grid (changes the algorithm, so it is printed beside the verdict, not
# in it): 1 degree cells; only the query's 3x3 block is scored, widening one
# ring at a time until the k-th best `a` is below the guaranteed lower bound of
# anything outside the block, so the result stays exact. Applied to both sides.

Mix.install([{:defk, path: Path.expand("..", __DIR__)}])

defmodule Geo.Kernels do
  use Defk

  # positions of the k smallest haversine `a` values, in rank order
  defk nearest(lat :: [f64], lon :: [f64], coslat :: [f64], qlat :: f64, qlon :: f64, k :: i64) ::
         [i64] do
    best_a = alloc(f64, k)
    best_i = alloc(i64, k)
    cq = cos(qlat)

    for s <- 0..(k - 1)//1 do
      best_a[s] = 10.0
      best_i[s] = -1
    end

    _ =
      for i <- 0..(len(lat) - 1)//1, reduce: 0 do
        worst ->
          sdlat = sin((lat[i] - qlat) / 2)
          s2 = sdlat * sdlat

          # a >= s2, so a candidate whose latitude term alone is too big is out
          if s2 < best_a[worst] do
            sdlon = sin((lon[i] - qlon) / 2)
            a = s2 + cq * coslat[i] * sdlon * sdlon

            if a < best_a[worst] do
              best_a[worst] = a
              best_i[worst] = i

              for s <- 1..(k - 1)//1, reduce: 0 do
                # worst = largest (a, index) key, matching Elixir's tuple order on ties
                w ->
                  if best_a[s] > best_a[w] or (best_a[s] == best_a[w] and best_i[s] > best_i[w]),
                    do: s,
                    else: w
              end
            else
              worst
            end
          else
            worst
          end
      end

    # selection sort into rank order
    for s <- 0..(k - 2)//1 do
      m =
        for j <- (s + 1)..(k - 1)//1, reduce: s do
          mm ->
            if best_a[j] < best_a[mm] or (best_a[j] == best_a[mm] and best_i[j] < best_i[mm]),
              do: j,
              else: mm
        end

      ta = best_a[s]
      ti = best_i[s]
      best_a[s] = best_a[m]
      best_i[s] = best_i[m]
      best_a[m] = ta
      best_i[m] = ti
    end

    best_i
  end

  # the same over gathered grid candidates: ties break by ids[], not position;
  # returns positions in rank order (callers guarantee len(lat) >= k)
  defk nearest_ids(
         ids :: [i64],
         lat :: [f64],
         lon :: [f64],
         coslat :: [f64],
         qlat :: f64,
         qlon :: f64,
         k :: i64
       ) :: [i64] do
    best_a = alloc(f64, k)
    best_i = alloc(i64, k)
    cq = cos(qlat)

    for s <- 0..(k - 1)//1 do
      best_a[s] = 10.0
      best_i[s] = 0
    end

    _ =
      for i <- 0..(len(lat) - 1)//1, reduce: 0 do
        worst ->
          sdlat = sin((lat[i] - qlat) / 2)
          s2 = sdlat * sdlat

          if s2 <= best_a[worst] do
            sdlon = sin((lon[i] - qlon) / 2)
            a = s2 + cq * coslat[i] * sdlon * sdlon

            if a < best_a[worst] or (a == best_a[worst] and ids[i] < ids[best_i[worst]]) do
              best_a[worst] = a
              best_i[worst] = i

              for s <- 1..(k - 1)//1, reduce: 0 do
                w ->
                  if best_a[s] > best_a[w] or
                       (best_a[s] == best_a[w] and ids[best_i[s]] > ids[best_i[w]]),
                     do: s,
                     else: w
              end
            else
              worst
            end
          else
            worst
          end
      end

    for s <- 0..(k - 2)//1 do
      m =
        for j <- (s + 1)..(k - 1)//1, reduce: s do
          mm ->
            if best_a[j] < best_a[mm] or
                 (best_a[j] == best_a[mm] and ids[best_i[j]] < ids[best_i[mm]]),
               do: j,
               else: mm
        end

      ta = best_a[s]
      ti = best_i[s]
      best_a[s] = best_a[m]
      best_i[s] = best_i[m]
      best_a[m] = ta
      best_i[m] = ti
    end

    best_i
  end
end

defmodule Geo.Elixir do
  @big 1.0e10

  # index: one binary of 24-byte records <<lat, lon, cos_lat>> (f64 native).
  # Walked in parallel chunks, one per scheduler; each keeps a sorted bounded
  # top-k list of {a, index}, and the chunk lists are merged.
  def nearest(rec, qlat, qlon, k, chunks \\ System.schedulers_online()) do
    n = div(byte_size(rec), 24)
    per = div(n + chunks - 1, chunks)

    0..(chunks - 1)
    |> Task.async_stream(
      fn c ->
        s = c * per
        scan(binary_part(rec, s * 24, min(per, n - s) * 24), s, qlat, qlon, k)
      end,
      max_concurrency: chunks,
      ordered: false,
      timeout: :infinity
    )
    |> Enum.flat_map(fn {:ok, top} -> top end)
    |> Enum.sort()
    |> Enum.take(k)
    |> Enum.map(&elem(&1, 1))
  end

  # one chunk, one process: top-k of {a, index}, ascending
  def scan(rec, base, qlat, qlon, k) do
    walk(rec, base, :math.cos(qlat), qlat, qlon, @big, List.duplicate({@big, -1}, k))
  end

  defp walk(
         <<lat::float-64-native, lon::float-64-native, coslat::float-64-native, rest::binary>>,
         i,
         cq,
         qlat,
         qlon,
         worst,
         top
       ) do
    sdlat = :math.sin((lat - qlat) / 2)
    s2 = sdlat * sdlat

    if s2 < worst do
      sdlon = :math.sin((lon - qlon) / 2)
      a = s2 + cq * coslat * sdlon * sdlon

      if a < worst do
        top = insert(top, {a, i})
        {worst, _} = List.last(top)
        walk(rest, i + 1, cq, qlat, qlon, worst, top)
      else
        walk(rest, i + 1, cq, qlat, qlon, worst, top)
      end
    else
      walk(rest, i + 1, cq, qlat, qlon, worst, top)
    end
  end

  defp walk(<<>>, _, _, _, _, _, top), do: top

  # insert into the ascending list and drop the old last (the caller knows the
  # new entry sorts before it); equal `a` keeps the earlier index first
  defp insert([_], e), do: [e]
  defp insert([{ta, _} = h | t], {a, _} = e) when ta <= a, do: [h | insert(t, e)]
  defp insert([h | t], e), do: [e, h | :lists.droplast(t)]
end

defmodule Geo.Grid do
  # 1 degree cells. Index per cell: cell => binary of 32-byte records
  # <<id, lat, lon, cos_lat>> for Elixir, cell => {ids, lat, lon, cos} columns for defk.
  @cell :math.pi() / 180
  @big 1.0e10

  def cell(lat_deg, lon_deg), do: {floor(lat_deg), floor(lon_deg)}

  # all cells of the (2r+1)^2 block around the query's cell
  def block({cy, cx}, r), do: for(y <- (cy - r)..(cy + r), x <- (cx - r)..(cx + r), do: {y, x})

  # no point outside the block has an `a` below this (lon term; data never wraps)
  def bound(qlat, r, cmin) do
    s = :math.sin(r * @cell / 2)
    :math.cos(qlat) * cmin * s * s
  end

  # Elixir: widen the block until the k-th `a` is under the bound
  def elixir(cells, cmin, qcell, qlat, qlon, k, r \\ 1) do
    rec = for c <- block(qcell, r), into: <<>>, do: Map.get(cells, c, <<>>)

    with true <- byte_size(rec) >= k * 32,
         top = walk(rec, :math.cos(qlat), qlat, qlon, @big, @big, List.duplicate({@big, @big}, k)),
         {kth, _} = List.last(top),
         true <- kth < bound(qlat, r, cmin) do
      Enum.map(top, &elem(&1, 1))
    else
      _ -> elixir(cells, cmin, qcell, qlat, qlon, k, r + 1)
    end
  end

  defp walk(
         <<id::signed-64-native, lat::float-64-native, lon::float-64-native,
           coslat::float-64-native, rest::binary>>,
         cq,
         qlat,
         qlon,
         worst,
         worst_id,
         top
       ) do
    sdlat = :math.sin((lat - qlat) / 2)
    s2 = sdlat * sdlat

    if s2 <= worst do
      sdlon = :math.sin((lon - qlon) / 2)
      a = s2 + cq * coslat * sdlon * sdlon

      if a < worst or (a == worst and id < worst_id) do
        top = insert(top, {a, id})
        {worst, worst_id} = List.last(top)
        walk(rest, cq, qlat, qlon, worst, worst_id, top)
      else
        walk(rest, cq, qlat, qlon, worst, worst_id, top)
      end
    else
      walk(rest, cq, qlat, qlon, worst, worst_id, top)
    end
  end

  defp walk(<<>>, _, _, _, _, _, top), do: top

  defp insert([_], e), do: [e]
  defp insert([h | t], e) when h <= e, do: [h | insert(t, e)]
  defp insert([h | t], e), do: [e, h | :lists.droplast(t)]

  # defk: gather the block's columns, one kernel call, same widening rule
  def defk(cells, cmin, qcell, qlat, qlon, k, r \\ 1) do
    found = for c <- block(qcell, r), v = Map.get(cells, c), do: v
    col = fn j -> IO.iodata_to_binary(for t <- found, do: elem(t, j)) end
    {ids, lat, lon, cos} = {col.(0), col.(1), col.(2), col.(3)}

    with true <- byte_size(ids) >= k * 8,
         pos =
           for(
             <<p::64-signed-native <- Geo.Kernels.nearest_ids(ids, lat, lon, cos, qlat, qlon, k)>>,
             do: p
           ),
         last = List.last(pos),
         kth = a_at(lat, lon, cos, last, qlat, qlon),
         true <- kth < bound(qlat, r, cmin) do
      for p <- pos do
        <<_::binary-size(^p * 8), id::signed-64-native, _::binary>> = ids
        id
      end
    else
      _ -> defk(cells, cmin, qcell, qlat, qlon, k, r + 1)
    end
  end

  defp a_at(lat, lon, cos, p, qlat, qlon) do
    <<_::binary-size(^p * 8), la::float-64-native, _::binary>> = lat
    <<_::binary-size(^p * 8), lo::float-64-native, _::binary>> = lon
    <<_::binary-size(^p * 8), c::float-64-native, _::binary>> = cos
    sdlat = :math.sin((la - qlat) / 2)
    sdlon = :math.sin((lo - qlon) / 2)
    sdlat * sdlat + :math.cos(qlat) * c * sdlon * sdlon
  end
end

# 500k points scattered over Europe (deterministic)
n = 500_000
rad = &(&1 * :math.pi() / 180)

# built once, as at application boot; kept out of this process's heap
points =
  for i <- 1..n do
    lat_deg = 36 + rem(i * 7919, 3400) / 100
    lon_deg = -10 + rem(i * 104_729, 4000) / 100
    lat = rad.(lat_deg)
    {i - 1, lat_deg, lon_deg, lat, rad.(lon_deg), :math.cos(lat)}
  end

col = fn f -> for p <- points, into: <<>>, do: <<f.(p)::float-64-native>> end

:persistent_term.put(
  :geo_rec,
  for(
    {_, _, _, lat, lon, c} <- points,
    into: <<>>,
    do: <<lat::float-64-native, lon::float-64-native, c::float-64-native>>
  )
)

:persistent_term.put(:geo_packed, {col.(&elem(&1, 3)), col.(&elem(&1, 4)), col.(&elem(&1, 5))})

# grid indexes, one per side
by_cell = Enum.group_by(points, fn {_, la, lo, _, _, _} -> Geo.Grid.cell(la, lo) end)

:persistent_term.put(
  :geo_grid_elixir,
  Map.new(by_cell, fn {c, ps} ->
    {c,
     for(
       {id, _, _, lat, lon, cl} <- ps,
       into: <<>>,
       do:
         <<id::signed-64-native, lat::float-64-native, lon::float-64-native, cl::float-64-native>>
     )}
  end)
)

:persistent_term.put(
  :geo_grid_defk,
  Map.new(by_cell, fn {c, ps} ->
    pk = fn f -> for p <- ps, into: <<>>, do: <<f.(p)::float-64-native>> end

    {c,
     {for(p <- ps, into: <<>>, do: <<elem(p, 0)::signed-64-native>>), pk.(&elem(&1, 3)),
      pk.(&elem(&1, 4)), pk.(&elem(&1, 5))}}
  end)
)

:persistent_term.put(:geo_cmin, points |> Enum.map(&elem(&1, 5)) |> Enum.min())

{qlat_deg, qlon_deg} = {59.3293, 18.0686}
{qlat, qlon} = {rad.(qlat_deg), rad.(qlon_deg)}
qcell = Geo.Grid.cell(qlat_deg, qlon_deg)

elixir_nearest = fn -> Geo.Elixir.nearest(:persistent_term.get(:geo_rec), qlat, qlon, 10) end

defk_nearest = fn ->
  {lat, lon, coslat} = :persistent_term.get(:geo_packed)
  for <<i::64-signed-native <- Geo.Kernels.nearest(lat, lon, coslat, qlat, qlon, 10)>>, do: i
end

result =
  Defk.Bench.report(
    name: "geo_nearest",
    expected: :good,
    baseline: :optimized,
    elixir: elixir_nearest,
    defk: defk_nearest,
    check: fn -> elixir_nearest.() == defk_nearest.() end,
    reason: "float math per candidate over a packed index reused by every query"
  )

# beside the verdict: single-process Elixir, and the grid on both sides
best = fn f ->
  f.()

  1..5
  |> Enum.map(fn _ ->
    :erlang.garbage_collect()
    elem(:timer.tc(f), 0)
  end)
  |> Enum.min()
  |> Kernel./(1000)
  |> Float.round(3)
end

single = fn -> Geo.Elixir.nearest(:persistent_term.get(:geo_rec), qlat, qlon, 10, 1) end

grid_elixir = fn ->
  cells = :persistent_term.get(:geo_grid_elixir)
  Geo.Grid.elixir(cells, :persistent_term.get(:geo_cmin), qcell, qlat, qlon, 10)
end

grid_defk = fn ->
  cells = :persistent_term.get(:geo_grid_defk)
  Geo.Grid.defk(cells, :persistent_term.get(:geo_cmin), qcell, qlat, qlon, 10)
end

exact = elixir_nearest.()
agree = single.() == exact and grid_elixir.() == exact and grid_defk.() == exact
single_ms = best.(single)
{ge, gd} = {best.(grid_elixir), best.(grid_defk)}

IO.puts("""

  beside the verdict (agrees with the full scan: #{agree})
    Elixir in one process (no parallel chunks): #{single_ms} ms; defk #{result.defk_ms} ms is #{Float.round(single_ms / result.defk_ms, 1)}x
    grid, Elixir: #{ge} ms
    grid, defk:   #{gd} ms (#{Float.round(ge / gd, 2)}x)
""")

agree or System.halt(1)
