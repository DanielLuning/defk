defmodule Defk.BuildTest do
  use ExUnit.Case, async: false

  @env %{erts: "15.2.1", cc: "cc", cc_version: "Apple clang version 17.0.0"}
  @src "int f(void) { return 1; }"

  test "identical inputs give the same 10-hex-char key" do
    key = Defk.Build.cache_key(@src, @env)
    assert key == Defk.Build.cache_key(@src, @env)
    assert key =~ ~r/\A[0-9a-f]{10}\z/
  end

  test "changing the ERTS version changes the key" do
    refute Defk.Build.cache_key(@src, @env) ==
             Defk.Build.cache_key(@src, %{@env | erts: "16.0"})
  end

  test "changing the compiler changes the key" do
    refute Defk.Build.cache_key(@src, @env) ==
             Defk.Build.cache_key(@src, %{@env | cc: "gcc"})
  end

  test "changing the compiler version changes the key" do
    refute Defk.Build.cache_key(@src, @env) ==
             Defk.Build.cache_key(@src, %{@env | cc_version: "gcc 14.1"})
  end

  test "changing the source changes the key" do
    refute Defk.Build.cache_key(@src, @env) == Defk.Build.cache_key(@src <> " ", @env)
  end

  test "the convenience wrapper is stable within a run" do
    assert Defk.Build.cache_key(@src) == Defk.Build.cache_key(@src)
  end

  describe "environment" do
    setup do
      saved = Map.new(["CC", "ERTS_INCLUDE_DIR"], &{&1, System.get_env(&1)})

      on_exit(fn ->
        for {k, v} <- saved, do: if(v, do: System.put_env(k, v), else: System.delete_env(k))
      end)
    end

    test "a missing compiler raises the actionable error and leaves no .so" do
      cc = Path.join(System.tmp_dir!(), "defk-no-such-cc-#{System.unique_integer([:positive])}")
      System.put_env("CC", cc)
      mod = "Defk.BuildTest.NoCc#{System.unique_integer([:positive])}"

      error =
        assert_raise CompileError, fn ->
          Code.compile_string("""
          defmodule #{mod} do
            use Defk
            defk f(x :: i64) :: i64, do: x + 1
          end
          """)
        end

      msg = Exception.message(error)
      assert msg =~ "error: cannot compile #{mod}: C compiler `#{cc}` not found"
      assert msg =~ "why: a kernel is compiled to native code at build time"
      assert msg =~ "xcode-select --install"
      assert msg =~ "apt install build-essential"
      assert msg =~ "apk add build-base"
      assert msg =~ "(defk no-c-compiler"

      dir = Path.join(Mix.Project.build_path(), "defk")
      assert Path.wildcard(Path.join(dir, "#{mod}-*.so")) == []
    end

    test "a kernel module asks Mix to recompile when CC or ERTS_INCLUDE_DIR changes" do
      System.put_env("CC", System.get_env("CC") || "cc")
      System.delete_env("ERTS_INCLUDE_DIR")
      mod = Module.concat(Defk.BuildTest, "Hook#{System.unique_integer([:positive])}")

      Code.compile_string("""
      defmodule #{inspect(mod)} do
        use Defk
        defk f(x :: i64) :: i64, do: x + 1
      end
      """)

      assert mod.__mix_recompile__?() == false

      original = System.get_env("CC")
      System.put_env("CC", original <> "-other")
      assert mod.__mix_recompile__?()
      System.put_env("CC", original)
      assert mod.__mix_recompile__?() == false

      System.delete_env("CC")
      assert mod.__mix_recompile__?()
      System.put_env("CC", original)

      System.put_env("ERTS_INCLUDE_DIR", "/somewhere")
      assert mod.__mix_recompile__?()
      System.delete_env("ERTS_INCLUDE_DIR")
      assert mod.__mix_recompile__?() == false
    end

    test "ERTS_INCLUDE_DIR overrides the include dir" do
      System.delete_env("ERTS_INCLUDE_DIR")
      default = Defk.Build.erts_include()
      assert default =~ "erts-"

      dir = Path.join(System.tmp_dir!(), "defk-erts-include")
      System.put_env("ERTS_INCLUDE_DIR", dir)
      assert Defk.Build.erts_include() == dir

      with_override = Defk.Build.cache_key(@src)
      System.delete_env("ERTS_INCLUDE_DIR")
      refute with_override == Defk.Build.cache_key(@src)
      System.put_env("ERTS_INCLUDE_DIR", dir)

      System.put_env("ERTS_INCLUDE_DIR", "")
      assert Defk.Build.erts_include() == default
    end
  end
end
