# The owned-buffer budget (defk-4b2): every alloc/2, copy and bitstring
# buffer a call makes lives until the kernel returns, so one in a loop body
# keeps a buffer per iteration. A call raises ArgumentError "out of memory"
# once its live owned bytes would pass `use Defk, max_owned:` (default: half
# of physical memory), instead of growing until the OS kills the node. It is
# a limit of native code only: Elixir mode garbage-collects the old binaries
# and succeeds.

defmodule Defk.OwnedBudgetTest.K do
  # 8 KiB: eight 1 KiB buffers fit, the ninth does not
  use Defk, max_owned: 8 * 1024

  # k i64 elements per iteration, each kept until the kernel returns
  defk alloc_loop(n :: i64, k :: i64) :: i64 do
    for i <- 0..(n - 1)//1, reduce: 0 do
      acc ->
        a = alloc(i64, k)
        a[0] = i
        acc + a[0]
    end
  end

  # `b = a` in the body, `a` written and `b` read after it: a copy of `a`
  # every iteration (docs/language.md, Copies)
  defk copy_loop(a :: [i64], n :: i64) :: i64 do
    for i <- 0..(n - 1)//1, reduce: 0 do
      acc ->
        b = a
        a[0] = i
        acc + b[0] + a[0]
    end
  end

  # one alloc outside any loop, returned: under the budget, then handed over
  defk fill(n :: i64) :: [i64] do
    out = alloc(i64, n)

    for i <- 0..(n - 1)//1 do
      out[i] = i
    end

    out
  end

  # a bitstring accumulator's buffer grows by doubling, each growth counted
  defk bits(n :: i64) :: bitstring do
    for i <- 0..(n - 1)//1, reduce: <<>> do
      acc -> <<acc::bitstring, band(i, 255)::size(8)>>
    end
  end
end

defmodule Defk.OwnedBudgetTest.Default do
  use Defk

  defk alloc_loop(n :: i64, k :: i64) :: i64 do
    for i <- 0..(n - 1)//1, reduce: 0 do
      acc ->
        a = alloc(i64, k)
        a[0] = i
        acc + a[0]
    end
  end
end

