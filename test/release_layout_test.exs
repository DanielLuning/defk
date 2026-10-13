defmodule Defk.ReleaseLayoutTest do
  # Where a kernel's library ships and loads from (defk-n8f): a Mix app's
  # module loads it from its app's ebin/, wherever the app is at load time, so
  # it travels with `mix release` and a moved _build; anything else loads it
  # from the absolute build path. The subprocess builds in a directory of its
  # own, so the module can run async.
  use ExUnit.Case, async: true

  @root Path.expand("..", __DIR__)

  test "an app module loads its library from its app's ebin/" do
    lib = Examples.Kernels.__defk_lib__()
    ebin = Path.join(to_string(:code.lib_dir(:defk)), "ebin")
    assert Path.dirname(lib) == ebin
    assert Path.basename(lib) =~ ~r/\AElixir\.Examples\.Kernels-[0-9a-f]{10}\.so\z/
    assert File.exists?(lib)
  end

  test "a module with no owning app (Code.compile_string) loads from the build path" do
    [{mod, _}] =
      Code.compile_string("""
      defmodule Defk.ReleaseLayoutTest.Script do
        use Defk
        defk f(x :: i64) :: i64, do: x + 1
      end
      """)

    lib = mod.__defk_lib__()
    assert Path.dirname(lib) == Path.join(Mix.Project.build_path(), "defk")
    assert mod.f(41) == 42
  end

  # A real Mix app depending on defk, compiled in a subprocess, then moved.
  @tag timeout: 600_000
  test "a compiled app runs from another directory without _build/<env>/defk" do
    tmp = Path.join(System.tmp_dir!(), "defk-n8f-#{System.unique_integer([:positive])}")
    app = Path.join(tmp, "app")
    on_exit(fn -> File.rm_rf!(tmp) end)

    File.mkdir_p!(Path.join(app, "lib"))
    File.mkdir_p!(Path.join(app, "priv"))
    File.write!(Path.join(app, "priv/keep.txt"), "source priv\n")

    File.write!(Path.join(app, "mix.exs"), """
    defmodule N8fApp.MixProject do
      use Mix.Project
      def project,
        do: [app: :n8f_app, version: "0.1.0", deps: [{:defk, path: #{inspect(@root)}}]]
    end
    """)

    File.write!(Path.join(app, "lib/n8f_app.ex"), """
    defmodule N8fApp do
      use Defk
      defk triple(x :: i64) :: i64, do: x * 3
    end
    """)

    mix!(app, ["compile"])

    ebin = Path.join(app, "_build/prod/lib/n8f_app/ebin")
    assert [so] = Path.wildcard(Path.join(ebin, "Elixir.N8fApp-*.so"))
    # the source priv/ (symlinked from _build in this layout) gains nothing
    assert File.ls!(Path.join(app, "priv")) == ["keep.txt"]

    # an unchanged kernel is a cache hit: a miss would rewrite the .c
    cache_c = Path.join(app, "_build/prod/defk/" <> Path.basename(so, ".so") <> ".c")
    File.rm!(cache_c)
    mix!(app, ["compile", "--force"])
    refute File.exists?(cache_c)
    assert Path.wildcard(Path.join(ebin, "Elixir.N8fApp-*.so")) == [so]

    # a changed kernel replaces its library in ebin/, the old one is removed
    File.write!(Path.join(app, "lib/n8f_app.ex"), """
    defmodule N8fApp do
      use Defk
      defk triple(x :: i64) :: i64, do: x + x + x
    end
    """)

    mix!(app, ["compile"])
    assert [new_so] = Path.wildcard(Path.join(ebin, "Elixir.N8fApp-*.so"))
    refute new_so == so
    so = new_so

    # a deleted library (and cache) is rebuilt by a plain compile: without it
    # the module's on_load fails, and Mix never asks __mix_recompile__?/0 of
    # a module that cannot load. Mix loads the old module once while it checks
    # for stale sources, so the compile prints that on_load failure, then
    # recompiles the module.
    File.rm!(so)
    File.rm_rf!(Path.join(app, "_build/prod/defk"))
    out = mix!(app, ["compile"])
    assert out =~ "The on_load function for module Elixir.N8fApp returned"
    assert out =~ "Compiling 1 file (.ex)"
    assert File.exists?(so)

    # move the compiled apps away and drop the whole _build
    moved = Path.join(tmp, "moved")
    File.mkdir_p!(moved)

    File.cp_r!(Path.join(app, "_build/prod/lib"), Path.join(moved, "lib"),
      dereference_symlinks: true
    )

    File.rm_rf!(Path.join(app, "_build"))

    {out, 0} =
      System.cmd(
        "elixir",
        [
          "-pa",
          Path.join(moved, "lib/n8f_app/ebin"),
          "-pa",
          Path.join(moved, "lib/defk/ebin"),
          "-e",
          "IO.inspect({N8fApp.triple(14), N8fApp.__defk_lib__()})"
        ],
        cd: tmp,
        env: [{"MIX_ENV", nil}],
        stderr_to_stdout: true
      )

    {result, lib} = out |> String.trim() |> Code.eval_string() |> elem(0)
    assert result == 42
    assert lib == Path.join([moved, "lib/n8f_app/ebin", Path.basename(so)])
  end

  defp mix!(dir, args) do
    {out, status} =
      System.cmd("mix", args,
        cd: dir,
        env: [{"MIX_ENV", "prod"}, {"MIX_BUILD_PATH", nil}, {"MIX_DEPS_PATH", nil}],
        stderr_to_stdout: true
      )

    assert status == 0, "mix #{Enum.join(args, " ")} failed:\n" <> out
    out
  end
end
