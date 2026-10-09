# Word loads from a [u8] (defk-n4r.2): u64_le(bytes, i) and friends read the
# unsigned w-byte integer at byte offset i, as Elixir's
# <<_::binary-size(i), x::little-unsigned-size(w * 8), _::binary>> = bytes,
# raise Enum.OutOfBoundsError like a[i] when i < 0 or i + w > len(bytes),
# and drop the check where the compiler proves i + w <= len(bytes). u64 is
# returned as its i64 bit pattern (a limit).

defmodule Defk.WordLoadsTest.K do
  use Defk

  defk(u64_le_f(b :: [u8], i :: i64) :: i64, do: u64_le(b, i))
  defk(u64_be_f(b :: [u8], i :: i64) :: i64, do: u64_be(b, i))
  defk(u32_le_f(b :: [u8], i :: i64) :: i64, do: u32_le(b, i))
  defk(u32_be_f(b :: [u8], i :: i64) :: i64, do: u32_be(b, i))
  defk(u16_le_f(b :: [u8], i :: i64) :: i64, do: u16_le(b, i))
  defk(u16_be_f(b :: [u8], i :: i64) :: i64, do: u16_be(b, i))

  # a binary module attribute is a [u8] in static storage (defk-ivt)
  @magic <<0x7F, "ELF", 2, 1, 1, 0>>
  defk(magic(i :: i64) :: i64, do: u32_be(@magic, i))

  # a load as an operand of checked arithmetic: the u64 bit pattern overflows
  defk(u64_plus(b :: [u8], i :: i64, x :: i64) :: i64, do: u64_le(b, i) + x)
end

# offsets proven in range: no bounds check
defmodule Defk.WordLoadsTest.Proven do
  use Defk

  # every 8-byte window, wrapped to 64 bits
  defk windows(b :: [u8]) :: i64 do
    for i <- 0..(len(b) - 8)//1, reduce: 0 do
      acc -> wrap64(acc + u64_le(b, i))
    end
  end

  # whole words, a step of 8
  defk words(b :: [u8]) :: i64 do
    for i <- 0..(len(b) - 8)//8, reduce: 0 do
      acc -> bxor(acc, u64_be(b, i))
    end
  end

  defk halves(b :: [u8]) :: i64 do
    for i <- 0..(len(b) - 4)//1, reduce: 0 do
      acc -> acc + u32_le(b, i) - u16_be(b, i + 2)
    end
  end

  # a u16 indexes a 65536-element table without a check
  defk lookup(b :: [u8]) :: i64 do
    table = alloc(u8, 65_536)

    for i <- 0..(len(b) - 2)//1, reduce: 0 do
      acc -> acc + table[u16_le(b, i)]
    end
  end
end

# one byte short of proven: the check stays and raises at the end
defmodule Defk.WordLoadsTest.Short do
  use Defk

  defk windows(b :: [u8]) :: i64 do
    for i <- 0..(len(b) - 7)//1, reduce: 0 do
      acc -> wrap64(acc + u64_le(b, i))
    end
  end
end

