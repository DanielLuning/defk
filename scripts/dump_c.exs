# Dump the generated C of every test kernel and example: the byte-identical
# gate the compiler-refactor tickets rely on (defk-mif; ADR-0007's migration
# step, Defk.Facts, Defk.Copies, the strip record). Run it on both sides of a
# change and diff:
#
#   DEFK_DUMP_C=tmp/c_main mix dump_c
#   ... switch branches ...
#   DEFK_DUMP_C=tmp/c_branch mix dump_c
#   diff -r tmp/c_main tmp/c_branch && echo byte-identical
#
# `mix dump_c` is `compile --force` + this script, in the test env. The
# forced compile regenerates the C of lib and test/support kernels with the
# current compiler (an unchanged module would otherwise keep the C of its
# last compile), and DEFK_DUMP_C (read in Defk.__before_compile__) makes
# every `use Defk` module write its C into the directory. This script then
# loads what that compile does not reach:
#
#   * every test/**/*_test.exs module — ExUnit is started, no tests run
#   * every top-level examples/*.exs — only its defmodule forms are
#     evaluated, so kernels compile without Mix.install and without the
#     benches running (examples living in their own directory, like
#     one_brc/, are not covered)
#
# Two modules sharing a name overwrite one file; the last write wins on both
# sides of a diff, so the gate stays sound — it just sees one of them.

out =
  case System.fetch_env("DEFK_DUMP_C") do
    {:ok, dir} ->
      dir

    :error ->
      IO.puts(:stderr, "DEFK_DUMP_C must name the output directory for the whole command:")
      IO.puts(:stderr, "  DEFK_DUMP_C=tmp/c_main mix dump_c")
      System.halt(2)
  end

# before the helper: ExUnit.start registers its run-at-exit hook only when
# the FIRST start allows autorun, so this start is what keeps the suite from
# running; the helper's own ExUnit.start then only merges configuration
# (and does the loading that matters here: the catalog and the fuzzy_search
# kernels)
ExUnit.start(autorun: false)
Code.require_file("test/test_helper.exs")

for file <- Enum.sort(Path.wildcard("test/**/*_test.exs")), do: Code.require_file(file)

# an example is Elixir modules followed by input setup and a bench; only the
# modules matter here, and nothing outside a defmodule may feed one (an
# example that needs file-level setup for its modules breaks this gate
# loudly, which is the correct outcome: fix the example or this script)
defmodules = fn file ->
  forms =
    case Code.string_to_quoted!(File.read!(file), file: file) do
      {:__block__, _, forms} -> forms
      form -> [form]
    end

  for {:defmodule, _, _} = m <- forms, do: m
end

examples =
  Path.wildcard("examples/*.exs")
  |> Enum.reject(fn f ->
    base = Path.basename(f)
    String.starts_with?(base, "_")
  end)
  |> Enum.sort()

# a module that does not `use Defk` contributes no C, so when it fails to
# compile here (usually a dependency only the example's own Mix.install has,
# like Crux in cdcl_sat.exs) it is skipped and named; a kernel module that
# fails stays a hard error, because the dump would silently lose its C
kernel? = fn m ->
  m
  |> Macro.prewalk(false, fn
    {:use, _, [{:__aliases__, _, [:Defk]} | _]} = n, _ -> {n, true}
    n, acc -> {n, acc}
  end)
  |> elem(1)
end

skipped =
  for file <- examples, {:defmodule, _, [name | _]} = m <- defmodules.(file), reduce: [] do
    skipped ->
      try do
        Code.eval_quoted(m, [], file: file)
        skipped
      rescue
        e ->
          if kernel?.(m), do: reraise(e, __STACKTRACE__)
          [{file, Macro.to_string(name)} | skipped]
      end
  end

for {file, name} <- Enum.reverse(skipped),
    do: IO.puts("skipped #{name} (#{file}): no C, compile failed outside the mix project")

dumped = out |> Path.join("*.c") |> Path.wildcard() |> length()
IO.puts("dumped the C of #{dumped} modules to #{out}")
