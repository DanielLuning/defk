# alloc/2 sizes at the extremes (defk-gtv). n * sizeof(T) used to wrap, so
# alloc(f64, 2^61) made a 0-byte buffer of length 2^61 and a write inside its
# bounds crashed the VM. A length whose byte size is over 2^48 (the user
# address space of 64-bit platforms) raises "length too large"; one the
# allocator cannot provide raises "out of memory". Either way the VM survives
# and the next call works, and Elixir mode raises the same.

defmodule Defk.AllocTest.K do
  use Defk

  # the ticket's repro
  defk big(n :: i64, i :: i64) :: f64 do
    out = alloc(f64, n)
    out[i] = 1.0
    out[0]
  end

  defk len_f64(n :: i64) :: i64 do
    length(alloc(f64, n))
  end

  defk len_i64(n :: i64) :: i64 do
    length(alloc(i64, n))
  end

  defk len_u8(n :: i64) :: i64 do
    length(alloc(u8, n))
  end

  # the second alloc fails after the first one succeeded: its buffer is freed
  defk two(n :: i64) :: i64 do
    a = alloc(f64, 16)
    b = alloc(f64, n)
    length(a) + length(b)
  end

  # indices at the extremes: the bounds check casts the index to unsigned, so
  # -1 and index == len must raise instead of wrapping into the buffer
  defk at(a :: [i64], i :: i64) :: i64 do
    a[i]
  end

  defk put_at(n :: i64, i :: i64) :: i64 do
    out = alloc(i64, n)
    out[i] = 7
    out[i]
  end
end

