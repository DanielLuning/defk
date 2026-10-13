defmodule Defk.BuildTest do
  use ExUnit.Case, async: false
  import Defk.TestKit, only: [restore_env_on_exit: 1]

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

  describe "the compiler on macOS with CC unset (defk-h30)" do
    # xcrun's answers, by argument list
    defp xcrun(clang, sdk) do
      fn
        "xcrun", ["-f", "clang"], _ -> {clang <> "\n", 0}
        "xcrun", ["--show-sdk-path"], _ -> {sdk <> "\n", 0}
      end
    end

    setup do
      clang =
        Path.join(System.tmp_dir!(), "defk-fake-clang-#{System.unique_integer([:positive])}")

      File.write!(clang, "")
      on_exit(fn -> File.rm(clang) end)
      %{clang: clang}
    end

    test "resolves clang and the SDK once, instead of the cc shim per compile", %{clang: clang} do
      assert Defk.Build.resolve_cc({:unix, :darwin}, xcrun(clang, "/sdk")) ==
               {clang, ["-isysroot", "/sdk"]}
    end

    test "falls back to cc when xcrun is missing, fails, or names no file", %{clang: clang} do
      missing = fn _, _, _ -> raise ErlangError, original: :enoent end
      fails = fn _, _, _ -> {"xcrun: error: unable to find utility", 72} end

      for cmd <- [missing, fails, xcrun(clang <> "-gone", "/sdk"), xcrun(clang, "")] do
        assert Defk.Build.resolve_cc({:unix, :darwin}, cmd) == {"cc", []}
      end
    end

    test "other systems run cc as before" do
      no_call = fn _, _, _ -> flunk("ran a command") end
      assert Defk.Build.resolve_cc({:unix, :linux}, no_call) == {"cc", []}
    end
  end

  describe "environment" do
    setup do
      restore_env_on_exit(["CC", "ERTS_INCLUDE_DIR"])
    end

    test "an explicit CC runs as given, with no SDK argument" do
      System.put_env("CC", "gcc-14")
      assert Defk.Build.compiler() == {"gcc-14", []}
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
