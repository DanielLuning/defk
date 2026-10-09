# one_brc/elixir.exs: 1BRC in pure Elixir, the baseline every kernel is measured against
#
# Why people reach for a NIF here: parsing and aggregating a huge text file
# (the One Billion Row Challenge, https://github.com/gunnarmorling/1brc:
# `<station>;<temp>\n` lines, min/mean/max per station) is the job that sends
# Elixir developers to Rustler. The kernel side (defk-n4r.6) is not written
# yet, so this script only prints its own timings and does not call
# Defk.Bench.report.
#
#   elixir examples/one_brc/gen.exs 10M --seed 1          # make the file first
#   elixir examples/one_brc/elixir.exs [variant ...] [--print] [--reps N] [--chunk-mb N] [--file PATH]
#   elixir examples/one_brc/elixir.exs --check             # reference comparison, two seeds
#
# The file is $ONE_BRC_FILE, default /tmp/one_brc/measurements.txt (never in the
# repo). With no variant the five parallel variants run (par_map is the one to
# beat); `all` also runs the sequential ones. `--print` writes the result
# string to stdout, in the upstream format `{Abha=-23.0/18.0/59.2, ...}`:
# sorted by name (bytes), each of min/mean/max with one decimal, the mean
# rounded with IEEE 754 roundTowardPositive (upstream README: ceiling), so
# -0.25 prints -0.2 and 0.21 prints 0.3. Done on integers: the mean in tenths is
# ceil(sum / count).
#
# Variants. <mode>_<kind>: mode seq = one process, par = Task.async_stream
# over chunks on every scheduler with per-task accumulators merged at the end
# (the Erlang/Elixir 1BRC threads' winner too: blubparadox, garazdawi,
# stevensonmt and the "12 minutes to 25 seconds" talk all end up at
# chunks + workers). Every variant reads with :file.pread (each task opens its
# own raw handle), chunks aligned to a line start by reading one byte early and
# skipping to the first \n, and reading a few bytes past the chunk end to
# finish its last line. A chunk is at most 32 MB (the number of chunks is at
# least 4 per scheduler, so small files still use every core).
#
#   map      (a) byte-by-byte name scan and temperature by binary pattern
#                matching (the whole `-dd.d\n` shape in one clause), integer
#                x10, map accumulator keyed by the station binary
#   ets      (b) the same with an :ets :set per process (lookup + insert)
#   split    (d) :binary.split per line (chunk -> lines -> [name, temp]),
#                integer x10 parse; the form per-row term creation hurts most
#   float    (e) map variant with the temperature as a sub-binary and
#                :erlang.binary_to_float, float sums (rounded back to tenths)
#   atomics      map kept static (name -> slot) with the four statistics in an
#                :atomics array: after the first pass over each name a row is
#                one lookup and four BIF calls, no tuple or map rebuilt per row
#
# Measured (M-series Mac, 12 schedulers, OTP 29, Elixir 1.20.2, file in the
# page cache, best of 3 parallel / best of 1 sequential at 100M; 10M rows =
# 138 MB, 100M rows = 1379 MB; wall time from the file on disk to the
# formatted string):
#
#   variant                                      10M rows   100M rows (dev size)
#   par_atomics  static map + :atomics stats       145 ms     1663 ms  <- fastest
#   par_ets      per-task :ets                     206 ms     2293 ms
#   par_map      per-task map accumulator (c)      309 ms     3620 ms
#   par_split    :binary.split per line (d)        367 ms     4683 ms  (5.0 GB peak memory)
#   par_float    binary_to_float temperature (e)  1631 ms    16086 ms
#   seq_atomics                                   1380 ms    20374 ms
#   seq_ets      (b)                              2121 ms    22427 ms
#   seq_split                                     2661 ms    27060 ms
#   seq_map      (a)                              2893 ms    34370 ms
#   seq_float                                     3644 ms    46407 ms
#
# What the numbers say, and what the research note (docs/research/string-workloads.md
# on branch research/string-workloads) predicted: the cost is per-row term
# creation, not scanning. (1) The float temperature (e) is 5x slower than the
# integer x10 parse: a sub-binary plus a boxed float per row. (2) :binary.split
# per line (d) is slightly faster than the byte-matching map variant on one
# process (27 s vs 34 s at 100M: the map variant pays name_len/2 per byte and
# a map rebuild per row), but it holds each chunk as ~1M line sub-binaries,
# so in parallel it is slower (4.7 s vs 3.6 s) and peaks at 5 GB. Swapping the
# byte-by-byte name scan for one :binary.match per row in the atomics variant
# was slower too (2391 ms vs 1663 ms at 100M; names are short). (3) Rebuilding
# the {min, max, sum, count} tuple and the map on every row (a, c) is what an
# in-place accumulator avoids: ETS is 1.4x faster than the map and the static-
# map + :atomics layout 1.4x faster again, so the fastest variant is (c) with
# atomics, not (c) with a map. (4) The
# parallel win is 12-13x on 12 schedulers (par_atomics vs seq_atomics).
# Chunk size at 100M, par_atomics (best of 3): 4 MB 2116 ms, 8 MB 1884, 16 MB
# 2120, 32 MB 1818, 64 MB 1807; the default (at most 32 MB, at least 4 chunks
# per scheduler) is 28 MB there. The per-row cost left is the sub-binary for
# the map key (one per row) and the key hash.
#
# End to end on the development size (100M rows), par_atomics, 12 schedulers:
# 1.66 s wall from the file on disk (page cache; a cold read is bounded by the
# disk) to the formatted string, peak memory 449 MB (588 MB over three runs;
# :erlang.memory(:total) sampled every 5 ms, 91 MB at idle).
#
# Baseline: optimised for this shape: the five variants (a)-(e) are measured
# at both sizes, tried in sequential and parallel form, and the winner uses
# the same tricks a kernel would (no per-row term but the key). Not tried:
# keying by a hash of the name bytes instead of the sub-binary, reading with
# mmap (ticket defk-n4r.7), :prim_file or read-ahead tuning, a line-length-
# specialised matcher (stevensonmt's), Explorer/Polars (native, so not
# pure Elixir).
#
# Correctness (`--check`): all ten variants equal a reference built from a
# trivially simple Enum pipeline (File.read, String.split, Enum.group_by,
# Float.ceil for the mean) on 100k rows for seeds 1 and 2, at 50 kB chunks
# (every line cut at a boundary) and at the automatic chunk size. Prints
# "correct".
#
defmodule OneBrc.Elixir do
  @overread 256
  @cap 12_288

  # ---- driver ---------------------------------------------------------------

  @doc "File on disk -> the formatted result string."
  def solve(variant, file, opts \\ []) do
    {mode, kind} = parse_variant(variant)
    size = File.stat!(file).size
    schedulers = System.schedulers_online()

    stats =
      case mode do
        :seq ->
          chunk = opts[:chunk_bytes] || (opts[:chunk_mb] || 32) * 1_048_576

          chunks(size, chunk)
          |> Enum.reduce(%{}, fn {off, len}, acc -> merge(acc, chunk_stats(kind, file, off, len, size)) end)

        :par ->
          chunk = opts[:chunk_bytes] || (opts[:chunk_mb] && opts[:chunk_mb] * 1_048_576) || chunk_for(size, schedulers)

          chunks(size, chunk)
          |> Task.async_stream(fn {off, len} -> chunk_stats(kind, file, off, len, size) end,
            max_concurrency: schedulers,
            ordered: false,
            timeout: :infinity
          )
          |> Enum.reduce(%{}, fn {:ok, part}, acc -> merge(acc, part) end)
      end

    format(stats)
  end

  def variants do
    for mode <- [:par, :seq], kind <- [:map, :ets, :split, :float, :atomics], do: :"#{mode}_#{kind}"
  end

  defp parse_variant(v) do
    [mode, kind] = v |> Atom.to_string() |> String.split("_")
    {String.to_existing_atom(mode), String.to_existing_atom(kind)}
  end

  # at most 32 MB, at least 4 chunks per scheduler, at least 1 MB
  defp chunk_for(size, schedulers), do: size |> div(schedulers * 4) |> min(32 * 1_048_576) |> max(1_048_576)

  defp chunks(size, chunk), do: for(off <- 0..(size - 1)//chunk, do: {off, min(chunk, size - off)})

  defp merge(a, b) do
    Map.merge(a, b, fn _name, {mn1, mx1, s1, c1}, {mn2, mx2, s2, c2} ->
      {min(mn1, mn2), max(mx1, mx2), s1 + s2, c1 + c2}
    end)
  end

  # The chunk owns the lines that start in [off, off + len). Returns the
  # stats map for them.
  defp chunk_stats(kind, file, off, len, size) do
    {:ok, fd} = :file.open(file, [:raw, :binary, :read])
    start = max(off - 1, 0)
    {:ok, data} = :file.pread(fd, start, off + len - start + @overread)
    :ok = :file.close(fd)
    _ = size

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

  defp process(:map, body), do: map_loop(body, %{})
  defp process(:float, body), do: float_loop(body, %{}) |> Map.new(fn {k, {a, b, s, c}} -> {k, {round(a * 10), round(b * 10), round(s * 10), c}} end)
  defp process(:split, body), do: split_loop(:binary.split(body, "\n", [:global]), %{})

  defp process(:ets, body) do
    tab = :ets.new(:brc, [:set, :private])
    ets_loop(body, tab)
    out = :ets.tab2list(tab) |> Map.new(fn {k, a, b, s, c} -> {k, {a, b, s, c}} end)
    :ets.delete(tab)
    out
  end

  defp process(:atomics, body) do
    ref = :atomics.new(@cap * 4, signed: true)
    {names, _n} = at_loop(body, %{}, 0, ref)

    Map.new(names, fn {name, i} ->
      b = i * 4
      {name, {:atomics.get(ref, b + 1), :atomics.get(ref, b + 2), :atomics.get(ref, b + 3), :atomics.get(ref, b + 4)}}
    end)
  end

  # ---- (a) map accumulator, byte-by-byte --------------------------------------

  defp map_loop(<<>>, acc), do: acc

  defp map_loop(bin, acc) do
    n = name_len(bin, 0)
    <<name::binary-size(^n), ?;, rest::binary>> = bin
    map_temp(rest, name, acc)
  end

  defp name_len(<<?;, _::binary>>, n), do: n
  defp name_len(<<_, rest::binary>>, n), do: name_len(rest, n + 1)

  defp map_temp(<<?-, a, b, ?., c, ?\n, rest::binary>>, name, acc),
    do: map_loop(rest, upd(acc, name, -((a - 48) * 100 + (b - 48) * 10 + (c - 48))))

  defp map_temp(<<?-, a, ?., c, ?\n, rest::binary>>, name, acc),
    do: map_loop(rest, upd(acc, name, -((a - 48) * 10 + (c - 48))))

  defp map_temp(<<a, b, ?., c, ?\n, rest::binary>>, name, acc),
    do: map_loop(rest, upd(acc, name, (a - 48) * 100 + (b - 48) * 10 + (c - 48)))

  defp map_temp(<<a, ?., c, ?\n, rest::binary>>, name, acc),
    do: map_loop(rest, upd(acc, name, (a - 48) * 10 + (c - 48)))

  defp upd(acc, name, t) do
    case acc do
      %{^name => {mn, mx, s, c}} -> %{acc | name => {min(mn, t), max(mx, t), s + t, c + 1}}
      %{} -> Map.put(acc, name, {t, t, t, 1})
    end
  end

  # ---- (b) :ets accumulator -----------------------------------------------------

  defp ets_loop(<<>>, _tab), do: :ok

  defp ets_loop(bin, tab) do
    n = name_len(bin, 0)
    <<name::binary-size(^n), ?;, rest::binary>> = bin
    ets_temp(rest, name, tab)
  end

  defp ets_temp(<<?-, a, b, ?., c, ?\n, rest::binary>>, name, tab),
    do: ets_upd(rest, name, tab, -((a - 48) * 100 + (b - 48) * 10 + (c - 48)))

  defp ets_temp(<<?-, a, ?., c, ?\n, rest::binary>>, name, tab),
    do: ets_upd(rest, name, tab, -((a - 48) * 10 + (c - 48)))

  defp ets_temp(<<a, b, ?., c, ?\n, rest::binary>>, name, tab),
    do: ets_upd(rest, name, tab, (a - 48) * 100 + (b - 48) * 10 + (c - 48))

  defp ets_temp(<<a, ?., c, ?\n, rest::binary>>, name, tab),
    do: ets_upd(rest, name, tab, (a - 48) * 10 + (c - 48))

  defp ets_upd(rest, name, tab, t) do
    case :ets.lookup(tab, name) do
      [{_, mn, mx, s, c}] -> :ets.insert(tab, {name, min(mn, t), max(mx, t), s + t, c + 1})
      [] -> :ets.insert(tab, {name, t, t, t, 1})
    end

    ets_loop(rest, tab)
  end

  # ---- (d) :binary.split per line -------------------------------------------------

  defp split_loop([<<>>], acc), do: acc
  defp split_loop([], acc), do: acc

  defp split_loop([line | lines], acc) do
    [name, temp] = :binary.split(line, ";")
    split_loop(lines, upd(acc, name, temp_tenths(temp)))
  end

  defp temp_tenths(<<?-, a, b, ?., c>>), do: -((a - 48) * 100 + (b - 48) * 10 + (c - 48))
  defp temp_tenths(<<?-, a, ?., c>>), do: -((a - 48) * 10 + (c - 48))
  defp temp_tenths(<<a, b, ?., c>>), do: (a - 48) * 100 + (b - 48) * 10 + (c - 48)
  defp temp_tenths(<<a, ?., c>>), do: (a - 48) * 10 + (c - 48)

  # ---- (e) temperature as a float ---------------------------------------------------

  defp float_loop(<<>>, acc), do: acc

  defp float_loop(bin, acc) do
    n = name_len(bin, 0)
    <<name::binary-size(^n), ?;, rest::binary>> = bin
    k = nl_len(rest, 0)
    <<temp::binary-size(^k), ?\n, rest::binary>> = rest
    t = :erlang.binary_to_float(temp)

    acc =
      case acc do
        %{^name => {mn, mx, s, c}} -> %{acc | name => {min(mn, t), max(mx, t), s + t, c + 1}}
        %{} -> Map.put(acc, name, {t, t, t, 1})
      end

    float_loop(rest, acc)
  end

  defp nl_len(<<?\n, _::binary>>, n), do: n
  defp nl_len(<<_, rest::binary>>, n), do: nl_len(rest, n + 1)

  # ---- atomics: static name -> slot map, statistics in an :atomics array ----------------

  defp at_loop(<<>>, names, n, _ref), do: {names, n}

  defp at_loop(bin, names, n, ref) do
    k = name_len(bin, 0)
    <<name::binary-size(^k), ?;, rest::binary>> = bin
    at_temp(rest, name, names, n, ref)
  end

  defp at_temp(<<?-, a, b, ?., c, ?\n, rest::binary>>, name, names, n, ref),
    do: at_upd(rest, name, names, n, ref, -((a - 48) * 100 + (b - 48) * 10 + (c - 48)))

  defp at_temp(<<?-, a, ?., c, ?\n, rest::binary>>, name, names, n, ref),
    do: at_upd(rest, name, names, n, ref, -((a - 48) * 10 + (c - 48)))

  defp at_temp(<<a, b, ?., c, ?\n, rest::binary>>, name, names, n, ref),
    do: at_upd(rest, name, names, n, ref, (a - 48) * 100 + (b - 48) * 10 + (c - 48))

  defp at_temp(<<a, ?., c, ?\n, rest::binary>>, name, names, n, ref),
    do: at_upd(rest, name, names, n, ref, (a - 48) * 10 + (c - 48))

  defp at_upd(rest, name, names, n, ref, t) do
    case names do
      %{^name => i} ->
        b = i * 4
        if t < :atomics.get(ref, b + 1), do: :atomics.put(ref, b + 1, t)
        if t > :atomics.get(ref, b + 2), do: :atomics.put(ref, b + 2, t)
        :atomics.add(ref, b + 3, t)
        :atomics.add(ref, b + 4, 1)
        at_loop(rest, names, n, ref)

      %{} ->
        n < @cap || raise "more than #{@cap} distinct stations"
        b = n * 4
        :atomics.put(ref, b + 1, t)
        :atomics.put(ref, b + 2, t)
        :atomics.put(ref, b + 3, t)
        :atomics.put(ref, b + 4, 1)
        at_loop(rest, Map.put(names, name, n), n + 1, ref)
    end
  end

  # ---- output: {Abha=-23.0/18.0/59.2, ...} ----------------------------------------------

  def format(stats) do
    body =
      stats
      |> Enum.sort()
      |> Enum.map_join(", ", fn {name, {mn, mx, s, c}} ->
        [name, ?=, tenths(mn), ?/, tenths(ceil_div(s, c)), ?/, tenths(mx)] |> IO.iodata_to_binary()
      end)

    "{" <> body <> "}"
  end

  # ceil(a / b) for b > 0: roundTowardPositive
  defp ceil_div(a, b), do: -Integer.floor_div(-a, b)

  defp tenths(t) do
    sign = if t < 0, do: "-", else: ""
    a = abs(t)
    "#{sign}#{div(a, 10)}.#{rem(a, 10)}"
  end

  # ---- independent reference: a trivially simple Enum pipeline (small files only) ------------

  def reference(file) do
    file
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(fn line ->
      [name, temp] = String.split(line, ";")
      {name, temp |> String.to_float() |> Kernel.*(10) |> round()}
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {name, ts} ->
      mean = Float.ceil(Enum.sum(ts) / length(ts))
      "#{name}=#{one(Enum.min(ts))}/#{one(round(mean))}/#{one(Enum.max(ts))}"
    end)
    |> Enum.join(", ")
    |> then(&("{" <> &1 <> "}"))
  end

  defp one(t), do: :erlang.float_to_binary(t / 10, decimals: 1)

  # ---- measuring -------------------------------------------------------------------------------

  def timed(variant, file, opts) do
    for p <- Process.list(), do: :erlang.garbage_collect(p)
    parent = self()
    base = :erlang.memory(:total)

    sampler =
      spawn_link(fn ->
        sample = fn sample, peak ->
          receive do
            :stop -> send(parent, {:peak, peak})
          after
            5 -> sample.(sample, max(peak, :erlang.memory(:total)))
          end
        end

        sample.(sample, base)
      end)

    {us, out} = :timer.tc(fn -> solve(variant, file, opts) end)
    send(sampler, :stop)

    peak =
      receive do
        {:peak, p} -> p
      end

    {us, peak, out}
  end

  def main(argv) do
    {opts, names, _} =
      OptionParser.parse(argv,
        strict: [print: :boolean, check: :boolean, reps: :integer, chunk_mb: :integer, file: :string]
      )

    if opts[:check], do: check(opts), else: bench(names, opts)
  end

  defp bench(names, opts) do
    file = opts[:file] || System.get_env("ONE_BRC_FILE") || "/tmp/one_brc/measurements.txt"
    File.exists?(file) || raise "no #{file}: run `elixir examples/one_brc/gen.exs 10M` first"

    vs =
      case names do
        [] -> for k <- ~w(map ets split float atomics)a, do: :"par_#{k}"
        ["all"] -> variants()
        _ -> Enum.map(names, &String.to_atom/1)
      end

    reps = opts[:reps] || 3
    size = File.stat!(file).size

    IO.puts(
      "file #{file} (#{div(size, 1_000_000)} MB), #{System.schedulers_online()} schedulers, " <>
        "best of #{reps}, wall time from file on disk (page cache) to the formatted string"
    )

    outs =
      for v <- vs do
        runs = for _ <- 1..reps, do: timed(v, file, opts)
        {us, peak, out} = Enum.min_by(runs, &elem(&1, 0))

        IO.puts(
          String.pad_trailing("#{v}", 14) <>
            String.pad_leading("#{Float.round(us / 1000, 0) |> trunc()} ms", 10) <>
            String.pad_leading("#{Float.round(size / us, 2)} MB/s", 14) <>
            "   peak memory #{div(peak, 1_048_576)} MB (max of #{reps} runs sampled every 5 ms: " <>
            "#{div(runs |> Enum.map(&elem(&1, 1)) |> Enum.max(), 1_048_576)} MB)"
        )

        out
      end

    [first | rest] = outs
    Enum.all?(rest, &(&1 == first)) || raise "variants disagree on this file"
    if length(outs) > 1, do: IO.puts("all #{length(outs)} variants agree with each other")
    if opts[:print], do: IO.puts(first)
  end

  defp check(_opts) do
    gen = Path.join(__DIR__, "gen.exs")

    for seed <- [1, 2] do
      path = "/tmp/one_brc/check_#{seed}.txt"
      {_, 0} = System.cmd("elixir", [gen, "100000", "--seed", "#{seed}", "--out", path])
      ref = reference(path)

      for v <- variants() do
        out = solve(v, path, chunk_bytes: 50_021)
        out == ref || raise "#{v} (50 kB chunks) differs from the reference for seed #{seed}"
      end

      # the automatic chunk sizes too
      for v <- variants() do
        out = solve(v, path, [])
        out == ref || raise "#{v} (auto chunks) differs from the reference for seed #{seed}"
      end

      IO.puts("seed #{seed}: #{length(variants())} variants match the reference (#{String.length(ref)} chars)")
    end

    IO.puts("correct")
  end
end

OneBrc.Elixir.main(System.argv())
