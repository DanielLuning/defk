# Owned arrays as reduce accumulators (defk-n4r.10): `for ..., reduce:` and
# Enum.reduce_while/3 thread an array accumulator through the loop in place.
# The accumulator's buffer is the loop's own (an alloc/2 array, or a copy of
# an input or of an array another live binding still sees), so the body's
# writes and a helper that returns the array (`{slots, n} = insert(slots, ...)`)
# need no copy. Each kernel is checked against Elixir mode, where the reduce
# form is plain Elixir, and the generated C for where copies are.

defmodule Defk.ArrayAccumulatorTest.K do
  use Defk

  # a histogram built through a reduce accumulator, returned after the loop
  defk histogram(bytes :: [u8]) :: [i64] do
    for b <- bytes, reduce: alloc(i64, 256) do
      h ->
        h[b] = h[b] + 1
        h
    end
  end

  # in a tuple with a count, behind a filter
  defk histogram_from(bytes :: [u8], t :: i64) :: {[i64], i64} do
    for b <- bytes, b >= t, reduce: {alloc(i64, 256), 0} do
      {h, n} ->
        h[b] = h[b] + 1
        {h, n + 1}
    end
  end

  # the accumulator array is written again after the loop
  defk written_after(n :: i64) :: [i64] do
    a =
      for i <- 0..(n - 1)//1, reduce: alloc(i64, n + 1) do
        a ->
          a[i + 1] = a[i] + i
          a
      end

    a[0] = -1
    a
  end

  # 1BRC-shaped: an open-addressing table of keys and per-slot stats
  # {count, sum, min, max}, updated by an inlined helper that returns both
  defk insert(slots :: [i64], stats :: [i64], key :: i64, t :: i64) :: {[i64], [i64], i64} do
    mask = len(slots) - 1

    j =
      Enum.reduce_while(0..mask//1, band(key, mask), fn _, j ->
        if slots[j] == 0 or slots[j] == key,
          do: {:halt, j},
          else: {:cont, band(j + 1, mask)}
      end)

    new = if slots[j] == 0, do: 1, else: 0
    slots[j] = key
    s = j * 4
    stats[s] = stats[s] + 1
    stats[s + 1] = stats[s + 1] + t
    stats[s + 2] = if new == 1, do: t, else: min(stats[s + 2], t)
    stats[s + 3] = if new == 1, do: t, else: max(stats[s + 3], t)
    {slots, stats, new}
  end

  # two alloc'd tables threaded through a for ..., reduce: by the helper
  defk aggregate(keys :: [i64], temps :: [i64]) :: {[i64], [i64], i64} do
    for k <- 0..(min(len(keys), len(temps)) - 1)//1,
        reduce: {alloc(i64, 64), alloc(i64, 256), 0} do
      {slots, stats, n} ->
        {slots, stats, new} = insert(slots, stats, keys[k], temps[k])
        {slots, stats, n + new}
    end
  end

  # one line "name;temp\n" from pos: {hash of name (never 0), temp, next pos}
  defk parse_line(bytes :: [u8], pos :: i64) :: {i64, i64, i64} do
    {h, semi} =
      Enum.reduce_while(pos..(len(bytes) - 1)//1, {0, pos}, fn i, {h, _} ->
        b = bytes[i]
        if b == 59, do: {:halt, {h, i}}, else: {:cont, {band(h * 31 + b, 0xFFFFFFFF), i}}
      end)

    {t, neg, nl} =
      Enum.reduce_while((semi + 1)..(len(bytes) - 1)//1, {0, false, len(bytes)}, fn i,
                                                                                    {t, neg, _} ->
        b = bytes[i]

        cond do
          b == 10 -> {:halt, {t, neg, i}}
          b == 45 -> {:cont, {t, true, i}}
          true -> {:cont, {t * 10 + (b - 48), neg, i}}
        end
      end)

    {bor(h, 1), if(neg, do: -t, else: t), nl + 1}
  end

  # the 1BRC loop: one line per step of an Enum.reduce_while, the tables
  # threaded through its accumulator
  defk brc(bytes :: [u8]) :: {[i64], [i64], i64} do
    {slots, stats, n, _} =
      Enum.reduce_while(
        0..(len(bytes) - 1)//1,
        {alloc(i64, 64), alloc(i64, 256), 0, 0},
        fn _, {slots, stats, n, pos} ->
          {h, t, next} = parse_line(bytes, pos)
          {slots, stats, new} = insert(slots, stats, h, t)

          if next >= len(bytes),
            do: {:halt, {slots, stats, n + new, next}},
            else: {:cont, {slots, stats, n + new, next}}
        end
      )

    {slots, stats, n}
  end

  # two rows swapped every step: renames, no copies
  defk pascal(n :: i64) :: [i64] do
    {row, _} =
      for i <- 1..n//1, reduce: {alloc(i64, n + 1), alloc(i64, n + 1)} do
        {row, next} ->
          next[0] = 1

          for j <- 1..i//1 do
            next[j] = row[j - 1] + row[j]
          end

          {next, row}
      end

    row
  end

  # the initial array is still read after the loop: copied once, before it
  defk alias_outside(n :: i64) :: {[i64], [i64]} do
    a = alloc(i64, n)

    b =
      for i <- 0..(n - 1)//1, reduce: a do
        acc ->
          acc[i] = i + 1
          acc
      end

    {a, b}
  end

  # the body aliases the accumulator to a name the next iteration reads (as
  # the accumulator prev): the write after the alias copies
  defk alias_in_body(n :: i64) :: {[i64], i64} do
    {a, _, s} =
      for i <- 0..(n - 1)//1, reduce: {alloc(i64, n), alloc(i64, n), 0} do
        {a, prev, s} ->
          p = a
          a[i] = i + 1
          {a, p, s + total(prev)}
      end

    {a, s}
  end

  defk total(a :: [i64]) :: i64 do
    for x <- a, reduce: 0 do
      acc -> acc + x
    end
  end

  # an input array as the initial accumulator: copied, the caller's unchanged
  defk doubled(a :: [i64]) :: [i64] do
    for i <- 0..(len(a) - 1)//1, reduce: a do
      acc ->
        acc[i] = band(acc[i], 0xFFFF) * 2
        acc
    end
  end

  # one array as two accumulators: one of them is copied
  defk same_init(n :: i64) :: {[i64], [i64]} do
    a = alloc(i64, n)

    for i <- 0..(n - 1)//1, reduce: {a, a} do
      {x, y} ->
        x[i] = i + 1
        {x, y}
    end
  end

  # the body gives back an array bound before the loop, which it also reads
  defk restart(n :: i64) :: {[i64], i64} do
    base = alloc(i64, n)

    for i <- 0..(n - 1)//1, reduce: {base, 0} do
      {acc, s} ->
        acc[i] = i + 1
        {base, s + total(acc) + base[i]}
    end
  end

  # f64 accumulators: from alloc/2 (finite), and a copy of an input, whose
  # elements are still checked when read
  defk prefix(a :: [f64]) :: [f64] do
    for i <- 1..(len(a) - 1)//1, reduce: a do
      acc ->
        acc[i] = acc[i] + acc[i - 1]
        acc
    end
  end

  defk scaled(a :: [f64], k :: f64) :: {[f64], f64} do
    for i <- 0..(len(a) - 1)//1, reduce: {alloc(f64, len(a)), 0.0} do
      {out, s} ->
        out[i] = a[i] * k
        {out, s + out[i]}
    end
  end

  # the accumulator becomes an input in the body: a copy of it each step,
  # which is neither finite nor known to have one element, as alloc/2's was
  defk pick_input(a :: [f64]) :: {[f64], f64} do
    for _ <- 0..1//1, reduce: {alloc(f64, 1), 0.0} do
      {acc, s} -> {a, s + acc[0]}
    end
  end

  # the same for [f32], whose input reads are checked like [f64]'s (defk-4ai);
  # alloc(f32, len(a)) has no constant length, so finiteness is the only fact
  # the new value loses
  defk pick_input_f32(a :: [f32]) :: {[f32], f64} do
    for _ <- 0..1//1, reduce: {alloc(f32, len(a)), 0.0} do
      {acc, s} -> {a, s + acc[0]}
    end
  end

  # an accumulator named like an array read after the loop may be bound
  # again in the body: it shadows that array (no array-rebind-in-loop)
  defk shadow(n :: i64) :: {[i64], [i64]} do
    slots = alloc(i64, 4)

    t =
      for i <- 0..(n - 1)//1, reduce: alloc(i64, 4) do
        slots ->
          {slots, _} = bump(slots, i)
          slots
      end

    {slots, t}
  end

  defk bump(a :: [i64], i :: i64) :: {[i64], i64} do
    j = band(i, 3)
    a[j] = a[j] + 1
    {a, j}
  end

  # swapped accumulators in a flat float loop that runs flagged: a strip
  # replayed after an inf restores which array is which
  defk swap_mul(n :: i64) :: f64 do
    a = alloc(f64, 8)
    b = alloc(f64, 8)
    a[0] = 1.0e300
    b[0] = 1.0

    {_, _, s} =
      for _ <- 0..(n - 1)//1, reduce: {a, b, 1.0} do
        {x, y, s} -> {y, x, s * x[0]}
      end

    s
  end
