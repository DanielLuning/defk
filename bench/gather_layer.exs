# A gather loop: which runtime checks stay in its hot loop, and what each
# costs. A sparse layer over an [f32] weight array, with the input index of
# each term in an [i32] array: output r is the sum over t < k of
# w[r * k + t] * x[base + idx[r * k + t]]. The fast-path report lists every
# check the compiler kept in the loop and the fact that would drop it;
# the timing gives the cost per output row. docs/performance.md 6.45.
#
#   mix run bench/gather_layer.exs [rounds]
#
# Each number is the best over the rounds of the us per output row over
# one call (n rows of k terms); other processes' CPU is printed before
# each block (Defk.Bench.other_cpu/0): at most one core counts as quiet.
rounds = String.to_integer(List.first(System.argv()) || "9")

defmodule Gather.Kernels do
  use Defk, report: :full

  # the shape from the arrays: n rows of k terms in w, one index per term
  defk layer(w :: [f32], idx :: [i32], x :: [f32], k :: i64, base :: i64) :: [f32] do
    n = div(length(w), k)
    out = alloc(f32, n)

    for r <- 0..(n - 1)//1 do
      out[r] =
        for t <- 0..(k - 1)//1, reduce: 0.0 do
          acc -> acc + w[r * k + t] * x[base + idx[r * k + t]]
        end
    end

    out
  end

  # the same with the shape and the base stated by raising guards
  defk layer_guarded(w :: [f32], idx :: [i32], x :: [f32], k :: i64, base :: i64) :: [f32] do
    if not (k > 0 and length(idx) == length(w) and base >= 0 and base <= length(x)),
      do: raise(ArgumentError, "shape")

    n = div(length(w), k)
    out = alloc(f32, n)

    for r <- 0..(n - 1)//1 do
      out[r] =
        for t <- 0..(k - 1)//1, reduce: 0.0 do
          acc -> acc + w[r * k + t] * x[base + idx[r * k + t]]
        end
    end

    out
  end

  # the NFA study's one fact: a product of two band(_, 1) values is 0 or 1
  defk bit_product(a :: [i64], b :: [i64]) :: i64 do
    n = min(length(a), length(b))

    for i <- 0..(n - 1)//1, reduce: 0 do
      acc ->
        hit = band(a[i], 1)
        ext = band(b[i], 1)
        acc + hit * (1 - ext)
    end
  end
end

defmodule Gather.Elixir do
  # the same sum in Elixir, as the agreement reference
  def layer(w, idx, x, k, base) do
    n = div(byte_size(w), 4 * k)

    for r <- 0..(n - 1), into: <<>> do
      acc =
        Enum.reduce(0..(k - 1), 0.0, fn t, acc ->
          j = r * k + t
          <<wv::float-32-native>> = binary_part(w, 4 * j, 4)
          <<iv::signed-32-native>> = binary_part(idx, 4 * j, 4)
          <<xv::float-32-native>> = binary_part(x, 4 * (base + iv), 4)
          acc + wv * xv
        end)

      <<acc::float-32-native>>
    end
  end
end

:rand.seed(:exsss, {4, 5, 6})
n = 4096
k = 16
m = 1024
base = 512
w = for _ <- 1..(n * k), into: <<>>, do: <<:rand.uniform() * 2 - 1::float-32-native>>
idx = for _ <- 1..(n * k), into: <<>>, do: <<:rand.uniform(m) - 1::signed-32-native>>
x = for _ <- 1..(m + base), into: <<>>, do: <<:rand.uniform() * 2 - 1::float-32-native>>

ref = Gather.Elixir.layer(w, idx, x, k, base)
^ref = Gather.Kernels.layer(w, idx, x, k, base)
^ref = Gather.Kernels.layer_guarded(w, idx, x, k, base)

Defk.Report.print(Gather.Kernels)

best = fn f ->
  Enum.min(for _ <- 1..rounds, do: elem(:timer.tc(f), 0)) / n
end

IO.puts(
  "\n#{n} rows x #{k} terms, best of #{rounds}  (other CPU: #{Float.round(Defk.Bench.other_cpu() * 1.0, 2)} cores)"
)

for {name, f} <- [
      {"layer", fn -> Gather.Kernels.layer(w, idx, x, k, base) end},
      {"layer_guarded", fn -> Gather.Kernels.layer_guarded(w, idx, x, k, base) end}
    ] do
  IO.puts(
    "  #{String.pad_trailing(name, 16)} #{:erlang.float_to_binary(best.(f), decimals: 3)} us per row"
  )
end
