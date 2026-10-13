# Write the generated C of one example's kernel module, with the current
# compiler, for the libFuzzer targets (scripts/fuzz/README.md):
#
#   mix run --no-start scripts/fuzz/gen_c.exs <example.exs> <Module> <out.c>
#
# Only the example's `defmodule` forms that `use Defk` are evaluated (as
# scripts/dump_c.exs does), so no Mix.install and no bench runs; the module's
# `__defk_c_source__/0` is what the compiler emitted for it. Nothing is
# hand-copied: a compiler or runtime-header change is what gets fuzzed.

[file, module_name, out] =
  case System.argv() do
    [_, _, _] = args ->
      args

    _ ->
      IO.puts(
        :stderr,
        "usage: mix run --no-start scripts/fuzz/gen_c.exs <example.exs> <Module> <out.c>"
      )

      System.halt(2)
  end

forms =
  case Code.string_to_quoted!(File.read!(file), file: file) do
    {:__block__, _, forms} -> forms
    form -> [form]
  end

uses_defk? = fn m ->
  m
  |> Macro.prewalk(false, fn
    {:use, _, [{:__aliases__, _, [:Defk]} | _]} = n, _ -> {n, true}
    n, acc -> {n, acc}
  end)
  |> elem(1)
end

for {:defmodule, _, _} = m <- forms, uses_defk?.(m), do: Code.eval_quoted(m, [], file: file)

module = Module.concat([module_name])

unless Code.ensure_loaded?(module) and function_exported?(module, :__defk_c_source__, 0) do
  IO.puts(:stderr, "gen_c: #{file} defines no kernel module #{module_name}")
  System.halt(2)
end

File.mkdir_p!(Path.dirname(out))
File.write!(out, module.__defk_c_source__())
IO.puts(:stderr, "gen_c: #{inspect(module)} -> #{out}")