end

defmodule Defk.ArrayAccumulatorTest do
  use ExUnit.Case, async: true
  use Defk.Properties
  import Defk.TestKit

  alias Defk.ArrayAccumulatorTest.K

  defp ints(bin), do: for(<<x::64-signed-native <- bin>>, do: x)

  defp agree(fun, args), do: Defk.Test.assert_agrees(K, fun, args)

  defp copies(c), do: length(String.split(c, "defk_copy_")) - 1

  @names ~w(Oslo Lima Pune Kyiv Baku Riga Bern Doha Rome Nuuk)

  defp lines(n, seed) do
    :rand.seed(:exsss, {seed, 1, 2})

    for _ <- 1..n, into: "" do
      "#{Enum.random(@names)};#{Enum.random(-999..999)}\n"
    end
  end

  describe "agreement" do
    test "a histogram through a reduce accumulator" do
      assert {:ok, h} = agree(:histogram, ["hello"])
      assert Enum.at(ints(h), ?l) == 2
      assert agree(:histogram_from, ["hello", ?h]) |> elem(1) |> elem(1) == 4
      assert {:ok, _} = agree(:histogram, [<<>>])
    end

    test "the accumulator array returned and written after the loop" do
      assert agree(:written_after, [4]) == {:ok, i64s([-1, 0, 1, 3, 6])}
      assert agree(:written_after, [0]) == {:ok, i64s([-1])}
    end

    test "two tables threaded through a loop by an inlined helper" do
      keys = i64s([5, 69, 5, 7, 69])
      temps = i64s([10, -3, 30, 4, 1])
      assert {:ok, {slots, stats, 3}} = agree(:aggregate, [keys, temps])
      assert Enum.at(ints(slots), 5) == 5
      assert Enum.at(ints(slots), 6) == 69
      assert Enum.slice(ints(stats), 20, 8) == [2, 40, 10, 30, 2, -2, -3, 1]
    end

    test "the 1BRC loop over lines" do
      data = "Oslo;-12\nLima;300\nOslo;7\n"
      assert {:ok, {_, stats, 2}} = agree(:brc, [data])
      assert Enum.sum(ints(stats)) != 0
      assert {:ok, {_, _, 10}} = agree(:brc, [lines(500, 1)])
      assert {:ok, {_, _, 0}} = agree(:brc, [""])
    end

    test "swapped rows" do
      assert agree(:pascal, [5]) == {:ok, i64s([1, 4, 6, 4, 1, 0])}
      assert agree(:pascal, [0]) == {:ok, i64s([0])}
    end

    test "aliases see the array they had" do
      assert agree(:alias_outside, [3]) == {:ok, {i64s([0, 0, 0]), i64s([1, 2, 3])}}
      assert agree(:alias_in_body, [3]) == {:ok, {i64s([1, 2, 3]), 1}}
      assert agree(:same_init, [2]) == {:ok, {i64s([1, 2]), i64s([0, 0])}}
      assert agree(:restart, [3]) == {:ok, {i64s([0, 0, 0]), 1 + 2 + 3}}
    end

    test "an accumulator shadows an array of the same name" do
      assert agree(:shadow, [6]) == {:ok, {i64s([0, 0, 0, 0]), i64s([2, 2, 1, 1])}}
    end

    test "a flagged strip replays swapped accumulators from its start" do
      assert agree(:swap_mul, [2]) == {:ok, 1.0e300}

      for n <- [3, 4, 5] do
        assert {:raise, %ArithmeticError{message: m}} = agree(:swap_mul, [n])
        assert m =~ "*", m
      end
    end

    test "an input as the initial accumulator leaves the caller's binary unchanged" do
      a = i64s([1, 2, 3])
      assert agree(:doubled, [a]) == {:ok, i64s([2, 4, 6])}
      assert a == i64s([1, 2, 3])

      b = f64s([1.0, 2.0, 3.0])
      assert agree(:prefix, [b]) == {:ok, f64s([1.0, 3.0, 6.0])}
      assert b == f64s([1.0, 2.0, 3.0])
    end

    test "a non-finite input element in a copied accumulator raises when read" do
      bad = <<0x7FF0000000000000::64-native>>
      assert {:raise, %ArgumentError{}} = agree(:prefix, [f64s([1.0]) <> bad])
      assert {:raise, %ArgumentError{}} = agree(:pick_input, [bad])
      assert agree(:pick_input, [f64s([2.5])]) == {:ok, {f64s([2.5]), 2.5}}
      assert {:raise, %Enum.OutOfBoundsError{}} = agree(:pick_input, [<<>>])
      assert {:raise, %ArgumentError{}} = agree(:pick_input_f32, [<<0x7F800000::32-native>>])

      assert agree(:pick_input_f32, [<<2.5::float-32-native>>]) ==
               {:ok, {<<2.5::float-32-native>>, 2.5}}

      assert agree(:scaled, [f64s([1.0, 2.0]), 0.5]) == {:ok, {f64s([0.5, 1.0]), 1.5}}
    end
  end

  describe "where copies are" do
    test "none in the 1BRC-shaped loops, the histogram or swapped rows" do
      for k <- [:histogram, :histogram_from, :written_after, :aggregate, :brc, :pascal, :scaled] do
        assert copies(kernel_c(K, k)) == 0, "#{k}"
      end
    end

    test "once for an initial array another binding still reads, before the loop" do
      for k <- [:alias_outside, :doubled, :same_init, :prefix] do
        c = kernel_c(K, k)
        assert copies(c) == 1, "#{k}"
        # the kernel's loop, not the loop that zeroes the alloc (defk-ktw)
        [before_loop, _] = String.split(c, "/* defk:loop ", parts: 2)
        assert before_loop =~ "defk_copy_", "#{k}"
      end
    end

    test "at the write after an alias in the body" do
      assert copies(kernel_c(K, :alias_in_body)) == 1
    end
  end

  describe "under forced yields" do
    # every safepoint yields and resumes; the accumulator arrays are owned
    # buffers in the frame, which the resumed kernel keeps writing
    test "the accumulators resume where they left off" do
      n = 5_000
      bytes = :binary.list_to_bin(for k <- 1..n, do: rem(k * 7919, 256))
      keys = i64s(for k <- 1..n, do: rem(k * 31, 50) + 1)
      temps = i64s(for k <- 1..n, do: rem(k * 17, 1999) - 999)

      forced(K, fn ->
        for {f, args} <- [
              histogram: [bytes],
              histogram_from: [bytes, 100],
              aggregate: [keys, temps],
              brc: [lines(2_000, 2)],
              pascal: [60],
              alias_in_body: [300],
              doubled: [keys],
              restart: [200]
            ] do
          assert {:ok, _} = agree(f, args)
        end
      end)
    end
  end

  agreement(K, [
    :histogram,
    :doubled,
    :insert,
    :parse_line,
    :total,
    :prefix,
    :pick_input,
    :pick_input_f32,
    histogram_from: [args: StreamData.fixed_list([G.array(:u8), G.i64(-1..256)])],
    written_after: [args: StreamData.fixed_list([StreamData.integer(0..100)])],
    aggregate: [
      args:
        StreamData.fixed_list([
          G.array(:i64, of: StreamData.integer(1..200)),
          G.array(:i64, of: StreamData.integer(-999..999))
        ])
    ],
    brc: [
      args:
        StreamData.map(
          StreamData.list_of(
            StreamData.tuple({StreamData.member_of(@names), StreamData.integer(-999..999)})
          ),
          fn ls -> Enum.map_join(ls, fn {s, t} -> "#{s};#{t}\n" end) end
        )
        |> StreamData.map(&[&1])
    ],
    pascal: [args: StreamData.fixed_list([StreamData.integer(0..70)])],
    alias_outside: [args: StreamData.fixed_list([StreamData.integer(0..100)])],
    alias_in_body: [args: StreamData.fixed_list([StreamData.integer(0..60)])],
    same_init: [args: StreamData.fixed_list([StreamData.integer(0..100)])],
    restart: [args: StreamData.fixed_list([StreamData.integer(0..60)])],
    scaled: [args: StreamData.fixed_list([G.array(:f64), G.f64()])],
    shadow: [args: StreamData.fixed_list([StreamData.integer(0..100)])],
    bump: [args: StreamData.fixed_list([G.array(:i64), G.i64()])],
    swap_mul: [args: StreamData.fixed_list([StreamData.integer(0..10)])]
  ])
end
