defmodule Defk.Build do
  @moduledoc false
  # Compile generated C with the system C compiler, cached by hash.

  # compile-time attribute for the same reason as lib/defk.ex
  # credo:disable-for-next-line ExSlop.Check.Warning.PathExpandPriv
  @priv Path.expand("../../priv", __DIR__)

  # The cache key (see cache_key/2) covers: these cflags, the generated C
  # source, the contents of priv/defk_runtime.h, the ERTS version (whose
  # erl_nif.h the library is built against), the resolved compiler (`CC` or
  # "cc") and the first line of its `--version` output.
  # -ffp-contract=off: never fuse a*b+c into an FMA, whose single rounding
  # differs from Elixir's in the last bit. Float results must be bit-exact
  # with Elixir mode, so no -ffast-math or reassociation either (defk-jlk).
  # Hardening flags (defk-j5n): -fstack-protector-strong, -D_FORTIFY_SOURCE=2,
  # -fno-strict-overflow. Measured 2026-10-08: 7 interleaved rounds against the
  # unflagged baseline, best-of per round, sum/dot/count_primes/count_primes_early.
  # Worst metric: +1.64% (all three combined, count_primes_early); worst per-flag
  # +1.62% (fno-strict-overflow) — all under the 2% bar. Adopted.
  # -fno-builtin (defk-6g6): libm calls are never fused or substituted. With
  # cos(a) and sin(a) in one loop clang emits one sincos call (Darwin's
  # __sincos_stret, glibc's sincos) whose sin differs from :math.sin in the
  # last bit; -fno-builtin-sin -fno-builtin-cos -fno-builtin-sincos did NOT stop
  # it, only -fno-builtin did. It also stops pow(x, 2.0) -> x*x and
  # pow(x, 0.5) -> sqrt (the latter differs for -0.0 and -inf). Measured
  # 2026-10-09: 7 interleaved rounds against the build without it, best-of per
  # round (sum best-of-5, dot 5, count_primes 3, count_primes_early 5), plus a
  # second 7 rounds of count_primes_early alone (best of 15): flagged vs
  # unflagged, best across rounds: sum -0.71%, dot -0.16%, count_primes +0.15%,
  # count_primes_early +2.30% (first run) and +0.88% (second). Single rounds
  # swing -8%..+6% either way on this machine, and the loop of
  # count_primes_early calls no builtin, so the worst case is noise-level:
  # +2.3% at the very worst, about +1% on the mean of rounds. Adopted.
  @cflags ~w(-O3 -ffp-contract=off -std=gnu11 -fPIC -shared -Wall -Wno-unused-label -Wno-unused-variable -fstack-protector-strong -D_FORTIFY_SOURCE=2 -fno-strict-overflow -fno-builtin)

  def build!(module, src, file) do
    dir = Path.join(build_root(), "defk")
    File.mkdir_p!(dir)

    base = Path.join(dir, "#{module}-#{cache_key(src)}")

    unless File.exists?(base <> ".so") do
      File.write!(base <> ".c", src)
      cc = System.get_env("CC", "cc")

      args =
        @cflags ++
          ["-I", erts_include(), "-I", @priv, "-o", base <> ".so", base <> ".c"] ++
          if(match?({:unix, :darwin}, :os.type()), do: ~w(-undefined dynamic_lookup), else: [])

      run_cc!(cc, args, module, file, base)
    end

    base
  end

  @doc """
  Where the module's library is loaded from at run time (defk-n8f), after
  `build!/3` built it at `base`.

  A module compiled by Mix from its project's `elixirc_paths` (a `.ex` file)
  belongs to that Mix app: its library is copied into the app's `ebin/`
  directory (`Mix.Project.compile_path/0`) as `<Module>-<key>.so`, beside its
  `.beam`, and `{:app, app, name, fallback}` says to load it from
  `:code.lib_dir(app)/ebin/<name>` at load time, or from the absolute
  `fallback` (that copy) when `app` is not in the code path. `ebin/` is
  always a real directory in `_build` (`priv/` is a symlink to the source
  `priv/` in dev, which must not gain build output) and `mix release` copies
  all of it, so the library ships with the release and survives relocation.
  The cache stays in `_build/<env>/defk`: the copy is made only when
  missing, and older libraries of the same module are removed from `ebin/`.

  Any other module (a script, `Mix.install`, `Code.compile_string/2`, a test
  file) gets `{:path, base}`: the absolute build path, as before.
  """
  @spec placement!(module(), String.t(), String.t() | nil) ::
          {:app, atom(), String.t(), String.t()} | {:path, String.t()}
  def placement!(module, base, file) do
    case owning_app(file) do
      {app, ebin} ->
        name = Path.basename(base) <> ".so"
        target = Path.join(ebin, name)
        unless File.exists?(target), do: install!(base <> ".so", target, module)
        {:app, app, name, target}

      nil ->
        {:path, base}
    end
  end

  # {app, ebin} when `file` is compiled by Mix into its project's ebin
  defp owning_app(file) do
    with true <- is_binary(file) and Path.extname(file) == ".ex",
         true <- mix_project?(),
         config = Mix.Project.config(),
         app when is_atom(app) and app != nil <- config[:app],
         true <- in_elixirc_paths?(file, config) do
      {app, Mix.Project.compile_path(config)}
    else
      _ -> nil
    end
  end

  defp in_elixirc_paths?(file, config) do
    root = Path.dirname(Mix.Project.project_file() || Path.join(File.cwd!(), "mix.exs"))
    file = Path.expand(file)

    config
    |> Keyword.get(:elixirc_paths, ["lib"])
    |> Enum.any?(fn p ->
      p = Path.expand(p, root)
      file == p or String.starts_with?(file, p <> "/")
    end)
  end

  # Copy atomically (another VM compiling the same app never sees a torn
  # file), then drop this module's libraries with another key.
  defp install!(src, target, module) do
    dir = Path.dirname(target)
    File.mkdir_p!(dir)
    tmp = "#{target}.#{System.pid()}.#{System.unique_integer([:positive])}.tmp"
    File.cp!(src, tmp)
    File.rename!(tmp, target)

    stale = ~r/\A#{Regex.escape(Atom.to_string(module))}-[0-9a-f]{10}\.so\z/

    for f <- File.ls!(dir), f != Path.basename(target), f =~ stale do
      File.rm(Path.join(dir, f))
    end

    :ok
  end

  # Run the compiler. A failed build never leaves a half-written .so behind,
  # or the next build would take it for a cache hit.
  defp run_cc!(cc, args, module, file, base) do
    case System.cmd(cc, args, stderr_to_stdout: true) do
      {_, 0} ->
        :ok

      {out, _} ->
        File.rm(base <> ".so")

        raise CompileError,
          file: file,
          line: 0,
          description: "defk: C compilation failed (#{base}.c):\n" <> out
    end
  rescue
    e in ErlangError ->
      File.rm(base <> ".so")

      if e.original == :enoent,
        do: reraise(Defk.Errors.no_compiler(module, file, cc), __STACKTRACE__),
        else: reraise(e, __STACKTRACE__)
  end

  # The fast-path report's remark pass (`use Defk, report: :full`): the same
  # compile with clang's loop-vectorize remarks, to an object file that is
  # thrown away, so the cached .so is never touched. -gline-tables-only gives
  # the remarks their C lines and does not change what the optimiser does.
  # The remarks are cached beside the .so, named by these flags too.
  @remark_flags ~w(-gline-tables-only -Rpass=loop-vectorize -Rpass-missed=loop-vectorize -Rpass-analysis=loop-vectorize)

  @doc """
  Whether `CC` (or "cc") is clang, by the first line of its `--version`.
  """
  @spec clang?() :: boolean()
  def clang?, do: System.get_env("CC", "cc") |> cc_version() |> String.contains?("clang")

  @doc """
  clang's loop-vectorize remarks on the C source `src` of the library at
  `base` (from `build!/3`), in the order clang gave them: `{:ok, [{file,
  line, kind, message}]}`, kind `:passed`, `:missed` or `:analysis`, or
  `{:error, output}` if the pass failed. Run only for `report: :full`, and
  only when `clang?/0`.
  """
  @spec remarks!(binary(), String.t()) ::
          {:ok, [{String.t(), pos_integer(), atom(), String.t()}]} | {:error, String.t()}
  def remarks!(src, base) do
    tag = @remark_flags |> :erlang.md5() |> Base.encode16(case: :lower) |> binary_part(0, 6)
    cached = "#{base}-#{tag}.remarks"

    # A cached file with no remark line in it is a torn or empty write, never
    # a real result (the runtime header alone always gives loop remarks): it
    # is a miss. A fresh pass is written atomically (temp file, then rename),
    # so a reader in another VM, or a killed writer, never leaves one behind.
    with {:error, _} <- cached_remarks(cached),
         {:ok, out} <- remark_pass(src, base) do
      if String.contains?(out, ": remark: "), do: write_atomic!(cached, out)
      {:ok, parse_remarks(out)}
    else
      {:ok, out} -> {:ok, parse_remarks(out)}
      {:error, out} -> {:error, out}
    end
  end

  defp cached_remarks(path) do
    case File.read(path) do
      {:ok, out} -> if String.contains?(out, ": remark: "), do: {:ok, out}, else: {:error, ""}
      error -> error
    end
  end

  defp write_atomic!(path, data) do
    tmp = "#{path}.#{System.pid()}.#{System.unique_integer([:positive])}.tmp"
    File.write!(tmp, data)
    File.rename!(tmp, path)
  end

  defp remark_pass(src, base) do
    c = base <> ".c"
    File.exists?(c) || File.write!(c, src)
    obj = "#{base}-remarks-#{System.pid()}-#{System.unique_integer([:positive])}.o"

    args =
      (@cflags -- ["-shared"]) ++
        @remark_flags ++ ["-I", erts_include(), "-I", @priv, "-c", "-o", obj, c]

    try do
      case System.cmd(System.get_env("CC", "cc"), args, stderr_to_stdout: true) do
        {out, 0} -> {:ok, out}
        {out, _} -> {:error, out}
      end
    after
      File.rm(obj)
    end
  end

  @remark ~r/^(.+?):(\d+):\d+: remark: (.*) \[-Rpass(|-missed|-analysis)=loop-vectorize\]$/

  # The file is kept as its basename: the cached text names the .c of the
  # checkout that built it, which is not this one after a moved project, a
  # copied _build or a restored CI cache (defk-fr7). The basename carries the
  # module and the cache key, so it still names exactly this kernel's C.
  defp parse_remarks(out) do
    for line <- String.split(out, "\n"), [_, file, l, msg, kind] <- [Regex.run(@remark, line)] do
      kind = %{"" => :passed, "-missed" => :missed, "-analysis" => :analysis}[kind]
      {Path.basename(file), String.to_integer(l), kind, msg}
    end
  end

  @doc """
  Cache key for a generated kernel: the 10 hex chars used in the file name.

  Fills in the environment-dependent parts (ERTS version, resolved compiler,
  first line of `cc --version`) and delegates to `cache_key/2`.
  """
  @spec cache_key(binary()) :: String.t()
  def cache_key(src) do
    cc = System.get_env("CC", "cc")

    cache_key(src, %{
      erts: to_string(:erlang.system_info(:version)) <> erts_include_override(),
      cc: cc,
      cc_version: cc_version(cc)
    })
  end

  @doc """
  Pure cache key: md5 over the cflags, the C source, the runtime header
  contents, and the `:erts`, `:cc` and `:cc_version` strings in `env`.
  Returns the first 10 lowercase hex chars.
  """
  @spec cache_key(binary(), %{erts: String.t(), cc: String.t(), cc_version: String.t()}) ::
          String.t()
  def cache_key(src, %{erts: erts, cc: cc, cc_version: cc_version}) do
    header = File.read!(Path.join(@priv, "defk_runtime.h"))

    [@cflags, src, header, erts, cc, cc_version]
    |> :erlang.md5()
    |> Base.encode16(case: :lower)
    |> binary_part(0, 10)
  end

  @doc """
  A 64-bit hash of the runtime header, the base of the frame layout tag
  (`DEFK_LAYOUT_TAG`, defk-ls8): a frame stamped by a different header never
  passes the check.
  """
  @spec header_hash() :: non_neg_integer()
  def header_hash do
    <<h::64, _::binary>> = :erlang.md5(File.read!(Path.join(@priv, "defk_runtime.h")))
    h
  end

  # A cross-build's headers differ from the running ERTS's, so they key the cache.
  defp erts_include_override do
    case System.get_env("ERTS_INCLUDE_DIR", "") do
      "" -> ""
      dir -> "@" <> dir
    end
  end

  # First line of `<cc> --version`, "unknown" if it cannot be run. Memoised in
  # :persistent_term so a module with many kernels shells out once per cc.
  # "unknown" is not memoised, so a compiler installed later in the same VM is
  # picked up (the build raises when it is missing, so this costs one failed
  # exec per attempt).
  defp cc_version(cc) do
    key = {__MODULE__, :cc_version, cc}

    case :persistent_term.get(key, nil) do
      nil ->
        version = probe_cc_version(cc)
        if version != "unknown", do: :persistent_term.put(key, version)
        version

      version ->
        version
    end
  end

  defp probe_cc_version(cc) do
    case System.cmd(cc, ["--version"], stderr_to_stdout: true) do
      {out, 0} -> out |> String.split("\n", parts: 2) |> hd() |> String.trim()
      _ -> "unknown"
    end
  rescue
    _ -> "unknown"
  end

  @doc false
  # Whether a Mix project is running. Mix.Project can be loaded without Mix
  # started (`elixir script.exs`, an escript, a release that ships :mix),
  # and then Mix.Project.get/0 exits: check the project stack first.
  @spec mix_project?() :: boolean()
  def mix_project? do
    Code.ensure_loaded?(Mix.Project) and Process.whereis(Mix.ProjectStack) != nil and
      Mix.Project.get() != nil
  end

  defp build_root do
    if mix_project?(),
      do: Mix.Project.build_path(),
      else: System.tmp_dir!()
  end

  @doc """
  The directory holding `erl_nif.h`: `ERTS_INCLUDE_DIR` when set and non-empty
  (the elixir_make convention, for cross-builds), else the running ERTS's.
  """
  @spec erts_include() :: String.t()
  def erts_include do
    case System.get_env("ERTS_INCLUDE_DIR", "") do
      "" -> default_erts_include()
      dir -> dir
    end
  end

  defp default_erts_include do
    Path.join([to_string(:code.root_dir()), "erts-#{:erlang.system_info(:version)}", "include"])
  end
end
