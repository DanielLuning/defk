# The layout-noise band: how much a kernel's time moves when only the
# addresses of its code move. Each build gets the same generated C, with an
# unused function of `pad` bytes put before it (a CC wrapper passes
# `-include` of a header that holds it), so every function after it, the
# kernels too, sits `pad` bytes further on (`nm -n` on the built .so files
# shows it; the C differs only in the module name, which is data, not code;
# functions are 4-byte aligned on arm64). Each build has its own wrapper
# path, which is in the build cache key, so each pad compiles once.
# Interleaved rounds, the order of the builds rotated each round, best of
# `best` calls per build per round, so machine noise hits every build alike.
#
# The control: the first build is also measured under two more labels
# (0b, 0c), the same code at the same addresses, so its three medians differ
# by sampling noise only.
#
# Per kernel it prints the median of each label's round-bests, the layout
# range (slowest median over fastest, minus 1, over the builds) and the
# same-build range (the same over the first build's three labels), and for
# count_primes every round-best. A difference between two builds of one
# kernel that is inside the layout range can be layout alone.
# `mix run bench/layout_noise.exs [rounds] [pads]`, pads comma-separated
# bytes (default 0,4,8,16,24,32,40,48).

rounds = String.to_integer(Enum.at(System.argv(), 0) || "15")

pads =
  case Enum.at(System.argv(), 1) do
    nil -> [0, 4, 8, 16, 24, 32, 40, 48]
    s -> s |> String.split(",") |> Enum.map(&String.to_integer/1)
  end

best = 3

body =
  quote do
    use Defk

    defk sum(a :: [f64]) :: f64 do
      for x <- a, reduce: 0.0 do
        acc -> acc + x
      end
    end

    defk dot(a :: [f64], b :: [f64]) :: f64 do
      n = min(length(a), length(b))

      for i <- 0..(n - 1)//1, reduce: 0.0 do
        acc -> acc + a[i] * b[i]
      end
    end

    defk count_primes(n :: i64) :: i64 do
      for i <- 2..n//1, reduce: 0 do
        count -> if prime?(i), do: count + 1, else: count
      end
    end

    # all the work happens two calls deep; callees are inlined
    defk count_primes_via_call(n :: i64) :: i64 do
      count_primes(n)
    end

    defk prime?(x :: i64) :: bool do
      limit = trunc(:math.sqrt(x))

      for d <- 2..limit//1, reduce: true do
        p -> p and rem(x, d) != 0
      end
    end

    defk count_primes_early(n :: i64) :: i64 do
      for i <- 2..n//1, reduce: 0 do
        count -> if prime_early?(i), do: count + 1, else: count
      end
    end

    defk prime_early?(x :: i64) :: bool do
      Enum.all?(2..trunc(:math.sqrt(x))//1, fn d -> rem(x, d) != 0 end)
    end
  end

cc = System.get_env("CC", "cc")
dir = Path.join(System.tmp_dir!(), "defk-layout-noise")
File.mkdir_p!(dir)

builds =
  for pad <- pads do
    header = Path.join(dir, "pad#{pad}.h")
    wrapper = Path.join(dir, "cc-pad#{pad}")

    File.write!(header, """
    __attribute__((used, noinline)) static void defk_layout_pad(void) {
      __asm__ volatile(".space #{pad}");
    }
    """)

    File.write!(wrapper, "#!/bin/sh\nexec #{cc} -include #{header} \"$@\"\n")
    File.chmod!(wrapper, 0o755)
    System.put_env("CC", wrapper)
    mod = Module.concat(LayoutNoise, "Pad#{pad}")
    Module.create(mod, body, Macro.Env.location(__ENV__))
    {"#{pad}", mod}
  end

if cc == "cc", do: System.delete_env("CC"), else: System.put_env("CC", cc)

{base, base_mod} = hd(builds)
same = [base, "#{base}b", "#{base}c"]
labels = builds ++ [{"#{base}b", base_mod}, {"#{base}c", base_mod}]

:rand.seed(:exsss, {1, 2, 3})
pack = fn n -> for _ <- 1..n, into: <<>>, do: <<:rand.uniform() * 2 - 1::float-64-native>> end
a = pack.(1_000_000)
b = pack.(1_000_000)

cases = [
  sum: [a],
  dot: [a, b],
  count_primes: [300_000],
  count_primes_via_call: [300_000],
  count_primes_early: [1_000_000]
]

for {f, args} <- cases do
  [first | rest] = for {_, mod} <- builds, do: apply(mod, f, args)
  Enum.all?(rest, &(&1 === first)) || raise "#{f}: the builds disagree"
end

time = fn mod, f, args ->
  for(_ <- 1..best, do: elem(:timer.tc(fn -> apply(mod, f, args) end), 0)) |> Enum.min()
end

{waited, cpu0} = Defk.Bench.wait_quiet()

runs =
  for r <- 0..(rounds - 1), {f, args} <- cases do
    # rotate which label goes first
    {front, back} = Enum.split(labels, rem(r, length(labels)))
    for {label, mod} <- back ++ front, do: {f, label, time.(mod, f, args)}
  end
  |> List.flatten()

cpu1 = Defk.Bench.other_cpu()
quiet = if Defk.Bench.quiet?({cpu0, cpu1}), do: "quiet", else: "LOADED: provisional"

med = fn l -> Enum.at(Enum.sort(l), div(length(l), 2)) end
pct = fn x -> :erlang.float_to_binary(100 * x, decimals: 1) <> "%" end

IO.puts(
  "#{length(builds)} builds (pads #{Enum.join(pads, ",")} bytes) and #{base}b, #{base}c " <>
    "(the #{base} build again), #{rounds} rounds, best of #{best} per label per round (us); " <>
    "other CPU #{inspect(cpu0)} -> #{inspect(cpu1)} cores after #{waited} s settling: #{quiet}"
)

times = fn f, label -> for {^f, ^label, t} <- runs, do: t end
range = fn meds -> pct.(Enum.max(meds) / Enum.min(meds) - 1) end

for {f, _} <- cases do
  meds = Map.new(labels, fn {label, _} -> {label, med.(times.(f, label))} end)
  layout = for {label, _} <- builds, do: meds[label]

  IO.puts(
    String.pad_trailing("#{f}", 22) <>
      " medians " <>
      Enum.map_join(labels, " ", fn {label, _} -> "#{label}:#{meds[label]}" end) <>
      "  layout range #{range.(layout)} over #{length(layout)}  same-build range " <>
      "#{range.(Enum.map(same, &meds[&1]))} over 3"
  )
end

IO.puts("count_primes round-bests, in round order:")

for {label, _} <- labels,
    do:
      IO.puts(
        "  #{String.pad_trailing(label, 3)} " <> Enum.join(times.(:count_primes, label), " ")
      )
