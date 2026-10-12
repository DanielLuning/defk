# A kernel module defined in the running node with Code.compile_string/2:
# built, loaded and called with no restart, redefined in place, and the same
# in a plain `elixir` process where Mix.Project is loadable but Mix is not
# started (it crashed in Mix.Project.get/0 before Defk.Build.mix_project?/0).
defmodule Defk.RuntimeDefineTest do
  use ExUnit.Case, async: true

  defp define(mod, op) do
    Code.compile_string("""
    defmodule #{inspect(mod)} do
      use Defk
      defk f(a :: i64, b :: i64) :: i64, do: a #{op} b
    end
    """)
  end

  test "defined, called and redefined in the running node" do
    mod = Module.concat(__MODULE__, "K")
    define(mod, "+")
    assert mod.f(2, 3) == 5
    lib = mod.__defk_lib__()
    assert Path.type(lib) == :absolute

    ExUnit.CaptureIO.capture_io(:stderr, fn -> define(mod, "*") end)
    assert mod.f(2, 3) == 6
    assert mod.__defk_lib__() != lib
  end

  test "a compile error is raised to the caller, as from a file" do
    assert_raise CompileError, fn ->
      Code.compile_string("""
      defmodule Defk.RuntimeDefineTest.Bad do
        use Defk
        defk f(x :: i64) :: i64, do: Enum.map(x, & &1)
      end
      """)
    end
  end

  @tag :tmp_dir
  test "in a plain elixir process, with Mix loadable but not started", %{tmp_dir: dir} do
    script = Path.join(dir, "define.exs")

    File.write!(script, ~S"""
    Code.compile_string(\"""
    defmodule RT.K do
      use Defk
      defk f(a :: i64, b :: i64) :: i64, do: a + b
    end
    \""")

    IO.puts("RESULT #{RT.K.f(2, 3)} #{RT.K.__defk_lib__()}")
    """)

    {out, status} =
      System.cmd("elixir", ["-pa", Mix.Project.compile_path(), script],
        env: [{"TMPDIR", dir}],
        stderr_to_stdout: true
      )

    assert status == 0, out
    assert [_, lib] = Regex.run(~r/RESULT 5 (\S+)/, out), out
    # no Mix project: the build goes to the system temp directory
    assert String.starts_with?(Path.expand(lib), Path.expand(dir))
  end
end
