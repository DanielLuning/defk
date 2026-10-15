<!-- examples/cosine_topk.exs line 154 of v0.1.0. A frozen file is never edited. -->

<!-- defk-example compiles: a catalog kernel module -->
```elixir
defmodule Cosine.Kernels do
  use Defk, elixir_mode: true

  # all-MiniLM-L6-v2 and friends: the dimension is fixed by the model, and a
  # literal lets the compiler prove m[r * 384 + j] in bounds
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
```
