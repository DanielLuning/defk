# Target levels for the defk-ulk.1 study, and a CC wrapper per level that
# adds the level's flags to defk's own (Defk.Build passes `CC` through and
# keys its cache on the compiler path, so each wrapper gets its own .so and
# its own remark cache). Research tooling, not part of defk.
defmodule Simd.Levels do
  @arm64 [
    # what Defk.Build gives today on macOS: Apple clang's default CPU
    {"default", []},
    # what a portable Linux/aarch64 build gets (armv8.0-a, generic tuning)
    {"generic", ~w(-mcpu=generic)},
    {"armv8.2-a", ~w(-march=armv8.2-a)},
    {"native", ~w(-mcpu=native)}
  ]

  # compiled for remarks only: never timed here (no x86-64 hardware)
  @x86 [
    {"x86-64", ~w(-target x86_64-apple-macos13 -march=x86-64)},
    {"x86-64-v2", ~w(-target x86_64-apple-macos13 -march=x86-64-v2)},
    {"x86-64-v3", ~w(-target x86_64-apple-macos13 -march=x86-64-v3)},
    {"x86-64-v4", ~w(-target x86_64-apple-macos13 -march=x86-64-v4)}
  ]

  # timed on real x86-64 hardware by bench/simd/time.exs (not on this Mac):
  # the host's own triple, so no -target
  @x86_timed [
    {"default", []},
    {"x86-64-v2", ~w(-march=x86-64-v2)},
    {"x86-64-v3", ~w(-march=x86-64-v3)},
    {"native", ~w(-march=native)}
  ]

  def arm64, do: @arm64
  def x86, do: @x86
  def all, do: @arm64 ++ @x86

  @doc """
  The levels bench/simd/time.exs times on this machine's architecture, or
  `SIMD_LEVELS="name:flag flag,name:flag"` (the first should be "default:").
  """
  def timed do
    case System.get_env("SIMD_LEVELS", "") do
      "" ->
        timed_for_arch()

      spec ->
        for l <- String.split(spec, ","),
            [n, f] = String.split(l, ":", parts: 2),
            do: {n, String.split(f)}
    end
  end

  defp timed_for_arch do
    arch = to_string(:erlang.system_info(:system_architecture))
    if String.starts_with?(arch, "x86_64"), do: @x86_timed, else: @arm64
  end

  @doc "Path of an executable `cc` wrapper adding `flags` (made on first use)."
  def wrapper(name, flags) do
    cc = System.get_env("SIMD_CC", "cc")
    dir = Path.join(System.tmp_dir!(), "defk-simd-cc")
    File.mkdir_p!(dir)
    path = Path.join(dir, "cc-" <> name)
    body = "#!/bin/sh\nexec #{cc} #{Enum.join(flags, " ")} \"$@\"\n"

    unless File.read(path) == {:ok, body} do
      File.write!(path, body)
      File.chmod!(path, 0o755)
    end

    path
  end
end
