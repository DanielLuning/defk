defmodule Defk.LanguageDoc.Isolated do
  @moduledoc false
  # Runs the doc blocks that are not kernels (sketches, ExUnit test files,
  # scripts: see Defk.LanguageDoc) in a BEAM of their own, so that they can
  # define any module, start tests or set global state without touching the
  # suite that checks them.
  #
  # `run/1` is the parent's side: it writes the jobs to a file, starts
  # `mix run` in the test environment (the project is compiled already, so a
  # child boots in half a second) and reads the results back. `main/1` is the
  # child's.
  #
  # A job: `%{id: term, kind: :sketch | :script | :exunit, ...}`. Sketches
  # share one child, an ExUnit file or a script has its own, except that the
  # test files needing the same kernel share one (two children building the
  # same kernel at once would race on its cached library).

  @doc """
  Runs the jobs, concurrently where they do not share a child. Returns
  `%{id => :ok | {:error, why}}`.
  """
  def run(jobs, dir) do
    File.mkdir_p!(dir)

    jobs
    |> groups()
    |> Enum.with_index()
    |> Task.async_stream(fn {group, n} -> child(group, Path.join(dir, "child#{n}.term")) end,
      timeout: :infinity,
      ordered: false
    )
    |> Enum.reduce(%{}, fn {:ok, results}, acc -> Map.merge(acc, results) end)
  end

  defp groups(jobs) do
    by = fn kind -> Enum.filter(jobs, &(&1.kind == kind)) end

    sketches = by.(:sketch)
    scripts = Enum.map(by.(:script), &[&1])
    tests = by.(:exunit) |> Enum.group_by(& &1.needs) |> Map.values()
    Enum.reject([sketches | scripts ++ tests], &(&1 == []))
  end

  defp child(jobs, file) do
    File.write!(file, :erlang.term_to_binary(jobs))
    File.rm(file <> ".out")
    expr = "Defk.LanguageDoc.Isolated.main(#{inspect(file)})"
    args = ["run", "--no-compile", "--no-deps-check", "-e", expr]

    {output, status} =
      System.cmd(System.find_executable("mix"), args,
        env: [{"MIX_ENV", "test"}],
        stderr_to_stdout: true
      )

    case File.read(file <> ".out") do
      {:ok, bin} when status == 0 ->
        bin |> :erlang.binary_to_term() |> Map.new(fn {id, r} -> {id, with_output(r, output)} end)

      _ ->
        crash = {:error, "the child BEAM failed (exit #{status}):\n#{tail(output)}"}
        Map.new(jobs, &{&1.id, crash})
    end
  end

  defp with_output(:ok, _), do: :ok
  defp with_output({:error, why}, output), do: {:error, "#{why}\n#{tail(output)}"}

  defp tail(output), do: output |> String.split("\n") |> Enum.take(-60) |> Enum.join("\n")

  # ------------------------------------------------------------ the child --

  @doc false
  @spec main(String.t()) :: no_return()
  def main(file) do
    jobs = file |> File.read!() |> :erlang.binary_to_term()
    File.write!(file <> ".out", :erlang.term_to_binary(execute(jobs)))
    System.halt(0)
  end

  defp execute([%{kind: :sketch} | _] = jobs) do
    for {job, n} <- Enum.with_index(jobs) do
      {job.id, attempt(fn -> sketch(job, "Defk.LanguageDoc.Sketch.S#{n}") end)}
    end
  end

  defp execute([%{kind: :script} = job]), do: [{job.id, attempt(fn -> script(job) end)}]

  defp execute([%{kind: :exunit} | _] = jobs) do
    # a few runs per property: the guide's tests show the shape, not the depth
    Application.put_env(:stream_data, :max_runs, 20)
    ExUnit.start(autorun: false)
    Enum.each(hd(jobs).deps, &Code.compile_string/1)
    for job <- jobs, do: {job.id, attempt(fn -> exunit(job) end)}
  end

  defp attempt(fun) do
    fun.()
    :ok
  rescue
    e -> {:error, Exception.format(:error, e, __STACKTRACE__)}
  end

  # ---------------------------------------------------------------- sketch --

  defp sketch(job, module) do
    compile_quietly(sketch_source(job, module))
    Module.concat([module]).run()
  end

  # compiler warnings are the sketches' own (unused variables, an unused
  # import): only what stops the compile is reported
  defp compile_quietly(source) do
    {result, diagnostics} =
      Code.with_diagnostics(fn ->
        try do
          Code.compile_string(source)
          :ok
        rescue
          e in [CompileError, SyntaxError, TokenMissingError] -> {:error, e}
        end
      end)

    with {:error, e} <- result do
      errors = for %{severity: :error, message: message} <- diagnostics, do: message
      raise "does not compile: #{Exception.message(e)}\n#{Enum.join(errors, "\n")}"
    end
  end

  @doc """
  The module a sketch is run as. A block that starts with `def`, `defp` or an
  attribute is module-level code and its `setup` the body of `run/0` after it;
  any other block is the body of `run/0`, after its `setup`. A `# => value`
  after the code on a line is checked against that line's value.
  """
  def sketch_source(job, module) do
    source = expectations(job.source)
    setup = expectations(job.setup)

    {head, body} =
      if module_level?(source),
        do: {source, setup},
        else: {"", setup <> "\n" <> source}

    "defmodule #{module} do\n  import Bitwise\n#{job.defs}\n#{head}\n  def run do\n#{body}\n  end\nend\n"
  end

  defp module_level?(source),
    do: source =~ ~r/\A(\s*(#.*)?\n)*\s*(defp?\s|@)/

  # `expr  # => value` becomes a call checking the line's value
  defp expectations(source) do
    Regex.replace(~r/^(\s*)(.*\S)\s+# => (.*\S)\s*$/m, source, fn _, indent, expr, value ->
      ~s|#{indent}Defk.LanguageDoc.Isolated.expect!((#{expr}), #{inspect(value)})|
    end)
  end

  @doc false
  def expect!(value, shown) do
    {expected, _} = Code.eval_string(shown)

    if value === expected,
      do: value,
      else: raise("documented # => #{shown}, got #{inspect(value)}")
  end

  # ---------------------------------------------------------------- script --

  # the script's Mix.install line is the project itself here
  defp script(job) do
    source = String.replace(job.source, ~r/^Mix\.install\(.*\)\s*$/m, "")

    case Code.eval_string(source) do
      {%{correct: true}, _} ->
        :ok

      {other, _} ->
        raise "the script's last value is not a passing Defk.Bench.report: #{inspect(other)}"
    end
  end

  # ----------------------------------------------------------------- exunit --

  defp exunit(job) do
    Code.compile_string(job.source)
    %{failures: failures, total: total, excluded: excluded, skipped: skipped} = ExUnit.run()

    cond do
      failures > 0 -> raise "#{failures} of #{total} tests failed"
      total == 0 -> raise "the block defines no tests"
      excluded + skipped > 0 -> raise "#{excluded + skipped} tests were not run"
      true -> :ok
    end
  end
end
