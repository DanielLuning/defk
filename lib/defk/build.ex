defmodule Defk.Build do
  @moduledoc false
  # Compile generated C with the system C compiler, cached by hash.

  @priv Path.expand("../../priv", __DIR__)

  def build!(module, src, file) do
    dir = Path.join(build_root(), "defk")
    File.mkdir_p!(dir)
    hash = :erlang.md5([src, File.read!(Path.join(@priv, "defk_runtime.h"))]) |> Base.encode16(case: :lower)
    base = Path.join(dir, "#{module}-#{binary_part(hash, 0, 10)}")

    unless File.exists?(base <> ".so") do
      File.write!(base <> ".c", src)
      cc = System.get_env("CC", "cc")

      args =
        ~w(-O3 -std=gnu11 -fPIC -shared -Wall -Wno-unused-label -Wno-unused-variable) ++
          ["-I", erts_include(), "-I", @priv, "-o", base <> ".so", base <> ".c"] ++
          if(match?({:unix, :darwin}, :os.type()), do: ~w(-undefined dynamic_lookup), else: [])

      case System.cmd(cc, args, stderr_to_stdout: true) do
        {_, 0} -> :ok
        {out, _} -> raise CompileError, file: file, line: 0, description: "defk: C compilation failed (#{base}.c):\n" <> out
      end
    end

    base
  end

  defp build_root do
    if Code.ensure_loaded?(Mix.Project) and Mix.Project.get(), do: Mix.Project.build_path(), else: System.tmp_dir!()
  end

  defp erts_include do
    Path.join([to_string(:code.root_dir()), "erts-#{:erlang.system_info(:version)}", "include"])
  end
end
