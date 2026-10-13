defmodule Defk.SanitizeTest do
  # The sanitizer build mode, DEFK_SANITIZE (defk-96f.1): its flags, its place
  # in the cache key and the library's name, the build path a Mix app's module
  # needs, and the Mix recompile hook. These run in every `mix test` and need
  # no sanitizer runtime: the cache tests build with a fake compiler that
  # records its arguments.
  #
  # The tests tagged :sanitize build and run sanitized kernels, so they need
  # the toolchain's sanitizer runtimes and (for ASan) a second VM with the
  # runtime inserted; excluded by default:
  #
  #     mix test test/sanitize_test.exs --only sanitize
  use ExUnit.Case, async: false

  alias Defk.Build

  @vars ["CC", "DEFK_SANITIZE", "MIX_BUILD_PATH"]

  setup do
    saved = Map.new(@vars, &{&1, System.get_env(&1)})
    tmp = Path.join(System.tmp_dir!(), "defk_sanitize_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)

    on_exit(fn ->
      for {k, v} <- saved, do: if(v, do: System.put_env(k, v), else: System.delete_env(k))
      File.rm_rf!(tmp)
    end)

    %{tmp: tmp}
  end

  defp put_sanitize(nil), do: System.delete_env("DEFK_SANITIZE")
  defp put_sanitize(mode), do: System.put_env("DEFK_SANITIZE", mode)

  # A compiler that records each compile's arguments, one line per call, and
  # writes an empty library where -o says.
  defp fake_cc(tmp) do
    log = Path.join(tmp, "cc.log")
    cc = Path.join(tmp, "fake-cc")

    File.write!(cc, """
    #!/bin/sh
    if [ "$1" = "--version" ]; then echo "fake-cc 1.0"; exit 0; fi
    echo "$*" >> #{log}
    out=""; prev=""
    for a in "$@"; do [ "$prev" = "-o" ] && out="$a"; prev="$a"; done
    : > "$out"
    """)

    File.chmod!(cc, 0o755)
    {cc, log}
  end

  defp calls(log), do: log |> File.read!() |> String.split("\n", trim: true)

  defp build_dir, do: Path.join(Mix.Project.build_path(), "defk")

  defp cleanup(mod) do
    on_exit(fn ->
      for f <- Path.wildcard(Path.join(build_dir(), "#{mod}-*")), do: File.rm_rf!(f)
    end)
  end

  describe "the mode" do
    test "DEFK_SANITIZE is a comma-separated list, sorted and de-duplicated" do
      assert Build.parse_sanitize("") == []
      assert Build.parse_sanitize("address") == ["address"]
      assert Build.parse_sanitize("undefined, address") == ["address", "undefined"]
      assert Build.parse_sanitize("address,address,") == ["address"]
      assert Build.parse_sanitize("trap") == ["trap"]
    end

    test "an unknown mode, or undefined with trap, raises" do
      assert_raise ArgumentError, ~r/unknown mode "asan".*address, undefined, trap/, fn ->
        Build.parse_sanitize("asan")
      end

      assert_raise ArgumentError, ~r/undefined and trap are two ways to run UBSan/, fn ->
        Build.parse_sanitize("undefined,trap")
      end
    end

    test "each mode's flags, with debug info and frame pointers" do
      assert Build.sanitize_flags([]) == []

      address = Build.sanitize_flags(["address"])
      assert "-fsanitize=address" in address
      assert "-DDEFK_SANITIZE_ADDRESS=1" in address
      assert "-g" in address
      assert "-fno-omit-frame-pointer" in address

      assert "-fno-sanitize-recover=undefined" in Build.sanitize_flags(["undefined"])
      assert "-fsanitize-trap=undefined" in Build.sanitize_flags(["trap"])
      refute "-DDEFK_SANITIZE_ADDRESS=1" in Build.sanitize_flags(["undefined"])
    end

    test "the mode's flags are part of the cache key; a normal build's key is unchanged" do
      src = "int f(void) { return 1; }"
      env = %{erts: "17.0.3", cc: "cc", cc_version: "Apple clang version 21.0.0"}
      normal = Build.cache_key(src, env)

      assert Build.cache_key(src, Map.put(env, :sanitize, [])) == normal

      keys =
        for modes <- [["address"], ["undefined"], ["trap"], ["address", "undefined"]],
            do: Build.cache_key(src, Map.put(env, :sanitize, Build.sanitize_flags(modes)))

      assert [_, _, _, _, _] = Enum.uniq([normal | keys])
    end
  end

  describe "the cache" do
    # The spike behind the ticket saw an ASan library silently reused by a
    # later normal run (docs/research/c-verification-macos.md, finding 7).
    for {first, second} <- [{nil, "address"}, {"address", nil}, {"address", "undefined"}] do
      test "a #{first || "normal"} build, then a #{second || "normal"} build, never reuses the other's library",
           %{tmp: tmp} do
        {cc, log} = fake_cc(tmp)
        System.put_env("CC", cc)
        mod = :"Elixir.Defk.SanitizeTest.Cache#{System.unique_integer([:positive])}"
        cleanup(mod)
        src = "/* #{mod} */ int f(void) { return 1; }"

        put_sanitize(unquote(first))
        a = Build.build!(mod, src, nil)
        put_sanitize(unquote(second))
        b = Build.build!(mod, src, nil)

        refute a == b
        assert File.exists?(a <> ".so") and File.exists?(b <> ".so")
        assert [call_a, call_b] = calls(log)

        # each mode back again: its own library, from the cache
        put_sanitize(unquote(first))
        assert Build.build!(mod, src, nil) == a
        put_sanitize(unquote(second))
        assert Build.build!(mod, src, nil) == b
        assert [_, _] = calls(log)

        for {base, call, mode} <- [{a, call_a, unquote(first)}, {b, call_b, unquote(second)}] do
          if mode do
            assert Path.basename(base) =~ ~r/\A#{mod}-[0-9a-f]{10}-san-#{mode}\z/
            assert call =~ "-fsanitize=#{mode}"
            assert call =~ "-g -fno-omit-frame-pointer"
          else
            assert Path.basename(base) =~ ~r/\A#{mod}-[0-9a-f]{10}\z/
            refute call =~ "-fsanitize"
            refute call =~ "DEFK_SANITIZE"
          end

          assert call =~ "-o #{base}.so"
        end
      end
    end
  end

  describe "a Mix app's module" do
    setup %{tmp: tmp} do
      mod = :"Elixir.Defk.SanitizeTest.App#{System.unique_integer([:positive])}"
      base = Path.join(tmp, "#{mod}-0123456789-san-address")
      File.write!(base <> ".so", "")
      ebin = Mix.Project.compile_path()
      on_exit(fn -> for f <- Path.wildcard(Path.join(ebin, "#{mod}-*")), do: File.rm(f) end)
      %{mod: mod, base: base, ebin: ebin, app_file: Path.expand("lib/defk.ex")}
    end

    test "refuses the mode without a build path of its own, and leaves ebin alone", c do
      System.put_env("DEFK_SANITIZE", "address")
      System.delete_env("MIX_BUILD_PATH")

      error = assert_raise CompileError, fn -> Build.placement!(c.mod, c.base, c.app_file) end
      msg = Exception.message(error)
      assert msg =~ "compiled with DEFK_SANITIZE=address into its app's ebin/"
      assert msg =~ "MIX_BUILD_PATH=_build/test_sanitize_address DEFK_SANITIZE=address"
      assert Path.wildcard(Path.join(c.ebin, "#{c.mod}-*")) == []
    end

    test "with MIX_BUILD_PATH, the library goes to that build path's ebin, not the normal one",
         c do
      own = Path.join(c.tmp, "build")
      System.put_env("DEFK_SANITIZE", "address")
      System.put_env("MIX_BUILD_PATH", own)

      assert {:app, :defk, name, target} = Build.placement!(c.mod, c.base, c.app_file)
      assert name == Path.basename(c.base) <> ".so"
      assert target == Path.join([own, "lib/defk/ebin", name])
      assert File.exists?(target)

      System.delete_env("MIX_BUILD_PATH")
      assert Path.wildcard(Path.join(c.ebin, "#{c.mod}-*")) == []
    end

    test "a module not compiled into an app (a test file, a script) needs no build path", c do
      System.put_env("DEFK_SANITIZE", "address")
      System.delete_env("MIX_BUILD_PATH")
      assert Build.placement!(c.mod, c.base, "test/some_test.exs") == {:path, c.base}
    end
  end

  test "a kernel module asks Mix to recompile when DEFK_SANITIZE changes" do
    System.delete_env("DEFK_SANITIZE")
    mod = Module.concat(Defk.SanitizeTest, "Hook#{System.unique_integer([:positive])}")

    Code.compile_string("""
    defmodule #{inspect(mod)} do
      use Defk
      defk f(x :: i64) :: i64, do: x + 1
    end
    """)

    assert mod.__mix_recompile__?() == false
    System.put_env("DEFK_SANITIZE", "address")
    assert mod.__mix_recompile__?()
    System.delete_env("DEFK_SANITIZE")
    assert mod.__mix_recompile__?() == false
  end

  test "a normal build compiles none of the sanitizer code in the runtime header", %{tmp: tmp} do
    defmodule Plain do
      use Defk
      defk(inc(x :: i64) :: i64, do: x + 1)
    end

    c = Path.join(tmp, "plain.c")
    File.write!(c, Plain.__defk_c_source__())
    include = ["-I", Build.erts_include(), "-I", Application.app_dir(:defk, "priv")]
    cc = System.get_env("CC", "cc")

    {normal, 0} = System.cmd(cc, ["-E", "-std=gnu11"] ++ include ++ [c])
    refute normal =~ "defk_poison_slack"
    refute normal =~ "__sanitizer"

    {address, 0} =
      System.cmd(cc, ["-E", "-std=gnu11", "-DDEFK_SANITIZE_ADDRESS=1"] ++ include ++ [c])

    assert address =~ "defk_poison_slack"
    assert address =~ "__sanitizer_get_ownership"
  end

  describe "sanitized kernels" do
    @describetag :sanitize

    test "undefined: builds, loads its runtime itself, and the kernel runs" do
      System.put_env("DEFK_SANITIZE", "undefined")
      mod = Module.concat(Defk.SanitizeTest, "Ubsan#{System.unique_integer([:positive])}")
      cleanup(mod)

      Code.compile_string("""
      defmodule #{inspect(mod)} do
        use Defk
        defk inc(x :: i64) :: i64, do: x + 1
      end
      """)

      assert mod.__defk_lib__() =~ ~r/-san-undefined\.so\z/
      assert mod.inc(41) == 42
    end

    # A 1-byte write past an alloc/2 result, planted in the C by a CC
    # wrapper, on the stock emulator with the ASan runtime inserted and
    # +Mea min (docs/research/c-verification-macos.md §1). ERTS's
    # CHICKEN_PAD slack hides it unless the runtime header poisons it: the
    # control run builds the same planted kernel without the poisoning.
    @tag timeout: 300_000
    test "address: a planted 1-byte overrun of an alloc/2 result is reported", %{tmp: tmp} do
      if :os.type() != {:unix, :darwin},
        do: flunk("this test inserts Apple clang's ASan runtime: macOS only")

      flip = run_flip(tmp, plant: false)
      assert flip.status == 0, flip.out
      assert flip.out =~ "n=101: 101 bytes, first 254, last 254"

      planted = run_flip(tmp, plant: true)
      refute planted.status == 0
      assert planted.out =~ "ERROR: AddressSanitizer: use-after-poison"
      assert planted.out =~ "WRITE of size 1"

      assert planted.out =~
               ~r/in run_k0_flip Elixir\.SanFlip-[0-9a-f]{10}-san-address\.planted\.c/

      assert planted.out =~ "in defk_own_raw defk_runtime.h"

      control = run_flip(tmp, plant: true, poison: false)
      assert control.status == 0, control.out
      refute control.out =~ "AddressSanitizer"
    end
  end

  # Runs the flip kernel in a second VM (not under Mix, so its library is
  # built under that VM's tmp dir) with DEFK_SANITIZE=address and the ASan
  # runtime inserted. `plant:` makes the write out[i] be out[i + 1].
  defp run_flip(tmp, opts) do
    dir = Path.join(tmp, "flip_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    script = Path.join(dir, "flip.exs")
    wrapper = Path.join(dir, "cc-plant")

    File.write!(script, """
    defmodule SanFlip do
      use Defk

      defk flip(a :: [u8]) :: [u8] do
        n = len(a)
        out = alloc(u8, n)

        for i <- 0..(n - 1)//1 do
          out[i] = 255 - a[i]
        end

        out
      end
    end

    for n <- [100, 101, 104] do
      out = SanFlip.flip(:binary.copy(<<1>>, n))
      IO.puts("n=\#{n}: \#{byte_size(out)} bytes, first \#{:binary.first(out)}, last \#{:binary.last(out)}")
    end
    """)

    plant =
      if opts[:plant], do: ~S{s/(v_out_2).data\[v_i_3\] =/(v_out_2).data[v_i_3 + 1] =/}, else: ""

    extra = if opts[:poison] == false, do: "-UDEFK_SANITIZE_ADDRESS", else: ""

    File.write!(wrapper, """
    #!/bin/bash
    if [ "$1" = "--version" ]; then exec cc --version; fi
    out=()
    for a in "$@"; do
      if [[ -n '#{plant}' && "$a" == */Elixir.SanFlip-*.c ]]; then
        p="${a%.c}.planted.c"; sed -e '#{plant}' "$a" > "$p"; out+=("$p")
      else out+=("$a"); fi
    done
    exec cc "${out[@]}" #{extra}
    """)

    File.chmod!(wrapper, 0o755)
    {resource, 0} = System.cmd("cc", ["-print-resource-dir"])
    asan = Path.join(String.trim(resource), "lib/darwin/libclang_rt.asan_osx_dynamic.dylib")
    assert File.exists?(asan)

    {out, status} =
      System.cmd(
        System.find_executable("elixir"),
        ["-pa", Path.join(to_string(:code.lib_dir(:defk)), "ebin"), script],
        env: [
          {"CC", wrapper},
          {"DEFK_SANITIZE", "address"},
          {"TMPDIR", dir},
          {"MIX_BUILD_PATH", nil},
          {"ERL_AFLAGS", "-env DYLD_INSERT_LIBRARIES #{asan} +Mea min"}
        ],
        stderr_to_stdout: true
      )

    %{out: out, status: status}
  end
end
