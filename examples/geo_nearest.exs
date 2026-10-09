# geo_nearest: the 10 closest of 500k locations to a point
#
# Why people reach for a NIF here: "nearest driver / store / vehicle" queries
# compute a great-circle distance to every candidate on every request.
# Expected verdict: good
#
#   elixir examples/geo_nearest.exs
#
# Both versions keep their index in their natural form, built once at boot
# and stored in :persistent_term as a real app would: a list of tuples for
# Elixir, packed f64 arrays for defk. (With the 500k tuples on the benchmark
# process's heap instead, GC copying them tripled the Elixir time.) Candidates are
# ranked by the haversine term `a` (monotonic in distance), so no asin/sqrt
# per candidate; kilometres are computed for the 10 winners only.
#
# Elixir baseline: first pass. Not yet tried: storing the index as packed
# binaries and walking them with binary matching; a coarse grid or bounding
# box so most candidates are never scored (helps both sides).

Mix.install([{:defk, path: Path.expand("..", __DIR__)}])

defmodule Geo.Kernels do
  use Defk

  # indices of the k smallest haversine `a` values
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
          sdlon = sin((lon[i] - qlon) / 2)
          a = sdlat * sdlat + cq * coslat[i] * sdlon * sdlon

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
      end

    best_i
  end
end

defmodule Geo.Elixir do
  # points: [{lat_rad, lon_rad, cos_lat}]; bounded top-k list of {a, index}
  def nearest(points, qlat, qlon, k) do
    cq = :math.cos(qlat)

    {_, _, top} =
      Enum.reduce(points, {0, 0, []}, fn {lat, lon, coslat}, {i, count, top} ->
        sdlat = :math.sin((lat - qlat) / 2)
        sdlon = :math.sin((lon - qlon) / 2)
        a = sdlat * sdlat + cq * coslat * sdlon * sdlon

        cond do
          count < k ->
            {i + 1, count + 1, :lists.merge([{a, i}], top)}

          a < elem(List.last(top), 0) ->
            {i + 1, count, :lists.merge([{a, i}], Enum.drop(top, -1))}

          true ->
            {i + 1, count, top}
        end
      end)

    Enum.map(top, &elem(&1, 1))
  end
end

# 500k points scattered over Europe (deterministic)
n = 500_000
rad = &(&1 * :math.pi() / 180)

# built once, as at application boot; kept out of this process's heap
index = fn ->
  for i <- 1..n do
    lat = rad.(36 + rem(i * 7919, 3400) / 100)
    lon = rad.(-10 + rem(i * 104_729, 4000) / 100)
    {lat, lon, :math.cos(lat)}
  end
end

:persistent_term.put(:geo_points, index.())

pack = fn f ->
  for p <- :persistent_term.get(:geo_points), into: <<>>, do: <<f.(p)::float-64-native>>
end

:persistent_term.put(:geo_packed, {pack.(&elem(&1, 0)), pack.(&elem(&1, 1)), pack.(&elem(&1, 2))})
{qlat, qlon} = {rad.(59.3293), rad.(18.0686)}

elixir_nearest = fn -> Geo.Elixir.nearest(:persistent_term.get(:geo_points), qlat, qlon, 10) end

defk_nearest = fn ->
  {lat, lon, coslat} = :persistent_term.get(:geo_packed)
  for <<i::64-signed-native <- Geo.Kernels.nearest(lat, lon, coslat, qlat, qlon, 10)>>, do: i
end

Defk.Bench.report(
  name: "geo_nearest",
  expected: :good,
  baseline: :first_pass,
  elixir: elixir_nearest,
  defk: defk_nearest,
  check: fn -> Enum.sort(elixir_nearest.()) == Enum.sort(defk_nearest.()) end,
  reason: "float math per candidate over a packed index reused by every query"
)
