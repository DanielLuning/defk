# Fault containment (defk-7dm). A kernel never faults by construction, so a
# SIGSEGV, SIGBUS, SIGILL or SIGFPE inside kernel native code is a defk bug.
# The runtime's per-library signal handler turns such a fault into a
# RuntimeError for the calling process when the fault is synchronous, a
# kernel of that library runs on the faulting thread and the PC is inside the
# library's own code; anything else is chained to the previous handler and
# kills the node as before. __defk_inject_fault__/1 (a test-only hook,
# MIX_ENV=test) makes the next clock read fault on purpose.
#
# The cases that must kill the node run in a child VM (`mix run` under
# MIX_ENV=test, so the hook is compiled in); so do the chain cases after a
# hot upgrade or an unload, where a wrong answer is a node crash, not a
# failed assertion.

# a loop with a safepoint per iteration and an owned buffer to free
defmodule Defk.FaultContainmentTest.K do
  use Defk

  defk spin(n :: i64) :: i64 do
    buf = alloc(i64, 64)

    for i <- 0..(n - 1)//1, reduce: 0 do
      acc ->
        buf[rem(i, 64)] = i
        acc + buf[rem(i, 64)]
    end
  end
end

# a second library: its handler sits in front of K's in the chain
defmodule Defk.FaultContainmentTest.K2 do
  use Defk

  defk spin2(n :: i64) :: i64 do
    for i <- 0..(n - 1)//1, reduce: 0 do
      acc -> acc + rem(i, 3)
    end
  end
end

