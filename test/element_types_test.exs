# The narrow element types [i16], [i32] and [f32] (defk-4ai, decided in
# defk-dtw.13). A read widens as Elixir's bitstring match does (i16/i32 to
# i64, f32 to f64 exactly); an integer write out of range raises; an f32
# write rounds to nearest as <<v::float-32-native>> does and raises where
# that gives +-inf (a limit: Elixir stores inf), while underflow to 0.0 and
# subnormals follow Elixir. Inf/NaN bits in an [f32] input raise when read
# (defk-q1c). An input whose byte size is not a multiple of the element
# width raises ArgumentError at the call. Every case runs in both modes.

defmodule Defk.ElementTypesTest.K do
  use Defk

  defk(at16(a :: [i16], i :: i64) :: i64, do: a[i])
  defk(at32(a :: [i32], i :: i64) :: i64, do: a[i])
  defk(atf32(a :: [f32], i :: i64) :: f64, do: a[i])

  defk lens(a :: [i16], b :: [i32], c :: [f32]) :: {i64, i64, i64} do
    {len(a), len(b), len(c)}
  end

  defk put16(v :: i64) :: [i16] do
    out = alloc(i16, 2)
    out[1] = v
    out
  end

  defk put32(v :: i64) :: [i32] do
    out = alloc(i32, 2)
    out[1] = v
    out
  end

  defk putf32(v :: f64) :: [f32] do
    out = alloc(f32, 2)
    out[1] = v
    out
  end

  # an integer stored into [f32] widens, as into [f64]
  defk putf32_int(v :: i64) :: [f32] do
    out = alloc(f32, 1)
    out[0] = v
    out
  end

  # an f32 the kernel wrote reads back rounded, without an inf/NaN check
  defk roundtrip(v :: f64) :: f64 do
    out = alloc(f32, 1)
    out[0] = v
    out[0] * 2.0
  end

  # a write into an input array copies it first; the caller's binary is kept
  defk set16(a :: [i16], i :: i64, v :: i64) :: [i16] do
    a[i] = v
    a
  end

  defk setf32(a :: [f32], i :: i64, v :: f64) :: [f32] do
    a[i] = v
    a
  end

  defk sum16(a :: [i16]) :: i64 do
    for x <- a, reduce: 0 do
      acc -> acc + x
    end
  end

  defk sum32(a :: [i32]) :: i64 do
    for x <- a, reduce: 0 do
      acc -> acc + x
    end
  end

  # a flat float loop over [f32] input reads (a flagged strip)
  defk sumf32(a :: [f32]) :: f64 do
    for x <- a, reduce: 0.0 do
      acc -> acc + x
    end
  end

  # f64 -> f32 in a flat loop: each write may overflow f32 (a flagged strip)
  defk narrow(a :: [f64]) :: [f32] do
    out = alloc(f32, len(a))

    for i <- 0..(len(a) - 1)//1 do
      out[i] = a[i]
    end

    out
  end

  defk scalef32(a :: [f32], k :: f64) :: [f32] do
    out = alloc(f32, len(a))

    for i <- 0..(len(a) - 1)//1 do
      out[i] = a[i] * k
    end

    out
  end

  defk widen(a :: [f32]) :: [f64] do
    out = alloc(f64, len(a))

    for i <- 0..(len(a) - 1)//1 do
      out[i] = a[i]
    end

    out
  end

  # i64 -> i16 with the range check on every write
  defk to16(a :: [i64]) :: [i16] do
    out = alloc(i16, len(a))

    for i <- 0..(len(a) - 1)//1 do
      out[i] = a[i]
    end

    out
  end

  defk to32(a :: [i64]) :: [i32] do
    out = alloc(i32, len(a))

    for i <- 0..(len(a) - 1)//1 do
      out[i] = a[i]
    end

    out
  end
end

# PCM mixing with clip prevention: the clamp's range facts prove every write
# fits in i16, so the store has no check, and the loop vectorises like hand C
# (the bounds are proven too: out has len(a) elements, i < min(len(a), len(b)))
defmodule Defk.ElementTypesTest.Mix do
  use Defk

  defk mix(a :: [i16], b :: [i16]) :: [i16] do
    out = alloc(i16, len(a))

    for i <- 0..(min(len(a), len(b)) - 1)//1 do
      out[i] = max(min(a[i] + b[i], 32_767), -32_768)
    end

    out
  end
end

