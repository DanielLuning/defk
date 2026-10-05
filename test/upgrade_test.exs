# Hot code upgrade with suspended kernel frames (defk-nbl).
#
# A kernel is started, suspended between two of its yields
# (:erlang.suspend_process/1 only takes effect once the NIF has rescheduled
# itself), and its module is recompiled with a different body and frame
# layout. The suspended kernel must finish in the library it started in, each
# library must destroy only its own frames, and new calls must run the new
# code. `old_stats` is a fun created by the old module instance, so it reads
# the old library's counters after the upgrade.

defmodule Defk.UpgradeTest do
  use ExUnit.Case, async: false

  # long enough (~0.5 s) that the kernel is certainly still running when it is
  # suspended, with an easy closed form for the answer
  @n 1_000_000_000
  @timeout 30_000

  setup do
    prev = Code.get_compiler_option(:ignore_module_conflict)
    Code.put_compiler_option(:ignore_module_conflict, true)
    on_exit(fn -> Code.put_compiler_option(:ignore_module_conflict, prev) end)
  end

  defp source(mod, :a) do
    """
    defmodule #{inspect(mod)} do
      use Defk
      defk spin(n :: i64) :: i64 do
        for i <- 0..(n - 1)//1, reduce: 0 do
          acc -> acc + rem(i, 7)
        end
      end
      def stats_fun, do: fn -> __defk_stats__() end
    end
    """
  end

  # more locals, so a different frame struct
  defp source(mod, :b) do
    """
    defmodule #{inspect(mod)} do
      use Defk
      defk spin(n :: i64) :: i64 do
        k = n * 3
        {s, t} =
          for i <- 0..(n - 1)//1, reduce: {0, 1} do
            {a, b} -> {a + rem(i, 5), rem(b * 3 + k, 1000)}
          end
        s * 1000 + t
      end
      def stats_fun, do: fn -> __defk_stats__() end
    end
    """
  end

  defp load(mod, version) do
    [{^mod, _}] = Code.compile_string(source(mod, version))
    mod.__defk_lib__()
  end

  defp spin_a(n), do: div(n, 7) * 21 + Enum.sum(0..(rem(n, 7) - 1)//1)

  # start mod.spin(@n) in a process and suspend it between two yields
  defp start_suspended(mod) do
    parent = self()
    pid = spawn(fn -> send(parent, {:spin, self(), mod.spin(@n)}) end)
    stats = mod.stats_fun()
    wait_until(fn -> stats.().yields > 0 end)
    true = :erlang.suspend_process(pid)
    assert Process.alive?(pid)
    assert %{frames_live: 1, promotions: 1} = stats.()
    {pid, stats}
  end

  defp wait_until(f, deadline \\ System.monotonic_time(:millisecond) + @timeout) do
    cond do
      f.() -> :ok
      System.monotonic_time(:millisecond) > deadline -> flunk("timed out")
      true ->
        Process.sleep(1)
        wait_until(f, deadline)
    end
  end

  test "reloading with no live frames runs the new code" do
    mod = Module.concat(__MODULE__, "Idle")
    lib_a = load(mod, :a)
    assert mod.spin(10) == spin_a(10)
    lib_b = load(mod, :b)
    assert lib_a != lib_b
    assert mod.spin(10) == 20_769
    assert %{frames_live: 0} = mod.__defk_stats__()
  end

  test "a kernel suspended across an upgrade finishes in the old library" do
    mod = Module.concat(__MODULE__, "Upgrade")
    lib_a = load(mod, :a)
    {pid, old_stats} = start_suspended(mod)

    assert load(mod, :b) != lib_a
    assert mod.spin(10) == 20_769
    # the suspended caller still counts as running the old module's code
    refute :code.soft_purge(mod)

    :erlang.resume_process(pid)
    assert_receive {:spin, ^pid, result}, @timeout
    assert result == spin_a(@n)

    # each library destroyed only its own frames
    wait_until(fn -> old_stats.().frames_live == 0 end)
    assert %{frames_live: 0, promotions: 0} = mod.__defk_stats__()
    assert :code.soft_purge(mod)
    assert mod.spin(10) == 20_769
  end

  test "reloading the same library while a kernel is suspended" do
    mod = Module.concat(__MODULE__, "Same")
    lib = load(mod, :a)
    {pid, stats} = start_suspended(mod)

    # same source, same .so: the new instance shares the old one's statics
    assert load(mod, :a) == lib
    :erlang.resume_process(pid)
    assert_receive {:spin, ^pid, result}, @timeout
    assert result == spin_a(@n)
    wait_until(fn -> stats.().frames_live == 0 end)
    assert %{frames_live: 0, promotions: 1} = mod.__defk_stats__()
  end

  test "killing a kernel suspended across an upgrade frees its frame in the old library" do
    mod = Module.concat(__MODULE__, "Kill")
    load(mod, :a)
    {pid, old_stats} = start_suspended(mod)
    load(mod, :b)

    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, _, _, :killed}, @timeout
    wait_until(fn -> old_stats.().frames_live == 0 end)
    assert %{frames_live: 0} = mod.__defk_stats__()
  end

  test "purging the old code kills the suspended kernel, like any process in old code" do
    mod = Module.concat(__MODULE__, "Purge")
    load(mod, :a)
    {pid, _old_stats} = start_suspended(mod)
    load(mod, :b)

    ref = Process.monitor(pid)
    assert :code.purge(mod)
    assert_receive {:DOWN, ^ref, _, _, :killed}, @timeout
    refute_received {:spin, ^pid, _}
    assert %{frames_live: 0} = mod.__defk_stats__()
    assert mod.spin(10) == 20_769
  end
end
