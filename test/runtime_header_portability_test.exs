defmodule Defk.RuntimeHeaderPortabilityTest do
  use ExUnit.Case, async: true

  # The runtime header must compile cleanly on every compiler we support.
  # Passing an int64_t * where enif_get_int64 takes a long * (macOS) was only
  # a warning under Apple clang but an error under Homebrew LLVM, so no kernel
  # built there. The glibc half of the problem (__sigsetjmp redeclared
  # returns_twice, or a clang-built kernel's first raise is a Bus error) needs
  # Linux with CC=clang: raise_test.exs covers it there.

  defmodule K do
    use Defk

    defk add(a :: i64, b :: i64) :: i64 do
      a + b
    end
  end

  test "a kernel's C, runtime header included, has no incompatible pointer types" do
    dir = Path.join(System.tmp_dir!(), "defk_runtime_header_portability_test")
    File.mkdir_p!(dir)
    c = Path.join(dir, "k.c")
    File.write!(c, K.__defk_c_source__())
    priv = Application.app_dir(:defk, "priv")

    {out, status} =
      System.cmd(
        System.get_env("CC", "cc"),
        ~w(-fsyntax-only -std=gnu11 -Werror=incompatible-pointer-types) ++
          ["-I", Defk.Build.erts_include(), "-I", priv, c],
        stderr_to_stdout: true
      )

    assert status == 0, out
    refute out =~ "incompatible pointer types"
    assert K.add(2, 3) == 5
  end
end
