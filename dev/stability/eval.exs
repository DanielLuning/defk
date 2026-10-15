# Runs the test sample (dev/stability/sample.exs) against the compiler of a
# release: `mix defk.stability.freeze` checks the release's tag out in a
# temporary worktree and runs this script there, in the test environment,
#
#     MIX_ENV=test mix run <this file> <sample.exs> <results>
#
# so the kernels are compiled, and every call evaluated, by the tag's code.
# Each call runs natively and in Elixir mode, the two must agree (the same
# value, or the same exception for the same reason, as test/support's
# Defk.LanguageDoc requires), and the native result is written to
# `<results>` as a term: `[{file, [{call, {:value, term} | {:raise, module,
# message}}]}]`, the message with the module written as `M`, as the frozen
# file calls it. The script uses only what the release ships (`Defk`,
# `Defk.ElixirMode.with_mode/2`, `Defk.Test.agreement_reason/1`), nothing
# from the checkout that runs the task.

defmodule Defk.StabilitySample.Eval do
  @moduledoc false

  def main([sample_path, out_path]) do
    {sample, _} = Code.eval_file(sample_path)
    dir = Path.join(System.tmp_dir!(), "defk_stability_sample")
    File.mkdir_p!(dir)

    results =
      for entry <- sample do
        mod = compile!(entry, dir)
        {entry.file, for(call <- entry.calls, do: {call, step!(mod, entry.file, call)})}
      end

    File.write!(out_path, :erlang.term_to_binary(results))
    IO.puts("#{length(results)} sample module(s) run")
  end

  def main(_), do: raise(ArgumentError, "usage: mix run eval.exs <sample.exs> <results>")

  defp compile!(entry, dir) do
    mod =
      Module.concat(Defk.StabilitySample, Macro.camelize(String.replace(entry.file, "-", "_")))

    path = Path.join(dir, "#{inspect(mod)}.ex")
    File.write!(path, "defmodule #{inspect(mod)} do\n  use Defk\n\n#{entry.source}\nend\n")
    Code.compile_file(path)
    mod
  end

  defp step!(mod, file, call) do
    native = eval(mod, :native, call)
    elixir = eval(mod, :elixir, call)

    if not agree?(native, elixir) do
      raise "#{file}: #{call}: native #{show(native)}, Elixir mode #{show(elixir)}"
    end

    case native do
      {:ok, value} ->
        {:value, value}

      {:raise, e} ->
        {:raise, inspect(e.__struct__), String.replace(Exception.message(e), inspect(mod), "M")}
    end
  end

  defp eval(mod, mode, call) do
    src = "alias #{inspect(mod)}, as: M\n#{call}"
    Defk.ElixirMode.with_mode(mode, fn -> {:ok, elem(Code.eval_string(src), 0)} end)
  rescue
    e -> {:raise, e}
  end

  defp agree?({:ok, a}, {:ok, b}), do: a === b

  defp agree?({:raise, a}, {:raise, b}),
    do:
      {a.__struct__, Defk.Test.agreement_reason(a)} ==
        {b.__struct__, Defk.Test.agreement_reason(b)}

  defp agree?(_, _), do: false

  defp show({:ok, v}), do: inspect(v)
  defp show({:raise, e}), do: "** (#{inspect(e.__struct__)}) #{Exception.message(e)}"
end

Defk.StabilitySample.Eval.main(System.argv())
