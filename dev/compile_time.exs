# Compiler time: compare rounds of DEFK_COMPILE_TIME logs from two
# checkouts. One round is one dump of every kernel, its log one line per
# module, "<Module> <microseconds> <reductions>" of a compile measured in a
# fresh process (Defk.__before_compile__):
#
#   DEFK_COMPILE_TIME=tmp/base1.log DEFK_DUMP_C=tmp/c_base mix dump_c   # in the base checkout
#   DEFK_COMPILE_TIME=tmp/new1.log  DEFK_DUMP_C=tmp/c_new  mix dump_c   # in the new one
#   ... base2, new2, ..., interleaved so drift hits both sides ...
#   elixir dev/compile_time.exs tmp/base*.log -- tmp/new*.log
#   elixir dev/compile_time.exs --reductions tmp/base*.log -- tmp/new*.log
#
# Microseconds drift with the machine (a laptop's clock on battery moved a
# whole round by about 25% between runs); reductions, the work the BEAM
# counts, repeat to about 0.1% and are the figure to compare when the
# change is the compiler's own work. Only the modules every log has are
# compared, so kernels added between the two checkouts do not count as a
# cost, but a kernel edited between them does: check that the examples and
# test modules are unchanged. A module name compiled twice in one round
# (two files) is summed. Each side's figure is the median of its rounds,
# with and without SatEx.Kernels (examples/cdcl_sat.exs, thousands of kept
# checks: it dominates any prover cost). With no `--`, the logs are one
# side and only its medians are printed.

{column, args} =
  case System.argv() do
    ["--reductions" | rest] -> {2, rest}
    rest -> {1, rest}
  end

{base_paths, new_paths} =
  case Enum.split_while(args, &(&1 != "--")) do
    {base, ["--" | new]} -> {base, new}
    {base, []} -> {base, []}
  end

if base_paths == [] do
  IO.puts(
    :stderr,
    "usage: elixir dev/compile_time.exs [--reductions] <base logs> [-- <new logs>]"
  )

  System.halt(2)
end

read = fn path ->
  for line <- File.read!(path) |> String.split("\n", trim: true),
      [mod | figures] = String.split(line),
      n = String.to_integer(Enum.at(figures, column - 1)),
      reduce: %{},
      do: (acc -> Map.update(acc, mod, n, &(&1 + n)))
end

{base, new} = {Enum.map(base_paths, read), Enum.map(new_paths, read)}

common =
  (base ++ new)
  |> Enum.map(&MapSet.new(Map.keys(&1)))
  |> Enum.reduce(&MapSet.intersection/2)

median = fn xs ->
  sorted = Enum.sort(xs)
  n = length(sorted)
  mid = div(n, 2)

  if rem(n, 2) == 1,
    do: Enum.at(sorted, mid),
    else: div(Enum.at(sorted, mid - 1) + Enum.at(sorted, mid), 2)
end

total = fn round, mods -> mods |> Enum.map(&Map.fetch!(round, &1)) |> Enum.sum() end
without_sat = MapSet.delete(common, "SatEx.Kernels")

side = fn rs ->
  {median.(Enum.map(rs, &total.(&1, common))), median.(Enum.map(rs, &total.(&1, without_sat)))}
end

show =
  if column == 1,
    do: fn us -> :erlang.float_to_binary(us / 1000, decimals: 1) <> " ms" end,
    else: fn r -> :erlang.float_to_binary(r / 1.0e6, decimals: 2) <> "M reductions" end

pct = fn a, b -> :erlang.float_to_binary(100 * (b - a) / a, decimals: 1) <> "%" end

IO.puts(
  "#{MapSet.size(common)} modules in every log; rounds: #{length(base)} base, #{length(new)} new"
)

{b_all, b_wo} = side.(base)
IO.puts("base: #{show.(b_all)} (without SatEx.Kernels #{show.(b_wo)})")

if new != [] do
  {n_all, n_wo} = side.(new)
  IO.puts("new:  #{show.(n_all)} (without SatEx.Kernels #{show.(n_wo)})")
  IO.puts("change: #{pct.(b_all, n_all)} (without SatEx.Kernels #{pct.(b_wo, n_wo)})")

  deltas =
    for m <- common do
      {m, median.(Enum.map(new, & &1[m])) - median.(Enum.map(base, & &1[m]))}
    end

  IO.puts("largest changes by module (median):")

  deltas
  |> Enum.sort_by(&(-abs(elem(&1, 1))))
  |> Enum.take(5)
  |> Enum.each(fn {m, d} -> IO.puts("  #{m} #{if d >= 0, do: "+", else: ""}#{show.(d)}") end)
end
