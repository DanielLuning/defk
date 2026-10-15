<!-- examples/geo_nearest.exs line 54 of v0.1.0. A frozen file is never edited. -->

<!-- defk-example compiles: a catalog kernel module -->
```elixir
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
      for i <- 0..(length(lat) - 1)//1, reduce: 0 do
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
  # returns positions in rank order (callers guarantee length(lat) >= k)
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
      for i <- 0..(length(lat) - 1)//1, reduce: 0 do
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
```
