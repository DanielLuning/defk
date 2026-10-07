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
  # alloc/2 refuses arrays this large instead of letting the VM abort on a
  # failed allocation; native raises ArgumentError for such sizes too (defk-gtv)
  @max_alloc_bytes 0x1000000000000

  defguardp is_i64(x) when is_integer(x) and x >= @min and x <= @max

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

  defp fit(r, _a, _op, _b) when is_i64(r), do: r
  defp fit(_r, a, op, b), do: raise(ArithmeticError, "i64 overflow in #{a} #{op} #{b}")

  defp check(r, _msg) when is_i64(r), do: r
  defp check(_r, msg), do: raise(ArithmeticError, msg)

  # -------------------------------------------------------------- arrays --
  # [T] is a binary of native-endian T. Reads match it like the bitstring
  # match would; writes rebuild it (value semantics, defk-i2e).

  def alloc(n, _esz) when n < 0, do: raise(ArgumentError, "alloc/2: negative length #{n}")
  def alloc(n, esz) when n * esz > @max_alloc_bytes, do: raise(ArgumentError, "alloc/2: length too large")
  def alloc(n, esz), do: <<0::size(n * esz)-unit(8)>>

  def len_f64(a), do: Kernel.div(byte_size(a), 8)
  def len_i64(a), do: Kernel.div(byte_size(a), 8)
  def len_u8(a), do: byte_size(a)

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
  def put_i64(a, i, x), do: put(a, i, 8, <<x::signed-64-native>>)
  def put_u8(a, i, x) when x in 0..255, do: put(a, i, 1, <<x>>)
  def put_u8(_a, _i, x), do: raise(ArgumentError, "value #{x} does not fit in u8")

  defp put(a, i, esz, bytes) do
    in_bounds!(a, i, esz)
    <<pre::binary-size(^i * ^esz), _::binary-size(^esz), post::binary>> = a
    <<pre::binary, bytes::binary, post::binary>>
  end

  # `for x <- a`: elements in order, each read only when the loop reaches it
  def elems_f64(a), do: Stream.map(0..(len_f64(a) - 1)//1, &get_f64(a, &1))
  def elems_i64(a), do: for(<<x::signed-64-native <- a>>, do: x)
  def elems_u8(a), do: :binary.bin_to_list(a)

  defp in_bounds!(a, i, esz) do
    len = Kernel.div(byte_size(a), esz)

    if i < 0 or i >= len do
      raise %Enum.OutOfBoundsError{message: "index #{i} out of bounds for array of length #{len}", index: i}
    end
  end

  # ---------------------------------------------------------------- loops --

  # Every range generator is set up here: `a..b` counts down when a > b, as
  # in Elixir; a zero step raises ArgumentError, as Range does and the kernel
  # does. (A range-level limit the kernel checks before its loop starts
  # belongs here.)
  def range(a, b), do: range(a, b, if(a <= b, do: 1, else: -1))
  def range(a, b, step), do: a..b//step

  # ------------------------------------------------------------ arguments --
  # Checked like the kernel's entry: array arguments first, then scalars, each
  # in parameter order. An f64 parameter takes an integer that fits in i64 and
  # converts it, as the kernel does.

  def args!(args, params) do
    indexed = Enum.with_index(Enum.zip(args, params), 1)
    for {{arg, {p, {:arr, e}}}, n} <- indexed, do: array!(arg, n, p, e)
    for {{arg, {p, t}}, n} <- indexed, do: if(match?({:arr, _}, t), do: arg, else: scalar!(arg, t, n, p))
  end

  defp array!(a, n, p, e) do
    is_binary(a) || raise ArgumentError, "argument #{n} (#{p}) must be a binary of packed #{e}"
    esz = if e == :u8, do: 1, else: 8

    Kernel.rem(byte_size(a), esz) == 0 ||
      raise ArgumentError, "argument #{n} (#{p}): byte size #{byte_size(a)} is not a multiple of #{esz} (#{e})"
  end

  defp scalar!(x, :i64, _n, _p) when is_i64(x), do: x
  defp scalar!(_x, :i64, n, p), do: raise(ArgumentError, "argument #{n} (#{p}) must be an integer fitting in i64")
  defp scalar!(x, :f64, _n, _p) when is_float(x), do: x
  defp scalar!(x, :f64, _n, _p) when is_i64(x), do: :erlang.float(x)
  defp scalar!(_x, :f64, n, p), do: raise(ArgumentError, "argument #{n} (#{p}) must be a number")
  defp scalar!(x, :bool, _n, _p) when is_boolean(x), do: x
  defp scalar!(_x, :bool, n, p), do: raise(ArgumentError, "argument #{n} (#{p}) must be a boolean")
end
