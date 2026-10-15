defmodule Defk.ElixirMode.Ops do
  @moduledoc false
  # The operations Elixir mode's generated code calls where plain Elixir has
  # no limit: i64 range checks, packed-array reads and writes, and argument
  # checks. Each raises the same exception module as the kernel (and, where
  # the kernel's message is fixed, the same message), so the two modes agree.
  # Float arithmetic needs nothing here: Elixir already raises ArithmeticError
  # where a float operation would give inf or NaN.

  # the messages, shared with the kernel's runtime (priv/defk_messages.h)
  require Defk.Messages, as: Messages

  @min -0x8000000000000000
  @max 0x7FFFFFFFFFFFFFFF
  # alloc/2 over DEFK_ALLOC_MAX_BYTES raises "length too large", as native
  # does. From 2^47 bytes no platform's allocator serves the request (native
  # raises "out of memory"), and asking the VM for it aborts the VM, so
  # Elixir mode raises native's "out of memory" without trying.
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

  def div(_a, 0), do: raise(ArithmeticError, Messages.text(:div_by_zero))
  def div(a, b), do: check(Kernel.div(a, b), Messages.text(:i64_overflow_div))

  def rem(_a, 0), do: raise(ArithmeticError, Messages.text(:rem_by_zero))
  def rem(a, b), do: Kernel.rem(a, b)

  # float -> i64: the i64 range check also rejects what C can't convert
  def trunc(f), do: check(Kernel.trunc(f), Messages.text(:trunc_fit, a: f))
  def round(f), do: check(Kernel.round(f), Messages.text(:round_fit, a: f))

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
    do: raise(ArithmeticError, Messages.text(:wbsl_negative, n: n))

  def wbsl_var(a, n), do: wbsl(a, n)

  # u64: + - * checked to 0..2^64 - 1, as the kernel's defk_add_u64
  def add_u64(a, b), do: fit_u64(a + b, a, "+", b)
  def sub_u64(a, b), do: fit_u64(a - b, a, "-", b)
  def mul_u64(a, b), do: fit_u64(a * b, a, "*", b)

  def div_u64(_a, 0), do: raise(ArithmeticError, Messages.text(:div_by_zero))
  def div_u64(a, b), do: Kernel.div(a, b)
  def rem_u64(_a, 0), do: raise(ArithmeticError, Messages.text(:rem_by_zero))
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
    do: raise(ArithmeticError, Messages.text(:u64_overflow_shift, f: f, a: a, n: n))

  defp shifted_u64(r, _f, _a, _n), do: r

  # a u64 where an i64 is expected and back: the same integer, or
  # ArithmeticError when the other type cannot hold it
  def u64_to_i64(a) when is_i64(a), do: a
  def u64_to_i64(a), do: raise(ArithmeticError, Messages.text(:u64_to_i64, a: a))
  def i64_to_u64(a) when a >= 0, do: a
  def i64_to_u64(a), do: raise(ArithmeticError, Messages.text(:i64_to_u64, a: a))

  defp fit_u64(r, _a, _op, _b) when is_u64(r), do: r

  defp fit_u64(_r, a, op, b),
    do: raise(ArithmeticError, Messages.text(:u64_overflow, a: a, op: op, b: b))

  defp shifted(:overflow, f, a, n),
    do: raise(ArithmeticError, Messages.text(:i64_overflow_shift, f: f, a: a, n: n))

  defp shifted(r, _f, _a, _n), do: r

  defp fit(r, _a, _op, _b) when is_i64(r), do: r

  defp fit(_r, a, op, b),
    do: raise(ArithmeticError, Messages.text(:i64_overflow, a: a, op: op, b: b))

  @doc false
  # Whether an ArithmeticError is an i64 or u64 limit (the exact result leaves
  # the type) and not an error Elixir would raise: a case guard raises the
  # first and fails its clause on the second
  def limit?(%ArithmeticError{} = e), do: Messages.reason(e) == :overflow

  defp check(r, _msg) when is_i64(r), do: r
  defp check(_r, msg), do: raise(ArithmeticError, msg)

  # -------------------------------------------------------------- arrays --
  # [T] is a binary of native-endian T. Reads match it like the bitstring
  # match would; writes rebuild it (value semantics).

  def alloc(n, _esz) when n < 0, do: raise(ArgumentError, Messages.text(:alloc_negative, n: n))

  def alloc(n, esz) when n * esz > @max_alloc_bytes,
    do: raise(ArgumentError, Messages.text(:alloc_too_large))

  def alloc(n, esz) when n * esz >= @no_alloc_bytes,
    do: raise(ArgumentError, Messages.text(:out_of_memory_bytes, bytes: n * esz))

  def alloc(n, esz) do
    bytes = n * esz
    own!(bytes)
    <<0::size(bytes)-unit(8)>>
  end

  # The owned-buffer budget. Native code keeps every
  # buffer a call allocates until the kernel returns and raises once the
  # call's live bytes would pass max_owned_bytes (defk_owned_check). Elixir
  # mode counts the bytes of every alloc/2 of the call against the same
  # max_owned_bytes, read from the module's native library (so the default,
  # half of physical memory, and `use Defk, max_owned_bytes:` are the same
  # number), and raises the
  # same message before building the binary. It cannot see what else native
  # code counts (value-semantics copies, bitstring accumulator buffers,
  # aligned copies of misaligned inputs), so its total is never above
  # native's: where Elixir mode raises, native has raised at that alloc or
  # before it.
  @owned :defk_em_owned

  @doc false
  # runs one Elixir-mode call (`__defk_elixir__/2`) with a fresh count
  def owned_call(max_owned_bytes, fun) do
    Process.put(@owned, {0, max_owned_bytes})

    try do
      fun.()
    after
      Process.delete(@owned)
    end
  end

  defp own!(bytes) do
    case Process.get(@owned) do
      {owned, max} when bytes > max - owned ->
        raise ArgumentError, Messages.text(:over_budget, bytes: bytes, max: max)

      {owned, max} ->
        Process.put(@owned, {owned + bytes, max})

      nil ->
        :ok
    end
  end

  def len_f64(a), do: Kernel.div(byte_size(a), 8)
  def len_i64(a), do: Kernel.div(byte_size(a), 8)
  def len_u8(a), do: byte_size(a)
  def len_u64(a), do: Kernel.div(byte_size(a), 8)
  def len_i16(a), do: Kernel.div(byte_size(a), 2)
  def len_i32(a), do: Kernel.div(byte_size(a), 4)
  def len_f32(a), do: Kernel.div(byte_size(a), 4)

  @doc false
  # bytes per element of [e]
  def esize(:u8), do: 1
  def esize(:i16), do: 2
  def esize(e) when e in [:i32, :f32], do: 4
  def esize(e) when e in [:i64, :f64, :u64], do: 8

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

  def get_i16(a, i) do
    in_bounds!(a, i, 2)
    <<_::binary-size(^i * 2), x::signed-16-native, _::binary>> = a
    x
  end

  def get_i32(a, i) do
    in_bounds!(a, i, 4)
    <<_::binary-size(^i * 4), x::signed-32-native, _::binary>> = a
    x
  end

  # f32 widens to the f64 of the same value, as the match does
  def get_f32(a, i) do
    case a do
      <<_::binary-size(^i * 4), x::float-32-native, _::binary>> when i >= 0 -> x
      _ -> get_failed(a, i, 4)
    end
  end

  # an f64 or f32 element whose bits are inf or NaN (only an input array can hold
  # one): ArgumentError, reason :non_finite_input
  defp get_failed(a, i, esz) do
    in_bounds!(a, i, esz)
    raise ArgumentError, Messages.text(:nonfinite_input, i: i)
  end

  # a value that doesn't fit its element type raises before the bounds check,
  # as in the kernel
  def put_f64(a, i, x) when is_float(x), do: put(a, i, 8, <<x::float-64-native>>)
  def put_i64(a, i, x) when is_i64(x), do: put(a, i, 8, <<x::signed-64-native>>)
  def put_i64(_a, _i, x), do: raise(ArgumentError, Messages.text(:value_i64, v: x))
  def put_u8(a, i, x) when x in 0..255, do: put(a, i, 1, <<x>>)
  def put_u8(_a, _i, x), do: raise(ArgumentError, Messages.text(:value_u8, v: x))
  def put_u64(a, i, x) when is_u64(x), do: put(a, i, 8, <<x::unsigned-64-native>>)
  def put_u64(_a, _i, x), do: raise(ArgumentError, Messages.text(:value_u64, v: x))

  def put_i16(a, i, x) when x in -0x8000..0x7FFF, do: put(a, i, 2, <<x::signed-16-native>>)
  def put_i16(_a, _i, x), do: raise(ArgumentError, Messages.text(:value_i16, v: x))

  def put_i32(a, i, x) when x in -0x80000000..0x7FFFFFFF,
    do: put(a, i, 4, <<x::signed-32-native>>)

  def put_i32(_a, _i, x), do: raise(ArgumentError, Messages.text(:value_i32, v: x))

  # rounded to nearest as the bitstring does; where that gives +-inf (which
  # Elixir stores, and no match reads back) the write raises, as the kernel's
  def put_f32(a, i, x) when is_float(x) do
    case <<x::float-32-native>> do
      <<_::float-32-native>> = bytes -> put(a, i, 4, bytes)
      _ -> raise ArgumentError, Messages.text(:value_f32, v: x)
    end
  end

  defp put(a, i, esz, bytes) do
    in_bounds!(a, i, esz)
    <<pre::binary-size(^i * ^esz), _::binary-size(^esz), post::binary>> = a
    <<pre::binary, bytes::binary, post::binary>>
  end

  # copy/5 and copy_back/4 on a packed array of esz-byte elements, checked in
  # the kernel's order (defk_rcopy_T): the length, the destination range, then
  # the source range (copy_back: the offset). copy_back is
  # out[at + j] = out[at + j - off] for j = 0..n-1 in order, so when off < n
  # the off elements before `at` repeat; the pattern copy below is that loop.
  def copy(a, at, s, from, n, esz) do
    if n < 0, do: raise(ArgumentError, Messages.text(:copy_negative, f: "copy/5", n: n))
    len = Kernel.div(byte_size(a), esz)
    slen = Kernel.div(byte_size(s), esz)
    if at < 0 or at > len - n, do: copy_oob("copy/5", n, "at", at, "array", len)
    if from < 0 or from > slen - n, do: copy_oob("copy/5", n, "from", from, "source array", slen)
    splice(a, at * esz, binary_part(s, from * esz, n * esz))
  end

  def copy_back(a, at, off, n, esz) do
    if n < 0, do: raise(ArgumentError, Messages.text(:copy_negative, f: "copy_back/4", n: n))
    len = Kernel.div(byte_size(a), esz)
    if at < 0 or at > len - n, do: copy_oob("copy_back/4", n, "at", at, "array", len)
    copy_back_offset!(at, off, n)
    copy_run(a, at, off, n, esz)
  end

  # the offset is checked only when something is copied: an empty copy reads
  # nothing (an LZ element with no match)
  defp copy_back_offset!(_at, _off, 0), do: :ok

  defp copy_back_offset!(_at, off, _n) when off < 1,
    do: raise(ArgumentError, Messages.text(:copy_back_offset, off: off))

  defp copy_back_offset!(at, off, _n) do
    if at < off do
      raise %Enum.OutOfBoundsError{
        message: Messages.text(:copy_back_before_start, off: off, at: at),
        index: at - off
      }
    end
  end

  defp copy_run(a, _at, _off, 0, _esz), do: a

  defp copy_run(a, at, off, n, esz) do
    run =
      if off >= n do
        binary_part(a, (at - off) * esz, n * esz)
      else
        pattern = binary_part(a, (at - off) * esz, off * esz)

        :binary.copy(pattern, Kernel.div(n, off)) <>
          binary_part(pattern, 0, Kernel.rem(n, off) * esz)
      end

    splice(a, at * esz, run)
  end

  defp copy_oob(f, n, where, i, what, len) do
    raise %Enum.OutOfBoundsError{
      message: Messages.text(:copy_oob, f: f, n: n, where: where, i: i, what: what, len: len),
      index: i
    }
  end

  defp splice(a, pos, bytes) do
    k = byte_size(bytes)
    <<pre::binary-size(^pos), _::binary-size(^k), post::binary>> = a
    <<pre::binary, bytes::binary, post::binary>>
  end

  # word loads from a [u8]: the unsigned w-byte integer at byte offset i, as
  # <<_::binary-size(i), x::little-unsigned-size(w * 8), _::binary>> = a;
  # u64 is the i64 bit pattern (signed), as the kernel returns it
  # <<acc::bitstring, v::size(n), ...>> with the bitstring accumulator's
  # limits, as the kernel checks them (defk_bits_put): a size outside 0..64,
  # or a value outside 0..2^n - 1 (-2^(n-1)..2^(n-1) - 1 for a signed
  # segment), which Elixir would truncate, raises. A signed 0-width segment
  # holds no bits and only 0 fits, as an unsigned one.
  def bits(acc, segs) do
    Enum.reduce(segs, acc, fn
      {_v, n, _signed}, _acc when n not in 0..64 ->
        raise ArgumentError, Messages.text(:segment_size, n: n)

      {v, n, false}, _acc when v < 0 or v > Bitwise.bsl(1, n) - 1 ->
        raise ArgumentError, Messages.text(:segment_fit, v: v, n: n, signed: "")

      {v, n, false}, acc ->
        <<acc::bitstring, v::size(n)>>

      {v, n, true}, acc ->
        signed_fits?(v, n) ||
          raise ArgumentError, Messages.text(:segment_fit, v: v, n: n, signed: " signed")

        <<acc::bitstring, v::signed-size(n)>>
    end)
  end

  defp signed_fits?(v, 0), do: v == 0
  defp signed_fits?(v, n), do: v in -Bitwise.bsl(1, n - 1)..(Bitwise.bsl(1, n - 1) - 1)

  def u64_le(a, i), do: Defk.Bits.wrap64(:binary.decode_unsigned(word(a, i, 8), :little))
  def u64_be(a, i), do: Defk.Bits.wrap64(:binary.decode_unsigned(word(a, i, 8), :big))
  def u32_le(a, i), do: :binary.decode_unsigned(word(a, i, 4), :little)
  def u32_be(a, i), do: :binary.decode_unsigned(word(a, i, 4), :big)
  def u16_le(a, i), do: :binary.decode_unsigned(word(a, i, 2), :little)
  def u16_be(a, i), do: :binary.decode_unsigned(word(a, i, 2), :big)

  defp word(a, i, w) do
    if i < 0 or i > byte_size(a) - w do
      raise %Enum.OutOfBoundsError{
        message: Messages.text(:oob_load, w: w, i: i, len: byte_size(a)),
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
  def elems_i16(a), do: for(<<x::signed-16-native <- a>>, do: x)
  def elems_i32(a), do: for(<<x::signed-32-native <- a>>, do: x)
  def elems_f32(a), do: Stream.map(0..(len_f32(a) - 1)//1, &get_f32(a, &1))

  defp in_bounds!(a, i, esz) do
    len = Kernel.div(byte_size(a), esz)

    if i < 0 or i >= len do
      raise %Enum.OutOfBoundsError{
        message: Messages.text(:oob, i: i, len: len),
        index: i
      }
    end
  end

  # ---------------------------------------------------------------- loops --

  # Every range generator is set up here: `a..b` counts down when a > b, as
  # in Elixir; a zero step raises ArgumentError, as Range does and the kernel
  # does. A range whose last element is within one step of the i64 limit
  # raises before its loop starts, as the kernel does (defk_range_limit):
  # the kernel's counter would overflow stepping past it.
  def range(a, b), do: range(a, b, if(a <= b, do: 1, else: -1))

  def range(a, b, step) do
    r = a..b//step
    n = Range.size(r)
    last = a + (n - 1) * step

    if n > 0 and ((step > 0 and last > @max - step) or (step < 0 and last < @min - step)) do
      raise ArithmeticError, Messages.text(:range_limit, last: last)
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
    is_binary(a) || raise ArgumentError, Messages.text(:arg_binary, n: n, p: p, t: e)
    esz = esize(e)

    Kernel.rem(byte_size(a), esz) == 0 ||
      raise ArgumentError,
            Messages.text(:arg_size, n: n, p: p, size: byte_size(a), esz: esz, t: e)
  end

  defp scalar!(x, :i64, _n, _p) when is_i64(x), do: x

  defp scalar!(_x, :i64, n, p),
    do: raise(ArgumentError, Messages.text(:arg_i64, n: n, p: p))

  defp scalar!(x, :f64, _n, _p) when is_float(x), do: x
  defp scalar!(x, :f64, _n, _p) when is_i64(x), do: :erlang.float(x)
  defp scalar!(_x, :f64, n, p), do: raise(ArgumentError, Messages.text(:arg_f64, n: n, p: p))
  defp scalar!(x, :u64, _n, _p) when is_u64(x), do: x

  defp scalar!(_x, :u64, n, p),
    do: raise(ArgumentError, Messages.text(:arg_u64, n: n, p: p))

  defp scalar!(x, :bool, _n, _p) when is_boolean(x), do: x

  defp scalar!(_x, :bool, n, p),
    do: raise(ArgumentError, Messages.text(:arg_bool, n: n, p: p))
end
