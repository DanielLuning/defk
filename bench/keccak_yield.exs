# Yield bookkeeping in a hot short loop: the Keccak round loop (24 trips, no
# safepoint inside) in the yielding kernel against the same kernel with
# yield: false. Two signals: the stack spills in the hottest loop of the
# compiled C (cc -S with the build's flags; the basic block with the most
# `ror` instructions; loads and stores against [sp]), which do not depend
# on load, and the time for one 16 MB message, interleaved. The kernels
# are examples/keccak.exs' own, read from the file and compiled twice.
# docs/performance.md 6.8 and 6.46.
#
#   mix run bench/keccak_yield.exs [rounds]
rounds = String.to_integer(List.first(System.argv()) || "7")

src = File.read!("examples/keccak.exs")
{c0, _} = :binary.match(src, "defmodule Keccak.Constants")
{k0, _} = :binary.match(src, "kernels =\n  quote do")
{k1, _} = :binary.match(src, "\nModule.create(Keccak.Kernels")
constants = binary_part(src, c0, k0 - c0)
kernels = binary_part(src, k0, k1 - k0)
# every kernel head gets yield: false in the blocking twin
blocking = Regex.replace(~r/(defk \w+\(.*\) :: \S+) do$/m, kernels, "\\1, yield: false do")

{yielding_ast, _} = Code.eval_string(constants <> "\n" <> kernels)
{blocking_ast, _} = Code.eval_string(blocking)

Module.create(KY.Yield, yielding_ast, Macro.Env.location(__ENV__))
Module.create(KY.Blocking, blocking_ast, Macro.Env.location(__ENV__))

defmodule KY.Spills do
  # The stack loads and stores in the hottest loop of a module's C: the
  # basic block of the assembly with the most `ror` instructions.
  def count(mod, name) do
    dir = Path.join("tmp", "keccak_yield")
    File.mkdir_p!(dir)
    c = Path.join(dir, name <> ".c")
    s = Path.join(dir, name <> ".s")
    File.write!(c, mod.__defk_c_source__())

    flags =
      ~w(-O3 -ffp-contract=off -std=gnu11 -fPIC -Wall -Wno-unused-label -Wno-unused-variable -fstack-protector-strong -D_FORTIFY_SOURCE=2 -fno-strict-overflow -fno-builtin)

    {_, 0} =
      System.cmd(
        "cc",
        ["-S"] ++ flags ++ ["-I", Defk.Build.erts_include(), "-I", "priv", "-o", s, c],
        stderr_to_stdout: true
      )

    blocks =
      s
      |> File.read!()
      |> String.split("\n")
      |> Enum.chunk_while(
        [],
        fn line, acc ->
          if Regex.match?(~r/^\S+:/, line),
            do: {:cont, Enum.reverse(acc), [line]},
            else: {:cont, [line | acc]}
        end,
        fn acc -> {:cont, Enum.reverse(acc), []} end
      )

    {block, rors} =
      blocks
      |> Enum.map(&{&1, Enum.count(&1, fn l -> l =~ ~r/^\s+ror/ end)})
      |> Enum.max_by(&elem(&1, 1))

    # the loop body ends at its back-edge; what follows in the same block
    # (no label) is the exit path, run once per enclosing iteration
    block = Enum.take_while(block, &(not (&1 =~ ~r/^\s+b\.\w+/))) ++ ["b."]

    stores = Enum.count(block, &(&1 =~ ~r/^\s+st[pr]\b.*\[sp/))
    loads = Enum.count(block, &(&1 =~ ~r/^\s+ld[pr]\b.*\[sp/))

    %{
      rors: rors,
      stores: stores,
      loads: loads,
      instructions: Enum.count(block, &(&1 =~ ~r/^\s+[a-z]/))
    }
  end
end

big = :crypto.strong_rand_bytes(16 * 1024 * 1024)
^big = big
true = KY.Yield.keccak256(big) == KY.Blocking.keccak256(big)

for {name, mod} <- [{"yielding", KY.Yield}, {"blocking", KY.Blocking}] do
  %{rors: r, stores: st, loads: ld, instructions: n} = KY.Spills.count(mod, name)

  IO.puts(
    "#{String.pad_trailing(name, 10)} round loop: #{st} stack stores, #{ld} stack loads, #{r} ror, #{n} instructions"
  )
end

t = fn f -> elem(:timer.tc(f), 0) / 1000 end

IO.puts(
  "\n16 MB keccak256, best and median of #{rounds} interleaved  (other CPU: #{Float.round(Defk.Bench.other_cpu() * 1.0, 2)} cores)"
)

pairs =
  for _ <- 1..rounds do
    {t.(fn -> KY.Yield.keccak256(big) end), t.(fn -> KY.Blocking.keccak256(big) end)}
  end

med = fn l -> Enum.at(Enum.sort(l), div(length(l), 2)) end
ys = Enum.map(pairs, &elem(&1, 0))
bs = Enum.map(pairs, &elem(&1, 1))

IO.puts("  yielding  #{Float.round(Enum.min(ys), 2)} / #{Float.round(med.(ys), 2)} ms")
IO.puts("  blocking  #{Float.round(Enum.min(bs), 2)} / #{Float.round(med.(bs), 2)} ms")

IO.puts(
  "  ratio     #{Float.round(Enum.min(ys) / Enum.min(bs), 3)}x (best), #{Float.round(med.(ys) / med.(bs), 3)}x (median)"
)
