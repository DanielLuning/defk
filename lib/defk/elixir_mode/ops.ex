defmodule Defk.ElixirMode.Ops do
  @moduledoc false
  # The operations Elixir mode's generated code calls where plain Elixir has
  # no limit: i64 range checks, packed-array reads and writes, and argument
  # checks. Each raises the same exception module as the kernel (and, where
  # the kernel's message is fixed, the same message), so the two modes agree.
  # Float arithmetic needs nothing here: Elixir already raises ArithmeticError
  # where a float operation would give inf or NaN (defk-q1c).

  @min -0x8000000000000000
  @max 0x7FFFFFFFFFFFFFFF
  # alloc/2 over DEFK_ALLOC_MAX_BYTES raises "length too large", as native
  # does (defk-gtv). From 2^47 bytes no platform's allocator serves the
  # request (native raises "out of memory"), and asking the VM for it aborts
  # the VM, so Elixir mode raises native's "out of memory" without trying.
  @max_alloc_bytes 2 ** 48
  @no_alloc_bytes 2 ** 47

  @max_u64 0xFFFFFFFFFFFFFFFF

  defguardp is_i64(x) when is_integer(x) and x >= @min and x <= @max
  defguardp is_u64(x) when is_integer(x) and x >= 0 and x <= @max_u64

  # ------------------------------------------------------------ integers --

  def add(a, b), do: fit(a + b, a, "+", b)
  def sub(a, b), do: fit(a - b, a, "-", b)
  def mul(a, b), do: fit(a * b, a, "*", b)
  def neg(a), do: sub(0, a)
  def abs(a) when a < 0, do: neg(a)
  def abs(a), do: a

  def div(_a, 0), do: raise(ArithmeticError, "div/2 by zero")
  def div(a, b), do: check(Kernel.div(a, b), "i64 overflow in div/2")

  def rem(_a, 0), do: raise(ArithmeticError, "rem/2 by zero")
  def rem(a, b), do: Kernel.rem(a, b)

  # float -> i64: the i64 range check also rejects what C can't convert
  def trunc(f), do: check(Kernel.trunc(f), "trunc/1: #{inspect(f)} does not fit in i64")
  def round(f), do: check(Kernel.round(f), "round/1: #{inspect(f)} does not fit in i64")

  # Bitwise.bsl/bsr with the i64 limit: the exact result, or ArithmeticError
  # where it leaves i64, as the kernel does (defk_bsl_i64). A shift past 63
  # is decided without Bitwise, which would build a huge bignum or raise
  # SystemLimitError for one.
  def bsl(a, n), do: shifted(shift(:bsl, a, n), "bsl", a, n)
  def bsr(a, n), do: shifted(shift(:bsr, a, n), "bsr", a, n)

  @doc false
  # bsl/bsr(a, n) on i64 values as Elixir computes them, or :overflow when
  # the exact result does not fit in i64 (also used by the compiler)
  def shift(:bsr, a, n), do: shift(:bsl, a, -n)
  def shift(:bsl, a, n) when n >= 64, do: if(a == 0, do: 0, else: :overflow)
  def shift(:bsl, a, n) when n <= -64, do: if(a < 0, do: -1, else: 0)

  def shift(:bsl, a, n) do
    r = Bitwise.bsl(a, n)
    if is_i64(r), do: r, else: :overflow
  end

  # masked arithmetic (Defk.Masked): bsl inside the mask, where only the low
  # 64 bits matter, so a shift of 64 or more is 0 without building a bignum
  def wbsl(_a, n) when n >= 64, do: 0
  def wbsl(a, n), do: Bitwise.bsl(a, n)

  # the same by a count that is not a literal: a negative count raises, as
  # the kernel's does (defk_wbsl)
  def wbsl_var(_a, n) when n < 0,
    do: raise(ArithmeticError, "bsl/2 by the negative count #{n} inside a mask")

  def wbsl_var(a, n), do: wbsl(a, n)

  # u64 (defk-wlu): + - * checked to 0..2^64 - 1, as the kernel's defk_add_u64
  def add_u64(a, b), do: fit_u64(a + b, a, "+", b)
  def sub_u64(a, b), do: fit_u64(a - b, a, "-", b)
  def mul_u64(a, b), do: fit_u64(a * b, a, "*", b)

  def div_u64(_a, 0), do: raise(ArithmeticError, "div/2 by zero")
  def div_u64(a, b), do: Kernel.div(a, b)
  def rem_u64(_a, 0), do: raise(ArithmeticError, "rem/2 by zero")
  def rem_u64(a, b), do: Kernel.rem(a, b)

  # bsl/bsr of a u64: exact (bsr of a u64 is logical); bsl raises past 2^64 - 1
  def bsl_u64(a, n), do: shifted_u64(shift_u64(a, n), "bsl", a, n)
  def bsr_u64(a, n), do: shifted_u64(shift_u64(a, -n), "bsr", a, n)

  defp shift_u64(a, n) when n >= 64, do: if(a == 0, do: 0, else: :overflow)
  defp shift_u64(_a, n) when n <= -64, do: 0

  defp shift_u64(a, n) do
    r = Bitwise.bsl(a, n)
    if is_u64(r), do: r, else: :overflow
  end

  defp shifted_u64(:overflow, f, a, n),
    do: raise(ArithmeticError, "u64 overflow in #{f}(#{a}, #{n})")

  defp shifted_u64(r, _f, _a, _n), do: r

  # a u64 where an i64 is expected and back: the same integer, or
  # ArithmeticError when the other type cannot hold it
  def u64_to_i64(a) when is_i64(a), do: a
  def u64_to_i64(a), do: raise(ArithmeticError, "#{a} does not fit in i64")
  def i64_to_u64(a) when a >= 0, do: a
  def i64_to_u64(a), do: raise(ArithmeticError, "#{a} does not fit in u64")

  defp fit_u64(r, _a, _op, _b) when is_u64(r), do: r
  defp fit_u64(_r, a, op, b), do: raise(ArithmeticError, "u64 overflow in #{a} #{op} #{b}")

  defp shifted(:overflow, f, a, n), do: raise(ArithmeticError, "i64 overflow in #{f}(#{a}, #{n})")
  defp shifted(r, _f, _a, _n), do: r

  defp fit(r, _a, _op, _b) when is_i64(r), do: r
  defp fit(_r, a, op, b), do: raise(ArithmeticError, "i64 overflow in #{a} #{op} #{b}")

  defp check(r, _msg) when is_i64(r), do: r
  defp check(_r, msg), do: raise(ArithmeticError, msg)

  # -------------------------------------------------------------- arrays --
  # [T] is a binary of native-endian T. Reads match it like the bitstring
  # match would; writes rebuild it (value semantics, defk-i2e).

  def alloc(n, _esz) when n < 0, do: raise(ArgumentError, "alloc/2: negative length #{n}")

  def alloc(n, esz) when n * esz > @max_alloc_bytes,
    do: raise(ArgumentError, "alloc/2: length too large")

  def alloc(n, esz) when n * esz >= @no_alloc_bytes,
    do: raise(ArgumentError, "out of memory (allocating #{n * esz} bytes)")

  def alloc(n, esz), do: <<0::size(n * esz)-unit(8)>>

  def len_f64(a), do: Kernel.div(byte_size(a), 8)
  def len_i64(a), do: Kernel.div(byte_size(a), 8)
  def len_u8(a), do: byte_size(a)
  def len_u64(a), do: Kernel.div(byte_size(a), 8)

  def get_f64(a, i) do
    case a do
      <<_::binary-size(^i * 8), x::float-64-native, _::binary>> when i >= 0 -> x
      _ -> get_failed(a, i, 8)
    end
  end

  def get_i64(a, i) do
    in_bounds!(a, i, 8)
    <<_::binary-size(^i * 8), x::signed-64-native, _::binary>> = a
    x
  end

  def get_u64(a, i) do
    in_bounds!(a, i, 8)
    <<_::binary-size(^i * 8), x::unsigned-64-native, _::binary>> = a
    x
  end

  def get_u8(a, i) do
    in_bounds!(a, i, 1)
    :binary.at(a, i)
  end

  # an f64 element whose bits are inf or NaN (only an input array can hold
  # one): ArgumentError, reason :non_finite_input (defk-q1c)
  defp get_failed(a, i, esz) do
    in_bounds!(a, i, esz)
    raise ArgumentError, "non-finite float (inf or NaN) read from an input array at index #{i}"
  end

  # a value that doesn't fit its element type raises before the bounds check,
  # as in the kernel
  def put_f64(a, i, x) when is_float(x), do: put(a, i, 8, <<x::float-64-native>>)
  def put_i64(a, i, x) when is_i64(x), do: put(a, i, 8, <<x::signed-64-native>>)
  def put_i64(_a, _i, x), do: raise(ArgumentError, "value #{x} does not fit in i64")
  def put_u8(a, i, x) when x in 0..255, do: put(a, i, 1, <<x>>)
  def put_u8(_a, _i, x), do: raise(ArgumentError, "value #{x} does not fit in u8")
  def put_u64(a, i, x) when is_u64(x), do: put(a, i, 8, <<x::unsigned-64-native>>)
  def put_u64(_a, _i, x), do: raise(ArgumentError, "value #{x} does not fit in u64")

  defp put(a, i, esz, bytes) do
    in_bounds!(a, i, esz)
    <<pre::binary-size(^i * ^esz), _::binary-size(^esz), post::binary>> = a
    <<pre::binary, bytes::binary, post::binary>>
  end

  # word loads from a [u8]: the unsigned w-byte integer at byte offset i, as
  # <<_::binary-size(i), x::little-unsigned-size(w * 8), _::binary>> = a;
  # u64 is the i64 bit pattern (signed), as the kernel returns it
  def u64_le(a, i), do: Defk.Bits.wrap64(:binary.decode_unsigned(word(a, i, 8), :little))
  def u64_be(a, i), do: Defk.Bits.wrap64(:binary.decode_unsigned(word(a, i, 8), :big))
  def u32_le(a, i), do: :binary.decode_unsigned(word(a, i, 4), :little)
  def u32_be(a, i), do: :binary.decode_unsigned(word(a, i, 4), :big)
  def u16_le(a, i), do: :binary.decode_unsigned(word(a, i, 2), :little)
  def u16_be(a, i), do: :binary.decode_unsigned(word(a, i, 2), :big)

  defp word(a, i, w) do
    if i < 0 or i > byte_size(a) - w do
      raise %Enum.OutOfBoundsError{
        message: "#{w}-byte load at index #{i} out of bounds for array of length #{byte_size(a)}",
        index: i
      }
    end

    binary_part(a, i, w)
  end

  # `for x <- a`: elements in order, each read only when the loop reaches it
  def elems_f64(a), do: Stream.map(0..(len_f64(a) - 1)//1, &get_f64(a, &1))
  def elems_i64(a), do: for(<<x::signed-64-native <- a>>, do: x)
  def elems_u8(a), do: :binary.bin_to_list(a)
  def elems_u64(a), do: for(<<x::unsigned-64-native <- a>>, do: x)

  defp in_bounds!(a, i, esz) do
    len = Kernel.div(byte_size(a), esz)

    if i < 0 or i >= len do
      raise %Enum.OutOfBoundsError{
        message: "index #{i} out of bounds for array of length #{len}",
        index: i
      }
    end
  end

  # ---------------------------------------------------------------- loops --

  # Every range generator is set up here: `a..b` counts down when a > b, as
  # in Elixir; a zero step raises ArgumentError, as Range does and the kernel
  # does. A range whose last element is within one step of the i64 limit
  # raises before its loop starts, as the kernel does (defk_range_limit):
  # the kernel's counter would overflow stepping past it (defk-gtv).
  def range(a, b), do: range(a, b, if(a <= b, do: 1, else: -1))

  def range(a, b, step) do
    r = a..b//step
    n = Range.size(r)
    last = a + (n - 1) * step

    if n > 0 and ((step > 0 and last > @max - step) or (step < 0 and last < @min - step)) do
      raise ArithmeticError,
            "range element #{last} is within one step of the i64 limit (stepping past it overflows)"
    end

    r
  end

  # ------------------------------------------------------------ arguments --
  # Checked like the kernel's entry: array arguments first, then scalars, each
  # in parameter order. An f64 parameter takes an integer that fits in i64 and
  # converts it, as the kernel does.

  def args!(args, params) do
    indexed = Enum.with_index(Enum.zip(args, params), 1)
    for {{arg, {p, {:arr, e}}}, n} <- indexed, do: array!(arg, n, p, e)

    for {{arg, {p, t}}, n} <- indexed,
        do: if(match?({:arr, _}, t), do: arg, else: scalar!(arg, t, n, p))
  end

  defp array!(a, n, p, e) do
    is_binary(a) || raise ArgumentError, "argument #{n} (#{p}) must be a binary of packed #{e}"
    esz = if e == :u8, do: 1, else: 8

    Kernel.rem(byte_size(a), esz) == 0 ||
      raise ArgumentError,
            "argument #{n} (#{p}): byte size #{byte_size(a)} is not a multiple of #{esz} (#{e})"
  end

  defp scalar!(x, :i64, _n, _p) when is_i64(x), do: x

  defp scalar!(_x, :i64, n, p),
    do: raise(ArgumentError, "argument #{n} (#{p}) must be an integer fitting in i64")

  defp scalar!(x, :f64, _n, _p) when is_float(x), do: x
  defp scalar!(x, :f64, _n, _p) when is_i64(x), do: :erlang.float(x)
  defp scalar!(_x, :f64, n, p), do: raise(ArgumentError, "argument #{n} (#{p}) must be a number")
  defp scalar!(x, :u64, _n, _p) when is_u64(x), do: x

  defp scalar!(_x, :u64, n, p),
    do: raise(ArgumentError, "argument #{n} (#{p}) must be an integer fitting in u64")

  defp scalar!(x, :bool, _n, _p) when is_boolean(x), do: x

  defp scalar!(_x, :bool, n, p),
    do: raise(ArgumentError, "argument #{n} (#{p}) must be a boolean")
end