defmodule Defk.OwnedBudgetTest do
  use ExUnit.Case, async: false

  import Defk.Test.Frames

  alias Defk.OwnedBudgetTest.{Default, K}

  @oom ~r/^out of memory \(allocating 1024 bytes would take this call's buffers past max_owned, 8192 bytes\)$/

  defp i64s(list), do: for(x <- list, into: <<>>, do: <<x::signed-64-native>>)

  defp elixir(fun, args), do: K.__defk_elixir__(fun, args)

  defp forced(fun) do
    K.__defk_force_yields__(true)

    try do
      fun.()
    after
      K.__defk_force_yields__(false)
    end
  end

  test "the budget is the module's max_owned, and half of physical memory by default" do
    assert K.__defk_stats__().max_owned == 8192
    default = Default.__defk_stats__().max_owned
    assert is_integer(default) and default >= 64 * 1024 * 1024
    assert Default.alloc_loop(100, 1024) == Enum.sum(0..99)
  end

  test "an alloc in a loop raises out of memory past the budget, at the exact buffer" do
    # 8 x 1 KiB fit exactly; the ninth passes 8 KiB
    assert K.alloc_loop(8, 128) == Enum.sum(0..7)
    assert K.alloc_loop(8, 128) == elixir(:alloc_loop, [8, 128])
    assert_raise ArgumentError, @oom, fn -> K.alloc_loop(9, 128) end
    # Elixir mode garbage-collects the old binaries: the limit is native only
    assert elixir(:alloc_loop, [9, 128]) == Enum.sum(0..8)
    # one buffer larger than the whole budget
    assert_raise ArgumentError, ~r/^out of memory \(allocating 8200 bytes/, fn ->
      K.alloc_loop(1, 1025)
    end
  end

  test "a copy in a loop raises out of memory past the budget" do
    a = i64s(Enum.to_list(1..128))
    assert K.copy_loop(a, 3) == elixir(:copy_loop, [a, 3])
    assert_raise ArgumentError, @oom, fn -> K.copy_loop(a, 1000) end
    # a write in a `for` body is kept for the next iteration: b[0] is the
    # previous i (1, the input's, at i = 0), a[0] is i
    assert elixir(:copy_loop, [a, 1000]) == 1 + Enum.sum(for i <- 1..999, do: 2 * i - 1)
    assert K.copy_loop(a, 7) == elixir(:copy_loop, [a, 7])
  end

  test "a returned array is counted while the kernel runs, and a call under the budget agrees" do
    assert K.fill(1024) == i64s(Enum.to_list(0..1023))
    assert_raise ArgumentError, ~r/^out of memory \(allocating 8200 bytes/, fn -> K.fill(1025) end
  end

  test "a bitstring accumulator's growth is counted" do
    small = K.bits(1000)
    assert small == elixir(:bits, [1000])
    assert_raise ArgumentError, ~r/^out of memory/, fn -> K.bits(10_000) end
  end

  test "the count is per call: a call after a raise starts from zero" do
    for _ <- 1..3 do
      assert_raise ArgumentError, @oom, fn -> K.alloc_loop(100, 128) end
      assert K.alloc_loop(8, 128) == Enum.sum(0..7)
    end
  end

  test "under forced yields the count survives every resume and frames are freed" do
    forced(fn ->
      y0 = K.__defk_stats__().yields
      # 8 iterations of zeroing in strips and loop back-edges, each a yield
      assert K.alloc_loop(8, 128) == Enum.sum(0..7)
      assert K.__defk_stats__().yields > y0
      assert_raise ArgumentError, @oom, fn -> K.alloc_loop(9, 128) end
      assert_raise ArgumentError, @oom, fn -> K.alloc_loop(9, 128) end
      assert K.alloc_loop(8, 128) == Enum.sum(0..7)
      a = i64s(Enum.to_list(1..128))
      assert K.copy_loop(a, 3) == elixir(:copy_loop, [a, 3])
      assert_raise ArgumentError, @oom, fn -> K.copy_loop(a, 1000) end
      assert K.bits(1000) == elixir(:bits, [1000])
      assert_raise ArgumentError, ~r/^out of memory/, fn -> K.bits(10_000) end
    end)

    assert_frames_live(K)
  end

  test "concurrent calls each have their own count" do
    results =
      1..32
      |> Task.async_stream(fn i -> K.alloc_loop(8, 128) + i end, max_concurrency: 16)
      |> Enum.map(fn {:ok, r} -> r end)

    assert results == for(i <- 1..32, do: Enum.sum(0..7) + i)
  end

  describe "fast-path report" do
    defp owned_notes(kernel) do
      for {^kernel, line, {:owned, :per_iteration, text}} <- K.__defk_report__(),
          do: {line, text}
    end

    test "notes an alloc and a copy inside a loop" do
      assert [{_, text}] = owned_notes({:alloc_loop, 2})

      assert text =~
               "alloc/2 is inside a loop: each iteration keeps a buffer until the kernel returns"

      assert text =~ "Allocate before the loop and clear each pass"

      assert [{_, text}] = owned_notes({:copy_loop, 2})
      assert text =~ "this copy is inside a loop: each iteration keeps a buffer"
      assert Defk.Report.format(K) =~ "each iteration keeps a buffer until the kernel returns"
    end

    test "does not note an alloc outside a loop" do
      assert owned_notes({:fill, 1}) == []
    end
  end

  describe "use Defk, max_owned:" do
    for bad <- ["0", "-1", ":big", "\"1024\"", "1.5e3", "18_446_744_073_709_551_616"] do
      test "rejects #{bad}" do
        assert_raise ArgumentError,
                     ~r/max_owned: expects a positive integer number of bytes/,
                     fn ->
                       Code.compile_string("""
                       defmodule Defk.OwnedBudgetTest.Bad do
                         use Defk, max_owned: #{unquote(bad)}

                         defk one() :: i64, do: 1
                       end
                       """)
                     end
      end
    end

    test "lists max_owned among the options" do
      assert_raise ArgumentError, ~r/`max_owned: bytes`/, fn ->
        Code.compile_string("""
        defmodule Defk.OwnedBudgetTest.Unknown do
          use Defk, max_bytes: 10
        end
        """)
      end
    end
  end
end
