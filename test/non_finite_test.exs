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
    assert Defk.Test.reason(e) == reason
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

  test "float arms compile to a select" do
    c = File.read!(String.replace_suffix(K.__defk_lib__(), ".so", ".c"))
    assert c =~ "defk_fdiv_s(&"
    assert c =~ "defk_fmul_s(&"
  end

  # ---------------------------------------------------- agreement properties --

  agreement(K,
    add: [],
    sub: [],
    mul: [],
    fdiv: [],
    sqrt_of: [],
    log_of: [],
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
    cond_ratio: []
  )
end