defmodule Defk.FaultContainmentTest do
  use ExUnit.Case, async: false
  import Defk.Test.Frames
  import Defk.TestKit

  alias Defk.FaultContainmentTest.{K, K2}

  @n 1_000_000
  @sum Enum.sum(0..(@n - 1))
  @segv ~r/defk bug: segmentation fault inside kernel native code \(signal \d+, code \d+, address 0x8, pc \+0x[0-9a-f]+\); the call was aborted and the node kept running/
  @x86 :erlang.system_info(:system_architecture) |> to_string() |> String.starts_with?("x86_64")

  setup do
    K.__defk_inject_fault__(0)
    K2.__defk_inject_fault__(0)
    :ok
  end

  test "the handler is compiled in and the hook only under fault hooks" do
    src = K.__defk_c_source__()
    assert src =~ "#define DEFK_FAULT_HOOKS 1"
    assert src =~ "defk_ctx **defk_slot = &defk_cur_ctx;"
    assert src =~ "*defk_slot = &F->ctx;"

    assert src =~
             "ERL_NIF_INIT(Elixir.Defk.FaultContainmentTest.K, defk_funcs, defk_load, NULL, defk_upgrade, defk_unload)"
  end

  test "a segmentation fault inside a kernel raises RuntimeError in the caller; the node keeps running" do
    live0 = K.__defk_stats__().frames_live
    assert K.spin(@n) == @sum

    K.__defk_inject_fault__(1)
    assert_raise RuntimeError, @segv, fn -> K.spin(@n) end

    # the hook is consumed by the fault, the library works again, nothing leaked
    assert K.spin(@n) == @sum
    assert_frames_live(K, live0)
  end

  test "an illegal instruction is contained the same way" do
    K.__defk_inject_fault__(2)

    assert_raise RuntimeError, ~r/defk bug: illegal instruction inside kernel native code/, fn ->
      K.spin(@n)
    end

    assert K.spin(@n) == @sum
  end

  if @x86 do
    test "an integer division by zero is contained (x86-64 traps on it)" do
      K.__defk_inject_fault__(3)

      assert_raise RuntimeError, ~r/defk bug: arithmetic fault inside kernel native code/, fn ->
        K.spin(@n)
      end

      assert K.spin(@n) == @sum
    end
  end

  test "a fault after the kernel yielded (a promoted frame, the step function) is contained and the frame freed" do
    live0 = K.__defk_stats__().frames_live

    forced(K, fn ->
      # let three clock reads pass: under forced yields each one yields
      K.__defk_inject_fault__(1 + 256 * 3)
      assert_raise RuntimeError, @segv, fn -> K.spin(@n) end
      assert K.spin(1000) == Enum.sum(0..999)
    end)

    assert_frames_live(K, live0)
    assert K.__defk_stats__().promotions > 0
  end

  test "a fault in the older library is contained through the newer library's handler; other kernels are unaffected" do
    # K2 loaded after K: its handler is in front and chains to K's
    other =
      Task.async(fn ->
        for _ <- 1..20, do: K2.spin2(@n)
      end)

    for _ <- 1..5 do
      K.__defk_inject_fault__(1)
      assert_raise RuntimeError, @segv, fn -> K.spin(@n) end
    end

    expected = Enum.sum(for i <- 0..(@n - 1), do: rem(i, 3))
    assert Task.await(other, 30_000) == List.duplicate(expected, 20)

    # and a fault in the newer library, at the head of the chain
    K2.__defk_inject_fault__(1)
    assert_raise RuntimeError, @segv, fn -> K2.spin2(@n) end
    assert K2.spin2(@n) == expected
  end

  test "the fault is reported on the calling process only; a sibling process is not touched" do
    parent = self()

    pid =
      spawn(fn ->
        K.__defk_inject_fault__(1)

        try do
          K.spin(@n)
          send(parent, :no_raise)
        rescue
          e in RuntimeError -> send(parent, {:raised, Exception.message(e)})
        end
      end)

    assert_receive {:raised, msg}, 10_000
    assert msg =~ "segmentation fault"
    refute Process.alive?(pid) and false
    assert K.spin(100) == Enum.sum(0..99)
  end

  # ---- child VM: faults that must still kill the node, and the chain after upgrades/unloads ----

  @child_timeout 120_000

  defp child(script_body, dir) do
    script = Path.join(dir, "child.exs")
    File.write!(script, script_body)

    # `timeout`: a child that hangs (a handler that loops) must not hang the
    # suite; it is killed and the test fails on its output
    [exe | args] =
      if(System.find_executable("timeout"), do: ["timeout", "90"], else: []) ++
        ["mix", "run", "--no-compile", "--no-deps-check", script]

    {out, status} =
      System.cmd(exe, args,
        cd: File.cwd!(),
        env: [{"MIX_ENV", "test"}, {"MIX_BUILD_PATH", nil}],
        stderr_to_stdout: true
      )

    {out, status}
  end

  @kernels ~S'''
  k2_src = """
  defmodule FC.K2 do
    use Defk
    defk spin2(n :: i64) :: i64 do
      for i <- 0..(n - 1)//1, reduce: 0 do
        acc -> acc + rem(i, 3)
      end
    end
  end
  """
  Code.compile_string(k2_src)

  defmodule FC.K do
    use Defk
    defk spin(n :: i64) :: i64 do
      for i <- 0..(n - 1)//1, reduce: 0 do
        acc -> acc + rem(i, 7)
      end
    end
  end

  contained = fn mod, fun ->
    mod.__defk_inject_fault__(1)
    try do
      apply(mod, fun, [1_000_000])
      IO.puts("NOT_CONTAINED #{inspect(mod)}")
    rescue
      e in RuntimeError ->
        if Exception.message(e) =~ "segmentation fault inside kernel native code",
          do: IO.puts("CONTAINED #{inspect(mod)}"),
          else: IO.puts("WRONG_MESSAGE #{Exception.message(e)}")
    end
  end
  '''

  @tag :tmp_dir
  @tag timeout: @child_timeout
  test "a fault outside kernel code (in libc, called from a kernel) still kills the node", %{
    tmp_dir: dir
  } do
    {out, status} =
      child(
        @kernels <>
          ~S"""
          contained.(FC.K, :spin)
          FC.K.__defk_inject_fault__(4)
          FC.K.spin(1_000_000)
          IO.puts("SURVIVED")
          """,
        dir
      )

    assert out =~ "CONTAINED FC.K", out
    refute out =~ "SURVIVED", out
    assert status != 0, out
  end

  @tag :tmp_dir
  @tag timeout: @child_timeout
  test "a fault in the library while no kernel runs still kills the node", %{tmp_dir: dir} do
    {out, status} =
      child(
        @kernels <>
          ~S"""
          contained.(FC.K, :spin)
          FC.K.__defk_inject_fault__(-1)
          IO.puts("SURVIVED")
          """,
        dir
      )

    assert out =~ "CONTAINED FC.K", out
    refute out =~ "SURVIVED", out
    assert status != 0, out
  end

  @tag :tmp_dir
  @tag timeout: @child_timeout
  test "the chain stays valid across a hot upgrade and across unloads (the retired images stay mapped)",
       %{
         tmp_dir: dir
       } do
    {out, status} =
      child(
        @kernels <>
          ~S'''
          # chain so far: K2 (first), K (head). Upgrade K: the new image goes in
          # front and pins the old one; purge the old code (ERTS unmaps it unless
          # pinned). A fault in K2 then passes the new K, the old K and K2's own
          # handler: it is contained only if the old image is still mapped.
          Code.put_compiler_option(:ignore_module_conflict, true)
          Code.compile_string("""
          defmodule FC.K do
            use Defk
            defk spin(n :: i64) :: i64 do
              k = 2
              for i <- 0..(n - 1)//1, reduce: 0 do
                acc -> acc + rem(i, 7) * k
              end
            end
          end
          """)
          # (purge returns whether it had to kill a process)
          false = :code.purge(FC.K)
          contained.(FC.K2, :spin2)
          contained.(FC.K, :spin)
          IO.puts("UPGRADE_OK")

          # two more libraries: U1 then U2 (head). Delete and purge U1: its
          # handler is not the head, so it pins its image. Then U2: the head, so
          # it restores U1's (pinned) handler as the head.
          for u <- [:U1, :U2] do
            Code.compile_string("""
            defmodule FC.#{u} do
              use Defk
              defk f(n :: i64) :: i64 do
                for i <- 0..(n - 1)//1, reduce: 0 do
                  acc -> acc + i
                end
              end
            end
            """)
          end
          499_500 = FC.U1.f(1000)
          499_500 = FC.U2.f(1000)
          true = :code.delete(FC.U1)
          false = :code.purge(FC.U1)
          contained.(FC.K2, :spin2)
          IO.puts("UNLOAD_NONHEAD_OK")
          true = :code.delete(FC.U2)
          false = :code.purge(FC.U2)
          contained.(FC.K2, :spin2)
          contained.(FC.K, :spin)
          IO.puts("UNLOAD_HEAD_OK")

          # the same module reloaded with unchanged code: the same .so, the same
          # image and statics from dlopen, so its handler is already in the
          # chain and must not be installed again (that saved its own handler
          # as the previous one, and the first fault spun forever)
          Code.compile_string(k2_src)
          Code.compile_string(k2_src)
          contained.(FC.K2, :spin2)
          contained.(FC.K, :spin)
          IO.puts("RELOAD_SAME_OK")

          # and the node still dies on a fault nobody contains
          FC.K.__defk_inject_fault__(-1)
          IO.puts("SURVIVED")
          ''',
        dir
      )

    assert out =~ "UPGRADE_OK", out
    assert out =~ "UNLOAD_NONHEAD_OK", out
    assert out =~ "UNLOAD_HEAD_OK", out
    assert out =~ "RELOAD_SAME_OK", out
    refute out =~ "NOT_CONTAINED", out
    refute out =~ "WRONG_MESSAGE", out
    refute out =~ "SURVIVED", out
    assert status != 0, out
  end
end
