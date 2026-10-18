defmodule Defk.ContractKit do
  @moduledoc false
  # The one helper module a contract test may call besides defk's public API,
  # ExUnit and Covenant (test/contracts/README.md). A release freezes its
  # contract tests (test/stability/<version>/contracts/, written by `mix
  # defk.stability.freeze`), and every later commit runs them, so what a
  # function here means is frozen too: a function is never removed, renamed
  # or changed in meaning; a new need is a new function. The suite checks
  # that contract tests call no other defk module outside the public API
  # (test/contracts/kit_test.exs).

  alias Defk.LanguageDoc
  alias Defk.StabilityCorpus, as: Corpus

  @exceptions "test/stability/exceptions.exs"

  @doc """
  Compiles `body` in a fresh module under `ns` that uses defk: `:ok`, or the
  compile error's message. Options: `use:` (the `use Defk` options, as
  source), `key:` (any term, to tell apart two compiles of one body).
  """
  def compile(ns, body, opts \\ []), do: Defk.TestKit.compile(ns, body, opts)

  @doc "`compile/3` that returns `{:ok, module}` or `{:error, message}`."
  def compiled(ns, body, opts \\ []), do: Defk.TestKit.compiled(ns, body, opts)

  @doc "The error codes in a compile error message, in order."
  def codes(msg), do: Defk.TestKit.codes(msg)

  @doc "`{result, yields}`: `fun`'s result and how many times `mod`'s kernels yielded in it."
  def yields(mod, fun), do: Defk.TestKit.yields(mod, fun)

  @doc "Runs `fun` with a forced yield at every safepoint of `mod`'s kernels; returns its result."
  def forced(mod, fun), do: Defk.TestKit.forced(mod, fun)

  @doc """
  The runtime counters of the kernel library `mod` has loaded now:
  `%{frames_live:, promotions:, yields:}` (frames held by suspended calls,
  calls whose state moved into a frame, yields).
  """
  def stats(mod), do: Map.take(mod.__defk_stats__(), [:frames_live, :promotions, :yields])

  @doc """
  Source for a function `stats_fun/0` to put inside a kernel module: it
  returns a fun that reads that module instance's counters, as `stats/1`
  does, also after a reload replaced the instance.
  """
  def stats_fun_source,
    do:
      "def stats_fun, do: fn -> Map.take(__defk_stats__(), [:frames_live, :promotions, :yields]) end"

  @doc """
  Asserts that the library `mod` has loaded has `expected` live frames
  (default 0), waiting up to `timeout` ms for frame destructors to run.
  """
  def assert_frames_live(mod, expected \\ 0, timeout \\ 30_000),
    do: Defk.Test.Frames.assert_frames_live(mod, expected, timeout)

  @doc "The path of the native library `mod` has loaded now."
  def lib(mod), do: mod.__defk_lib__()

  @doc """
  Makes `mod`'s kernel library fault on purpose (MIX_ENV=test only): `kind`
  1 a segmentation fault, 2 an illegal instruction, 3 an integer division by
  zero, at the next clock read; `kind + 256 * n` lets `n` clock reads pass
  first; 0 turns it off.
  """
  def inject_fault(mod, kind), do: mod.__defk_inject_fault__(kind)

  @doc """
  What the kernel build reads from the environment now, without building:
  `%{cc: {executable, args}, erts_include: dir}`.
  """
  def build_env, do: %{cc: Defk.Build.compiler(), erts_include: Defk.Build.erts_include()}

  @doc "Packs integers as an `[i64]` argument."
  def i64s(list), do: Defk.TestKit.i64s(list)

  @doc "Polls `f` every millisecond until it returns truthy; fails after `timeout` ms."
  def wait_until(f, timeout \\ 30_000), do: Defk.TestKit.wait_until(f, timeout)

  @doc """
  `{file, examples}` of every frozen file of a kind (`:kernels` or
  `:rejections`), every release, the file relative to `test/stability/`.
  """
  def frozen(kind), do: Corpus.examples(kind)

  @doc "The paths of every frozen file of a kind, for `@external_resource`."
  def frozen_paths(kind), do: Corpus.files(kind)

  @doc """
  True when a frozen kernel example is one a kernel corpus may hold: it
  runs `iex>` steps or is annotated `compiles:`, and is not a known failure.
  """
  def frozen_kernel?(%{check: :run, known_failure: nil}), do: true
  def frozen_kernel?(%{check: {:compiles, _}, known_failure: nil}), do: true
  def frozen_kernel?(_), do: false

  @doc """
  Compiles every frozen example concurrently: `%{file => :ok | message}`.
  Once per test run for the same examples: the live contract and every
  frozen copy of it compile the same corpus, and the modules are named after
  the files, so a second caller waits for the first and shares its result.
  A shared result whose modules were unloaded since (a mutation run purges
  the modules each test run loads) is compiled again, and so is one that
  other defk code compiled: the key holds the loaded code's identity, so a
  result a mutated compiler gave is never reused by the unmutated one.
  """
  def compile_frozen(examples, kind) do
    key = {__MODULE__, :frozen, kind, :erlang.phash2({examples, defk_code()})}

    :global.trans({key, self()}, fn ->
      case :persistent_term.get(key, nil) do
        compiled when is_map(compiled) ->
          if loaded?(compiled, examples, kind),
            do: compiled,
            else: compile_and_keep(key, examples, kind)

        nil ->
          compile_and_keep(key, examples, kind)
      end
    end)
  end

  # the md5 of every loaded module of the defk application
  defp defk_code do
    {:ok, mods} = :application.get_key(:defk, :modules)
    for mod <- mods, :code.is_loaded(mod) != false, do: {mod, mod.module_info(:md5)}
  end

  defp compile_and_keep(key, examples, kind) do
    compiled = Corpus.compile_all(examples, kind)
    :persistent_term.put(key, compiled)
    compiled
  end

  # every module a compile result says compiled is still loaded
  defp loaded?(compiled, examples, kind) do
    Enum.all?(
      for({file, exs} <- examples, ex <- exs, Map.get(compiled, file) == :ok, do: {file, ex}),
      fn {file, ex} ->
        Code.ensure_loaded?(Module.concat([Corpus.named(file, ex, kind).module]))
      end
    )
  end

  @doc "A test name for a frozen file's examples."
  def label(examples), do: Corpus.label(examples)

  @doc """
  Checks a frozen kernel example against its compile result: it compiles,
  natively and in Elixir mode, and every recorded `iex>` step gives the
  recorded result in both. Fails the test otherwise.
  """
  def verify_frozen!(file, example, result),
    do: LanguageDoc.verify!(Corpus.named(file, example, :kernels), result)

  @doc """
  The live exception list for frozen files (`test/stability/exceptions.exs`):
  `kind` is `:fixed` (a bug fix the CHANGELOG names changed the frozen result)
  or `:newly_supported` (a frozen rejection compiles now, its code still
  active); `[{file, words}]`, `words` a phrase of the CHANGELOG entry. The
  list only grows.
  """
  def exceptions(kind), do: @exceptions |> Code.eval_file() |> elem(0) |> Map.fetch!(kind)

  @doc "The words of `file`'s exception of `kind`, or nil."
  def exception(kind, file) do
    case List.keyfind(exceptions(kind), file, 0) do
      {_, words} -> words
      nil -> nil
    end
  end

  @doc "The files an exception list names that no frozen file of `examples` is."
  def not_frozen(exceptions, examples), do: Corpus.not_frozen(exceptions, examples)

  @doc "True when CHANGELOG.md contains `words`."
  def changelog?(words), do: File.read!("CHANGELOG.md") =~ words

  @doc """
  The released compile error codes, `test/stability/codes.txt`:
  `[{code, retired_version | nil}]` in file order. Fails the test on a line
  that is neither `<code>` nor `<code> retired <version>`.
  """
  def ledger do
    for line <- String.split(File.read!("test/stability/codes.txt"), "\n", trim: true),
        not String.starts_with?(line, "#") do
      case String.split(line) do
        [code] ->
          {code, nil}

        [code, "retired", version] ->
          {code, version}

        _ ->
          ExUnit.Assertions.flunk(
            "test/stability/codes.txt: a line is `<code>` or `<code> retired <version>`: #{inspect(line)}"
          )
      end
    end
  end

  @doc """
  Every compile error code of the registry, in registry order, read when
  called: `%{code:, kind:, example:, rewrite:, retired:}`. `kind` is
  `:error`, `:subset`, `:planned` or `:retired`; `example` and `rewrite` are
  kernel source or nil (a code the build environment raises has no example,
  nor has a retired one); `retired` is the version that retired the code, or
  nil. The registry's own keys are not promised; this shape is.
  """
  def registry do
    for e <- Defk.Errors.entries() do
      %{
        code: e.code,
        kind: e.kind,
        example: e[:example],
        rewrite: e[:rewrite],
        retired: get_in(e, [:retired, :version])
      }
    end
  end

  @doc """
  The codes the compiler's source names, as string literals in `lib/`
  (other than the registry itself and `Defk.Test`, whose strings are message
  fragments): the codes defk can raise. A MapSet.
  """
  def raised_codes do
    src =
      (Path.wildcard("lib/**/*.ex") -- ["lib/defk/errors.ex", "lib/defk/test.ex"])
      |> Enum.map_join("\n", &File.read!/1)

    ~r/"([a-z0-9]+(?:-[a-z0-9]+)+|recursion|pipe)"[,)]/
    |> Regex.scan(src)
    |> MapSet.new(&Enum.at(&1, 1))
  end

  @doc """
  The frozen API snapshots, `test/stability/<version>/api.exs`, every
  release: `[map]` as the freeze task wrote them.
  """
  def api_snapshots do
    for path <- api_paths(), do: path |> Code.eval_file() |> elem(0)
  end

  @doc "The paths of the frozen API snapshots, for `@external_resource`."
  def api_paths, do: Enum.sort(Path.wildcard("test/stability/*/api.exs"))
end
