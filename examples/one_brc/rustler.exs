# one_brc/rustler.exs: the 1BRC per-chunk aggregate as a Rustler NIF, the
# comparison beside the pure-Elixir baseline (elixir.exs) and, later, defk
#
# The NIF a careful Elixir developer would write today: rustler/native/one_brc_nif
# parses one newline-aligned chunk (same integer-x10 temperature parse) into a
# std `HashMap<&[u8], Stats>` (keys are slices of the input; ahash is not in the
# offline cargo cache, so std's SipHash) and returns a list of
# `{name, min, max, sum, count}` tuples (one binary per distinct station, not a
# packed binary). It is exposed twice: `OneBrc.Nif.aggregate/1`, a plain NIF
# (runs on a normal scheduler for the whole call), and
# `OneBrc.Nif.aggregate_dirty/1`, `#[rustler::nif(schedule = "DirtyCpu")]`.
# The dynamic-station form only (like par_map: names discovered while
# parsing); no known-station-list form was written, so there is no NIF
# counterpart of par_atomics' static map.
#
# This driver reuses elixir.exs: the chunking (pread with one byte of look-
# behind, skip to the first \n, 256 bytes of overread, <= 32 MB and >= 4
# chunks per scheduler, Task.async_stream with per-task results merged with
# Map.merge) is copied unchanged from OneBrc.Elixir.chunk_stats/solve, and
# the baseline module is compiled from elixir.exs itself (without its main
# call) for `format/1`, the reference, and the par_map baseline in the tick
# gap run, so the output string is produced by the same code.
#
#   elixir examples/one_brc/gen.exs 10M --seed 1          # make the file first
#   cd examples/one_brc/rustler && mix deps.get
#   mix run ../rustler.exs [nif nif_dirty] [--print] [--reps N] [--file PATH]
#   mix run ../rustler.exs --check          # vs elixir.exs's reference, 2 seeds
#   mix run ../rustler.exs --tick           # 1 ms ticker, one scheduler
#
# Toolchain: Rust (rustc/cargo 1.94.1, aarch64-apple-darwin) plus the `rustler`
# crate 0.37.4 and Hex package 0.38.0, compiled with --release (opt-level 3,
# LTO) by `mix compile` (the crates are downloaded from crates.io on first
# build; no network is needed afterwards). defk needs only cc.
#
# Measured (M-series Mac, 12 schedulers, OTP 29, Elixir 1.20.2, file in the
# page cache, best of 3, wall time from the file on disk to the formatted
# string; seed 1, 10M rows = 138 MB, 100M rows = 1379 MB). The machine was
# NOT quiet (load average ~21 from other jobs), so absolute numbers are noisy:
#
#   variant                            10M rows   100M rows (dev size)
#   NIF plain (normal scheduler)         67 ms       760 ms
#   NIF DirtyCpu                         34 ms       318 ms
#   Elixir par_map (same chunking)      342 ms      3535 ms   (elixir.exs, this run)
#
# (elixir.exs's own table has par_map 3620 ms and par_atomics 1663 ms at
# 100M.) The DirtyCpu NIF is 11x faster than par_map and 5x faster than the
# fastest Elixir variant; the plain NIF is 2.4x slower than DirtyCpu here
# because its 12 concurrent calls run on the 12 normal schedulers that also
# do the pread/merge work and share cores with the load, while dirty
# schedulers are extra OS threads.
#
# Tick gap (bench/tick_gap.exs method, Defk.Bench.TickGap: a 1 ms ticker, ONE
# scheduler online, the whole 100M-row solve run once; `mix run ../rustler.exs
# --tick`):
#
#   case                  runtime       p99 gap    max gap
#   elixir par_map        29597 ms       2.17 ms   13.33 ms
#   NIF plain              2265 ms      55.35 ms   55.35 ms   (one ~28 MB chunk per call, not preemptible)
#   NIF DirtyCpu           2279 ms       2.17 ms    5.61 ms
#
# With one scheduler online the plain NIF still finishes in 2.3 s (it ran
# one chunk at a time, unloaded by the busy machine at that moment) but
# starves the ticker for 55 ms per chunk; DirtyCpu keeps the ticker within
# 5.6 ms, below the pure-Elixir loop's 13 ms max.
#
# Correctness (`--check`): both NIF variants equal elixir.exs's Enum
# reference on 100k rows for seeds 1 and 2, at 50 kB chunks and at the
# automatic chunk size. Prints "correct".
#
defmodule OneBrc.Rustler do
  @overread 256

  # compile the baseline (everything in elixir.exs but its trailing main call)
  src =
    Path.join(__DIR__, "elixir.exs")
    |> File.read!()
    |> String.replace(~r/^OneBrc\.Elixir\.main\(System\.argv\(\)\)\s*\z/m, "")

  Code.compile_string(src, "elixir.exs")

  def variants, do: [:nif, :nif_dirty]

  @doc "File on disk -> the formatted result string; the chunking of OneBrc.Elixir.solve(:par_*)."
  def solve(variant, file, opts \\ []) do
    size = File.stat!(file).size
    schedulers = System.schedulers_online()
    chunk = opts[:chunk_bytes] || (opts[:chunk_mb] && opts[:chunk_mb] * 1_048_576) || chunk_for(size, schedulers)

    chunks(size, chunk)
    |> Task.async_stream(fn {off, len} -> chunk_stats(variant, file, off, len) end,
      max_concurrency: schedulers,
      ordered: false,
      timeout: :infinity
    )
    |> Enum.reduce(%{}, fn {:ok, part}, acc -> merge(acc, part) end)
    |> OneBrc.Elixir.format()
  end

  # ---- copied from elixir.exs (keep identical) -------------------------------
  defp chunk_for(size, schedulers), do: size |> div(schedulers * 4) |> min(32 * 1_048_576) |> max(1_048_576)

  defp chunks(size, chunk), do: for(off <- 0..(size - 1)//chunk, do: {off, min(chunk, size - off)})

  defp merge(a, b) do
    Map.merge(a, b, fn _name, {mn1, mx1, s1, c1}, {mn2, mx2, s2, c2} ->
      {min(mn1, mn2), max(mx1, mx2), s1 + s2, c1 + c2}
    end)
  end

  defp chunk_stats(kind, file, off, len) do
    {:ok, fd} = :file.open(file, [:raw, :binary, :read])
    start = max(off - 1, 0)
    {:ok, data} = :file.pread(fd, start, off + len - start + @overread)
    :ok = :file.close(fd)

    lim = min(off + len - start, byte_size(data))

    skip =
      if off == 0 do
        0
      else
        {i, 1} = :binary.match(data, "\n")
        i + 1
      end

    last =
      case :binary.match(data, "\n", scope: {lim - 1, byte_size(data) - lim + 1}) do
        {i, 1} -> i
        :nomatch -> byte_size(data) - 1
      end

    if last < skip do
      %{}
    else
      body = binary_part(data, skip, last + 1 - skip)
      process(kind, body)
    end
  end

  # ---- the only part that differs: the chunk goes to the NIF ------------------
  defp process(:nif, body), do: body |> OneBrc.Nif.aggregate() |> to_map()
  defp process(:nif_dirty, body), do: body |> OneBrc.Nif.aggregate_dirty() |> to_map()

  defp to_map(list), do: Map.new(list, fn {name, mn, mx, s, c} -> {name, {mn, mx, s, c}} end)

  # ---- measuring --------------------------------------------------------------

  def main(argv) do
    {opts, names, _} =
      OptionParser.parse(argv,
        strict: [print: :boolean, check: :boolean, tick: :boolean, reps: :integer, chunk_mb: :integer, file: :string]
      )

    cond do
      opts[:check] -> check()
      opts[:tick] -> tick(opts)
      true -> bench(names, opts)
    end
  end

  defp file(opts) do
    file = opts[:file] || System.get_env("ONE_BRC_FILE") || "/tmp/one_brc/measurements.txt"
    File.exists?(file) || raise "no #{file}: run `elixir examples/one_brc/gen.exs 10M` first"
    file
  end

  defp bench(names, opts) do
    file = file(opts)
    reps = opts[:reps] || 3
    size = File.stat!(file).size
    vs = if names == [], do: variants(), else: Enum.map(names, &String.to_atom/1)

    IO.puts(
      "file #{file} (#{div(size, 1_000_000)} MB), #{System.schedulers_online()} schedulers, " <>
        "best of #{reps}, wall time from file on disk (page cache) to the formatted string"
    )

    outs =
      for v <- vs do
        runs =
          for _ <- 1..reps do
            for p <- Process.list(), do: :erlang.garbage_collect(p)
            :timer.tc(fn -> solve(v, file, opts) end)
          end

        {us, out} = Enum.min_by(runs, &elem(&1, 0))

        IO.puts(
          String.pad_trailing("#{v}", 12) <>
            String.pad_leading("#{trunc(Float.round(us / 1000, 0))} ms", 10) <>
            String.pad_leading("#{Float.round(size / us, 2)} MB/s", 14)
        )

        out
      end

    [first | rest] = outs
    Enum.all?(rest, &(&1 == first)) || raise "variants disagree on this file"
    if opts[:print], do: IO.puts(first)
  end

  # 1 ms ticker on one scheduler while the whole solve runs once (the method of
  # bench/tick_gap.exs, Defk.Bench.TickGap), for the baseline and both NIFs
  defp tick(opts) do
    file = file(opts)
    f = fn us -> :erlang.float_to_binary(us / 1000, decimals: 2) end
    IO.puts("tick gap, 1 ms ticker, one scheduler, #{file}")
    IO.puts(String.pad_trailing("case", 22) <> String.pad_trailing("runtime ms", 14) <> String.pad_trailing("p99 gap ms", 12) <> "max gap ms")

    cases = [
      {"elixir par_map", fn -> OneBrc.Elixir.solve(:par_map, file, []) end},
      {"nif (plain)", fn -> solve(:nif, file, opts) end},
      {"nif_dirty (DirtyCpu)", fn -> solve(:nif_dirty, file, opts) end}
    ]

    Defk.Bench.TickGap.with_one_scheduler(fn ->
      for {name, fun} <- cases do
        {us, gaps} = Defk.Bench.TickGap.measure(fun)

        IO.puts(
          String.pad_trailing(name, 22) <>
            String.pad_trailing(f.(us), 14) <>
            String.pad_trailing(f.(Defk.Bench.TickGap.percentile(gaps, 0.99)), 12) <>
            f.(Enum.max(gaps))
        )
      end
    end)
  end

  defp check do
    gen = Path.join(__DIR__, "gen.exs")

    for seed <- [1, 2] do
      path = "/tmp/one_brc/check_#{seed}.txt"
      {_, 0} = System.cmd("elixir", [gen, "100000", "--seed", "#{seed}", "--out", path])
      ref = OneBrc.Elixir.reference(path)

      for v <- variants(), opts <- [[chunk_bytes: 50_021], []] do
        solve(v, path, opts) == ref || raise "#{v} #{inspect(opts)} differs from the reference for seed #{seed}"
      end

      IO.puts("seed #{seed}: #{length(variants())} NIF variants x 2 chunkings match the reference (#{String.length(ref)} chars)")
    end

    IO.puts("correct")
  end
end

OneBrc.Rustler.main(System.argv())
