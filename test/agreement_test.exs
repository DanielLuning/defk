# Agreement properties for the catalog's kernels (defk-ne6): each kernel
# against its Elixir mode on generated arguments (Defk.Properties). The test
# files' own kernels have theirs next to them.

defmodule Defk.AgreementTest.Examples do
  use ExUnit.Case, async: true
  use Defk.Properties

  @min -0x8000000000000000
  @max 0x7FFFFFFFFFFFFFFF

  # count_primes(n) does about n^1.5 trial divisions; at the i64 maximum its
  # range raises before the loop starts
  defp trips, do: G.i64(-10..2_000, [@min, @max])

  # prime? divides by every d up to sqrt(x), without stopping early: x up
  # to 10^6, and negative edges (sqrt raises)
  defp divisible, do: G.i64(-1_000..1_000_000, [@min, -(2 ** 62)])

  # arrays of any floats (mostly a sum or product overflows to inf, and both
  # raise at that operation), of floats whose sums and products stay finite
  # (so the values are compared too), or holding inf or NaN bits (both raise
  # at the read)
  defp floats,
    do: one_of([G.array(:f64), G.array(:f64, of: G.f64(1.0e100)), G.array_non_finite()])

  agreement(Examples.Kernels, [
    :add,
    :histogram,
    :oob,
    :overflow,
    sum: [args: fixed_list([floats()])],
    dot: [args: fixed_list([floats(), floats()])],
    mean_var: [args: fixed_list([floats()])],
    scale: [args: fixed_list([floats(), one_of([G.f64(), G.f64(1.0e150)])])],
    count_primes: [args: fixed_list([trips()])],
    count_primes_noyield: [args: fixed_list([trips()])],
    count_primes_via_call: [args: fixed_list([trips()])],
    count_primes_early: [args: fixed_list([trips()])],
    count_primes_early_noyield: [args: fixed_list([trips()])],
    prime?: [args: fixed_list([divisible()])],
    # stops at the first divisor: every edge value has a small one or is
    # negative (sqrt raises), so only the uniform draws are bounded
    prime_early?: [args: fixed_list([G.i64(-1_000..10_000_000_000, G.i64_edges())])]
  ])
end

