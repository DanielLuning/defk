defmodule Defk.CatalogGenerators do
  @moduledoc false
  # Bounded argument generators for the catalog kernels that the stock
  # Defk.Generators would draw badly (defk-30c.2): Gorilla series, Snappy and
  # LZ4 streams (encoded here in Elixir, so the examples' Mix.install codecs
  # are not needed), and byte windows for the hashes. Each draw is small: a
  # whole property costs a few milliseconds.

  import StreamData
  import Bitwise

  alias Defk.Generators, as: G

  # --- Gorilla: p = [t0, v0, t1, v1, ...] with the f64 values as i64 bits ----

  # One delta of deltas: zero (the 1-bit code), inside each bucket and on its
  # edges (-63..64, -255..256, -2047..2048), or large (the 32-bit code, whose
  # mask drops the high bits).
  defp dod do
    frequency([
      {3, constant(0)},
      {3, integer(-70..70)},
      {2, member_of([-63, 64, -64, 65, -255, 256, -256, 257, -2047, 2048, -2048, 2049])},
      {2, integer(-5000..5000)},
      {1, integer(-0x80000000..0x80000000)},
      {1, member_of([2 ** 31, -(2 ** 31), 2 ** 32, 2 ** 40])}
    ])
  end

  # a value's bits: the previous ones again, or the previous XORed with k bits
  # at shift s (so the leading and trailing zero counts, the "same window"
  # and "new window" branches and the 64-bit window all occur), or random
  defp next_bits(prev) do
    frequency([
      {2, constant(prev)},
      {6,
       bind(integer(1..64), fn k ->
         bind(integer(0..(64 - k)), fn s ->
           map(integer(0..(2 ** k - 1)), fn m ->
             wrap(bxor(prev &&& 0xFFFFFFFFFFFFFFFF, m <<< s))
           end)
         end)
       end)},
      {2, map(integer(0..(2 ** 64 - 1)), &wrap/1)}
    ])
  end

  # x as an i64 (two's complement)
  defp wrap(x), do: Bitwise.band(x + 2 ** 63, 2 ** 64 - 1) - 2 ** 63

  @doc """
  The argument of `Gorilla.Kernels.streams/1`: up to `max_points` points,
  timestamps from the delta-of-delta buckets, values that change a few bits;
  rarely a start or delta that overflows i64 (both modes raise) and an odd
  length (the last element is ignored).
  """
  def gorilla_points(max_points) do
    bind(integer(0..max_points), fn n ->
      bind(tuple({G.i64(), integer(1..2000), series(n), list_of(dod(), length: n)}), fn {t0, d0,
                                                                                         vals,
                                                                                         dods} ->
        ts = timestamps(n, t0, d0, dods)
        flat = Enum.zip(ts, vals) |> Enum.flat_map(fn {t, v} -> [t, v] end)
        fixed_list([point_array(flat)])
      end)
    end)
  end

  # t0, t0 + d0, then the delta changes by each delta of deltas
  defp timestamps(0, _t0, _d0, _dods), do: []

  defp timestamps(n, t0, d0, dods) do
    {rev, _, _} =
      Enum.reduce(Enum.zip(1..(n - 1)//1, dods), {[t0], t0, d0}, fn {i, dd}, {acc, t, d} ->
        d = if i == 1, do: d0, else: d + dd
        {[wrap(t + d) | acc], wrap(t + d), d}
      end)

    Enum.reverse(rev)
  end

  defp series(0), do: constant([])
  defp series(n), do: bind(map(integer(0..(2 ** 64 - 1)), &wrap/1), &gen_series(n - 1, &1, [&1]))

  defp gen_series(0, _prev, acc), do: constant(Enum.reverse(acc))

  defp gen_series(left, prev, acc) do
    bind(next_bits(prev), fn v -> gen_series(left - 1, v, [v | acc]) end)
  end

  defp point_array(flat) do
    frequency([
      {12, constant(G.pack(:i64, flat))},
      # an odd length: the last element is never read
      {1, constant(G.pack(:i64, flat ++ [7]))},
      {1, constant(G.pack(:i64, Enum.drop(flat, -1)))}
    ])
    |> G.maybe_unaligned()
  end

  # --- Snappy and LZ4 streams -------------------------------------------------

  # Valid streams from a list of abstract operations, then mutations that
  # break them: a changed byte, a prefix, trailing bytes, a dropped or an
  # inserted byte. The kernels' raise paths come from the mutations and from
  # arbitrary bytes.

  defp mutate(bin) when is_binary(bin) do
    size = byte_size(bin)

    frequency([
      {8, constant(bin)},
      {3,
       bind(tuple({integer(0..max(size - 1, 0)), integer(0..255)}), fn {at, b} ->
         constant(set_byte(bin, at, b))
       end)},
      {2, map(integer(0..size), &binary_part(bin, 0, &1))},
      {1, map(binary(min_length: 1, max_length: 4), &(bin <> &1))},
      {1, map(integer(0..max(size - 1, 0)), &delete_byte(bin, &1))},
      {1,
       bind(tuple({integer(0..size), integer(0..255)}), fn {at, b} ->
         <<pre::binary-size(^at), post::binary>> = bin
         constant(<<pre::binary, b, post::binary>>)
       end)}
    ])
  end

  defp set_byte(<<>>, _at, _b), do: <<>>

  defp set_byte(bin, at, b) do
    <<pre::binary-size(^at), _, post::binary>> = bin
    <<pre::binary, b, post::binary>>
  end

  defp delete_byte(<<>>, _at), do: <<>>

  defp delete_byte(bin, at) do
    <<pre::binary-size(^at), _, post::binary>> = bin
    pre <> post
  end

  # literal lengths: mostly short, sometimes past the 60 or 256 where Snappy
  # changes its header, sometimes past 15 and 270 where LZ4 adds length bytes
  defp lit_len do
    frequency([
      {6, integer(1..20)},
      {3, integer(55..70)},
      {1, member_of([255, 256, 257, 270, 271, 300])}
    ])
  end

  defp copy_len do
    frequency([{6, integer(1..12)}, {3, integer(12..64)}, {1, member_of([255, 256, 300])}])
  end

  defp bytes(n), do: binary(length: n)

  # --- Snappy ---

  defp snappy_op do
    frequency([
      {4, bind(lit_len(), fn n -> tuple({constant(:lit), bytes(n), integer(0..4)}) end)},
      {5, tuple({constant(:copy), integer(0..70_000), copy_len(), integer(0..2)})}
    ])
  end

  @doc "A Snappy stream: valid, or mutated (a few bytes changed, cut, added)."
  def snappy_stream do
    list_of(snappy_op(), max_length: 10)
    |> map(&snappy_encode/1)
    |> bind(&mutate/1)
  end

  defp snappy_encode(ops) do
    {parts, total} =
      Enum.reduce(ops, {[], 0}, fn
        {:lit, bytes, form}, {acc, total} ->
          {[snappy_literal(bytes, form) | acc], total + byte_size(bytes)}

        {:copy, _, _, _}, {acc, 0} ->
          {acc, 0}

        {:copy, r, ln, form}, {acc, total} ->
          off = 1 + rem(r, total)
          {[snappy_copy(off, ln, form) | acc], total + ln}
      end)

    IO.iodata_to_binary([varint(total) | Enum.reverse(parts)])
  end

  defp varint(n) when n < 128, do: <<n>>
  defp varint(n), do: <<1::1, band(n, 127)::7, varint(n >>> 7)::binary>>

  # a literal's length may be written with any header that can hold it
  defp snappy_literal(bytes, form) do
    l = byte_size(bytes) - 1

    headers =
      if(l < 60, do: [<<l <<< 2>>], else: []) ++
        [<<60 <<< 2, l>>] ++
        [<<61 <<< 2, l::16-little>>, <<62 <<< 2, l::24-little>>, <<63 <<< 2, l::32-little>>]

    headers = Enum.filter(headers, fn h -> l < 256 or byte_size(h) > 2 end)
    [Enum.at(headers, rem(form, length(headers))), bytes]
  end

  defp snappy_copy(off, ln, form) do
    forms =
      if(ln >= 4 and ln <= 11 and off < 2048,
        do: [<<1 ||| (ln - 4) <<< 2 ||| (off >>> 8) <<< 5, band(off, 255)>>],
        else: []
      ) ++
        if(ln <= 64 and off < 65_536,
          do: [<<2 ||| (ln - 1) <<< 2, off::16-little>>],
          else: []
        ) ++
        if(ln <= 64, do: [<<3 ||| (ln - 1) <<< 2, off::32-little>>], else: [])

    case forms do
      [] -> <<2 ||| 63 <<< 2, min(off, 65_535)::16-little>>
      _ -> Enum.at(forms, rem(form, length(forms)))
    end
  end

  # --- LZ4 ---

  # {literals, match offset draw, match length}
  defp lz4_seq do
    tuple({
      bind(frequency([{2, constant(0)}, {8, lit_len()}]), &bytes/1),
      integer(0..70_000),
      frequency([{7, integer(4..19)}, {2, integer(19..80)}, {1, member_of([274, 275, 300])}])
    })
  end

  @doc """
  The arguments of `LzSnappy.Kernels.lz4_block_decode/2`: a block (valid, or
  mutated) and a `max_out` that is its exact output size, a little off it,
  arbitrary, or an allocation the kernel refuses.
  """
  def lz4_args do
    bind(tuple({list_of(lz4_seq(), max_length: 8), bytes_final()}), fn {seqs, last} ->
      {block, total} = lz4_encode(seqs, last)

      bind(mutate(block), fn block ->
        max_out =
          frequency([
            {6, constant(total)},
            {1, constant(total + 1)},
            {2, integer(max(total - 40, -2)..total)},
            {1, integer(-2..400)},
            {1, G.alloc_len(1)}
          ])

        fixed_list([G.maybe_unaligned(constant(block)), max_out])
      end)
    end)
  end

  defp bytes_final, do: frequency([{1, constant(<<>>)}, {8, bind(lit_len(), &bytes/1)}])

  defp lz4_encode(seqs, last) do
    {parts, total} =
      Enum.reduce(seqs, {[], 0}, fn {lits, r, mlen}, {acc, total} ->
        total = total + byte_size(lits)
        off = if total == 0, do: 1, else: 1 + rem(r, min(total, 65_535))
        {[lz4_sequence(lits, off, mlen) | acc], total + mlen}
      end)

    last_part = [lz4_token(byte_size(last), nil), lz4_ext(byte_size(last), 15), last]
    {IO.iodata_to_binary(Enum.reverse([last_part | parts])), total + byte_size(last)}
  end

  defp lz4_sequence(lits, off, mlen) do
    [
      lz4_token(byte_size(lits), mlen),
      lz4_ext(byte_size(lits), 15),
      lits,
      <<off::16-little>>,
      lz4_ext(mlen - 4, 15)
    ]
  end

  defp lz4_token(lit, mlen) do
    <<min(lit, 15)::4, if(mlen, do: min(mlen - 4, 15), else: 0)::4>>
  end

  # the bytes that continue a length of at least `from`
  defp lz4_ext(n, from) when n < from, do: []
  defp lz4_ext(n, from), do: lz4_ext_bytes(n - from)

  defp lz4_ext_bytes(r) when r >= 255, do: [255 | lz4_ext_bytes(r - 255)]
  defp lz4_ext_bytes(r), do: [r]

  @doc "The arguments of `LzSnappy.Kernels.ext_len/3`: runs of 255 bytes, then a last one."
  def ext_len_args do
    bind(list_of(frequency([{4, constant(255)}, {1, integer(0..254)}]), max_length: 12), fn bs ->
      src = :erlang.list_to_binary(bs)
      n = byte_size(src)

      fixed_list([
        G.maybe_unaligned(constant(src)),
        frequency([{8, integer(0..max(n, 1))}, {1, integer(-2..(n + 3))}]),
        frequency([{6, G.i64(-10..300)}, {1, G.i64()}])
      ])
    end)
  end

  # --- Hashes -------------------------------------------------------------------

  @doc "Bytes of any length up to `max`, with no strip lengths (the kernels' blocks are 8 to 32 bytes)."
  def window(max), do: G.array(:u8, max_length: max, strip: false)

  @doc """
  `[b, off, n | more]` for the `*_at` kernels: a window inside the bytes
  most of the time, sometimes one that reaches out of them or a negative
  length (index errors and range checks raise alike in both modes). `more`
  are generators of the trailing arguments.
  """
  def at_args(max, more \\ []) do
    bind(window(max), fn b ->
      size = byte_size(b)

      range =
        frequency([
          {8,
           bind(integer(0..size), fn off -> tuple({constant(off), integer(0..(size - off))}) end)},
          {1, tuple({integer(-2..(size + 2)), integer(-2..(size + 2))})}
        ])

      bind(range, fn {off, n} -> fixed_list([constant(b), constant(off), constant(n) | more]) end)
    end)
  end

  @doc "`[blob, offsets | more]` for the `*_batch` kernels: increasing offsets over the blob, sometimes arbitrary ones."
  def batch_args(max, more \\ []) do
    bind(window(max), fn blob ->
      size = byte_size(blob)

      offsets =
        frequency([
          {8,
           bind(list_of(integer(0..size), max_length: 6), fn cuts ->
             constant(Enum.sort([0, size | cuts]))
           end)},
          {1, list_of(integer(-2..(size + 2)), max_length: 5)}
        ])

      fixed_list([G.maybe_unaligned(constant(blob)), map(offsets, &G.pack(:i64, &1)) | more])
    end)
  end

  @doc "A long window, past the three 2048-byte streams of the CRC32C kernel."
  def long_window do
    bind(integer(6144..6400), fn n -> G.maybe_unaligned(binary(length: n)) end)
  end

  # --- HLL ---------------------------------------------------------------------

  @doc """
  The arguments of `Hll.Kernels.update_many/3`: a state of 4 header bytes and
  2^p registers (the length the kernel demands), hashes with every number of
  leading zeros, sometimes a state of the wrong length or a p out of range.
  """
  def hll_args do
    p =
      frequency([{8, integer(4..8)}, {1, integer(9..16)}, {1, integer(-1..20)}])

    bind(p, fn p ->
      len =
        if p in 4..16 and p <= 16,
          do: frequency([{9, constant(4 + 2 ** p)}, {1, integer(0..(4 + 2 ** p + 2))}]),
          else: integer(0..40)

      fixed_list([G.maybe_unaligned(bind(len, &binary(length: &1))), hashes(), constant(p)])
    end)
  end

  defp hashes do
    one = bind(integer(0..64), fn s -> map(integer(0..(2 ** 64 - 1)), &(&1 >>> s)) end)

    frequency([{4, one}, {1, G.u64()}])
    |> then(&list_of(&1, max_length: 40))
    |> map(&G.pack(:u64, &1))
    |> G.maybe_unaligned()
  end

  # --- Cosine -------------------------------------------------------------------

  @dim 384

  @doc """
  The arguments of `Cosine.Kernels.topk/4`: up to `max_rows` rows of 384 f32
  and a query of 384 f64, both from a seeded generator (a draw of 384 values
  one by one would cost a millisecond per row), with duplicate rows (ties go
  to the lower index), sometimes a wrong shape or an inf in the input.
  """
  def cosine_args(max_rows) do
    bind(tuple({integer(0..max_rows), integer(0..1_000_000), integer(0..3)}), fn {rows, seed,
                                                                                  kind} ->
      {m, q} = cosine_data(rows, seed, kind)

      fixed_list([
        G.maybe_unaligned(constant(m)),
        G.maybe_unaligned(constant(q)),
        frequency([{6, integer(1..(rows + 2))}, {1, integer(-1..1)}, {1, G.alloc_len(8)}]),
        G.i64()
      ])
    end)
    |> bind(&break_shape/1)
  end

  # kind 0: distinct rows, 1: every row the same, 2: two alternating rows, 3: a
  # row of zeros among others
  defp cosine_data(rows, seed, kind) do
    st = :rand.seed_s(:exsss, seed)
    {q, st} = vec(st, @dim)
    {r0, st} = vec(st, @dim)
    {r1, st} = vec(st, @dim)

    {list, _} =
      Enum.map_reduce(1..max(rows, 1)//1, st, fn i, st ->
        case {kind, i} do
          {1, _} -> {r0, st}
          {2, i} -> {if(rem(i, 2) == 0, do: r0, else: r1), st}
          {3, 2} -> {List.duplicate(0.0, @dim), st}
          _ -> vec(st, @dim)
        end
      end)

    list = if rows == 0, do: [], else: list
    {G.pack(:f32, List.flatten(list)), G.pack(:f64, q)}
  end

  defp vec(st, n) do
    {xs, st} =
      Enum.map_reduce(1..n, st, fn _, st ->
        {x, st} = :rand.uniform_s(st)
        {x * 2 - 1, st}
      end)

    norm = :math.sqrt(Enum.reduce(xs, 0.0, &(&1 * &1 + &2)))
    {Enum.map(xs, &(&1 / norm)), st}
  end

  defp break_shape([m, q, k, base]) do
    frequency([
      {12, constant([m, q, k, base])},
      {1, constant([m, binary_part(q, 0, byte_size(q) - 8), k, base])},
      {1, constant([binary_part(m, 0, max(byte_size(m) - 4, 0)), q, k, base])},
      {1, constant([<<m::binary, 0::32>>, q, k, base])},
      {1, constant([patch_inf(m), q, k, base])},
      {1, constant([m, patch_inf(q), k, base])}
    ])
  end

  # an inf in the first element (the kernels read the first f32 or f64)
  defp patch_inf(<<>>), do: <<>>

  defp patch_inf(bin) do
    w = if rem(byte_size(bin), 8) == 0 and byte_size(bin) == @dim * 8, do: 8, else: 4

    case w do
      8 ->
        <<_::64, rest::binary>> = bin
        <<0x7FF0000000000000::64-native, rest::binary>>

      4 ->
        <<_::32, rest::binary>> = bin
        <<0x7F800000::32-native, rest::binary>>
    end
  end
end
