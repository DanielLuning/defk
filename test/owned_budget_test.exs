# The owned-buffer budget: every alloc/2, copy and bitstring
# buffer a call makes lives until the kernel returns, so one in a loop body
# keeps a buffer per iteration. A call raises ArgumentError "out of memory"
# once its live owned bytes would pass `use Defk, max_owned_bytes:` (default: half
# of physical memory), instead of growing until the OS kills the node.
# Elixir mode enforces the same budget on alloc/2: it counts the
# bytes every alloc/2 of the call asks for, against the native library's
# max_owned_bytes, and raises the same message. It does not see value-semantics
# copies or bitstring buffers, so for those it garbage-collects the old
# binaries and succeeds where native raises.

defmodule Defk.OwnedBudgetTest.K do
  # 8 KiB: eight 1 KiB buffers fit, the ninth does not
  use Defk, max_owned_bytes: 8 * 1024

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
  # every iteration (docs/language.md, Copies). `b` dies at the end of the
  # iteration, so the previous iteration's copy is released there: the loop
  # holds two copies at a time, not one per iteration
  defk copy_loop(a :: [i64], n :: i64) :: i64 do
    for i <- 0..(n - 1)//1, reduce: 0 do
      acc ->
        b = a
        a[0] = i
        acc + b[0] + a[0]
    end
  end

  # the same shape with `a` as a reduce accumulator
  defk reduce_copy(a :: [i64], n :: i64) :: {[i64], i64} do
    for i <- 0..(n - 1)//1, reduce: {a, 0} do
      {a, s} ->
        b = a
        a[0] = i
        {a, s + b[0] + a[0]}
    end
  end

  # the copy and the dying binding inside an if arm
  defk arm_copy(a :: [i64], n :: i64) :: i64 do
    for i <- 0..(n - 1)//1, reduce: 0 do
      acc ->
        if i > 0 do
          b = a
          a[0] = i
          acc + b[0]
        else
          acc + a[0]
        end
    end
  end

  defk bump(a :: [i64]) :: [i64] do
    a[0] = a[0] + 1
    a
  end

  # a called kernel copies the caller's array (the caller reads it after);
  # the copy comes back as `b` and dies with the iteration
  defk callee_copy(a :: [i64], n :: i64) :: i64 do
    for _ <- 0..(n - 1)//1, reduce: 0 do
      acc ->
        b = bump(a)
        acc + b[0] + a[0]
    end
  end

  # the copies stay reachable: `c` is `b` or `a`, which the compiler cannot
  # tell apart, so neither buffer is released and the loop keeps one copy
  # per iteration until the kernel returns
  defk copy_kept(a :: [i64], n :: i64) :: i64 do
    for i <- 0..(n - 1)//1, reduce: 0 do
      acc ->
        b = a
        a[0] = i
        c = if i > 2, do: b, else: a
        acc + c[0]
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

  # a called kernel's allocations count against the caller's call
  defk alloc_twice(k :: i64) :: i64 do
    alloc_loop(4, k) + alloc_loop(4, k)
  end
end

defmodule Defk.OwnedBudgetTest.Default do
  use Defk

  defk one_alloc(n :: i64) :: i64 do
    length(alloc(u8, n))
  end

  defk alloc_loop(n :: i64, k :: i64) :: i64 do
    for i <- 0..(n - 1)//1, reduce: 0 do
      acc ->
        a = alloc(i64, k)
        a[0] = i
        acc + a[0]
    end
  end

  # five buffers in straight-line code: one more than the frame's own
  # owned slots (DEFK_OWNED_INLINE), so the table moves to the heap with
  # no safepoint in between
  defk five_allocs(k :: i64) :: i64 do
    a = alloc(i64, k)
    b = alloc(i64, k)
    c = alloc(i64, k)
    d = alloc(i64, k)
    e = alloc(i64, k)
    a[0] = 1
    b[0] = 2
    c[0] = 3
    d[0] = 4
    e[0] = 5
    a[0] + b[0] + c[0] + d[0] + e[0]
  end