defmodule Defk.ElementTypesTest do
  use ExUnit.Case, async: true
  use Defk.Properties

  alias Defk.ElementTypesTest.{K, Mix}

  @fmax 3.402_823_466_385_288_6e38
  # 2^128 - 2^103, halfway between the f32 maximum and 2^128: rounds to +inf
  @half 3.402_823_567_797_336_6e38
  @strip 2048

  defp agrees(fun, args), do: Defk.Test.assert_agrees(K, fun, args)

  defp raises(fun, args, module, reason) do
    assert {:raise, %^module{} = e} = agrees(fun, args)
    assert Defk.Test.reason(e) == reason
    e
  end

  defp element_range(fun, args), do: raises(fun, args, ArgumentError, :element_range)
  defp non_finite_input(fun, args), do: raises(fun, args, ArgumentError, :non_finite_input)
  defp badarg(fun, args), do: raises(fun, args, ArgumentError, :badarg)

  defp i16s(xs), do: for(x <- xs, into: <<>>, do: <<x::signed-16-native>>)
  defp i32s(xs), do: for(x <- xs, into: <<>>, do: <<x::signed-32-native>>)
  defp i64s(xs), do: for(x <- xs, into: <<>>, do: <<x::signed-64-native>>)
  defp f64s(xs), do: for(x <- xs, into: <<>>, do: <<x::float-64-native>>)
  defp f32s(xs), do: for(x <- xs, into: <<>>, do: f32(x))

  defp f32(:inf), do: <<0x7F800000::32-native>>
  defp f32(:neg_inf), do: <<0xFF800000::32-native>>
  defp f32(:nan), do: <<0x7FC00000::32-native>>
  defp f32(x), do: <<x::float-32-native>>

  defp next_down(x) do
    <<b::64>> = <<x::float-64>>
    <<y::float-64>> = <<b - 1::64>>
    y
  end

  test "reads widen to i64 and f64 as the bitstring match does" do
    a = i16s([-32_768, -1, 0, 32_767])

    for {x, i} <- Enum.with_index([-32_768, -1, 0, 32_767]),
        do: assert({:ok, ^x} = agrees(:at16, [a, i]))

    b = i32s([-2_147_483_648, 2_147_483_647, 7])
    assert {:ok, -2_147_483_648} = agrees(:at32, [b, 0])
    assert {:ok, 2_147_483_647} = agrees(:at32, [b, 1])

    c = f32s([0.1, -0.0, @fmax, 1.0e-40])
    <<x::float-32-native>> = f32(0.1)
    assert {:ok, ^x} = agrees(:atf32, [c, 0])
    assert {:ok, -0.0} = agrees(:atf32, [c, 1])
    assert {:ok, @fmax} = agrees(:atf32, [c, 2])
    assert {:ok, 9.99994610111476e-41} = agrees(:atf32, [c, 3])

    assert {:raise, %Enum.OutOfBoundsError{}} = agrees(:at16, [a, 4])
    assert {:raise, %Enum.OutOfBoundsError{}} = agrees(:atf32, [c, -1])
    assert {:ok, {4, 3, 4}} = agrees(:lens, [a, b, c])
  end

  test "an i16 write raises outside -32768..32767" do
    assert {:ok, <<0::16, 32_767::signed-16-native>>} = agrees(:put16, [32_767])
    assert {:ok, <<0::16, -32_768::signed-16-native>>} = agrees(:put16, [-32_768])
    e = element_range(:put16, [32_768])
    assert e.message =~ "does not fit in i16"
    element_range(:put16, [-32_769])
    element_range(:put16, [0x7FFFFFFFFFFFFFFF])
  end

  test "an i32 write raises outside the i32 range" do
    assert {:ok, <<0::32, 2_147_483_647::signed-32-native>>} = agrees(:put32, [2_147_483_647])
    assert {:ok, <<0::32, -2_147_483_648::signed-32-native>>} = agrees(:put32, [-2_147_483_648])
    element_range(:put32, [2_147_483_648])
    element_range(:put32, [-2_147_483_649])
  end

  test "an f32 write rounds to nearest, and raises where that gives inf" do
    for x <- [
          0.1,
          -0.1,
          1.0e-50,
          -1.0e-50,
          1.0e-40,
          @fmax,
          -@fmax,
          next_down(@half),
          1.0,
          0.0,
          -0.0
        ] do
      expected = <<0::32>> <> f32(x)
      assert {:ok, ^expected} = agrees(:putf32, [x])
    end

    for x <- [@half, -@half, 1.0e40, -1.0e40, 1.797_693_134_862_315_7e308] do
      e = element_range(:putf32, [x])
      assert e.message =~ "does not fit in f32"
    end

    assert {:ok, <<16_777_216.0::float-32-native>>} = agrees(:putf32_int, [16_777_217])
    # every i64 is in the f32 range (2^63 < 3.4e38)
    assert {:ok, _} = agrees(:putf32_int, [0x7FFFFFFFFFFFFFFF])
    <<r::float-32-native>> = f32(0.1)
    assert {:ok, d} = agrees(:roundtrip, [0.1])
    assert d === r * 2.0
  end

  test "a write into an input array copies it; the caller's binary is unchanged" do
    a = i16s([1, 2, 3])
    assert {:ok, out} = agrees(:set16, [a, 1, -5])
    assert out == i16s([1, -5, 3])
    assert a == i16s([1, 2, 3])
    element_range(:set16, [a, 1, 40_000])
    assert {:raise, %Enum.OutOfBoundsError{}} = agrees(:set16, [a, 3, 0])
    # the range check comes before the bounds check, in both modes
    element_range(:set16, [a, 3, 40_000])

    c = f32s([1.0, 2.0])
    assert {:ok, out} = agrees(:setf32, [c, 0, 0.5])
    assert out == f32s([0.5, 2.0])
    element_range(:setf32, [c, 5, 1.0e40])
  end

  test "an input whose byte size is not a multiple of the element width raises" do
    badarg(:at16, [<<1, 2, 3>>, 0])
    badarg(:at32, [<<1, 2, 3, 4, 5, 6>>, 0])
    badarg(:atf32, [<<1, 2, 3, 4, 5>>, 0])
    e = badarg(:lens, [<<>>, <<>>, <<1, 2>>])
    assert e.message =~ "is not a multiple of 4 (f32)"
    assert {:ok, {0, 0, 0}} = agrees(:lens, [<<>>, <<>>, <<>>])
  end

  test "an unaligned sub-binary reads the same elements" do
    <<_::8, a::binary>> = <<0>> <> i16s([5, -6, 7])
    assert {:ok, 6} = agrees(:sum16, [a])
    <<_::8, c::binary>> = <<0>> <> f32s([1.5, 2.5])
    assert {:ok, 4.0} = agrees(:sumf32, [c])
  end

  test "inf or NaN bits in an [f32] input raise when read, not when unread" do
    c = f32s([1.0, :inf, :nan, :neg_inf])
    assert {:ok, 1.0} = agrees(:atf32, [c, 0])
    for i <- 1..3, do: assert(non_finite_input(:atf32, [c, i]).message =~ "at index #{i}")
    non_finite_input(:sumf32, [c])
    non_finite_input(:widen, [c])
  end

  test "sums widen before adding" do
    assert {:ok, 98_301} = agrees(:sum16, [i16s([32_767, 32_767, 32_767])])

    assert {:ok, 6_442_450_941} =
             agrees(:sum32, [i32s([2_147_483_647, 2_147_483_647, 2_147_483_647])])
  end

  # positions in the first strip, at its end and in the next one
  defp positions(n),
    do: Enum.uniq(for p <- [0, 1, @strip - 1, @strip, @strip + 1, n - 1], p < n, do: p)

  # n elements, fill(i) everywhere but at p
  defp with_bad(n, p, bad, fill),
    do: for(i <- 0..(n - 1), do: if(i == p, do: bad, else: fill.(i)))

  defp fails_at(n, p) do
    element_range(:narrow, [f64s(with_bad(n, p, 1.0e40, &(&1 * 0.5)))])
    # every element from p on fails: still an f32 range error
    element_range(:narrow, [f64s(for i <- 0..(n - 1), do: if(i >= p, do: -1.0e39, else: 1.0))])

    c = f32s(with_bad(n, p, :nan, fn _ -> 1.0 end))
    assert non_finite_input(:sumf32, [c]).message =~ "at index #{p}"
    assert non_finite_input(:scalef32, [c, 2.0]).message =~ "at index #{p}"
    element_range(:scalef32, [f32s(with_bad(n, p, @fmax, fn _ -> 1.0 end)), 2.0])

    element_range(:to16, [i64s(with_bad(n, p, 32_768, & &1))])
    element_range(:to32, [i64s(with_bad(n, p, -2_147_483_649, &(-&1)))])
  end

  defp passes(n) do
    xs = for i <- 0..(n - 1), do: i * 0.1
    assert {:ok, out} = agrees(:narrow, [f64s(xs)])
    assert out == f32s(xs)
    assert {:ok, ^out} = agrees(:scalef32, [out, 1.0])
    assert {:ok, _} = agrees(:widen, [out])
    assert {:ok, _} = agrees(:sumf32, [out])
    assert {:ok, out16} = agrees(:to16, [i64s(for i <- 0..(n - 1), do: i - 2000)])
    assert out16 == i16s(for i <- 0..(n - 1), do: i - 2000)
  end

  defp strips(force?) do
    K.__defk_force_yields__(force?)

    try do
      for n <- [100, 2 * @strip + 3], p <- positions(n), do: fails_at(n, p)
      passes(2 * @strip + 3)
    after
      K.__defk_force_yields__(false)
    end
  end

  test "loops raise at the first failing element, at any position" do
    strips(false)
  end

  test "loops raise at the first failing element under forced yields" do
    strips(true)
  end

  test "PCM mixing clips to i16 and agrees with Elixir mode" do
    a = i16s([30_000, -30_000, 1, 32_767, -32_768])
    b = i16s([30_000, -30_000, 2, 0, -1, 99])
    native = Defk.ElixirMode.with_mode(:native, fn -> Mix.mix(a, b) end)
    assert native == i16s([32_767, -32_768, 3, 32_767, -32_768])
    # b shorter than a: the rest of out stays 0
    assert Mix.mix(a, i16s([1, 1])) == i16s([30_001, -29_999, 0, 0, 0])
    assert native === Mix.__defk_elixir__(:mix, [a, b])

    n = 2 * @strip + 3
    big = i16s(for i <- 0..(n - 1), do: rem(i * 7919, 65_536) - 32_768)
    Mix.__defk_force_yields__(true)

    try do
      assert {:ok, _} = Defk.Test.assert_agrees(Mix, :mix, [big, big])
    after
      Mix.__defk_force_yields__(false)
    end
  end

  test "the clamp's range facts drop the i16 write check" do
    c = File.read!(String.replace_suffix(Mix.__defk_lib__(), ".so", ".c"))
    refute c =~ "defk_to_i16("
    refute c =~ "defk_put_i16("
    refute c =~ "defk_get_i16("
    assert c =~ "(int16_t)"
  end

  test "an unknown element type lists the supported set" do
    src = """
    defmodule Defk.ElementTypesTest.Bad do
      use Defk
      defk f(a :: [u16]) :: i64, do: len(a)
    end
    """

    e = assert_raise CompileError, fn -> Code.compile_string(src) end
    assert Exception.message(e) =~ "f64, f32, i64, i32, i16, u8 and u64"

    src = """
    defmodule Defk.ElementTypesTest.BadAlloc do
      use Defk
      defk f(n :: i64) :: i64, do: len(alloc(u16, n))
    end
    """

    e = assert_raise CompileError, fn -> Code.compile_string(src) end
    assert Exception.message(e) =~ "f64, f32, i64, i32, i16, u8 and u64"
  end

  # ---------------------------------------------------- agreement properties --

  agreement(K,
    at16: [args: fixed_list([G.array(:i16), G.i64(-2..70)])],
    at32: [args: fixed_list([G.array(:i32), G.i64(-2..70)])],
    atf32: [args: fixed_list([one_of([G.array(:f32), G.array_non_finite(:f32)]), G.i64(-2..70)])],
    lens: [],
    put16: [],
    put32: [],
    putf32: [],
    putf32_int: [],
    roundtrip: [],
    set16: [args: fixed_list([G.array(:i16), G.i64(-2..70), G.i64()])],
    setf32: [args: fixed_list([G.array(:f32), G.i64(-2..70), G.f64()])],
    sum16: [],
    sum32: [],
    sumf32: [args: fixed_list([one_of([G.array(:f32), G.array_non_finite(:f32)])])],
    narrow: [args: fixed_list([G.array(:f64, of: G.f64(1.0e40))])],
    scalef32: [args: fixed_list([G.array(:f32), G.f64(1.0e10)])],
    widen: [args: fixed_list([one_of([G.array(:f32), G.array_non_finite(:f32)])])],
    to16: [args: fixed_list([G.array(:i64, of: G.i64(-40_000..40_000))])],
    to32: []
  )

  agreement(Mix, mix: [])
end
