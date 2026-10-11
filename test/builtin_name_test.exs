defmodule Defk.BuiltinNameTest.K do
  # kernels that reuse a builtin's name at an arity the builtin does not take:
  # calls are looked up by name and arity, so each reaches the kernel
  use Defk, elixir_mode: true

  defk log(x :: f64, base :: f64) :: f64 do
    log(x) / log(base)
  end

  defk alloc(n :: i64) :: i64 do
    n + 1
  end

  defk clz(x :: i64, y :: i64, z :: i64) :: i64 do
    x + y + z
  end

  defk min(a :: i64, b :: i64, c :: i64) :: i64 do
    min(a, min(b, c))
  end

  defk go(x :: i64) :: i64 do
    clz(x, 1, 2) + alloc(x) + min(x, 7, 9) + clz(x)
  end
end

defmodule Defk.BuiltinNameTest do
  use ExUnit.Case, async: true

  alias Defk.BuiltinNameTest.K

  @dir Path.join(System.tmp_dir!(), "defk_builtin_name_test")

  defp compile(body) do
    File.mkdir_p!(@dir)
    mod = "Defk.BuiltinNameTest.M#{System.unique_integer([:positive])}"
    path = Path.join(@dir, "#{String.replace(mod, ".", "_")}.ex")
    File.write!(path, "defmodule #{mod} do\n  use Defk\n\n#{body}\nend\n")

    try do
      Code.compile_file(path)
      :ok
    rescue
      e in CompileError -> Exception.message(e)
    end
  end

  test "a kernel named like a builtin at its arity is rejected with a rename hint" do
    msg =
      compile("""
      defk copy_back(out :: [u8], op :: i64, off :: i64, ln :: i64) :: [u8] do
        out
      end

      defk f(out :: [u8]) :: [u8] do
        copy_back(out, 0, 1, 1)
      end
      """)

    assert msg =~ "error: copy_back/4 is a builtin"
    assert msg =~ "why: `copy_back/4` is a builtin, so calls to it would reach the builtin"
    assert msg =~ "defk my_copy_back(out :: [u8], op :: i64, off :: i64, ln :: i64) :: [u8]"
    assert msg =~ "(defk builtin-name: "
    # one error, at the defk line, and none from the call of it
    assert [_] = Regex.scan(~r/^error: /m, msg)
    assert msg =~ ~r/4 │\s*defk copy_back/
  end

  test "each clashing kernel is one error" do
    msg =
      compile("""
      defk popcount(x :: i64) :: i64, do: x
      defk clz(x :: i64, w :: i64) :: i64, do: x
      defk crc32c(c :: i64, x :: i64, w :: i64) :: i64, do: c
      """)

    assert [_, _, _] = Regex.scan(~r/^\(defk builtin-name: /m, msg)
  end

  test "every builtin's arities are rejected" do
    for name <- Defk.Builtins.all(), arity <- Defk.Builtins.arities(name) do
      assert Defk.Builtins.builtin?(name, arity)
    end

    assert Defk.Builtins.arities(:clz) == [1, 2]
    refute Defk.Builtins.builtin?(:log, 2)
  end

  test "the same name at another arity is a kernel, in native code and Elixir mode" do
    assert {:ok, 68} = Defk.Test.assert_agrees(K, :go, [0])
    assert {:ok, 3.0} = Defk.Test.assert_agrees(K, :log, [8.0, 2.0]) |> approx()
  end

  defp approx({:ok, v}), do: {:ok, Float.round(v, 6)}
end
