# alloc/2 skips zeroing its buffer when the compiler proves every element is
# written before anything reads it: the alloc is bound to a
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
  #               range ends one early (:rebind), or length(out) (:mention)
  def shapes do
    :rand.seed(:exsss, {7, 11, 13})

    for j <- 1..96 do
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
        between: Enum.random([nil, nil, nil, :unrelated, :unrelated, :rebind, :mention]),
        # the writes are the body of a `reduce:` clause, the loop the right
        # side of `_ = for ...`
        reduce: :rand.uniform(4) == 1
      }

      {:"shape_#{j}", shape}
    end
  end

  # Random grid shapes around the nested form, kernels grid_j(n, m): two or
  # three levels (the third extent a literal 2), the levels in one for or
  # across two, the length's factors in either order, and near misses:
  #   swap    - the index uses n where the row-major form needs m
  #   offset  - the index is one higher
  #   guard   - the write is under `if rem(y + x, 3) != 0`
  #   read    - the write adds the element's old value
  #   start   - the innermost range starts at 1
  def grids do
    :rand.seed(:exsss, {17, 19, 23})

    for j <- 1..40 do
      shape = %{
        dims: Enum.random([2, 2, 3]),
        split: :rand.uniform(2) == 1,
        order: :rand.uniform(2) == 1,
        swap: :rand.uniform(5) == 1,
        offset: :rand.uniform(6) == 1,
        guard: :rand.uniform(8) == 1,
        read: :rand.uniform(8) == 1,
        start: :rand.uniform(6) == 1
      }

      {:"grid_#{j}", shape}
    end
  end

  # Every element is written, for every n, m in 0..5, or the kernel raises
  def grid_covers?(%{guard: true}), do: false
  def grid_covers?(%{read: true}), do: false

  def grid_covers?(s) do
    Enum.all?(for(n <- 0..5, m <- 0..5, do: {n, m}), fn {n, m} ->
      ch = if s.dims == 3, do: 2, else: 1
      stride = if s.swap, do: n, else: m
      from = if s.start, do: 1, else: 0

      idx =
        for y <- 0..(n - 1)//1,
            x <- from..(m - 1)//1,
            c <- 0..(ch - 1)//1,
            do: (y * stride + x) * ch + c + if(s.offset, do: 1, else: 0)

      len = n * m * ch
      Enum.any?(idx, &(&1 < 0 or &1 >= len)) or MapSet.new(idx) == MapSet.new(0..(len - 1)//1)
    end)
  end

  defp grid_index(s) do
    stride = if s.swap, do: quote(do: n), else: quote(do: m)
    row = quote(do: y * unquote(stride) + x)
    at = if s.dims == 3, do: quote(do: unquote(row) * 2 + c), else: row
    if s.offset, do: quote(do: unquote(at) + 1), else: at
  end

  defp grid_len(%{dims: 2, order: true}), do: quote(do: n * m)
  defp grid_len(%{dims: 2}), do: quote(do: m * n)
  defp grid_len(%{dims: 3, order: true}), do: quote(do: n * m * 2)
  defp grid_len(%{dims: 3}), do: quote(do: 2 * (m * n))

  defp grid_write(s) do
    at = grid_index(s)
    v = if s.read, do: quote(do: out[unquote(at)] + 1), else: quote(do: band(y + x, 255))
    w = quote(do: out[unquote(at)] = unquote(v))
    if s.guard, do: quote(do: if(rem(y + x, 3) != 0, do: unquote(w))), else: w
  end

  defp grid_loop(s) do
    from = if s.start, do: 1, else: 0
    w = grid_write(s)
    gx = quote(do: x <- unquote(from)..(m - 1)//1)
    gc = quote(do: c <- 0..(2 - 1)//1)
    inner = if s.dims == 3, do: [gx, gc], else: [gx]
    gy = quote(do: y <- 0..(n - 1)//1)

    if s.split,
      do: {:for, [], [gy, [do: {:for, [], inner ++ [[do: w]]}]]},
      else: {:for, [], [gy | inner] ++ [[do: w]]}
  end

  defmacro grid_kernels do
    for {name, s} <- grids() do
      quote do
        defk unquote(name)(n :: i64, m :: i64) :: [u8] do
          out = alloc(u8, unquote(grid_len(s)))
          unquote(grid_loop(s))
          out
        end
      end
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

  defp block_stmts({:__block__, _, ss}), do: ss
  defp block_stmts(s), do: [s]

  defp between(nil), do: nil
  defp between(:unrelated), do: quote(do: _ = n * 3)
  defp between(:rebind), do: quote(do: n = n - 1)
  defp between(:mention), do: quote(do: _ = length(out))

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

    grids =
      for {name, _} <- grids(),
          do:
            {name,
             [
               args:
                 quote(
                   do:
                     StreamData.fixed_list([
                       StreamData.integer(-2..40),
                       StreamData.integer(-2..40)
                     ])
                 )
             ]}

    quote do
      require Defk.Properties
      Defk.Properties.agreement(unquote(mod), unquote(named ++ shapes ++ grids))
    end
  end

  defmacro kernels do
    for {name, s} <- shapes() do
      writes = Enum.map(s.cs, &write(s, &1))
      body = {:__block__, [], writes}
      body = if s.guard, do: quote(do: if(rem(i, 3) != 0, do: unquote(body))), else: body
      range = quote(do: unquote(s.start)..unquote(stop(s.stop))//unquote(s.step))

      loop =
        if s.reduce do
          clause = {:__block__, [], block_stmts(body) ++ [quote(do: acc + 1)]}

          quote do
            _ =
              for i <- unquote(range), reduce: 0 do
                acc -> unquote(clause)
              end
          end
        else
          quote do
            for i <- unquote(range) do
              unquote(body)
            end
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

    length(a)
  end

  # ---- accepted: every element written before any read

  defk scale(a :: [f64], k :: f64) :: [f64] do
    out = alloc(f64, length(a))

    for i <- 0..(length(a) - 1)//1 do
      out[i] = a[i] * k
    end

    out
  end

  defk encode16(s :: [u8]) :: [u8] do
    n = length(s)
    out = alloc(u8, 2 * n)

    for i <- 0..(n - 1)//1 do
      b = s[i]
      out[2 * i] = @hex[band(bsr(b, 4), 15)]
      out[2 * i + 1] = @hex[band(b, 15)]
    end

    out
  end

  # the range end as length of the new array
  defk by_len(n :: i64) :: [i64] do
    out = alloc(i64, n)

    for i <- 0..(length(out) - 1)//1 do
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
    n = length(a)
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

  # the array is passed to length/1 in the body: any other mention keeps zeroing
  defk mentions(n :: i64) :: [i64] do
    out = alloc(i64, n)

    for i <- 0..(n - 1)//1 do
      out[i] = length(out)
    end

    out
  end

  # ---- accepted: a reduce: loop writing a captured array (monte_carlo's draws)

  defk fold_fill(n :: i64) :: {[i64], i64} do
    out = alloc(i64, n)

    sum =
      for i <- 0..(n - 1)//1, reduce: 0 do
        acc ->
          out[i] = i * 2
          acc + i
      end

    {out, sum}
  end

  # the fold's value is a tuple, the loop the right side of a match, k = 2
  defk fold_pair(n :: i64) :: {[i64], i64, i64} do
    out = alloc(i64, 2 * n)

    {a, b} =
      for i <- 0..(n - 1)//1, reduce: {1, 0} do
        {a, b} ->
          out[2 * i] = a
          out[2 * i + 1] = b
          {b + 1, a}
      end

    {out, a, b}
  end

  # ---- accepted: nested range loops writing a row-major index

  # two generators in one for
  defk grid2(h :: i64, w :: i64) :: [i64] do
    out = alloc(i64, h * w)

    for y <- 0..(h - 1)//1, x <- 0..(w - 1)//1 do
      out[y * w + x] = y - x
    end

    out
  end

  # three levels across two fors, other statements at the outer level, the
  # length's factors in another order (resize_bilinear's out)
  defk grid3(h :: i64, w :: i64, ch :: i64) :: [u8] do
    out = alloc(u8, ch * (w * h))

    for y <- 0..(h - 1)//1 do
      r = y * 3

      for x <- 0..(w - 1)//1, c <- 0..(ch - 1)//1 do
        out[(y * w + x) * ch + c] = band(r + x + c, 255)
      end
    end

    out
  end

  # ---- near misses around those

  # the fold's initial value reads the array
  defk fold_init_reads(n :: i64) :: {[i64], i64} do
    out = alloc(i64, n)

    s =
      for i <- 0..(n - 1)//1, reduce: if(n > 0, do: out[0], else: 0) do
        acc ->
          out[i] = 1
          acc + 1
      end

    {out, s}
  end

  # the index strides by the wrong extent: some elements stay unwritten
  defk grid_wrong_extent(h :: i64, w :: i64) :: [i64] do
    out = alloc(i64, h * w)

    for y <- 0..(h - 1)//1, x <- 0..(w - 1)//1 do
      out[y * h + x] = 1
    end

    out
  end

  # the inner loop is under a condition
  defk grid_inner_guarded(h :: i64, w :: i64) :: [i64] do
    out = alloc(i64, h * w)

    for y <- 0..(h - 1)//1 do
      if y > 0 do
        for x <- 0..(w - 1)//1 do
          out[y * w + x] = 1
        end
      end
    end

    out
  end

  # an extent is rebound inside the nest
  defk grid_rebinds(h :: i64, w :: i64) :: [i64] do
    out = alloc(i64, h * w)

    for y <- 0..(h - 1)//1 do
      w = max(w, 0)

      for x <- 0..(w - 1)//1 do
        out[y * w + x] = 1
      end
    end

    out
  end

  # the write reads another element
  defk grid_reads(h :: i64, w :: i64) :: [i64] do
    out = alloc(i64, h * w)

    for y <- 0..(h - 1)//1, x <- 0..(w - 1)//1 do
      out[y * w + x] = if x > 0, do: out[y * w + x - 1] + 1, else: 1
    end

    out
  end

  # the inner range starts at 1
  defk grid_from_one(h :: i64, w :: i64) :: [i64] do
    out = alloc(i64, h * w)

    for y <- 0..(h - 1)//1, x <- 1..(w - 1)//1 do
      out[y * w + x] = 1
    end

    out
  end

  # the index is not in the row-major form (it still covers: a shape the
  # proof does not recognise stays zeroed)
  defk grid_offset(h :: i64, w :: i64) :: [i64] do
    out = alloc(i64, h * w)

    for y <- 0..(h - 1)//1, x <- 0..(w - 1)//1 do
      out[y * w + x + 0] = 1
    end

    out
  end

  # a covering loop plus a tail that writes the rest (encode64's old shape):
  # proving the tail writes exactly the rest needs div/rem arithmetic the
  # proof does not do, so it stays zeroed
  defk with_tail(n :: i64) :: [u8] do
    pairs = div(n, 2)
    out = alloc(u8, 2 * div(n + 1, 2))

    for i <- 0..(pairs - 1)//1 do
      out[2 * i] = 1
      out[2 * i + 1] = 2
    end

    if rem(n, 2) == 1 do
      out[n - 1] = 1
      out[n] = 3
    end

    out
  end

  Defk.AllocUnzeroedTest.Shapes.kernels()
  Defk.AllocUnzeroedTest.Shapes.grid_kernels()
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
  # small), or not zeroed at all, as the report says and the C shows (a
  # nested form's alloc is raw with a zeroing under `if (extent < 0)`, which
  # no written array takes; its C has the strip loop or memset in that block)
  defp alloc_notes(name),
    do: for({{^name, _}, _, {:alloc, kind, _}} <- K.__defk_report__(), do: kind)

  defp zeroed?(name) do
    c = kernel_c(K, name)
    notes = alloc_notes(name)

    notes != [] and Enum.all?(notes, &(&1 in [:zeroed, :strips])) and
      (c =~ "defk_zero_strip(" or c =~ ~r/defk_alloc_(?!raw_)\w+\(ctx, /)
  end

  defp raw?(name) do
    notes = alloc_notes(name)

    notes != [] and Enum.all?(notes, &(&1 == :unzeroed)) and
      kernel_c(K, name) =~ "defk_alloc_raw_"
  end

  @accepted [
    :dirty,
    :scale,
    :encode16,
    :by_len,
    :raise_mid,
    :slow_fill,
    :two_outputs,
    :fold_fill,
    :fold_pair,
    :grid2,
    :grid3
  ]
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
    :mentions,
    :fold_init_reads,
    :with_tail
  ]
  # near misses taking (h, w)
  @grid_near_misses [
    :grid_wrong_extent,
    :grid_inner_guarded,
    :grid_rebinds,
    :grid_reads,
    :grid_from_one,
    :grid_offset
  ]

  describe "the generated C" do
    test "a loop writing every element first: no zeroing" do
      for name <- @accepted do
        assert raw?(name), "#{name} zeroes its buffer"
        refute zeroed?(name), "#{name} zeroes its buffer"
      end
    end

    test "every near miss keeps the zeroing" do
      for name <- @near_misses ++ @grid_near_misses do
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

      for name <- @grid_near_misses, {h, w} <- [{0, 0}, {1, 1}, {2, 3}, {3, 2}, {5, 7}] do
        K.dirty(8 * h * w)
        assert {_, _} = agree(name, [h, w]), "#{name}(#{h}, #{w})"
      end

      K.dirty(8 * 6)
      assert agree(:grid_wrong_extent, [2, 3]) == {:ok, i64s([1, 1, 1, 1, 1, 0])}
    end

    test "the reduce and grid forms, after the allocator held 255s" do
      K.dirty(8 * 5)
      assert agree(:fold_fill, [5]) == {:ok, {i64s([0, 2, 4, 6, 8]), 10}}
      K.dirty(8 * 6)
      assert agree(:fold_pair, [3]) == {:ok, {i64s([1, 0, 1, 1, 2, 1]), 2, 2}}
      K.dirty(8 * 6)
      assert agree(:grid2, [2, 3]) == {:ok, i64s([0, -1, -2, 1, 0, -1])}
      K.dirty(12)
      assert agree(:grid3, [2, 3, 2]) == {:ok, <<0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6>>}
      assert agree(:grid3, [0, 3, 2]) == {:ok, <<>>}
      assert {:raise, %ArgumentError{}} = agree(:grid3, [2, -1, 2])
      assert_frames_live(K)
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
      # the reduce: form is drawn too (the raw ones are fold_fill and
      # fold_pair above: the drawn reduce shapes that cover all have a
      # near-miss trait, an out-of-range c or a mention between)
      assert Enum.count(Shapes.shapes(), fn {_, s} -> s.reduce end) >= 10
      assert Enum.any?(Shapes.shapes(), fn {_, s} -> s.reduce and Shapes.covers?(s) end)
    end

    test "a raw alloc only where every element of a grid is written" do
      for {name, s} <- Shapes.grids() do
        if raw?(name), do: assert(Shapes.grid_covers?(s), "#{name} #{inspect(s)} skips zeroing")
        assert raw?(name) or zeroed?(name), "#{name}: no alloc found"
      end

      assert Enum.count(Shapes.grids(), fn {name, _} -> raw?(name) end) >= 3
      assert Enum.any?(Shapes.grids(), fn {name, s} -> raw?(name) and s.dims == 3 end)
      assert Enum.count(Shapes.grids(), fn {name, _} -> not raw?(name) end) >= 5
    end

    property "every grid reads back zeros where it did not write, in both modes" do
      check all(
              {name, _} <- member_of(Shapes.grids()),
              h <- integer(0..30),
              w <- integer(0..30),
              max_runs: 200
            ) do
        K.dirty(2 * h * w)
        agree(name, [h, w])
      end
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
  defp hw, do: fixed_list([integer(-2..60), integer(-2..60)])

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
    rebinds_length: [args: n()],
    fold_fill: [args: n()],
    fold_pair: [args: n()],
    fold_init_reads: [args: n()],
    with_tail: [args: n()],
    grid2: [args: hw()],
    grid3: [args: fixed_list([integer(-2..30), integer(-2..30), integer(-2..5)])],
    grid_wrong_extent: [args: hw()],
    grid_inner_guarded: [args: hw()],
    grid_rebinds: [args: hw()],
    grid_reads: [args: hw()],
    grid_from_one: [args: hw()],
    grid_offset: [args: hw()]
  )
end
