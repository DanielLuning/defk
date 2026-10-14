defmodule FuzzySearch.Kernels.Template do
  @moduledoc false
  # One kernel body, stamped out twice by FuzzySearch.Kernels (a module cannot
  # call a macro it defines itself).

  @doc "Defines the search kernel `name` with defk `opts`."
  defmacro defsearch(name, opts) do
    quote do
      defk unquote(name)(q :: [u8], blob :: [u8], offs :: [i64], k :: i64) :: [i64], unquote(opts) do
        m = length(q)
        row = alloc(i64, m + 1)
        best_d = alloc(i64, k)
        best_i = alloc(i64, k)

        for s <- 0..(k - 1)//1 do
          best_d[s] = 1_000_000_000
          best_i[s] = 1_000_000_000_000
        end

        # `worst` is the slot holding the largest (distance, index) key
        _worst =
          for c <- 0..(length(offs) - 2)//1, reduce: 0 do
            worst ->
              start = offs[c]
              n = offs[c + 1] - start

              # cut-off: once the top k is full, `bound` is the k-th best
              # distance; a word stops when its row minimum reaches it
              bound = best_d[worst]

              for j <- 0..m//1 do
                row[j] = j
              end

              # two-row DP collapsed into one row; `diag` carries row[i-1][j-1]
              cut =
                Enum.reduce_while(1..n//1, false, fn i, _ ->
                  ch = blob[start + i - 1]
                  diag0 = row[0]
                  row[0] = i

                  {_, row_min} =
                    for j <- 1..m//1, reduce: {diag0, i} do
                      {diag, mn} ->
                        up = row[j]
                        cost = if q[j - 1] == ch, do: 0, else: 1
                        v = min(min(up + 1, row[j - 1] + 1), diag + cost)
                        row[j] = v
                        {up, min(mn, v)}
                    end

                  if row_min >= bound, do: {:halt, true}, else: {:cont, false}
                end)

              d = row[m]

              if not cut and (d < best_d[worst] or (d == best_d[worst] and c < best_i[worst])) do
                best_d[worst] = d
                best_i[worst] = c

                for s <- 1..(k - 1)//1, reduce: 0 do
                  w ->
                    if best_d[s] > best_d[w] or (best_d[s] == best_d[w] and best_i[s] > best_i[w]),
                      do: s,
                      else: w
                end
              else
                worst
              end
          end

        out = alloc(i64, 2 * k)

        for s <- 0..(k - 1)//1 do
          out[2 * s] = best_i[s]
          out[2 * s + 1] = best_d[s]
        end

        out
      end
    end
  end

end

defmodule FuzzySearch.Kernels do
  @moduledoc """
  The same Levenshtein top-k search as `FuzzySearch.ElixirBackend`, as a defk kernel.

  `search/4` yields to the scheduler like Elixir code. `search_blocking/4` is
  the identical kernel compiled with `yield: false`: it behaves like a typical
  hand-written NIF and holds its scheduler until it finishes.

  Returns a packed `[i64]` of `k` `(index, distance)` pairs in slot order;
  empty slots have distance `@empty`.
  """
  use Defk
  require FuzzySearch.Kernels.Template
  import FuzzySearch.Kernels.Template, only: [defsearch: 2]

  defsearch(:search, [])
  defsearch(:search_blocking, yield: false)

  @doc false
  def empty_distance, do: 1_000_000_000
end
