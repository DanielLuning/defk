# A float operation whose result would be inf or NaN raises ArithmeticError
# at that operation, as Elixir does; an inf or NaN read from an input array
# raises ArgumentError at the read (defk-i00, decided in defk-q1c). Every
# case runs in both modes through Defk.Test.assert_agrees.

defmodule Defk.NonFiniteTest.K do
  use Defk

  defk add(x :: f64, y :: f64) :: f64 do
    x + y
  end

  defk sub(x :: f64, y :: f64) :: f64 do
    x - y
  end

  defk mul(x :: f64, y :: f64) :: f64 do
    x * y
  end

  defk fdiv(x :: f64, y :: f64) :: f64 do
    x / y
  end

  defk sqrt_of(x :: f64) :: f64 do
    sqrt(x)
  end

  defk log_of(x :: f64) :: f64 do
    log(x)
  end

  defk log2_of(x :: f64) :: f64 do
    log2(x)
  end

  defk log10_of(x :: f64) :: f64 do
    :math.log10(x)
  end

  defk exp_of(x :: f64) :: f64 do
    exp(x)
  end

  defk pow_of(x :: f64, y :: f64) :: f64 do
    :math.pow(x, y)
  end

  # the non-finite value never reaches the return: an integer compared with
  # it (defk-t11.2's probe), or an output array element
  defk compare(i :: i64, x :: f64, y :: f64) :: bool do
    i > x * y
  end

  defk store(x :: f64, y :: f64) :: [f64] do
    out = alloc(f64, 1)
    out[0] = x * y
    out
  end

  # NaN reaching trunc/round: the operation that makes it raises first
  defk trunc_nan(x :: f64, y :: f64) :: i64 do
    trunc((x - y) / (x - y))
  end

  defk round_nan(x :: f64, y :: f64) :: i64 do
    round((x - y) / (x - y))
  end

  # input reads: a proved in-range index, a checked one, and an element loop
  defk first(a :: [f64]) :: f64 do
    a[0]
  end

  defk at(a :: [f64], i :: i64) :: f64 do
    a[i]
  end

  defk sum_to(a :: [f64], n :: i64) :: f64 do
    for i <- 0..(min(n, len(a)) - 1)//1, reduce: 0.0 do
      acc -> acc + a[i]
    end
  end

  defk sum_all(a :: [f64]) :: f64 do
    for x <- a, reduce: 0.0 do
      acc -> acc + x
    end
  end

  # an alloc/2 array is read without the input check
  defk copy_sum(a :: [f64]) :: f64 do
    b = alloc(f64, len(a))

    for i <- 0..(len(a) - 1)//1 do
      b[i] = a[i]
    end

    for x <- b, reduce: 0.0 do
      acc -> acc + x
    end
  end

  # one float expression is checked once and replayed on failure (float_tree
  # in the compiler): the replay raises where Elixir does, in its order
  defk overflow_then_read(a :: [f64], x :: f64) :: f64 do
    x * 1.0e308 * 10.0 + a[0]
  end

  defk read_then_overflow(a :: [f64], x :: f64) :: f64 do
    a[0] + x * 1.0e308 * 10.0
  end

  # x / inf is 0.0: the divisor is checked too
  defk over_read(a :: [f64], x :: f64) :: f64 do
    x / a[0]
  end

  defk over_product(x :: f64, y :: f64, z :: f64) :: f64 do
    x / (y * z) - x
  end

  defk mixed(i :: i64, x :: f64) :: f64 do
    -(i * x) + i / 2 * -1.0
  end

  # selects: the arm not taken may divide by zero or overflow
  defk safe_div(x :: f64, y :: f64) :: f64 do
    if y != 0.0, do: x / y, else: 0.0
  end

  defk scale_unless(keep :: bool, x :: f64, k :: f64) :: f64 do
    if keep, do: x, else: x * k
  end

  defk cond_ratio(x :: f64, y :: f64) :: f64 do
    cond do
      y == 0.0 -> x
      x / y > 1.0 -> x / y
      true -> y - x
    end
  end

  # flat loops whose only checks are float checks run each strip with a flag
  # and replay a failed strip with the raising checks (defk-6tt): an
  # element-wise map writing its output, a reduce, and two accumulators
  defk scale(a :: [f64], k :: f64) :: [f64] do
    out = alloc(f64, len(a))

    for i <- 0..(len(a) - 1)//1 do
      out[i] = a[i] * k
    end

    out
  end

  defk dot(a :: [f64], b :: [f64]) :: f64 do
    n = min(len(a), len(b))

    for i <- 0..(n - 1)//1, reduce: 0.0 do
      acc -> acc + a[i] * b[i]
    end
  end

  defk moments(a :: [f64]) :: {f64, f64} do
    for x <- a, reduce: {0.0, 0.0} do
      {s, q} -> {s + x, q + x * x}
    end
  end

  # a filter puts the accumulator's update under a branch, where no
  # end-of-strip test covers it: the update keeps its own check in a flagged
  # strip (defk-zj8). The comparison keeps an inf from the result's check.
  defk filtered_sumsq(a :: [f64]) :: bool do
    s =
      for x <- a, x > 0.0, reduce: 0.0 do
        acc -> acc + x * x
      end

    s > 1.0
  end

  # a numerator keeps an inf or NaN too, and 1.0 / 0.0 makes one
  defk halving(a :: [f64]) :: f64 do
    for x <- a, reduce: 0.0 do
      acc -> acc / 2.0 + 1.0 / x
    end
  end

  # strips that can also fail by i64 overflow (ix[i] * k) and an index out
  # of bounds (a[j], out[j]) run flagged too, every check setting the flag
  # (defk-hki): a gather read and a scatter write, whose flagged forms never
  # touch memory outside the array
  defk gather(a :: [f64], ix :: [i64], k :: i64) :: f64 do
    for i <- 0..(len(ix) - 1)//1, reduce: 0.0 do
      acc -> acc + a[ix[i] * k] * 2.0
    end
  end

  defk scatter(a :: [f64], ix :: [i64], k :: i64) :: [f64] do
    out = alloc(f64, len(a))

    for i <- 0..(min(len(a), len(ix)) - 1)//1 do
      out[ix[i] * k] = a[i] * 2.0
    end

    out
  end

  # x[j] is proved in bounds from j's facts, but j is assigned in the strip:
  # a strip that also flags an overflow (ix[i] * 2) stays checked, since a
  # flagged run computes on after a failure (defk-hki)
  defk shifted_sum(x :: [f64], ix :: [i64]) :: f64 do
    n = min(len(x), len(ix))

    for i <- 0..(n - 2)//1, reduce: 0.0 do
      acc ->
        j = i + 1
        acc + x[j] + float(ix[i] * 2)
    end
  end

  # sqrt of a value never below 0.0 needs no check (defk-hki); of one that
  # may be below it, the check stays
  defk root_clamped(x :: f64) :: f64 do
    sqrt(max(x, 0.0))
  end

  defk root_abs(x :: f64, y :: f64) :: f64 do
    sqrt(min(abs(x), max(y, 1.0)))
  end

  defk root_shifted(x :: f64) :: f64 do
    sqrt(max(x, -1.0))
  end

  # an integer-only loop has no float check to flag (defk-60q)
  defk spread(a :: [u8]) :: [u8] do
    out = alloc(u8, 2 * len(a))

    for i <- 0..(len(a) - 1)//1 do
      out[2 * i] = a[i]
    end

    out
  end
