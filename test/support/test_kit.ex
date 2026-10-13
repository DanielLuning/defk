defmodule Defk.TestKit do
  @moduledoc false
  # Helpers the test files share (defk-zdm.3): one copy each, instead of one
  # per file. `import Defk.TestKit` in a test module.
  #
  # Compiling a kernel module from a test: `compile/3` writes it to a file,
  # so errors have source lines, and names it by its source, so the next run
  # hits the build cache (a new library costs a C compile and a first dlopen,
  # and the code server loads them one at a time: defk-dwa).

  import ExUnit.Assertions

  # ------------------------------------------------------------ compiling --

  @doc """
  Compiles `body` (kernels, or any module body) in a module under `ns` with
  `use Defk` (or `use Defk, <opts[:use]>`). Returns `:ok`, or the
  CompileError message.

  The module is `<ns>.M<hash of the source>`: the same source is the same
  module, compiled once per VM. Concurrent compiles of one source would
  define one module twice at once: give each a distinct `opts[:key]`, which
  is part of the hash.
  """
  def compile(ns, body, opts \\ []) do
    use_line = if u = opts[:use], do: "use Defk, #{u}", else: "use Defk"

    id =
      :erlang.md5([inspect(ns), use_line, body, inspect(opts[:key])])
      |> Base.encode16()
      |> binary_part(0, 12)

    mod = Module.concat(ns, "M" <> id)
    src = "defmodule #{inspect(mod)} do\n  #{use_line}\n\n#{indent(body)}\nend\n"

    if Code.ensure_loaded?(mod) do
      :ok
    else
      dir = Path.join([System.tmp_dir!(), "defk_test_kit", inspect(ns)])
      File.mkdir_p!(dir)
      path = Path.join(dir, "M#{id}.ex")
      File.write!(path, src)

      try do
        Code.compile_file(path)
        :ok
      rescue
        e in CompileError -> Exception.message(e)
      end
    end
  end

  @doc "Like `compile/3`, but fails the test when `body` compiles. Returns the message."
  def reject(ns, body, opts \\ []) do
    case compile(ns, body, opts) do
      :ok -> flunk("compiled, expected a compile error:\n#{body}")
      msg -> msg
    end
  end

  @doc "One kernel: `defk <name>(<params>) :: <ret> do <body> end`."
  def kernel(params, ret, body, name \\ "f"),
    do: "defk #{name}(#{params}) :: #{ret} do\n#{indent(body)}\nend"

  defp indent(text) do
    text |> String.split("\n") |> Enum.map_join("\n", &if(&1 == "", do: "", else: "  " <> &1))
  end

  @doc "The error codes in a compile error message, in order."
  def codes(msg), do: Regex.scan(~r/^\(defk ([a-z0-9-]+)[:;] /m, msg) |> Enum.map(&Enum.at(&1, 1))

  @doc "The `error: ...` lines of a compile error message, without the prefix."
  def whats(msg), do: Regex.scan(~r/^error: (.*)$/m, msg) |> Enum.map(&Enum.at(&1, 1))

  @doc "The rewrite under a message's hint, unindented; nil without one."
  def rewrite(msg) do
    case Regex.run(~r/^hint: .*:\n\n((?:    .*\n|\n)+)\(defk/m, msg) do
      [_, rw] ->
        rw
        |> String.split("\n")
        |> Enum.map_join("\n", &String.replace_prefix(&1, "    ", ""))
        |> String.trim_trailing()

      nil ->
        nil
    end
  end

  # ---------------------------------------------------------- generated C --

  @doc "The generated C of kernel `name` in `mod`: its section, up to the next kernel's."
  def kernel_c(mod, name) do
    [_ | chunks] = String.split(mod.__defk_c_source__(), "/* ---- ")

    Enum.find(chunks, &String.starts_with?(&1, "#{name}/")) ||
      flunk("#{inspect(mod)} has no kernel #{name}")
  end

  # ------------------------------------------------------------- yielding --

  @doc """
  Runs `fun` with every safepoint of `mod`'s kernels yielding. The flag is
  module-wide (Defk.Test.assert_agrees/4): only for modules no other test
  file calls while this runs.
  """
  def forced(mod, fun) do
    mod.__defk_force_yields__(true)

    try do
      fun.()
    after
      mod.__defk_force_yields__(false)
    end
  end

  @doc "`{result, yields}`: `fun`'s result and how many times `mod`'s kernels yielded in it."
  def yields(mod, fun) do
    y0 = mod.__defk_stats__().yields
    res = fun.()
    {res, mod.__defk_stats__().yields - y0}
  end

  @doc """
  `Defk.Test.assert_agrees/4` under forced yields, and the native call
  yielded at least `opts[:min_yields]` times (default 1): agreement alone
  does not show that a resume path ran. Returns the native outcome.
  """
  def assert_agrees_yielding(mod, fun, args, opts \\ []) do
    {min, opts} = Keyword.pop(opts, :min_yields, 1)

    {res, n} =
      yields(mod, fn -> forced(mod, fn -> Defk.Test.assert_agrees(mod, fun, args, opts) end) end)

    assert n >= min, "#{inspect(mod)}.#{fun} yielded #{n} times, expected at least #{min}"
    res
  end

  # ---------------------------------------------------------------- misc --

  @doc "Packs i64s as an [i64] argument."
  def i64s(list), do: Defk.Generators.pack(:i64, list)

  @doc "Packs floats as an [f64] argument."
  def f64s(list), do: Defk.Generators.pack(:f64, list)

  @doc "Polls `f` every millisecond until it returns truthy; fails after `timeout` ms."
  def wait_until(f, timeout \\ 30_000),
    do: await(f, System.monotonic_time(:millisecond) + timeout)

  defp await(f, deadline) do
    cond do
      f.() ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("timed out")

      true ->
        Process.sleep(1)
        await(f, deadline)
    end
  end

  @doc "Restores the environment variables `vars` when the test exits. Call from a test or setup."
  def restore_env_on_exit(vars) do
    saved = for v <- vars, do: {v, System.get_env(v)}

    ExUnit.Callbacks.on_exit(fn ->
      for {k, v} <- saved, do: if(v, do: System.put_env(k, v), else: System.delete_env(k))
    end)
  end

  @doc "The JSON of the `DEFK_RESULT ` line in a benchmark's output."
  def defk_result(out) do
    line = out |> String.split("\n") |> Enum.find(&String.starts_with?(&1, "DEFK_RESULT "))
    assert line, "no DEFK_RESULT line in:\n#{out}"
    JSON.decode!(String.replace_prefix(line, "DEFK_RESULT ", ""))
  end
end