defmodule Defk.AgreementTest.Catalog do
  use ExUnit.Case, async: true
  use Defk.Properties

  @min -0x8000000000000000
  @max 0x7FFFFFFFFFFFFFFF

  # Any floats (a sum, square or product that overflows to inf raises at that
  # operation in both modes, defk-i00), or floats small enough that none
  # does, so the computed values are compared too.
  defp f64s, do: one_of([G.f64(), G.f64(1.0e100)])

  # mean_std(x, w): a window 1..len(x) mostly; also empty or negative
  # windows and the lengths n - w + 1 that overflow or exceed the alloc limit
  # (never one a real allocator would grant)
  defp rolling(f64, opts \\ []) do
    bind(G.array(:f64, [of: f64] ++ opts), fn x ->
      n = div(byte_size(x), 8)

      w =
        frequency([
          {6, integer(1..max(n, 1))},
          {2, member_of([0, -1, -3, n + 1, n + 2])},
          {1,
           member_of([@min, @max, 2 ** 62, -(2 ** 62), 2 ** 53 + 1, -(2 ** 53 + 1), -(2 ** 61)])}
        ])

      fixed_list([constant(x), w])
    end)
  end

  # nearest(lat, lon, coslat, qlat, qlon, k): three arrays of one length
  # (sometimes lon or coslat shorter: index errors), k up to past the length
  # nearest_ids(ids, lat, lon, coslat, qlat, qlon, k): ids alongside the
  # three arrays, k up to past the length (the kernel's bounds checks raise
  # the same way in both modes when k exceeds it)
  defp geo_ids(f64, max_length) do
    bind(integer(0..max_length), fn n ->
      arr = fn -> G.array(:f64, of: f64, length: n) end

      fixed_list([
        G.array(:i64, length: n),
        arr.(),
        arr.(),
        arr.(),
        f64,
        f64,
        integer(0..(n + 2))
      ])
    end)
  end

  defp geo(f64, max_length) do
    bind(integer(0..max_length), fn n ->
      shorter = frequency([{8, constant(n)}, {1, integer(0..n)}])
      arr = fn len -> bind(len, &G.array(:f64, of: f64, length: &1)) end

      fixed_list([
        arr.(constant(n)),
        arr.(shorter),
        arr.(shorter),
        f64,
        f64,
        frequency([{6, integer(0..(n + 2))}, {1, G.alloc_len(8)}])
      ])
    end)
  end

  # gray_blur(rgb, w, h): byte_size(rgb) == 3 * w * h mostly; also any bytes
  # with any small sides, and sides whose product overflows, is negative, or
  # is at or past the alloc limit
  @hostile_sides [
    {@max, 2},
    {2, @max},
    {@min, -1},
    {@min, 1},
    {-1, 5},
    {2 ** 31, 2 ** 31},
    {2 ** 24, 2 ** 24},
    {2 ** 24 + 1, 2 ** 24},
    {2 ** 62, 4},
    {-(2 ** 31), 2 ** 31}
  ]

  defp blur(max_side) do
    frequency([
      {8,
       bind(tuple({integer(0..max_side), integer(0..max_side)}), fn {w, h} ->
         fixed_list([G.array(:u8, length: 3 * w * h), constant(w), constant(h)])
       end)},
      {2,
       fixed_list([
         G.array(:u8, max_length: 3 * max_side * max_side, strip: false),
         integer(-2..max_side),
         integer(-2..max_side)
       ])},
      {1,
       bind(member_of(@hostile_sides), fn {w, h} ->
         fixed_list([G.array(:u8, max_length: 8, strip: false), constant(w), constant(h)])
       end)}
    ])
  end

  # gray_blur_band(rgb, w, h, y0, y1): the same frames plus a row range, in
  # range most of the time, sometimes arbitrary (empty or out-of-frame bands)
  defp blur_band(max_side) do
    bind(blur(max_side), fn [rgb, w, h] ->
      range =
        if is_integer(w) and is_integer(h) and h in 0..max_side do
          frequency([
            {6, bind(integer(0..h), fn y0 -> tuple({constant(y0), integer(y0..h)}) end)},
            {1, tuple({integer(-2..(h + 2)), integer(-2..(h + 2))})}
          ])
        else
          tuple({integer(-2..4), integer(-2..4)})
        end

      bind(range, fn {y0, y1} -> constant([rgb, w, h, y0, y1]) end)
    end)
  end

  # search(q, blob, offs, k): words over a small alphabet (so distances tie)
  # in the fuzzy_search layout, one blob plus an offset table; sometimes an
  # offset table of arbitrary small offsets (index errors, negative lengths)
  defp fuzzy(max_words) do
    word = string(?a..?c, max_length: 8)

    bind(tuple({list_of(word, max_length: max_words), word}), fn {words, q} ->
      {offs, total} = Enum.map_reduce(words, 0, fn w, at -> {at, at + byte_size(w)} end)
      n = length(words)

      offs =
        frequency([
          {8, constant(offs ++ [total])},
          {1, list_of(integer(-2..(total + 3)), max_length: n + 2)}
        ])

      fixed_list([
        G.maybe_unaligned(constant(q)),
        G.maybe_unaligned(constant(IO.iodata_to_binary(words))),
        G.maybe_unaligned(map(offs, &G.pack(:i64, &1))),
        frequency([{6, integer(0..(n + 2))}, {1, G.alloc_len(8)}])
      ])
    end)
  end

  agreement(Rolling.Kernels,
    mean_std: [
      args: one_of([rolling(G.f64()), rolling(G.f64(1.0e100))]),
      deep: [
        args:
          one_of([rolling(G.f64(), max_length: 2049), rolling(G.f64(1.0e100), max_length: 2049)]),
        max_runs: 2_000
      ]
    ]
  )

  agreement(Geo.Kernels,
    nearest: [
      args: geo(f64s(), 40),
      deep: [args: geo(f64s(), 2049), max_runs: 1_000]
    ],
    nearest_ids: [
      args: geo_ids(f64s(), 40),
      deep: [args: geo_ids(f64s(), 2049), max_runs: 1_000]
    ]
  )

  agreement(Blur.Kernels,
    gray_blur: [args: blur(10), deep: [args: blur(48), max_runs: 1_000]],
    gray_blur_band: [args: blur_band(10), deep: [args: blur_band(48), max_runs: 1_000]]
  )

  agreement(FuzzySearch.Kernels,
    search: [args: fuzzy(16), deep: [args: fuzzy(200), max_runs: 1_000]],
    search_blocking: [args: fuzzy(16), deep: [args: fuzzy(200), max_runs: 1_000]]
  )
end
