# alloc/2 sizes at the extremes (defk-gtv). n * sizeof(T) used to wrap, so
# alloc(f64, 2^61) made a 0-byte buffer of length 2^61 and a write inside its
# bounds crashed the VM. A length whose byte size is over the largest BEAM
# binary raises "length too large"; one the allocator cannot provide raises
# "out of memory". Either way the VM survives and the next call works.

defmodule Defk.AllocTest.K do
  use Defk

  # the ticket's repro
  defk big(n :: i64, i :: i64) :: f64 do
    out = alloc(f64, n)
    out[i] = 1.0
    out[0]
  end

  defk len_f64(n :: i64) :: i64 do
    len(alloc(f64, n))
  end

  defk len_i64(n :: i64) :: i64 do
    len(alloc(i64, n))
  end

  defk len_u8(n :: i64) :: i64 do
    len(alloc(u8, n))
  end

  # the second alloc fails after the first one succeeded: its buffer is freed
  defk two(n :: i64) :: i64 do
    a = alloc(f64, 16)
    b = alloc(f64, n)
    len(a) + len(b)
  end
end

defmodule Defk.AllocTest do
  use ExUnit.Case, async: true
  alias Defk.AllocTest.K

  @i64_max 0x7FFF_FFFF_FFFF_FFFF
  @i64_min -0x8000_0000_0000_0000
  # DEFK_ALLOC_MAX_BYTES
  @max_bytes 2 ** 60

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

  test "lengths just over the largest binary" do
    too_large(fn -> K.len_u8(@max_bytes + 1) end)
    too_large(fn -> K.len_f64(div(@max_bytes, 8) + 1) end)
    too_large(fn -> K.len_i64(div(@max_bytes, 8) + 1) end)
  end

  test "sizes under that limit but beyond any allocator raise out of memory" do
    # 2^52 bytes (4 PiB) is past the user address space of every 64-bit platform
    out_of_memory(fn -> K.len_u8(@max_bytes) end)
    out_of_memory(fn -> K.len_f64(div(@max_bytes, 8)) end)
    out_of_memory(fn -> K.len_u8(2 ** 52) end)
    out_of_memory(fn -> K.len_i64(2 ** 49) end)
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
end
