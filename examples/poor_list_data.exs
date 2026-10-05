# poor_list_data: average order value of 1M orders fetched from the database
#
# The trap: the numbers are fast to crunch, but they arrive as an Elixir list
# (Ecto rows, decoded JSON). A kernel needs a packed binary, and packing the
# list costs more than Elixir's whole sum.
# Expected verdict: poor
#
#   elixir examples/poor_list_data.exs
#
# Use defk when data is already packed or is packed once and reused (see
# rolling_stats, geo_nearest). For one pass over a list, stay in Elixir.

Mix.install([{:defk, path: Path.expand("..", __DIR__)}])

defmodule Orders.Kernels do
  use Defk

  defk sum(a :: [f64]) :: f64 do
    for x <- a, reduce: 0.0 do
      acc -> acc + x
    end
  end
end

totals = for i <- 1..1_000_000, do: 5.0 + rem(i * 7919, 50_000) / 100

elixir_avg = fn -> Enum.sum(totals) / length(totals) end

defk_avg = fn ->
  packed = for x <- totals, into: <<>>, do: <<x::float-64-native>>
  Orders.Kernels.sum(packed) / length(totals)
end

Defk.Bench.report(
  name: "poor_list_data",
  expected: :poor,
  elixir: elixir_avg,
  defk: defk_avg,
  check: fn -> abs(elixir_avg.() - defk_avg.()) < 1.0e-6 end,
  reason: "packing a list into a binary costs more than summing it in Elixir"
)
