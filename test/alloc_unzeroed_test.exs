# alloc/2 skips zeroing its buffer when the compiler proves every element is
# written before anything reads it (defk-ktw): the alloc is bound to a
# variable, and the next statement is a plain `for` over 0..(n - 1)//1 whose
# body writes x[k * i + c] for every c in 0..k-1 at its top level and does
# not otherwise mention x, where k * n is the alloc's length. The memset is a
# full extra pass over the output (scale, encode16). Anything else keeps the
# zeroing; each near miss below is one.
#
# Soundness is checked two ways: the generated C (raw alloc or not), and, for
# kernels drawn at random around the accepted form, that a raw alloc only
# ever appears where every element is written (brute force over small n), and
# that native and Elixir mode agree after the allocator held 255s, so an
# unwritten element that was not zeroed would show.

defmodule Defk.AllocUnzeroedTest.Shapes do
  @moduledoc false

  # Random kernel shapes around the accepted form, drawn once with a fixed
  # seed so the module compiles the same kernels every time. A shape:
  #   k, cs     - writes out[k * i + c] for each c in cs (in order)
  #   start     - the range's first index
  #   stop      - the range's last index is n + stop
  #   step      - the range's step
  #   guard     - the writes are under `if rem(i, 3) != 0`
  #   read      - each write adds the element's old value
  #   between   - a statement between the alloc and the loop: nil, one that
  #               mentions neither (:unrelated), one that rebinds n so the
  #               range ends one early (:rebind), or len(out) (:mention)
  def shapes do
    :rand.seed(:exsss, {7, 11, 13})

    for j <- 1..64 do
      k = Enum.random([1, 1, 2, 2, 3])
      cs = Enum.take_random(0..k, Enum.random(1..(k + 1)))
      cs = if :rand.uniform(2) == 1, do: Enum.shuffle(Enum.to_list(0..(k - 1))), else: cs

      shape = %{
        k: k,
        cs: cs,
        start: Enum.random([0, 0, 0, 0, 1]),
        stop: Enum.random([-1, -1, -1, -2, 0]),
        step: Enum.random([1, 1, 1, 1, 2]),
        guard: :rand.uniform(8) == 1,
        read: :rand.uniform(8) == 1,
        between: Enum.random([nil, nil, nil, :unrelated, :unrelated, :rebind, :mention])
      }

      {:"shape_#{j}", shape}
    end
  end

  # Every element is written, for every n in 0..12 the kernel does not raise
  # at (a write out of bounds raises: Elixir mode raises too).
  def covers?(%{guard: true}), do: false
  def covers?(%{read: true}), do: false

  def covers?(s) do
    Enum.all?(0..12, fn n ->
      m = if s.between == :rebind, do: n - 1, else: n
      idx = for i <- s.start..(m + s.stop)//s.step, c <- s.cs, do: s.k * i + c
      len = s.k * n
      Enum.any?(idx, &(&1 < 0 or &1 >= len)) or MapSet.new(idx) == MapSet.new(0..(len - 1)//1)
    end)
  end

  defp index(1, 0), do: quote(do: i)
  defp index(k, 0), do: quote(do: unquote(k) * i)
  defp index(k, c), do: quote(do: unquote(k) * i + unquote(c))

  defp len(1), do: quote(do: n)
  defp len(k), do: quote(do: unquote(k) * n)

  defp stop(-1), do: quote(do: n - 1)
  defp stop(-2), do: quote(do: n - 2)
  defp stop(0), do: quote(do: n)

  defp between(nil), do: nil
  defp between(:unrelated), do: quote(do: _ = n * 3)
  defp between(:rebind), do: quote(do: n = n - 1)
  defp between(:mention), do: quote(do: _ = len(out))

  defp write(s, c) do
    at = index(s.k, c)
    v = if s.read, do: quote(do: out[unquote(at)] + unquote(c + 1)), else: c + 1
    quote(do: out[unquote(at)] = unquote(v))
  end

  # Defk.Properties.agreement/2 over `named` and an entry for each shape
  defmacro agreement(mod, named) do
    shapes =
      for {name, _} <- shapes(),
          do: {name, [args: quote(do: StreamData.fixed_list([StreamData.integer(-2..300)]))]}

    quote do
      require Defk.Properties
      Defk.Properties.agreement(unquote(mod), unquote(named ++ shapes))
    end
  end

  defmacro kernels do
    for {name, s} <- shapes() do
      writes = Enum.map(s.cs, &write(s, &1))
      body = {:__block__, [], writes}
      body = if s.guard, do: quote(do: if(rem(i, 3) != 0, do: unquote(body))), else: body

      loop =
        quote do
          for i <- unquote(s.start)..unquote(stop(s.stop))//unquote(s.step) do
            unquote(body)
          end
        end

      stmts =
        [quote(do: out = alloc(u8, unquote(len(s.k)))), between(s.between), loop, quote(do: out)]

      quote do
        defk unquote(name)(n :: i64) :: [u8] do
          unquote({:__block__, [], Enum.reject(stmts, &is_nil/1)})
        end
      end
    end
  end
end

defmodule Defk.AllocUnzeroedTest.K do
  use Defk
  require Defk.AllocUnzeroedTest.Shapes

  @hex "0123456789ABCDEF"

  # leaves n bytes of 255 to the allocator
  defk dirty(n :: i64) :: i64 do
    a = alloc(u8, n)

    for i <- 0..(n - 1)//1 do
      a[i] = 255
    end

    len(a)
  end

  # ---- accepted: every element written before any read

  defk scale(a :: [f64], k :: f64) :: [f64] do
    out = alloc(f64, len(a))

    for i <- 0..(len(a) - 1)//1 do
      out[i] = a[i] * k
    end

    out
  end

  defk encode16(s :: [u8]) :: [u8] do
    n = len(s)
    out = alloc(u8, 2 * n)

    for i <- 0..(n - 1)//1 do
      b = s[i]
      out[2 * i] = @hex[band(bsr(b, 4), 15)]
      out[2 * i + 1] = @hex[band(b, 15)]
    end

    out
  end

  # the range end as len of the new array
  defk by_len(n :: i64) :: [i64] do
    out = alloc(i64, n)

    for i <- 0..(len(out) - 1)//1 do
      out[i] = i * i
    end

    out
  end

  # a raise between the alloc and the last write: the buffer is freed
  defk raise_mid(n :: i64, at :: i64) :: [u8] do
    out = alloc(u8, n)

    for i <- 0..(n - 1)//1 do
      if i == at, do: raise(ArgumentError, "stop")
      out[i] = 1
    end

    out
  end

  # a long loop with a nested loop: it yields between writes
  defk slow_fill(n :: i64) :: [i64] do
    out = alloc(i64, n)

    for i <- 0..(n - 1)//1 do
      s =
        for j <- 0..rem(i, 5)//1, reduce: 0 do
          z -> z + j
        end

      out[i] = s
    end

    out
  end

  # two outputs written by one loop, other statements in between (the
  # shape of geohash_decode)
  defk two_outputs(a :: [f64]) :: {[f64], [f64]} do
    n = len(a)
    lo = alloc(f64, n)
    hi = alloc(f64, n)

    sum =
      for x <- a, reduce: 0.0 do
        z -> z + x
      end

    s = sum / float(max(n, 1))

    for i <- 0..(n - 1)//1 do
      lo[i] = a[i] - s
      hi[i] = a[i] + s
    end

    {lo, hi}
  end

  # ---- near misses: each keeps the zeroing

  # the range's n is not the alloc's: rebound in between
  defk rebinds_length(n :: i64) :: [i64] do
    out = alloc(i64, n)
    n = n - 1

    for i <- 0..(n - 1)//1 do
      out[i] = 1
    end

    out
  end

  # reads the element before writing it
  defk read_first(n :: i64) :: [i64] do
    out = alloc(i64, n)

    for i <- 0..(n - 1)//1 do
      out[i] = out[i] + 1
    end

    out
  end

  # reads another element
  defk read_other(n :: i64) :: [i64] do
    out = alloc(i64, n)

    for i <- 0..(n - 1)//1 do
      out[i] = if i > 0, do: out[i - 1] + 1, else: 1
    end

    out
  end

  # the last element is never written
  defk short_range(n :: i64) :: [i64] do
    out = alloc(i64, n)

    for i <- 0..(n - 2)//1 do
      out[i] = 1
    end

    out
  end

  defk from_one(n :: i64) :: [i64] do
    out = alloc(i64, n)

    for i <- 1..(n - 1)//1 do
      out[i] = 1
    end

    out
  end

  defk every_other(n :: i64) :: [i64] do
    out = alloc(i64, n)

    for i <- 0..(n - 1)//2 do
      out[i] = 1
    end

    out
  end

  # a filter skips some writes
  defk filtered(n :: i64) :: [i64] do
    out = alloc(i64, n)

    for i <- 0..(n - 1)//1, rem(i, 2) == 0 do
      out[i] = 1
    end

    out
  end

  # the write is under a condition
  defk guarded(n :: i64) :: [i64] do
    out = alloc(i64, n)

    for i <- 0..(n - 1)//1 do
      if rem(i, 2) == 0 do
        out[i] = 1
      end
    end

    out
  end

  # a statement between the alloc and the loop reads the array
  defk read_between(n :: i64) :: {[i64], i64} do
    out = alloc(i64, n)
    first = if n > 0, do: out[0], else: 0

    for i <- 0..(n - 1)//1 do
      out[i] = 1
    end

    {out, first}
  end

  # the loop variable is rebound before the write
  defk rebound(n :: i64) :: [i64] do
    out = alloc(i64, n)

    for i <- 0..(n - 1)//1 do
      i = div(i, 2)
      out[i] = 1
    end

    out
  end

  # the array escapes into another binding before it is written
  defk escapes(n :: i64) :: {[i64], [i64]} do
    out = alloc(i64, n)

    copies =
      for i <- 0..(n - 1)//1, reduce: out do
        c ->
          out2 = c
          out2[i] = 1
          out2
      end

    {out, copies}
  end

  # the length in the range is not the alloc's
  defk other_length(n :: i64, m :: i64) :: [i64] do
    out = alloc(i64, n)

    for i <- 0..(min(n, m) - 1)//1 do
      out[i] = 1
    end

    out
  end

  # two of the three channels of each pixel
  defk two_of_three(n :: i64) :: [u8] do
    out = alloc(u8, 3 * n)

    for i <- 0..(n - 1)//1 do
      out[3 * i] = 1
      out[3 * i + 2] = 3
    end

    out
  end

  # the array is passed to len/1 in the body: any other mention keeps zeroing
  defk mentions(n :: i64) :: [i64] do
    out = alloc(i64, n)

    for i <- 0..(n - 1)//1 do
      out[i] = len(out)
    end

    out
  end

  Defk.AllocUnzeroedTest.Shapes.kernels()
end

defmodule Defk.AllocUnzeroedTest do
  # No other test file calls K or Shapes, so their forced-yield flags are
  # this module's own.
  use ExUnit.Case, async: true
  import Defk.Test.Frames
  import Defk.TestKit
  use Defk.Properties

  alias Defk.AllocUnzeroedTest.{K, Shapes}
  require Shapes

  defp agree(fun, args), do: Defk.Test.assert_agrees(K, fun, args)

  # each kernel here has one alloc: zeroed (in strips, or at once when
  # small), or not zeroed at all
  defp zeroed?(name) do
    c = kernel_c(K, name)
    c =~ "defk_zero_strip(" or c =~ ~r/defk_alloc_(?!raw_)\w+\(ctx, /
  end

  defp raw?(name), do: kernel_c(K, name) =~ "defk_alloc_raw_" and not zeroed?(name)

  @accepted [:dirty, :scale, :encode16, :by_len, :raise_mid, :slow_fill, :two_outputs]
  @near_misses [
    :rebinds_length,
    :read_first,
    :read_other,
    :short_range,
    :from_one,
    :every_other,
    :filtered,
    :guarded,
    :read_between,
    :rebound,
    :escapes,
    :other_length,
    :two_of_three,
    :mentions
  ]

  describe "the generated C" do
    test "a loop writing every element first: no zeroing" do
      for name <- @accepted do
        assert raw?(name), "#{name} zeroes its buffer"
        refute zeroed?(name), "#{name} zeroes its buffer"
      end
    end

    test "every near miss keeps the zeroing" do
      for name <- @near_misses do
        refute raw?(name), "#{name} skips zeroing"
        assert zeroed?(name), "#{name} has no zeroing"
      end
    end

    test "the fast-path report says why an alloc is not zeroed" do
      notes = for {{:scale, 2}, _, {:alloc, v, t}} <- K.__defk_report__(), do: {v, t}
      assert [{:unzeroed, text}] = notes
      assert text =~ "writes every element"
    end
  end

  describe "agreement" do
    test "the accepted kernels, after the allocator held 255s" do
      a = f64s(for x <- 1..5000, do: x * 0.25)
      K.dirty(8 * 5000)
      assert agree(:scale, [a, 2.0]) == {:ok, f64s(for x <- 1..5000, do: x * 0.5)}
      K.dirty(2 * 3)
      assert agree(:encode16, [<<1, 171, 255>>]) == {:ok, "01ABFF"}
      K.dirty(8 * 4)
      assert agree(:by_len, [4]) == {:ok, i64s([0, 1, 4, 9])}
      assert {:raise, %ArgumentError{message: "stop"}} = agree(:raise_mid, [10, 4])
      assert agree(:raise_mid, [3, 4]) == {:ok, <<1, 1, 1>>}
      assert agree(:slow_fill, [7]) == {:ok, i64s([0, 1, 3, 6, 10, 0, 1])}
      assert_frames_live(K)
    end

    test "under forced yields, a resume in the middle of the writes" do
      {_, count} =
        yields(K, fn ->
          forced(K, fn ->
            n = 10_000
            K.dirty(8 * n)
            assert {:ok, _} = agree(:slow_fill, [n])
            assert {:raise, %ArgumentError{}} = agree(:raise_mid, [n, n - 3])
          end)
        end)

      assert count > 0

      assert_frames_live(K)
    end

    test "the near misses read zeros where they did not write" do
      for name <- @near_misses -- [:other_length], n <- [0, 1, 7, 100] do
        K.dirty(24 * n)
        assert {_, _} = agree(name, [n]), "#{name}(#{n})"
      end

      K.dirty(8 * 10)
      assert agree(:other_length, [10, 4]) == {:ok, i64s([1, 1, 1, 1, 0, 0, 0, 0, 0, 0])}
    end
  end

  describe "random shapes around the accepted form" do
    test "a raw alloc only where every element is written" do
      for {name, s} <- Shapes.shapes() do
        if raw?(name), do: assert(Shapes.covers?(s), "#{name} #{inspect(s)} skips zeroing")
        assert raw?(name) or zeroed?(name), "#{name}: no alloc found"
      end
    end

    test "the accepted form is among them, so the check above is not vacuous" do
      assert Enum.count(Shapes.shapes(), fn {name, _} -> raw?(name) end) >= 3
      assert Enum.count(Shapes.shapes(), fn {name, _} -> not raw?(name) end) >= 10
    end

    property "every shape reads back zeros where it did not write, in both modes" do
      check all(
              {name, _} <- member_of(Shapes.shapes()),
              n <- integer(0..300),
              max_runs: 300
            ) do
        K.dirty(3 * n)
        agree(name, [n])
      end
    end
  end

  # ---------------------------------------------------- agreement properties --

  defp n, do: fixed_list([integer(-2..3000)])

  Shapes.agreement(K,
    dirty: [args: fixed_list([G.alloc_len(1)])],
    scale: [args: fixed_list([G.array(:f64), G.f64(1.0e6)])],
    encode16: [args: fixed_list([G.array(:u8)])],
    by_len: [args: n()],
    raise_mid: [args: fixed_list([integer(-2..3000), integer(-2..3000)])],
    slow_fill: [args: n()],
    read_first: [args: n()],
    read_other: [args: n()],
    short_range: [args: n()],
    from_one: [args: n()],
    every_other: [args: n()],
    filtered: [args: n()],
    guarded: [args: n()],
    read_between: [args: n()],
    rebound: [args: n()],
    escapes: [args: fixed_list([integer(-2..300)])],
    other_length: [args: fixed_list([integer(-2..3000), integer(-2..3000)])],
    two_of_three: [args: n()],
    mentions: [args: n()],
    two_outputs: [args: fixed_list([G.array(:f64)])],
    rebinds_length: [args: n()]
  )
end
