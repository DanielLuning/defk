# Times the catalogue kernels built at each target level of this machine's
# architecture (Simd.Levels.timed/0: arm64 or x86-64), interleaved,
# and checks that every level agrees with the default build (large inputs)
# and with Elixir mode (small inputs, every kernel).
#
#   mix run bench/simd/time.exs [rounds] [out.etf]
#
# Each round runs every case at every level in a rotated order, best of
# `reps` calls per level (reps calibrated to ~50 ms per level); the speedup of
# a level is default / level per round, reported as the median over rounds.
# Relative numbers like these hold up under load better than absolute times.
# Research tooling for defk-ulk.1 (docs/research/simd.md), not part of defk.
Code.require_file("load.exs", __DIR__)
Code.require_file("levels.exs", __DIR__)
Code.require_file("cases.exs", __DIR__)

[rounds, out] =
  case System.argv() do
    [r, o] -> [String.to_integer(r), o]
    [r] -> [String.to_integer(r), Path.join(System.tmp_dir!(), "defk-simd-time.etf")]
    [] -> [7, Path.join(System.tmp_dir!(), "defk-simd-time.etf")]
  end

load = fn -> :os.cmd(~c"uptime") |> to_string() |> String.trim() end
IO.puts("start: #{load.()}")

IO.puts(
  "arch: #{:erlang.system_info(:system_architecture)}, cc: #{System.get_env("SIMD_CC", "cc")}"
)

kernels = Map.new(Simd.Load.all(), &{&1.mod, &1})
levels = Simd.Levels.timed()
big = Simd.Cases.all(:big)
mods = big |> Enum.map(&elem(&1, 1)) |> Enum.uniq()

# variant modules: %{{level, mod} => variant module}
variants =
  for {{level, flags}, i} <- Enum.with_index(levels), mod <- mods, into: %{} do
    name = Module.concat(["SimdL#{i}", inspect(mod)])
    Simd.Load.variant(kernels[mod], name, Simd.Levels.wrapper(level, flags))
    {{level, mod}, name}
  end

IO.puts("built #{map_size(variants)} variant modules: #{load.()}")

# agreement: small inputs against Elixir mode, at every level
for {label, mod, f, args} <- Simd.Cases.all(:small), {level, _} <- levels do
  v = variants[{level, mod}]
  native = apply(v, f, args)
  ex = v.__defk_elixir__(f, args)
  native === ex || raise "#{label} at #{level}: native != Elixir mode"
end

IO.puts("Elixir mode agrees at every level (small inputs)")

# agreement: large inputs, every level against the default build
for {label, mod, f, args} <- big do
  ref = apply(variants[{"default", mod}], f, args)

  for {level, _} <- levels,
      do: apply(variants[{level, mod}], f, args) === ref || raise("#{label}: #{level} != default")
end

IO.puts("every level equals the default build (large inputs)")

time = fn v, f, args, reps ->
  for(_ <- 1..reps, do: elem(:timer.tc(fn -> apply(v, f, args) end), 0)) |> Enum.min()
end

reps =
  Map.new(big, fn {label, mod, f, args} ->
    t = max(time.(variants[{"default", mod}], f, args, 2), 1)
    {label, min(max(div(50_000, t), 3), 25)}
  end)

names = Enum.map(levels, &elem(&1, 0))

runs =
  for r <- 1..rounds, {label, mod, f, args} <- big do
    order = Enum.take(Stream.drop(Stream.cycle(names), r), length(names))

    ts =
      Map.new(order, fn level ->
        :erlang.garbage_collect()
        {level, time.(variants[{level, mod}], f, args, reps[label])}
      end)

    {label, r, ts}
  end

IO.puts("end: #{load.()}")

med = fn l -> l |> Enum.sort() |> Enum.at(div(length(l), 2)) end

results =
  for {label, _, _, _} <- big do
    rs = for {^label, _, ts} <- runs, do: ts
    best = Map.new(names, fn l -> {l, Enum.min(Enum.map(rs, & &1[l]))} end)

    speed =
      Map.new(names, fn l ->
        ratios = Enum.map(rs, &(&1["default"] / max(&1[l], 1)))
        {l, {med.(ratios), Enum.min(ratios), Enum.max(ratios)}}
      end)

    {label, best, speed}
  end

File.write!(out, :erlang.term_to_binary(%{rounds: rounds, results: results, levels: names}))

IO.puts(
  "\n#{rounds} rounds; best us per level; speedup = default / level, median (min..max) over rounds"
)

IO.puts(Enum.join(["case" | names] ++ Enum.map(tl(names), &"x #{&1}"), "\t"))

for {label, best, speed} <- results do
  cells = Enum.map(names, &to_string(best[&1]))

  sp =
    for l <- tl(names) do
      {m, lo, hi} = speed[l]
      "#{Float.round(m, 3)} (#{Float.round(lo, 2)}..#{Float.round(hi, 2)})"
    end

  IO.puts(Enum.join([label | cells] ++ sp, "\t"))
end