defmodule Defk.WordLoadsTest do
  use ExUnit.Case, async: true
  use Defk.Properties

  alias Defk.WordLoadsTest.{K, Proven, Short}

  @max_i64 0x7FFFFFFFFFFFFFFF

  @loads [
    {:u64_le_f, 8, :little},
    {:u64_be_f, 8, :big},
    {:u32_le_f, 4, :little},
    {:u32_be_f, 4, :big},
    {:u16_le_f, 2, :little},
    {:u16_be_f, 2, :big}
  ]

  # Elixir's own reading of the bytes, u64 as its i64 bit pattern
  defp elixir_load(bytes, i, w, endian) do
    bits = w * 8

    x =
      case endian do
        :little ->
          <<_::binary-size(^i), x::little-unsigned-size(^bits), _::binary>> = bytes
          x

        :big ->
          <<_::binary-size(^i), x::big-unsigned-size(^bits), _::binary>> = bytes
          x
      end

    if w == 8 do
      <<s::signed-64>> = <<x::64>>
      s
    else
      x
    end
  end

  defp agrees(mod \\ K, fun, args), do: Defk.Test.assert_agrees(mod, fun, args)

  test "every load at every offset matches the bitstring match" do
    bytes = :crypto.strong_rand_bytes(19) <> <<0xFF, 0x80, 0, 0x7F, 1, 2, 3, 4, 0xFE>>
    n = byte_size(bytes)

    for {f, w, endian} <- @loads, i <- -2..(n + 1) do
      if i >= 0 and i + w <= n do
        assert agrees(f, [bytes, i]) == {:ok, elixir_load(bytes, i, w, endian)}
      else
        assert {:raise, %Enum.OutOfBoundsError{index: ^i} = e} = agrees(f, [bytes, i])
        assert e.message == "#{w}-byte load at index #{i} out of bounds for array of length #{n}"
      end
    end
  end

  test "loads at the edges of the array and of i64" do
    for {f, w, _} <- @loads, n <- [0, 1, w - 1, w, w + 1] do
      bytes = :binary.copy(<<0xAB>>, n)

      for i <- [-1, 0, n - w, n - w + 1, n, 0x7FFFFFFFFFFFFFFF, -0x8000000000000000] do
        agrees(f, [bytes, i])
        agrees(f, [G.unaligned(bytes), i])
      end
    end
  end

  test "u64 gives the i64 bit pattern; u32 and u16 are exact" do
    ones = <<0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF>>
    assert K.u64_le_f(ones, 0) == -1
    assert K.u64_be_f(<<0x80, 0, 0, 0, 0, 0, 0, 0>>, 0) == -0x8000000000000000
    assert K.u64_le_f(<<0x80, 0, 0, 0, 0, 0, 0, 0>>, 0) == 0x80
    assert K.u64_le_f(<<1, 2, 3, 4, 5, 6, 7, 0x7F>>, 0) == 0x7F07060504030201
    assert K.u32_le_f(ones, 3) == 0xFFFFFFFF
    assert K.u32_be_f(<<0x12, 0x34, 0x56, 0x78>>, 0) == 0x12345678
    assert K.u16_le_f(ones, 6) == 0xFFFF
    assert K.u16_be_f(<<0x12, 0x34>>, 0) == 0x1234
    assert agrees(:magic, [0]) == {:ok, 0x7F454C46}
    assert {:raise, %Enum.OutOfBoundsError{index: 5}} = agrees(:magic, [5])

    # the bit pattern is an i64 like any other: checked arithmetic on it raises
    assert {:raise, %ArithmeticError{}} = agrees(:u64_plus, [ones <> <<0x7F>>, 1, 1])
    assert {:ok, -2} = agrees(:u64_plus, [ones, 0, -1])
  end

  test "a provable i + w <= len drops the check" do
    src = Proven.__defk_source__()
    refute src =~ ~r/defk_u(64|32|16)_(le|be)\(ctx/
    refute src =~ "defk_get_u8("
    assert src =~ "defk_u64_le_at("

    assert Short.__defk_source__() =~ "defk_u64_le(ctx"

    for n <- [0, 1, 7, 8, 9, 16, 17, 100] do
      bytes = :crypto.strong_rand_bytes(n)

      expect =
        if n < 8,
          do: 0,
          else:
            Enum.reduce(0..(n - 8), 0, fn i, acc ->
              <<s::signed-64>> = <<acc + elixir_load(bytes, i, 8, :little)::64>>
              s
            end)

      assert agrees(Proven, :windows, [bytes]) == {:ok, expect}
      agrees(Proven, :words, [bytes])
      agrees(Proven, :halves, [bytes])
      agrees(Proven, :lookup, [bytes])

      if n >= 7 do
        assert {:raise, %Enum.OutOfBoundsError{index: i}} = agrees(Short, :windows, [bytes])
        assert i == n - 7
      end
    end
  end

  # ------------------------------------------------------------ rejections --

  @dir Path.join(System.tmp_dir!(), "defk_word_loads_test")

  defp rejection(body, sig) do
    File.mkdir_p!(@dir)
    mod = "Defk.WordLoadsTest.Rej#{System.unique_integer([:positive])}"
    path = Path.join(@dir, "#{String.replace(mod, ".", "_")}.ex")

    File.write!(path, """
    defmodule #{mod} do
      use Defk

      defk f(#{sig}) :: i64 do
        #{body}
      end
    end
    """)

    e = assert_raise CompileError, fn -> Code.compile_file(path) end
    Exception.message(e)
  end

  defp codes(msg),
    do: Regex.scan(~r/^\(defk ([a-z0-9-]+)[:;] /m, msg) |> Enum.map(&Enum.at(&1, 1))

  defp whats(msg), do: Regex.scan(~r/^error: (.*)$/m, msg) |> Enum.map(&Enum.at(&1, 1))

  test "a load from an array that is not [u8], or at a float offset, is rejected" do
    msg = rejection("u64_le(a, 0)", "a :: [f64]")
    assert codes(msg) == ["builtin-arguments"]

    assert whats(msg) == [
             "u64_le/2 takes a [u8] array and an i64 byte offset, and is called here with ([f64], i64)"
           ]

    msg = rejection("u32_be(a, 0)", "a :: [i64]")
    assert codes(msg) == ["builtin-arguments"]

    msg = rejection("u16_le(a, x)", "a :: [u8], x :: f64")
    assert codes(msg) == ["builtin-arguments"]

    msg = rejection("u64_le(a)", "a :: [u8]")
    assert codes(msg) == ["builtin-arguments"]
  end

  # ---------------------------------------------------- agreement properties --

  # an array and an offset biased to the ends, past them, and the i64 limits
  defp offset_args do
    bind(G.array(:u8, max_length: 40), fn b ->
      n = byte_size(b)

      map(
        one_of([
          integer(-2..(n + 2)),
          member_of([n - 8, n - 7, n - 4, n - 3, n - 2, n - 1]),
          G.i64()
        ]),
        &[b, &1]
      )
    end)
  end

  agreement(K,
    u64_le_f: [args: offset_args()],
    u64_be_f: [args: offset_args()],
    u32_le_f: [args: offset_args()],
    u32_be_f: [args: offset_args()],
    u16_le_f: [args: offset_args()],
    u16_be_f: [args: offset_args()],
    magic: [args: fixed_list([G.i64(-2..8, [@max_i64])])],
    u64_plus: [args: bind(offset_args(), fn args -> map(G.i64(), &(args ++ [&1])) end)]
  )

  agreement(Proven, [:windows, :words, :halves, :lookup])
  agreement(Short, [:windows])
end