end

defmodule Defk.NonFiniteTest do
  use ExUnit.Case, async: true
  use Defk.Properties

  alias Defk.NonFiniteTest.K

  # the largest finite double
  @max 2.0 ** 1023 * (2 - 2.0 ** -52)
  @tiny 5.0e-324

  defp agrees(fun, args), do: Defk.Test.assert_agrees(K, fun, args)

  defp raises(fun, args, module, reason) do
    assert {:raise, %^module{} = e} = agrees(fun, args)
    assert Defk.Test.agreement_reason(e) == reason
    # raised by the failing operation itself, also after a flagged strip's
    # replay (never its fallback, which names no operation)
    refute e.message == "float result is inf or NaN"
    e
  end

  defp non_finite(fun, args), do: raises(fun, args, ArithmeticError, :non_finite)

  defp non_finite_input(fun, args), do: raises(fun, args, ArgumentError, :non_finite_input)

  defp pack(xs), do: for(x <- xs, into: <<>>, do: pack1(x))
  defp pack1(:inf), do: <<0x7FF0000000000000::64-native>>
  defp pack1(:neg_inf), do: <<0xFFF0000000000000::64-native>>
  defp pack1(:nan), do: <<0x7FF8000000000000::64-native>>
  defp pack1(x), do: <<x::float-64-native>>

  test "+, - and * overflowing to inf raise at the operation" do
    non_finite(:add, [@max, @max])
    non_finite(:sub, [-@max, @max])
    non_finite(:mul, [1.0e308, 10.0])
    non_finite(:mul, [-1.0e200, 1.0e200])
    assert {:ok, @max} = agrees(:add, [@max, 0.0])
  end

  test "x / 0.0 and 0.0 / 0.0 raise, and so does a quotient overflowing" do
    non_finite(:fdiv, [1.0, 0.0])
    non_finite(:fdiv, [-1.0, -0.0])
    non_finite(:fdiv, [0.0, 0.0])
    non_finite(:fdiv, [1.0e300, 1.0e-300])
  end

  test "sqrt and log outside their domain raise" do
    non_finite(:sqrt_of, [-1.0])
    non_finite(:log_of, [0.0])
    non_finite(:log_of, [-1.0])
    assert {:ok, -0.0} = agrees(:sqrt_of, [-0.0])
  end

  test "exp and pow overflowing raise" do
    non_finite(:exp_of, [1000.0])
    non_finite(:pow_of, [10.0, 400.0])
    non_finite(:pow_of, [0.0, -1.0])
    non_finite(:pow_of, [-8.0, 0.5])
    assert {:ok, 1.0} = agrees(:pow_of, [0.0, 0.0])
  end

  test "underflow to 0.0 or a subnormal does not raise" do
    assert {:ok, +0.0} = agrees(:mul, [1.0e-200, 1.0e-200])
    assert {:ok, -0.0} = agrees(:mul, [-1.0e-200, 1.0e-200])
    assert {:ok, @tiny} = agrees(:fdiv, [@tiny * 4, 4.0])
    assert {:ok, sub} = agrees(:sub, [2.2250738585072014e-308, 2.2250738585072009e-308])
    assert sub > 0.0 and sub < 2.2250738585072014e-308
    assert {:ok, +0.0} = agrees(:exp_of, [-1000.0])
    assert {:ok, +0.0} = agrees(:pow_of, [10.0, -400.0])
  end

  test "a non-finite value raises even when it is never returned" do
    non_finite(:compare, [1, 1.0e308, 10.0])
    non_finite(:store, [1.0e308, 10.0])
    assert {:ok, true} = agrees(:compare, [1, 0.5, 1.0])
  end

  test "trunc and round of NaN raise where the NaN is made" do
    non_finite(:trunc_nan, [1.0, 1.0])
    non_finite(:round_nan, [2.0, 2.0])
    assert {:ok, 1} = agrees(:trunc_nan, [3.0, 1.0])
  end

  test "an inf or NaN read from an input array raises ArgumentError at the read" do
    for bad <- [:inf, :neg_inf, :nan] do
      e = non_finite_input(:first, [pack([bad, 1.0])])
      assert e.message =~ "at index 0"
      non_finite_input(:at, [pack([1.0, bad]), 1])
      non_finite_input(:sum_to, [pack([1.0, 2.0, bad]), 3])
      non_finite_input(:sum_all, [pack([1.0, bad, 2.0])])
      non_finite_input(:copy_sum, [pack([bad])])
    end
  end

  test "an inf or NaN element that is never read does not raise" do
    for bad <- [:inf, :nan] do
      assert {:ok, 1.0} = agrees(:first, [pack([1.0, bad])])
      assert {:ok, 1.0} = agrees(:at, [pack([1.0, bad]), 0])
      assert {:ok, 3.0} = agrees(:sum_to, [pack([1.0, 2.0, bad]), 2])
    end

    # an out-of-range index raises the index error, not the input error
    assert {:raise, %Enum.OutOfBoundsError{}} = agrees(:at, [pack([:inf]), 1])
  end

  test "an expression checked once raises the first error in Elixir's order" do
    nan = pack([:nan])
    non_finite(:overflow_then_read, [nan, 1.0])
    non_finite_input(:read_then_overflow, [nan, 1.0])
    non_finite(:overflow_then_read, [pack([1.0]), 1.0])
    non_finite_input(:overflow_then_read, [nan, 1.0e-10])
    assert {:ok, x} = agrees(:overflow_then_read, [pack([1.0]), 1.0e-308])
    assert_in_delta x, 11.0, 1.0e-9
    non_finite_input(:over_read, [pack([:inf]), 1.0])
    non_finite(:over_read, [pack([0.0]), 1.0])
    assert {:ok, 0.5} = agrees(:over_read, [pack([2.0]), 1.0])
    non_finite(:over_product, [1.0, 1.0e200, 1.0e200])
    non_finite(:over_product, [1.0, 0.0, 1.0])
    assert {:ok, -0.5} = agrees(:over_product, [1.0, 2.0, 1.0])
    assert {:ok, -1.5} = agrees(:mixed, [1, 1.0])
    non_finite(:mixed, [2, 1.0e308])
  end

  test "a select whose untaken arm would raise does not raise" do
    assert {:ok, +0.0} = agrees(:safe_div, [1.0, 0.0])
    assert {:ok, 0.5} = agrees(:safe_div, [1.0, 2.0])
    assert {:ok, 1.0e308} = agrees(:scale_unless, [true, 1.0e308, 10.0])
    assert {:ok, 3.0} = agrees(:cond_ratio, [3.0, 0.0])
    assert {:ok, 3.0} = agrees(:cond_ratio, [3.0, 1.0])
    assert {:ok, 0.5} = agrees(:cond_ratio, [0.5, 1.0])
  end

  test "a select whose taken arm or reached condition is non-finite raises" do
    non_finite(:safe_div, [1.0e300, 1.0e-300])
    non_finite(:scale_unless, [false, 1.0e308, 10.0])
    non_finite(:cond_ratio, [1.0e300, 1.0e-300])
  end

  test "float arms compile to a select, a division arm to a branch" do
    c = File.read!(String.replace_suffix(K.__defk_lib__(), ".so", ".c"))
    assert c =~ "defk_fmul_s(&"
    # a division is not speculated (defk-id9)
    refute c =~ "defk_fdiv_s(&"
  end

  # DEFK_STRIP: positions in the first strip, at its end and in the next one
  @strip 2048

  defp positions(n),
    do: Enum.uniq(for p <- [0, 1, @strip - 1, @strip, @strip + 1, n - 1], p < n, do: p)

  defp with_bad(n, at, bad, fill \\ 0.5),
    do: pack(for i <- 0..(n - 1), do: if(i == at, do: bad, else: fill))

  defp flagged_strips(force?) do
    K.__defk_force_yields__(force?)

    try do
      # short loops (one plain loop, < DEFK_STRIP trips) and strips
      for n <- [100, 2 * @strip + 3], p <- positions(n) do
        non_finite(:scale, [with_bad(n, p, 1.0e308), 10.0])
        e = non_finite_input(:scale, [with_bad(n, p, :nan), 1.0])
        assert e.message =~ "at index #{p}"

        # the first error in program order wins: element p before element p + 1
        a =
          pack(
            for i <- 0..(n - 1), do: if(i == p, do: :inf, else: if(i > p, do: 1.0e308, else: 1.0))
          )

        e = non_finite_input(:scale, [a, 10.0])
        assert e.message =~ "at index #{p}"

        a =
          pack(
            for i <- 0..(n - 1), do: if(i == p, do: 1.0e308, else: if(i > p, do: :nan, else: 1.0))
          )

        non_finite(:scale, [a, 10.0])

        ones = with_bad(n, -1, nil, 1.0)
        non_finite(:dot, [with_bad(n, p, 1.0e200), with_bad(n, p, 1.0e200)])
        e = non_finite_input(:dot, [ones, with_bad(n, p, :neg_inf)])
        assert e.message =~ "at index #{p}"
        # the sum overflows at p and stays inf: raised at p, not at the end
        big = pack(for i <- 0..(n - 1), do: if(i < p, do: 0.0, else: 1.0e308))
        if p + 1 < n, do: non_finite(:dot, [big, with_bad(n, -1, nil, 2.0)])

        non_finite(:moments, [with_bad(n, p, 1.0e200)])
        e = non_finite_input(:moments, [with_bad(n, p, :nan)])
        assert e.message =~ "at index #{p}"
        non_finite(:halving, [with_bad(n, p, 0.0)])
        e = non_finite_input(:halving, [with_bad(n, p, :inf)])
        assert e.message =~ "at index #{p}"
      end

      n = 2 * @strip + 3
      assert {:ok, out} = agrees(:scale, [with_bad(n, -1, nil, 1.0e300), 10.0])
      assert byte_size(out) == 8 * n
      assert {:ok, _} = agrees(:dot, [with_bad(n, -1, nil, 1.0e150), with_bad(n, 7, 1.0e-300)])
      assert {:ok, _} = agrees(:moments, [with_bad(n, -1, nil, 1.0e150)])
    after
      K.__defk_force_yields__(false)
    end
  end

  test "a failing flagged strip raises the first error, at any position" do
    flagged_strips(false)
  end

  test "a failing flagged strip raises the first error under forced yields" do
    flagged_strips(true)
  end

  # the update sits under the filter's branch, and the sum's inf never
  # reaches a return check: only the update's own check can raise (defk-zj8)
  test "a filtered accumulator overflowing in a flagged strip raises at the operation" do
    for n <- [100, 2 * @strip + 3], p <- positions(n) do
      non_finite(:filtered_sumsq, [with_bad(n, p, 1.0e308, -1.0)])
      non_finite(:filtered_sumsq, [with_bad(n, p, 1.0e200, 1.0e154)])
    end

    assert {:ok, false} = agrees(:filtered_sumsq, [with_bad(2 * @strip + 3, -1, nil, -1.0e308)])
    assert {:ok, true} = agrees(:filtered_sumsq, [with_bad(2 * @strip + 3, 5, 1.0e154, -1.0)])
  end

  # Mixed-error strips (defk-hki). Each kind of error is made at one
  # iteration by the index ix[i] it reads: an i64 overflow of ix[i] * 2, an
  # index out of bounds (past the end, negative, far away), a NaN input
  # element, and a product overflowing to inf. a holds 0.5 except a NaN at 2
  # and 1.0e308 at 4; ix is 0 (a[0]) elsewhere.
  @mixed_len 8
  @kinds [:overflow, :past_end, :negative, :far, :nan, :inf]

  defp ix_of(:overflow), do: 2 ** 62
  defp ix_of(:past_end), do: div(@mixed_len, 2)
  defp ix_of(:negative), do: -1
  defp ix_of(:far), do: 2 ** 40
  defp ix_of(:nan), do: 1
  defp ix_of(:inf), do: 2

  defp reason_of(:overflow), do: {ArithmeticError, :overflow}
  defp reason_of(:nan), do: {ArgumentError, :non_finite_input}
  defp reason_of(:inf), do: {ArithmeticError, :non_finite}
  defp reason_of(_oob), do: {Enum.OutOfBoundsError, :index}

  defp mixed_a,
    do: pack(for i <- 0..(@mixed_len - 1), do: Map.get(%{2 => :nan, 4 => 1.0e308}, i, 0.5))

  # ix of length n with kind kinds[j] at position at[j]
  defp mixed_ix(n, placed) do
    m = Map.new(placed)
    for i <- 0..(n - 1), into: <<>>, do: <<Map.get(m, i, 0)::64-signed-native>>
  end

  # the kernel raises the first placed error in program order, as Elixir mode
  defp first_error(fun, args, kind) do
    {module, reason} = reason_of(kind)
    assert {:raise, %^module{} = e} = agrees(fun, args)
    assert Defk.Test.agreement_reason(e) == reason
    refute e.message == "float result is inf or NaN"
  end

  defp mixed_strips(force?) do
    K.__defk_force_yields__(force?)
    a = mixed_a()
    # scatter reads a[i] for i < len(a), so it runs over a longer a of 0.5s;
    # its own errors are the index ones and a NaN or inf at a[i]
    try do
      for n <- [100, 2 * @strip + 3],
          p <- positions(n),
          gap <- [1, @strip],
          q = p + gap,
          q < n,
          k1 <- @kinds,
          k2 <- @kinds,
          k1 != k2 do
        ix = mixed_ix(n, [{p, ix_of(k1)}, {q, ix_of(k2)}])
        first_error(:gather, [a, ix, 2], k1)
      end

      # three errors in one strip, in every order
      n = 2 * @strip + 3

      for p <- [0, @strip - 3, @strip + 7],
          [k1, k2, k3] <- permutations([:overflow, :far, :nan, :inf], 3) do
        ix = mixed_ix(n, [{p, ix_of(k1)}, {p + 1, ix_of(k2)}, {p + 2, ix_of(k3)}])
        first_error(:gather, [a, ix, 2], k1)
      end

      # an empty array: every read is out of bounds
      first_error(:gather, [<<>>, mixed_ix(n, []), 2], :far)
      assert {:ok, +0.0} = agrees(:gather, [<<>>, <<>>, 2])
      assert {:ok, x} = agrees(:gather, [a, mixed_ix(n, []), 2])
      assert x == n * 1.0

      for n <- [100, 2 * @strip + 3], p <- positions(n), gap <- [1, @strip], q = p + gap, q < n do
        big = with_bad(n, -1, nil, 0.5)

        for {k1, k2} <- [
              {:overflow, :far},
              {:far, :overflow},
              {:negative, :overflow},
              {:past, :far}
            ] do
          ix = mixed_ix(n, [{p, scatter_ix(k1, n)}, {q, scatter_ix(k2, n)}])
          first_error(:scatter, [big, ix, 2], scatter_kind(k1))
        end

        # an index error before a float error and the reverse
        nan_at_q = with_bad(n, q, :nan)
        first_error(:scatter, [nan_at_q, mixed_ix(n, [{p, 2 ** 40}]), 2], :far)
        first_error(:scatter, [with_bad(n, p, 1.0e308), mixed_ix(n, [{q, -5}]), 2], :inf)
        first_error(:scatter, [with_bad(n, p, :nan), mixed_ix(n, [{q, 2 ** 62}]), 2], :nan)
        first_error(:scatter, [nan_at_q, mixed_ix(n, [{p, 2 ** 62}]), 2], :overflow)
      end

      assert {:ok, out} = agrees(:scatter, [with_bad(n, -1, nil, 0.5), mixed_ix(n, []), 2])
      assert out == pack([1.0] ++ List.duplicate(0.0, n - 1))
    after
      K.__defk_force_yields__(false)
    end
  end

  defp scatter_ix(:past, n), do: n
  defp scatter_ix(kind, _n), do: ix_of(kind)
  defp scatter_kind(:past), do: :past_end
  defp scatter_kind(kind), do: kind

  defp permutations(_, 0), do: [[]]

  defp permutations(xs, k),
    do: for(x <- xs, rest <- permutations(xs -- [x], k - 1), do: [x | rest])

  test "a strip with overflow, bounds and float checks raises the first error in any order" do
    mixed_strips(false)
  end

  test "a mixed-error strip raises the first error under forced yields" do
    mixed_strips(true)
  end

  test "sqrt of a value never below 0.0 is unchecked and agrees" do
    assert {:ok, +0.0} = agrees(:root_clamped, [-4.0])
    assert {:ok, 2.0} = agrees(:root_clamped, [4.0])
    assert {:ok, 2.0} = agrees(:root_abs, [-4.0, 9.0])
    assert {:ok, 1.0} = agrees(:root_abs, [-4.0, -9.0])
    assert {:ok, +0.0} = agrees(:root_shifted, [0.0])
    non_finite(:root_shifted, [-0.5])
    c = File.read!(String.replace_suffix(K.__defk_lib__(), ".so", ".c"))
    assert c =~ "__builtin_sqrt(defk_max_f64(p_x, 0.0))"
    assert c =~ ~r/defk_sqrt\(ctx, defk_max_f64\(p_x, \(?-1\.0/
  end

  test "rolling mean_std raises its first error: a NaN read before the read past the end" do
    rolling = fn x, w -> Defk.Test.assert_agrees(Rolling.Kernels, :mean_std, [x, w]) end

    for n <- [100, 2 * @strip + 3], p <- positions(n), p < n - 1 do
      # w = -1 reads x[i + 1]: past the end at i = n - 1, after the NaN
      assert {:raise, %ArgumentError{}} = rolling.(with_bad(n, p, :nan), -1)
      assert {:raise, %ArithmeticError{}} = rolling.(with_bad(n, p, 1.0e200), -1)
      assert {:raise, %Enum.OutOfBoundsError{}} = rolling.(with_bad(n, -1, nil), -1)
      assert {:raise, %ArgumentError{}} = rolling.(with_bad(n, p, :inf), 3)
      # w = 0 divides by zero at the first window, after a NaN read at 0
      first = if p == 0, do: ArgumentError, else: ArithmeticError
      assert {:raise, %^first{}} = rolling.(with_bad(n, p, :nan), 0)
    end

    # the window sums check the reads they add, once per strip (seen_later/1)
    c = File.read!(String.replace_suffix(Rolling.Kernels.__defk_lib__(), ".so", ".c"))
    assert c =~ "defk_in_f64_later(ctx, "
    assert c =~ "#define defk_get_f64 DEFK_NF_get_f64"
  end

  test "mixed-error strips run flagged, with no unchecked access to a computed index" do
    c = File.read!(String.replace_suffix(K.__defk_lib__(), ".so", ".c"))
    assert c =~ "#define defk_get_in_f64 DEFK_NF_get_in_f64"
    assert c =~ "#define defk_put_f64 DEFK_NF_put_f64"
    assert c =~ "#define defk_mul_i64 DEFK_NF_mul_i64"

    nonfinite = fn kernel ->
      for {^kernel, _, {:nonfinite, kind, _}} <- K.__defk_report__(), do: kind
    end

    assert nonfinite.({:gather, 3}) == [:flagged]
    assert nonfinite.({:scatter, 3}) == [:flagged]
    assert nonfinite.({:shifted_sum, 2}) == [:checked]

    n = 2 * @strip + 3
    x = with_bad(n, -1, nil, 0.5)
    assert {:ok, _} = agrees(:shifted_sum, [x, mixed_ix(n, [])])
    first_error(:shifted_sum, [with_bad(n, 9, :nan), mixed_ix(n, [{@strip, 2 ** 62}])], :nan)
    first_error(:shifted_sum, [with_bad(n, @strip, :nan), mixed_ix(n, [{9, 2 ** 62}])], :overflow)
  end

  test "flat float loops run flagged, with the accumulator checked once per strip" do
    c = File.read!(String.replace_suffix(K.__defk_lib__(), ".so", ".c"))
    assert c =~ "#define defk_fmul DEFK_NF_fmul"
    assert c =~ ~r/goto defk_rp\d+;/
    assert c =~ ~r/defk_nf \| DEFK_NONFIN\(v_acc_\d+\)/
  end

  # ---------------------------------------------------- agreement properties --

  agreement(K,
    add: [],
    sub: [],
    mul: [],
    fdiv: [],
    sqrt_of: [],
    log_of: [],
    log2_of: [],
    log10_of: [],
    exp_of: [],
    pow_of: [],
    compare: [],
    store: [],
    trunc_nan: [],
    round_nan: [],
    first: [args: fixed_list([one_of([G.array(:f64), G.array_non_finite()])])],
    at: [args: fixed_list([one_of([G.array(:f64), G.array_non_finite()]), G.i64(-2..20)])],
    sum_to: [args: fixed_list([one_of([G.array(:f64), G.array_non_finite()]), G.i64(-2..40)])],
    sum_all: [args: fixed_list([one_of([G.array(:f64), G.array_non_finite()])])],
    copy_sum: [args: fixed_list([one_of([G.array(:f64), G.array_non_finite()])])],
    overflow_then_read: [
      args: fixed_list([one_of([G.array(:f64), G.array_non_finite()]), G.f64()])
    ],
    read_then_overflow: [
      args: fixed_list([one_of([G.array(:f64), G.array_non_finite()]), G.f64()])
    ],
    over_read: [args: fixed_list([one_of([G.array(:f64), G.array_non_finite()]), G.f64()])],
    over_product: [],
    mixed: [],
    safe_div: [],
    scale_unless: [],
    cond_ratio: [],
    scale: [args: fixed_list([one_of([G.array(:f64), G.array_non_finite()]), G.f64()])],
    dot: [
      args:
        fixed_list([
          one_of([G.array(:f64), G.array_non_finite()]),
          one_of([G.array(:f64), G.array_non_finite()])
        ])
    ],
    moments: [args: fixed_list([one_of([G.array(:f64), G.array_non_finite()])])],
    halving: [args: fixed_list([one_of([G.array(:f64), G.array_non_finite()])])],
    filtered_sumsq: [args: fixed_list([one_of([G.array(:f64), G.array_non_finite()])])],
    gather: [
      args:
        fixed_list([
          one_of([G.array(:f64), G.array_non_finite()]),
          G.array(:i64),
          G.i64()
        ])
    ],
    scatter: [
      args:
        fixed_list([
          one_of([G.array(:f64), G.array_non_finite()]),
          G.array(:i64),
          G.i64(-3..3)
        ])
    ],
    spread: [],
    root_clamped: [],
    root_abs: [],
    root_shifted: [],
    shifted_sum: [
      args: fixed_list([one_of([G.array(:f64), G.array_non_finite()]), G.array(:i64)])
    ]
  )
end
