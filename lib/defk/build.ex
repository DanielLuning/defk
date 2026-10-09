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
  @cflags ~w(-O3 -ffp-contract=off -std=gnu11 -fPIC -shared -Wall -Wno-unused-label -Wno-unused-variable -fstack-protector-strong -D_FORTIFY_SOURCE=2 -fno-strict-overflow)

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

  defp build_root do
    if Code.ensure_loaded?(Mix.Project) and Mix.Project.get(),
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
