defmodule Defk.Build do
  @moduledoc false
  # Compile generated C with the system C compiler, cached by hash.

  # compile-time attribute for the same reason as lib/defk.ex
  # credo:disable-for-next-line ExSlop.Check.Warning.PathExpandPriv
  @priv Path.expand("../../priv", __DIR__)

  # The cache key (see cache_key/2) covers: these cflags, the generated C
  # source, the contents of priv/defk_runtime.h and the generated
  # priv/defk_messages.h it includes, the ERTS version (whose
  # erl_nif.h the library is built against), the resolved compiler (`CC` or
  # "cc") and the first line of its `--version` output, and the sanitizer
  # mode's flags (`DEFK_SANITIZE`, sanitize/0).
  # -ffp-contract=off: never fuse a*b+c into an FMA, whose single rounding
  # differs from Elixir's in the last bit. Float results must be bit-exact
  # with Elixir mode, so no -ffast-math or reassociation either.
  # Hardening flags: -fstack-protector-strong, -D_FORTIFY_SOURCE=2,
  # -fno-strict-overflow. Measured 2026-10-08: 7 interleaved rounds against the
  # unflagged baseline, best-of per round, sum/dot/count_primes/count_primes_early.
  # Worst metric: +1.64% (all three combined, count_primes_early); worst per-flag
  # +1.62% (fno-strict-overflow) — all under the 2% bar. Adopted.
  # -fno-builtin: libm calls are never fused or substituted. With
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

  # The sanitizer build mode, `DEFK_SANITIZE`: a comma-separated
  # list of the keys below, appended after @cflags (so they win), plus
  # @sanitize_common. `undefined` stops at the first report
  # (-fno-sanitize-recover), so a test run cannot pass with one; `trap` is
  # UBSan with no runtime (SIGTRAP, no message: docs/research/
  # c-verification-macos.md §1). DEFK_SANITIZE_ADDRESS turns on the poisoning
  # of ERTS's binary slack in priv/defk_runtime.h (defk_poison_slack).
  @sanitizers %{
    "address" => ~w(-fsanitize=address -fno-common -DDEFK_SANITIZE_ADDRESS=1),
    "undefined" => ~w(-fsanitize=undefined -fno-sanitize-recover=undefined),
    "trap" => ~w(-fsanitize=undefined -fsanitize-trap=undefined)
  }
  @sanitize_common ~w(-g -fno-omit-frame-pointer)

  def build!(module, src, file) do
    modes = sanitize()
    base = lib_base(module, src)

    unless File.exists?(base <> ".so") do
      File.write!(base <> ".c", src)
      {cc, pre} = compiler()

      args =
        pre ++
          @cflags ++
          sanitize_flags(modes) ++
          ["-I", erts_include(), "-I", @priv, "-o", base <> ".so", base <> ".c"] ++
          if(match?({:unix, :darwin}, :os.type()), do: ~w(-undefined dynamic_lookup), else: [])

      run_cc!(cc, args, module, file, base)
    end

    base
  end

  @doc false
  # The library for `src`: `{:ok, base}` from build!/3, or `:no_cc` when
  # `DEFK_NO_CC` is set and the cache has no library with this key. With
  # `DEFK_NO_CC=1` the C is generated (and dumped, DEFK_DUMP_C) but never
  # compiled: the byte-identical gate and the compiler-time rounds need only
  # the C text. A library already in the cache is still used: it costs
  # nothing.
  @spec library(module(), binary(), String.t() | nil) :: {:ok, String.t()} | :no_cc
  def library(module, src, file) do
    if no_cc?() and not File.exists?(lib_base(module, src) <> ".so"),
      do: :no_cc,
      else: {:ok, build!(module, src, file)}
  end

  @doc false
  @spec no_cc?() :: boolean()
  def no_cc?, do: System.get_env("DEFK_NO_CC") in ["1", "true"]

  defp lib_base(module, src) do
    dir = Path.join(build_root(), "defk")
    File.mkdir_p!(dir)
    Path.join(dir, "#{module}-#{cache_key(src)}#{sanitize_suffix(sanitize())}")
  end

  @doc false
  # The compiler to run and the arguments it needs first. An
  # explicit CC runs as given. With CC unset, macOS's `cc` is an xcrun shim
  # that looks up the toolchain and the SDK on every call: about 95 ms of a
  # 120 ms kernel compile. So the clang it runs and the SDK it passes are
  # resolved once per VM. The cache key still names `cc` and its version
  # (cache_key/1): it is the same compiler, so no cached library is rebuilt.
  @spec compiler() :: {String.t(), [String.t()]}
  def compiler do
    case System.get_env("CC") do
      nil -> resolved_cc()
      cc -> {cc, []}
    end
  end

  defp resolved_cc do
    key = {__MODULE__, :resolved_cc}

    case :persistent_term.get(key, nil) do
      nil ->
        resolved = resolve_cc(:os.type(), &System.cmd/3)
        :persistent_term.put(key, resolved)
        resolved

      resolved ->
        resolved
    end
  end

  @doc false
  # `cmd` is System.cmd/3, or a test's stand-in. Any failure falls back to
  # the plain `cc`, which then works or fails exactly as before.
  @spec resolve_cc(tuple(), (String.t(), [String.t()], keyword() -> {String.t(), integer()})) ::
          {String.t(), [String.t()]}
  def resolve_cc({:unix, :darwin}, cmd) do
    with {:ok, clang} <- xcrun(cmd, ["-f", "clang"]),
         true <- File.regular?(clang),
         {:ok, sdk} when sdk != "" <- xcrun(cmd, ["--show-sdk-path"]) do
      {clang, ["-isysroot", sdk]}
    else
      _ -> {"cc", []}
    end
  end

  def resolve_cc(_os, _cmd), do: {"cc", []}

  defp xcrun(cmd, args) do
    case cmd.("xcrun", args, stderr_to_stdout: true) do
      {out, 0} -> {:ok, String.trim(out)}
      _ -> :error
    end
  rescue
    ErlangError -> :error
  end

  @doc """
  The sanitizer build mode, from `DEFK_SANITIZE`: `[]` (unset or empty: a
  normal build) or the sorted list of its modes, `"address"`, `"undefined"`
  and `"trap"`. Raises `ArgumentError` on any other value, and on
  `undefined` with `trap` (they are two ways to run UBSan).
  """
  @spec sanitize() :: [String.t()]
  def sanitize, do: parse_sanitize(System.get_env("DEFK_SANITIZE", ""))

  @doc """
  The environment variables the build reads, each with its tier: `:public`
  ones are promised (the stability guide, "The public API"), `:unstable` ones
  may change in any release ("What it does not cover"). `mix
  defk.stability.freeze` writes the public ones into a release's API
  snapshot, and the docs checks hold the guide to the unstable ones.
  """
  @spec env_vars() :: [{String.t(), :public | :unstable}]
  def env_vars, do: [{"CC", :public}, {"ERTS_INCLUDE_DIR", :public}, {"DEFK_SANITIZE", :unstable}]

  @doc false
  @spec parse_sanitize(String.t()) :: [String.t()]
  def parse_sanitize(value) do
    modes =
      value
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()
      |> Enum.sort()

    case Enum.reject(modes, &Map.has_key?(@sanitizers, &1)) do
      [] ->
        :ok

      bad ->
        raise ArgumentError,
              "DEFK_SANITIZE: unknown mode #{Enum.map_join(bad, ", ", &inspect/1)} in " <>
                "#{inspect(value)}; expected a comma-separated list of address, undefined, trap"
    end

    if "undefined" in modes and "trap" in modes do
      raise ArgumentError,
            "DEFK_SANITIZE: undefined and trap are two ways to run UBSan; pick one, got #{inspect(value)}"
    end

    modes
  end

  @doc """
  The compiler flags the sanitizer `modes` (`sanitize/0`) add after the
  normal ones: `[]` for a normal build.
  """
  @spec sanitize_flags([String.t()]) :: [String.t()]
  def sanitize_flags([]), do: []

  def sanitize_flags(modes),
    do: Enum.flat_map(modes, &Map.fetch!(@sanitizers, &1)) ++ @sanitize_common ++ libsan(modes)

  # A shared object built by clang off macOS has its sanitizer runtime
  # undefined (only an executable links it in), so the kernel library fails
  # to load: -shared-libsan links the shared runtime instead, as macOS clang
  # and gcc do by default, with an rpath to clang's runtime directory, which
  # the loader does not search. `trap` has no runtime.
  defp libsan(modes) do
    runtime? = Enum.any?(modes, &(&1 in ["address", "undefined"]))

    with true <- runtime? and not match?({:unix, :darwin}, :os.type()) and clang?(),
         dir when is_binary(dir) <- clang_runtime_dir(System.get_env("CC", "cc")) do
      ["-shared-libsan", "-Wl,-rpath,#{dir}"]
    else
      _ -> []
    end
  end

  # the directory of clang's runtime libraries (its builtins library is one)
  defp clang_runtime_dir(cc) do
    key = {__MODULE__, :clang_runtime_dir, cc}

    case :persistent_term.get(key, nil) do
      nil ->
        dir = probe_clang_runtime_dir(cc)
        if dir, do: :persistent_term.put(key, dir)
        dir

      dir ->
        dir
    end
  end

  defp probe_clang_runtime_dir(cc) do
    case System.cmd(cc, ["-print-libgcc-file-name", "--rtlib=compiler-rt"]) do
      {out, 0} -> out |> String.trim() |> Path.dirname()
      _ -> nil
    end
  rescue
    _ -> nil
  end

  # A sanitizer library's file name says so (`<Module>-<key>-san-address.so`):
  # the key already differs, the name is for people reading _build.
  defp sanitize_suffix([]), do: ""
  defp sanitize_suffix(modes), do: "-san-" <> Enum.join(modes, "+")

  @doc """
  Where the module's library is loaded from at run time, after
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

  In the sanitizer mode (`sanitize/0`) a Mix app's module compiles only when
  `MIX_BUILD_PATH` is set: its `.beam` and its library land in
  that build path's `ebin/`, never in the normal one, where a sanitized
  library would replace the normal one and a later normal run would load it
  (an ASan library aborts a VM without the ASan runtime, before Mix can
  recompile the module).
  """
  @spec placement!(module(), String.t(), String.t() | nil) ::
          {:app, atom(), String.t(), String.t()} | {:path, String.t()}
  def placement!(module, base, file) do
    case owning_app(file) do
      {app, ebin} ->
        sanitize_build_path!(module, file)
        name = Path.basename(base) <> ".so"
        target = Path.join(ebin, name)
        unless File.exists?(target), do: install!(base <> ".so", target, module)
        {:app, app, name, target}

      nil ->
        {:path, base}
    end
  end

  defp sanitize_build_path!(module, file) do
    modes = sanitize()

    if modes != [] and System.get_env("MIX_BUILD_PATH", "") == "" do
      mode = Enum.join(modes, ",")

      raise CompileError,
        file: file,
        line: 0,
        description:
          "defk: #{inspect(module)} is compiled with DEFK_SANITIZE=#{mode} into its app's ebin/, " <>
            "which would put a sanitized library where normal runs load it. Give the sanitizer " <>
            "build a build path of its own, e.g. " <>
            "MIX_BUILD_PATH=_build/#{Mix.env()}_sanitize_#{Enum.join(modes, "_")} DEFK_SANITIZE=#{mode}"
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

    stale = ~r/\A#{Regex.escape(Atom.to_string(module))}-[0-9a-f]{10}(-san-[a-z+]+)?\.so\z/

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
        do: reraise(Defk.Errors.Diagnostics.no_compiler(module, file, cc), __STACKTRACE__),
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
      {cc, pre} = compiler()

      case System.cmd(cc, pre ++ args, stderr_to_stdout: true) do
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
  # copied _build or a restored CI cache. The basename carries the
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
  first line of `cc --version`, the sanitizer mode's flags) and delegates to
  `cache_key/2`.
  """
  @spec cache_key(binary()) :: String.t()
  def cache_key(src) do
    cc = System.get_env("CC", "cc")

    cache_key(src, %{
      erts: to_string(:erlang.system_info(:version)) <> erts_include_override(),
      cc: cc,
      cc_version: cc_version(cc),
      sanitize: sanitize_flags(sanitize())
    })
  end

  @doc """
  Pure cache key: md5 over the cflags, the C source, the runtime header
  contents, the `:erts`, `:cc` and `:cc_version` strings in `env`, and the
  sanitizer flags in `env[:sanitize]` (`[]` or absent for a
  normal build, which leaves the key as it was before the mode existed).
  Returns the first 10 lowercase hex chars.
  """
  @spec cache_key(binary(), %{
          required(:erts) => String.t(),
          required(:cc) => String.t(),
          required(:cc_version) => String.t(),
          optional(:sanitize) => [String.t()]
        }) :: String.t()
  def cache_key(src, %{erts: erts, cc: cc, cc_version: cc_version} = env) do
    header = File.read!(Path.join(@priv, "defk_runtime.h"))
    messages = File.read!(Path.join(@priv, "defk_messages.h"))

    [@cflags, src, header, messages, erts, cc, cc_version, Map.get(env, :sanitize, [])]
    |> :erlang.md5()
    |> Base.encode16(case: :lower)
    |> binary_part(0, 10)
  end

  @doc """
  A 64-bit hash of the runtime header, the base of the frame layout tag
  (`DEFK_LAYOUT_TAG`): a frame stamped by a different header never
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