defmodule Defk.AllocTest do
  use ExUnit.Case, async: true
  import Defk.Test.Frames
  import Defk.TestKit, only: [i64s: 1]
  use Defk.Properties
  alias Defk.AllocTest.K

  @i64_max 0x7FFF_FFFF_FFFF_FFFF
  @i64_min -0x8000_0000_0000_0000
  # DEFK_ALLOC_MAX_BYTES
  @max_bytes 2 ** 48

  defp too_large(fun) do
    assert_raise ArgumentError, "alloc/2: length too large", fun
  end

  defp out_of_memory(fun) do
    assert_raise ArgumentError, ~r/^out of memory \(allocating \d+ bytes\)$/, fun
  end

  test "the ticket's repro raises instead of crashing the VM" do
    too_large(fn -> K.big(2 ** 61, 100_000_000) end)
    assert K.big(4, 3) == 0.0
  end

  test "lengths whose byte size wraps a 64-bit word" do
    # 2^61 * 8 and 2^62 * 8 wrap to 0, 2^63-1 wraps for every element size > 1
    for n <- [2 ** 61, 2 ** 62, @i64_max, div(@i64_max, 8) + 1] do
      too_large(fn -> K.len_f64(n) end)
      too_large(fn -> K.len_i64(n) end)
    end

    too_large(fn -> K.len_u8(@i64_max) end)
  end

  test "lengths just over the limit" do
    too_large(fn -> K.len_u8(@max_bytes + 1) end)
    too_large(fn -> K.len_f64(div(@max_bytes, 8) + 1) end)
    too_large(fn -> K.len_i64(div(@max_bytes, 8) + 1) end)
    too_large(fn -> K.len_u8(2 ** 52) end)
    too_large(fn -> K.len_i64(2 ** 49) end)
  end

  test "the limit itself is beyond any allocator: out of memory" do
    out_of_memory(fn -> K.len_u8(@max_bytes) end)
    out_of_memory(fn -> K.len_f64(div(@max_bytes, 8)) end)
  end

  @tag skip: not match?({:unix, :darwin}, :os.type())
  test "just over the macOS allocation limit (mmap tops out under 2^47 bytes)" do
    out_of_memory(fn -> K.len_u8(2 ** 47) end)
    out_of_memory(fn -> K.len_f64(2 ** 44) end)
  end

  test "negative lengths" do
    for n <- [-1, -(2 ** 61), @i64_min] do
      assert_raise ArgumentError, "alloc/2: negative length #{n}", fn -> K.len_f64(n) end
      assert_raise ArgumentError, "alloc/2: negative length #{n}", fn -> K.len_u8(n) end
    end
  end

  test "a failed alloc after a successful one, then normal calls" do
    too_large(fn -> K.two(2 ** 61) end)
    out_of_memory(fn -> K.two(div(@max_bytes, 8)) end)
    assert K.two(4) == 20
    assert K.len_u8(0) == 0
    assert K.len_f64(1000) == 1000
  end

  test "Elixir mode raises the same" do
    sizes = [2 ** 61, 2 ** 62, @i64_max, @max_bytes + 1, @max_bytes, -1, @i64_min, 0, 1000]

    for f <- [:len_u8, :len_f64, :len_i64], n <- sizes do
      assert outcome(fn -> Defk.ElixirMode.with_mode(:native, fn -> apply(K, f, [n]) end) end) ==
               outcome(fn -> K.__defk_elixir__(f, [n]) end),
             "#{f}(#{n})"
    end
  end

  # sizes at their extremes are covered above (lengths just over the limit,
  # the macOS allocation limit, negative and wrapping lengths); indices are
  # the other half of the threat entry (defk-5fc)
  describe "indices at the extremes" do
    test "index -1 and index == len raise Enum.OutOfBoundsError in both modes" do
      a = i64s([10, 20, 30, 40])

      for i <- [-1, 4, 5] do
        assert {:raise, %Enum.OutOfBoundsError{index: ^i}} = both(:at, [a, i])
        assert {:raise, %Enum.OutOfBoundsError{index: ^i}} = both(:put_at, [4, i])
      end

      # an empty array: length 0, so every index is out of bounds, 0 included
      for i <- [-1, 0] do
        assert {:raise, %Enum.OutOfBoundsError{index: ^i}} = both(:at, [<<>>, i])
        assert {:raise, %Enum.OutOfBoundsError{index: ^i}} = both(:put_at, [0, i])
      end

      # the check did not wrap -1 into the last element
      assert both(:at, [a, 0]) == {:ok, 10}
      assert both(:at, [a, 3]) == {:ok, 40}
      assert both(:put_at, [4, 3]) == {:ok, 7}
      assert_frames_live(K)
    end

    test "an index at the i64 extremes raises instead of reaching memory" do
      a = i64s([10, 20])

      for i <- [@i64_min, @i64_max, 2 ** 61, -(2 ** 61), @i64_min + 1] do
        msg = "index #{i} out of bounds for array of length 2"
        assert {:raise, %Enum.OutOfBoundsError{index: ^i} = e} = both(:at, [a, i])
        assert Exception.message(e) == msg
        assert {:raise, %Enum.OutOfBoundsError{index: ^i} = e} = both(:put_at, [2, i])
        assert Exception.message(e) == msg
      end

      # the VM and the kernel are still healthy afterwards
      assert K.at(a, 1) == 20
      assert K.put_at(2, 1) == 7
      assert_frames_live(K)
    end
  end

  # runs native and Elixir mode and asserts they agree (the one rule), then
  # returns both outcomes as {:ok, value} or {:raise, exception}
  defp both(fun, args) do
    native = outcome(fn -> Defk.ElixirMode.with_mode(:native, fn -> apply(K, fun, args) end) end)
    assert native == outcome(fn -> K.__defk_elixir__(fun, args) end), "#{fun}#{inspect(args)}"
    native
  end

  defp outcome(f) do
    {:ok, f.()}
  rescue
    e -> {:raise, e}
  end

  # ---------------------------------------------------- agreement properties --
  # Every kernel here against its Elixir mode (defk-ne6), at lengths that are
  # small, negative, or at or past the alloc limit (Defk.Generators.alloc_len:
  # never one a real allocator might grant), and indices around them.

  defp len_and_index(esz) do
    bind(G.alloc_len(esz), fn n ->
      m = min(max(n, 0), 100)
      fixed_list([constant(n), frequency([{3, integer(-2..(m + 2))}, {1, G.i64()}])])
    end)
  end

  defp at do
    bind(G.array(:i64), fn a ->
      len = div(byte_size(a), 8)
      fixed_list([constant(a), frequency([{3, integer(-2..(len + 2))}, {1, G.i64()}])])
    end)
  end

  agreement(K,
    big: [args: len_and_index(8)],
    len_f64: [args: fixed_list([G.alloc_len(8)])],
    len_i64: [args: fixed_list([G.alloc_len(8)])],
    len_u8: [args: fixed_list([G.alloc_len(1)])],
    two: [args: fixed_list([G.alloc_len(8)])],
    at: [args: at()],
    put_at: [args: len_and_index(8)]
  )
end
