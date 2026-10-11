# clang's loop-vectorize verdict for every loop of every catalogue kernel, at
# each target level (arm64 levels and, as remarks only, x86-64 levels).
#
#   mix run bench/simd/remarks.exs [out.etf]
#
# Uses Defk.Report.full/3 (the `report: :full` pass) with `CC` set to a
# wrapper per level, on the C each module was built from. Writes the results
# as an Erlang term file (default: $TMPDIR/defk-simd-remarks.etf) and prints
# one line per loop. Research tooling for defk-ulk.1, not part of defk.
Code.require_file("load.exs", __DIR__)
Code.require_file("levels.exs", __DIR__)

out = List.first(System.argv()) || Path.join(System.tmp_dir!(), "defk-simd-remarks.etf")

# duplicates of another module's source (Elixir-mode copies, the off build)
dups = [FloatChecks.Off, GeoCrc.KernelsEM, HashChain.KernelsEM, Keccak.ElixirMode]
mods = Enum.reject(Simd.Load.all(), &(&1.mod in dups))
dir = Path.join(System.tmp_dir!(), "defk-simd-remarks")
File.mkdir_p!(dir)

rows =
  for k <- mods do
    src = k.mod.__defk_c_source__()
    report = Enum.reject(k.mod.__defk_report__(), &match?({_, _, {:vectorize, _, _}}, &1))

    per_level =
      for {level, flags} <- Simd.Levels.all() do
        System.put_env("CC", Simd.Levels.wrapper(level, flags))
        base = Path.join(dir, "#{inspect(k.mod)}-#{level}")
        File.write!(base <> ".c", src)
        full = Defk.Report.full(report, src, base)
        {level, for({kern, line, {:vectorize, v, t}} <- full, do: {{kern, line}, {v, t}})}
      end

    System.delete_env("CC")
    loops = for {kern, line, {:loop, _, t}} <- report, do: {kern, line, t}

    %{
      mod: k.mod,
      file: k.file,
      loops: loops,
      levels: Map.new(per_level, fn {l, v} -> {l, Map.new(v)} end),
      report: report
    }
  end

File.write!(out, :erlang.term_to_binary(rows))

short = fn
  {:vectorized, t} ->
    "V " <> (Regex.run(~r/width: (\d+)/, t) |> then(&(&1 && List.last(&1))) |> to_string())

  {:partial, _} ->
    "P"

  {:missed, _} ->
    "-"

  {:unknown, _} ->
    "?"
end

levels = Enum.map(Simd.Levels.all(), &elem(&1, 0))
IO.puts(Enum.join(["file", "kernel", "line" | levels], "\t"))

for r <- rows, {{n, a} = kern, line, _t} <- r.loops do
  cells = for l <- levels, do: short.(r.levels[l][{kern, line}])
  IO.puts(Enum.join([r.file, "#{inspect(r.mod)}.#{n}/#{a}", line | cells], "\t"))
end

IO.puts("wrote #{out}")
