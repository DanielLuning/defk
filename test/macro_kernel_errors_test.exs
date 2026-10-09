defmodule Defk.MacroKernelErrorsTest do
  # A kernel defined by a macro (a `use` that quotes a `defk`) has AST nodes
  # without a column: its errors render with `file:line` and no caret.
  use ExUnit.Case, async: true

  @dir Path.join(System.tmp_dir!(), "defk_macro_kernel_errors_test")

  defp compile(kernel) do
    File.mkdir_p!(@dir)
    n = System.unique_integer([:positive])
    path = Path.join(@dir, "m#{n}.ex")

    File.write!(path, """
    defmodule Defk.MacroKernelErrorsTest.Mac#{n} do
      defmacro __using__(_) do
        quote do
          use Defk

          #{kernel}
        end
      end
    end

    defmodule Defk.MacroKernelErrorsTest.User#{n} do
      use Defk.MacroKernelErrorsTest.Mac#{n}
    end
    """)

    try do
      Code.compile_file(path)
      :ok
    rescue
      e in CompileError -> Exception.message(e)
    end
  end

  test "an expression error renders with code, kernel and file:line, no crash" do
    msg =
      compile("""
      defk f(a :: i64) :: {i64, i64} do
            if a > 0, do: {a, 1}, else: {0, a}
          end
      """)

    assert is_binary(msg)
    assert msg =~ "error: "
    assert msg =~ ~r/└─ \S+\.ex:\d+: .*\.f\/1/
    assert msg =~ "(defk branch-tuple"
    refute msg =~ "^"
  end

  test "an unknown variable renders" do
    msg =
      compile("""
      defk g(a :: i64) :: i64 do
            a + zzz
          end
      """)

    assert is_binary(msg)
    assert msg =~ ~r/└─ \S+\.ex:\d+: .*\.g\/1/
    assert msg =~ "(defk "
  end

  test "a head error renders" do
    msg = compile("defk f(x) :: i64 do\n x\n end")

    assert is_binary(msg)
    assert msg =~ "error: "
    assert msg =~ ~r/└─ \S+\.ex:\d+/
    assert msg =~ "(defk "
  end
end