end

defmodule Defk.OwnedBudgetTest do
  use ExUnit.Case, async: false
  use ExUnitProperties

  import Defk.Test.Frames
  import Defk.TestKit

  alias Defk.OwnedBudgetTest.{Default, K}

  @oom ~r/^out of memory \(allocating 1024 bytes would take this call's buffers past max_owned_bytes, 8192 bytes\)$/

  defp elixir(fun, args), do: K.__defk_elixir__(fun, args)

  test "the budget is the module's max_owned_bytes, and half of physical memory by default" do
    assert K.__defk_stats__().max_owned_bytes == 8192
    default = Default.__defk_stats__().max_owned_bytes
    assert is_integer(default) and default >= 64 * 1024 * 1024
    assert Default.alloc_loop(100, 1024) == Enum.sum(0..99)
  end

  # native and Elixir mode raise the same ArgumentError, message included;
  # returns the message
  defp same_raise(mod, fun, args) do
    native =
      assert_raise ArgumentError, fn ->
        Defk.ElixirMode.with_mode(:native, fn -> apply(mod, fun, args) end)
      end

    elixir = assert_raise ArgumentError, fn -> mod.__defk_elixir__(fun, args) end
    assert native.message == elixir.message, "#{fun}#{inspect(args)}"
    native.message
  end

  test "an alloc in a loop raises out of memory past the budget, at the exact buffer" do
    # 8 x 1 KiB fit exactly; the ninth passes 8 KiB
    assert K.alloc_loop(8, 128) == Enum.sum(0..7)
    assert K.alloc_loop(8, 128) == elixir(:alloc_loop, [8, 128])
    assert same_raise(K, :alloc_loop, [9, 128]) =~ @oom
    # one buffer larger than the whole budget
    assert same_raise(K, :alloc_loop, [1, 1025]) =~ ~r/^out of memory \(allocating 8200 bytes/
  end

  test "Elixir mode's budget is the native library's max_owned_bytes" do
    # rejected before anything is allocated, in both modes
    max = Default.__defk_stats__().max_owned_bytes

    assert same_raise(Default, :one_alloc, [max + 1]) =~
             ~r/^out of memory \(allocating #{max + 1}/

    assert Default.__defk_elixir__(:one_alloc, [1024]) == 1024
  end

  test "a called kernel's allocations count against the same call in both modes" do
    assert K.alloc_twice(128) == 2 * Enum.sum(0..3)
    assert elixir(:alloc_twice, [128]) == 2 * Enum.sum(0..3)
    assert same_raise(K, :alloc_twice, [129]) =~ ~r/^out of memory \(allocating 1032 bytes/
  end

  test "a copy in a loop that stays reachable raises out of memory past the budget" do
    a = i64s(Enum.to_list(1..128))
    assert K.copy_kept(a, 3) == elixir(:copy_kept, [a, 3])
    assert_raise ArgumentError, @oom, fn -> K.copy_kept(a, 1000) end
    # Elixir mode counts alloc/2 only: it garbage-collects the old copies.
    # c[0] is a[0] = i for i <= 2, then b[0], the previous i
    assert elixir(:copy_kept, [a, 1000]) == 0 + 1 + 2 + Enum.sum(for i <- 3..999, do: i - 1)
    assert K.copy_kept(a, 7) == elixir(:copy_kept, [a, 7])
  end

  describe "early release" do
    # the dying binding's buffer is released before the kernel returns, so
    # 1000 iterations of a 1 KiB copy fit an 8 KiB budget
    test "a per-iteration copy whose binding dies is released: the loop no longer accumulates" do
      a = i64s(Enum.to_list(1..128))
      # a write in a `for` body is kept for the next iteration: b[0] is the
      # previous i (1, the input's, at i = 0), a[0] is i
      expected = 1 + Enum.sum(for i <- 1..999, do: 2 * i - 1)
      assert K.copy_loop(a, 1000) == expected
      assert elixir(:copy_loop, [a, 1000]) == expected
      assert K.reduce_copy(a, 1000) == elixir(:reduce_copy, [a, 1000])
      assert K.arm_copy(a, 1000) == elixir(:arm_copy, [a, 1000])
      assert K.callee_copy(a, 1000) == elixir(:callee_copy, [a, 1000])
    end

    defp kernel_c(name) do
      K.__defk_c_source__()
      |> String.split("/* ---- #{name}/2")
      |> Enum.at(1)
      |> String.split("/* ---- ")
      |> hd()
    end

    test "the release is one runtime call per dying binding, in the generated C" do
      for name <- ["copy_loop", "reduce_copy", "arm_copy", "callee_copy"] do
        assert kernel_c(name) =~ "defk_disown(ctx, ", name
      end

      # copy_kept releases one buffer: the hoisted copy of the input, after
      # the loop; nothing inside the body
      [before_end, after_end] = String.split(kernel_c("copy_kept"), "/* defk:end */")
      refute before_end =~ "defk_disown"
      assert after_end =~ "defk_disown"
      refute kernel_c("alloc_loop") =~ "defk_disown"
    end

    test "under forced yields the released buffers and the budget agree with Elixir mode" do
      a = i64s(Enum.to_list(1..128))

      forced(K, fn ->
        {res, count} = yields(K, fn -> K.copy_loop(a, 200) end)
        assert res == elixir(:copy_loop, [a, 200])
        assert count > 0
        assert K.reduce_copy(a, 200) == elixir(:reduce_copy, [a, 200])
        assert K.arm_copy(a, 200) == elixir(:arm_copy, [a, 200])
        assert K.callee_copy(a, 200) == elixir(:callee_copy, [a, 200])
        assert_raise ArgumentError, @oom, fn -> K.copy_kept(a, 1000) end
      end)

      assert_frames_live(K)
    end

    property "every loop length and array agrees with Elixir mode under the budget" do
      check all(
              len <- StreamData.integer(1..64),
              n <- StreamData.integer(0..300),
              xs <- StreamData.list_of(StreamData.integer(-1000..1000), length: len),
              max_runs: 40
            ) do
        a = i64s(xs)

        for f <- [:copy_loop, :reduce_copy, :arm_copy, :callee_copy] do
          assert apply(K, f, [a, n]) == elixir(f, [a, n]), "#{f}(#{len}, #{n})"
        end
      end
    end

    test "notes the release in the fast-path report" do
      released = fn kernel ->
        for {^kernel, line, {:owned, :released, text}} <- K.__defk_report__(), do: {line, text}
      end

      # the copy made each iteration, and the hoisted copy of the input,
      # released after the loop
      assert [{_, text}, {_, after_loop}] = Enum.sort(released.({:copy_loop, 2}), :desc)
      assert text =~ "this copy is inside a loop and is released before the kernel returns"
      assert text =~ "at most two at a time"
      assert after_loop =~ "a's buffer, a copy, is released here"
      assert owned_notes({:copy_loop, 2}) == []

      assert [{_, text}] = released.({:callee_copy, 2})
      assert text =~ "released"

      assert [{_, text}] = released.({:copy_kept, 2})
      assert text =~ "a's buffer, a copy, is released here"
      assert [{_, _}] = owned_notes({:copy_kept, 2})
    end
  end

  test "a returned array is counted while the kernel runs, and a call under the budget agrees" do
    assert K.fill(1024) == i64s(Enum.to_list(0..1023))
    assert K.fill(1024) == elixir(:fill, [1024])
    assert same_raise(K, :fill, [1025]) =~ ~r/^out of memory \(allocating 8200 bytes/
  end

  test "a bitstring accumulator's growth is counted" do
    small = K.bits(1000)
    assert small == elixir(:bits, [1000])
    assert_raise ArgumentError, ~r/^out of memory/, fn -> K.bits(10_000) end
    # not in Elixir mode, which builds the bitstring as Elixir does
    assert elixir(:bits, [10_000]) == for(i <- 0..9_999, into: <<>>, do: <<rem(i, 256)>>)
  end

  test "the count is per call: a call after a raise starts from zero" do
    for _ <- 1..3 do
      assert same_raise(K, :alloc_loop, [100, 128]) =~ @oom
      assert K.alloc_loop(8, 128) == Enum.sum(0..7)
      assert elixir(:alloc_loop, [8, 128]) == Enum.sum(0..7)
    end

    # Elixir mode leaves nothing behind in the process
    assert Enum.filter(
             Process.get_keys(),
             &(is_atom(&1) and String.starts_with?(Atom.to_string(&1), "defk"))
           ) == []
  end

  test "under forced yields the count survives every resume and frames are freed" do
    forced(K, fn ->
      # 8 iterations of zeroing in strips and loop back-edges, each a yield
      {res, count} = yields(K, fn -> K.alloc_loop(8, 128) end)
      assert res == Enum.sum(0..7)
      assert count > 0
      assert_raise ArgumentError, @oom, fn -> K.alloc_loop(9, 128) end
      assert_raise ArgumentError, @oom, fn -> K.alloc_loop(9, 128) end
      assert K.alloc_loop(8, 128) == Enum.sum(0..7)
      a = i64s(Enum.to_list(1..128))
      assert K.copy_kept(a, 3) == elixir(:copy_kept, [a, 3])
      assert_raise ArgumentError, @oom, fn -> K.copy_kept(a, 1000) end
      assert K.bits(1000) == elixir(:bits, [1000])
      assert_raise ArgumentError, ~r/^out of memory/, fn -> K.bits(10_000) end
    end)

    assert_frames_live(K)
  end

  # the owned table starts in the frame (four slots) and moves to the heap
  # at the fifth buffer: in straight-line code, and after the frame became a
  # resource on a yield, where the table pointer must follow the frame
  test "the owned table outgrows the frame's own slots, with and without a yield" do
    assert Default.five_allocs(16) == 15

    forced(Default, fn ->
      # 1.6 MB buffers: each one's zeroing in strips yields, so the frame is
      # a resource before the second buffer, and the fifth buffer moves the
      # table while the frame is one
      for n <- [1, 4, 5, 9] do
        {res, count} = yields(Default, fn -> Default.alloc_loop(n, 200_000) end)
        assert res == Enum.sum(0..(n - 1)), "alloc_loop(#{n})"
        assert count >= n, "alloc_loop(#{n}) yielded #{count} times"
      end

      # small buffers: the loop's own safepoints yield
      {res, count} = yields(Default, fn -> Default.alloc_loop(100, 128) end)
      assert res == Enum.sum(0..99)
      assert count > 0
      assert Default.five_allocs(16) == 15
    end)

    assert_frames_live(Default)
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

      assert [{_, text}] = owned_notes({:copy_kept, 2})
      assert text =~ "this copy is inside a loop: each iteration keeps a buffer"
      assert Defk.Report.format(K) =~ "each iteration keeps a buffer until the kernel returns"
    end

    test "does not note an alloc outside a loop" do
      assert owned_notes({:fill, 1}) == []
    end
  end

  describe "use Defk, max_owned_bytes:" do
    for bad <- ["0", "-1", ":big", "\"1024\"", "1.5e3", "18_446_744_073_709_551_616"] do
      test "rejects #{bad}" do
        assert_raise ArgumentError,
                     ~r/max_owned_bytes: expects a positive integer number of bytes/,
                     fn ->
                       Code.compile_string("""
                       defmodule Defk.OwnedBudgetTest.Bad do
                         use Defk, max_owned_bytes: #{unquote(bad)}

                         defk one() :: i64, do: 1
                       end
                       """)
                     end
      end
    end

    test "lists max_owned_bytes among the options" do
      assert_raise ArgumentError, ~r/`max_owned_bytes: n`/, fn ->
        Code.compile_string("""
        defmodule Defk.OwnedBudgetTest.Unknown do
          use Defk, max_bytes: 10
        end
        """)
      end
    end
  end
end
