defmodule Defk.Generators do
  @moduledoc false
  # Edge-biased generators for kernel arguments (defk-63k, defk-ne6). Each
  # mixes uniform draws with a fixed set of values where native code and
  # Elixir most plausibly part ways: the i64 limits and their neighbours,
  # the points where a double stops holding every integer (2^53) or any i64
  # (2^63), signed zeros, subnormals, and arrays of length 0, 1 and around
  # DEFK_STRIP (flat loops run in strips of 2048, docs/project.md design decision 3),
  # passed aligned or as an unaligned sub-binary.

  import StreamData

  @i64_min -0x8000000000000000
  @i64_max 0x7FFFFFFFFFFFFFFF
  @strip 2048
  # DEFK_ALLOC_MAX_BYTES: alloc/2 over it raises "length too large", and at it
  # "out of memory" (Defk.ElixirMode.Ops)
  @max_alloc_bytes 2 ** 48
  # from 2^47 bytes neither mode tries to allocate (DEFK_NO_ALLOC_BYTES)
  @no_alloc_bytes 2 ** 47

  @i64_edges Enum.uniq([
               0,
               1,
               -1,
               @i64_min,
               @i64_max,
               @i64_min + 1,
               @i64_max - 1,
               2 ** 31,
               -(2 ** 31),
               2 ** 53,
               2 ** 53 - 1,
               2 ** 53 + 1,
               -(2 ** 53),
               -(2 ** 53 - 1),
               -(2 ** 53 + 1),
               2 ** 62,
               -(2 ** 62)
             ])

  # 2^53 + 1 is not a double: its neighbours are 2^53 and 2^53 + 2. The
  # doubles next to 2^63 are 2^63 - 1024 and 2^63 + 2048.
  @pos_f64_edges [
    0.0,
    1.0,
    5.0e-324,
    2.2e-308,
    2.2250738585072014e-308,
    1.7e308,
    1.797_693_134_862_315_7e308,
    9_007_199_254_740_991.0,
    9_007_199_254_740_992.0,
    9_007_199_254_740_994.0,
    9_223_372_036_854_774_784.0,
    9_223_372_036_854_775_808.0,
    9_223_372_036_854_777_856.0
  ]
  @f64_edges @pos_f64_edges ++ Enum.map(@pos_f64_edges, &(-&1))

  @doc "The i64 edge values."
  def i64_edges, do: @i64_edges

  @doc "The f64 edge values (both signs, so -0.0 too)."
  def f64_edges, do: @f64_edges

  @doc "Any i64: uniform, small, or an edge value."
  def i64 do
    frequency([
      {4, integer(@i64_min..@i64_max)},
      {2, integer(-1000..1000)},
      {3, member_of(@i64_edges)}
    ])
  end

  @u64_edges [
    0,
    1,
    2,
    @i64_max,
    @i64_max + 1,
    @i64_max + 2,
    2 ** 64 - 1,
    2 ** 64 - 2,
    2 ** 32,
    2 ** 53 + 1
  ]

  @doc "Any u64: uniform, small, or an edge value (2^63 - 1, 2^63, 2^64 - 1, ...)."
  def u64 do
    frequency([
      {4, integer(0..(2 ** 64 - 1))},
      {2, integer(0..1000)},
      {3, member_of(@u64_edges)}
    ])
  end

  @doc """
  An i64 in `range` (uniform, the range's ends, or an edge value inside it),
  or one of `extra`. For arguments that set a loop's trip count, where an
  arbitrary i64 would run for hours: `extra` adds the edges that are still
  cheap, such as the i64 maximum, which makes a range raise before its loop.
  """
  def i64(first..last//_ = range, extra \\ []) do
    edges = Enum.uniq(Enum.filter(@i64_edges, &(&1 in range)) ++ [first, last] ++ extra)
    frequency([{6, integer(range)}, {3, member_of(edges)}])
  end

  @doc """
  An alloc/2 length for elements of `esz` bytes: small, negative, or one at
  or past the alloc limit. Never a size a real allocator might grant (a
  2^31-element f64 array would allocate 16 GB in both modes).
  """
  def alloc_len(esz, small \\ 0..64) do
    over = div(@max_alloc_bytes, esz)
    # 2^47 bytes: out of memory without trying; one element less: past any
    # host's max_owned_bytes (half of physical memory by default), so both modes
    # raise the budget's out of memory before allocating (defk-bh3)
    no_alloc = div(@no_alloc_bytes, esz)

    safe =
      Enum.filter(@i64_edges, fn n -> n < 0 or n * esz < 2 ** 24 or n * esz > @max_alloc_bytes end)

    frequency([
      {6, integer(small)},
      {3, member_of(Enum.uniq(safe ++ [over, over + 1, -over, no_alloc, no_alloc - 1]))}
    ])
  end

  # StreamData.float/1 costs about 30 us a draw, too slow for 2049-element
  # arrays, so floats are built from integers: a scaled uniform draw, a
  # mantissa times a power of two (every magnitude equally likely), or 64
  # random bits.

  @doc "Any f64: uniform, any magnitude, any bit pattern, or an edge value."
  def f64 do
    frequency([
      {2, scaled(1.0e3)},
      {2, scaled(1.0e300)},
      {2, magnitude(1023)},
      {2, float_bits()},
      {3, member_of(@f64_edges)}
    ])
  end

  @doc """
  An f64 with magnitude at most `max_abs` (uniform, any magnitude up to it,
  or an edge value within it): for kernels whose arithmetic would mostly
  overflow to inf on any f64 (both modes raise, defk-i00), so that their
  computed values are compared too.
  """
  def f64(max_abs) when is_float(max_abs) do
    frequency([
      {3, scaled(max_abs)},
      {1, scaled(1.0)},
      {2, magnitude(trunc(:math.log2(max_abs)) - 1)},
      {3, member_of(Enum.filter(@f64_edges, &(abs(&1) <= max_abs)))}
    ])
  end

  # uniform in [-max_abs, max_abs]
  defp scaled(max_abs) do
    map(integer(-1_000_000_000..1_000_000_000), &(&1 / 1_000_000_000 * max_abs))
  end

  # m * 2^e with |m| < 2^53, so |x| < 2^(emax + 1); e from the subnormals up
  defp magnitude(emax) do
    map(tuple({integer(-(2 ** 53 - 1)..(2 ** 53 - 1)), integer(-1074..(emax - 52))}), fn {m, e} ->
      m * :math.pow(2.0, e)
    end)
  end

  # a finite double from 64 random bits
  defp float_bits do
    map(integer(0..(2 ** 64 - 1)), fn bits ->
      case <<bits::64>> do
        <<f::float-64>> -> f
        _ -> 0.0
      end
    end)
  end

  def bool, do: boolean()

  @doc """
  A packed array of `type` (`:f64`, `:i64`, `:u8`, `:i16`, `:i32`, `:f32`) as a binary: empty,
  length 1, up to `:max_length` (default 64), or (with `strip: true`, the
  default) 2047, 2048 or 2049 elements; sometimes an unaligned sub-binary.
  `:of` replaces the element generator, `:length` fixes the length.
  """
  def array(type, opts \\ []) do
    elem = Keyword.get_lazy(opts, :of, fn -> elem(type) end)

    lengths =
      case Keyword.fetch(opts, :length) do
        {:ok, n} ->
          constant(n)

        :error ->
          max = Keyword.get(opts, :max_length, 64)
          strip = if Keyword.get(opts, :strip, true), do: [{1, strip_length()}], else: []
          frequency([{1, constant(0)}, {1, constant(1)}, {6, integer(0..max)} | strip])
      end

    bind(lengths, fn n -> list_of(elem, length: n) end)
    |> map(&pack(type, &1))
    |> maybe_unaligned()
  end

  @doc """
  An `[f64]` (or `[f32]`) array with at least one element whose bits are inf
  or NaN (only an input array can hold one, defk-q1c): Elixir mode raises
  ArgumentError (:non_finite_input) when it reads one.
  """
  def array_non_finite(type \\ :f64, opts \\ []) do
    {w, bits} =
      case type do
        :f64 ->
          {8, [0x7FF0000000000000, 0xFFF0000000000000, 0x7FF8000000000000, 0x7FF0000000000001]}

        :f32 ->
          {4, [0x7F800000, 0xFF800000, 0x7FC00000, 0x7F800001]}
      end

    bind(tuple({array(type, Keyword.put(opts, :strip, false)), member_of(bits)}), fn {a, bits} ->
      n = div(byte_size(a), w)

      map(integer(0..n), fn at ->
        <<pre::binary-size(^at * ^w), post::binary>> = a
        <<pre::binary, bits::size(w * 8)-native, post::binary>>
      end)
    end)
  end

  @doc "A length either side of DEFK_STRIP."
  def strip_length, do: member_of([@strip - 1, @strip, @strip + 1])

  @doc "Indices of an n-element array in the first strip, at its end and in the next one."
  def strip_positions(n),
    do: Enum.uniq(for p <- [0, 1, @strip - 1, @strip, @strip + 1, n - 1], p < n, do: p)

  @doc "Packs `list` as an array of `type`."
  def pack(:f64, list), do: for(x <- list, into: <<>>, do: <<x::float-64-native>>)
  def pack(:i64, list), do: for(x <- list, into: <<>>, do: <<x::signed-64-native>>)
  def pack(:u8, list), do: :erlang.list_to_binary(list)
  def pack(:u64, list), do: for(x <- list, into: <<>>, do: <<x::unsigned-64-native>>)
  def pack(:i16, list), do: for(x <- list, into: <<>>, do: <<x::signed-16-native>>)
  def pack(:i32, list), do: for(x <- list, into: <<>>, do: <<x::signed-32-native>>)
  def pack(:f32, list), do: for(x <- list, into: <<>>, do: <<x::float-32-native>>)

  defp elem(:f64), do: f64()
  defp elem(:i64), do: i64()
  defp elem(:u8), do: integer(0..255)
  defp elem(:u64), do: u64()
  defp elem(:i16), do: narrow_int(16)
  defp elem(:i32), do: narrow_int(32)
  # an f64 that rounds to a finite f32 (|x| < 2^127), of any magnitude, or an
  # f32 edge: 0.1 rounds, the others are subnormal in f32 or the f32 maximum
  defp elem(:f32),
    do:
      one_of([
        f64(3.0e38),
        magnitude(126),
        member_of([0.1, 1.0e-40, 1.0e-45, 3.402_823_466_385_288_6e38])
      ])

  # a w-bit signed integer: uniform, or its range's ends and their neighbours
  defp narrow_int(w) do
    hi = Bitwise.bsl(1, w - 1) - 1
    lo = -hi - 1
    frequency([{6, integer(lo..hi)}, {3, member_of([0, 1, -1, lo, hi, lo + 1, hi - 1])}])
  end

  @doc "`bin`, or the same bytes as a sub-binary one byte into a larger binary (as bench/demo.exs does)."
  def maybe_unaligned(gen) do
    bind(gen, fn bin -> member_of([bin, unaligned(bin)]) end)
  end

  def unaligned(bin) do
    <<_::8, tail::binary>> = <<0>> <> bin
    tail
  end

  @doc "A generator for a kernel parameter of `type`."
  def for_type(:i64), do: i64()
  def for_type(:u64), do: u64()
  def for_type(:f64), do: f64()
  def for_type(:bool), do: bool()
  def for_type({:arr, e}), do: array(e)

  @doc """
  A value a kernel parameter of `type` must reject with ArgumentError:
  another term type, an integer outside i64, a float where an i64 is due, a
  bitstring that is not a binary, or (for elements wider than a byte) a
  binary whose size is not a multiple of the element width, sometimes as an
  unaligned sub-binary.
  """
  def hostile(type) do
    common = [:atom, nil, [], [1], %{}, {1}, self(), <<1::3>>]
    bignums = [@i64_max + 1, @i64_min - 1, 2 ** 64, -(2 ** 64), 2 ** 100]

    case type do
      :i64 -> member_of(common ++ bignums ++ [0.0, 1.0, -0.0, true, "1"])
      :u64 -> member_of(common ++ [-1, @i64_min, 2 ** 64, 2 ** 100, 0.0, 1.0, true, "1"])
      :f64 -> member_of(common ++ bignums ++ [true, "1.0"])
      :bool -> member_of(common ++ [0, 1, 1.0, :yes, "true"])
      {:arr, :u8} -> member_of(common ++ [1, 1.0, true, <<1, 2, 3::4>>])
      {:arr, e} -> one_of([member_of(common ++ [1, 1.0, true]), ragged(width(e))])
    end
  end

  defp width(e) when e in [:i16], do: 2
  defp width(e) when e in [:i32, :f32], do: 4
  defp width(_), do: 8

  # byte size not a multiple of the element width w
  defp ragged(w) do
    bind(tuple({integer(0..40), integer(1..(w - 1))}), fn {n, r} ->
      maybe_unaligned(binary(length: n * w + r))
    end)
  end
end
