# Multi-clause kernels (defk-u9c): one bodiless typed head, then clauses
# whose parameters are integer or bool literals, variables or `_`, each with
# an optional guard, as Elixir writes a multi-clause function. They compile to
# one `case` over the parameters; no clause matching raises
# FunctionClauseError, as Elixir does.

defmodule Defk.MultiClauseTest.K do
  use Defk

  # Gorilla's delta-of-delta bits as the anchor writes them, one clause per
  # bucket, masked at the range ends as the cond version in
  # test/bitstring_helper_test.exs is (dod_bits_cond, below)
  defk(dod_bits(acc :: bitstring, dod :: i64) :: bitstring)
  defk(dod_bits(acc, 0), do: <<acc::bitstring, 0::1>>)

  defk(dod_bits(acc, dod) when dod >= -63 and dod <= 64,
    do: <<acc::bitstring, 0b10::2, band(dod, 0x7F)::7>>
  )

  defk(dod_bits(acc, dod) when dod >= -255 and dod <= 255,
    do: <<acc::bitstring, 0b110::3, dod::9-signed>>
  )

  defk(dod_bits(acc, dod) when dod == 256, do: <<acc::bitstring, 0b110::3, band(dod, 0x1FF)::9>>)

  defk(dod_bits(acc, dod) when dod >= -2047 and dod <= 2047,
    do: <<acc::bitstring, 0b1110::4, dod::12-signed>>
  )

  defk(dod_bits(acc, dod) when dod == 2048,
    do: <<acc::bitstring, 0b1110::4, band(dod, 0xFFF)::12>>
  )

  defk(dod_bits(acc, dod), do: <<acc::bitstring, 0b1111::4, band(dod, 0xFFFFFFFF)::32>>)

  defk dod_bits_cond(acc :: bitstring, dod :: i64) :: bitstring do
    cond do
      dod == 0 -> <<acc::bitstring, 0::1>>
      dod >= -63 and dod <= 64 -> <<acc::bitstring, 0b10::2, band(dod, 0x7F)::7>>
      dod >= -255 and dod <= 255 -> <<acc::bitstring, 0b110::3, dod::9-signed>>
      dod == 256 -> <<acc::bitstring, 0b110::3, band(dod, 0x1FF)::9>>
      dod >= -2047 and dod <= 2047 -> <<acc::bitstring, 0b1110::4, dod::12-signed>>
      dod == 2048 -> <<acc::bitstring, 0b1110::4, band(dod, 0xFFF)::12>>
      true -> <<acc::bitstring, 0b1111::4, band(dod, 0xFFFFFFFF)::32>>
    end
  end

  defk(one_dod(dod :: i64) :: bitstring, do: dod_bits(<<>>, dod))
  defk(one_dod_cond(dod :: i64) :: bitstring, do: dod_bits_cond(<<>>, dod))

  defk timestamps(ts :: [i64]) :: bitstring do
    n = length(ts)

    if n == 0 do
      <<>>
    else
      t0 = ts[0]
      acc = <<>>
      acc = <<acc::bitstring, band(bsr(t0, 32), 0xFFFFFFFF)::32, band(t0, 0xFFFFFFFF)::32>>

      {acc, _, _} =
        for i <- 1..(n - 1)//1, reduce: {acc, 0, t0} do
          {acc, prev_delta, prev} ->
            delta = ts[i] - prev
            {dod_bits(acc, delta - prev_delta), delta, ts[i]}
        end

      acc
    end
  end

  # an entry kernel over two parameters, without a catch-all
  defk(pick(x :: i64, y :: i64) :: i64)
  defk(pick(0, y), do: y)
  defk(pick(x, 0) when x > 0, do: x * 10)
  defk(pick(x, y) when x in [1, 2, 3] and y in -5..-1, do: x - y)
  defk(pick(_x, 7), do: -7)

  # clauses that differ only by guard, and a guard error failing its clause
  defk(classify(x :: i64, y :: i64) :: i64)
  defk(classify(x, y) when div(x, y) > 2, do: 1)
  defk(classify(x, y) when rem(x, y) == 1 or x < 0, do: 2)
  defk(classify(x, _) when x > 1000, do: 3)

  # bool literals, exhaustive, so no clause error is possible
  defk(choose(c :: bool, a :: f64, b :: f64) :: f64)
  defk(choose(true, a, _), do: a)
  defk(choose(false, _, b), do: b * 2.0)

  # an f64 parameter only matched by guards, and `_name` patterns
  defk(magnitude(x :: f64, _scale :: i64) :: f64)
  defk(magnitude(x, _scale) when x < 0.0, do: -x)
  defk(magnitude(x, _), do: x)

  # clause variables named like the head's other parameters, and a body that
  # binds a head parameter's name as a fresh local
  defk(swap(a :: i64, b :: i64) :: i64)
  defk(swap(b, a) when b > a, do: b - a)

  defk swap(x, 0) do
    b = x * 2
    b + 1
  end

  defk(swap(a, b), do: a * 100 + b)

  # literal dispatch: the case becomes a switch or an if-chain
  defk(digit(d :: i64) :: i64)
  defk(digit(0), do: 10)
  defk(digit(1), do: 20)
  defk(digit(2), do: 30)
  defk(digit(-1), do: 40)

  # a tuple from the clauses, and a loop in one of them
  defk(stats(n :: i64, k :: i64) :: {i64, i64})
  defk(stats(0, _), do: {0, 0})

  defk stats(n, k) when n > 0 do
    s =
      for i <- 1..n//1, reduce: 0 do
        acc -> acc + i * k
      end

    {n, s}
  end

  # a multi-clause helper with no catch-all, inlined into a loop
  defk(step(x :: i64) :: i64)
  defk(step(x) when x >= 0 and x < 100, do: x + 1)
  defk(step(x) when x < 0, do: x - 1)

  defk steps(xs :: [i64]) :: i64 do
    for x <- xs, reduce: 0 do
      acc -> acc + step(x)
    end
  end

  # a bitstring helper with no catch-all
  defk(flag(acc :: bitstring, b :: i64) :: bitstring)
  defk(flag(acc, 0), do: <<acc::bitstring, 0::1>>)
  defk(flag(acc, 1), do: <<acc::bitstring, 1::1>>)

  defk flags(bs :: [i64]) :: bitstring do
    for b <- bs, reduce: <<>> do
      acc -> flag(acc, b)
    end
  end

  # a multi-clause kernel with yield: false on its head
  defk(tiny(x :: i64) :: i64, yield: false)
  defk(tiny(0), do: 1)
  defk(tiny(x), do: x)
end

defmodule Defk.MultiClauseTest.Ref do
  # The kernels' meaning in plain Elixir: the same clauses as defs, for the
  # results and the FunctionClauseError fields

  def pick(0, y), do: y
  def pick(x, 0) when x > 0, do: x * 10
  def pick(x, y) when x in [1, 2, 3] and y in -5..-1, do: x - y
  def pick(_x, 7), do: -7

  def classify(x, y) when div(x, y) > 2, do: 1
  def classify(x, y) when rem(x, y) == 1 or x < 0, do: 2
  def classify(x, _) when x > 1000, do: 3

  def swap(b, a) when b > a, do: b - a

  def swap(x, 0) do
    b = x * 2
    b + 1
  end

  def swap(a, b), do: a * 100 + b

  def digit(0), do: 10
  def digit(1), do: 20
  def digit(2), do: 30
  def digit(-1), do: 40

  def step(x) when x >= 0 and x < 100, do: x + 1
  def step(x) when x < 0, do: x - 1

  def dod(acc, 0), do: <<acc::bitstring, 0::1>>
  def dod(acc, d) when d >= -63 and d <= 64, do: <<acc::bitstring, 0b10::2, d::7-signed>>
  def dod(acc, d) when d >= -255 and d <= 256, do: <<acc::bitstring, 0b110::3, d::9-signed>>
  def dod(acc, d) when d >= -2047 and d <= 2048, do: <<acc::bitstring, 0b1110::4, d::12-signed>>
  def dod(acc, d), do: <<acc::bitstring, 0b1111::4, d::32>>

  def timestamps([]), do: <<>>

  def timestamps([t0 | rest]) do
    {acc, _, _} =
      Enum.reduce(rest, {<<t0::64>>, 0, t0}, fn t, {acc, prev_delta, prev} ->
        delta = t - prev
        {dod(acc, delta - prev_delta), delta, t}
      end)

    acc
  end
end

defmodule Defk.MultiClauseTest do
  use Defk.Case, async: false
  import Defk.Test.Frames
  # kernel_c/2 here is an entry kernel's C function, not the kit's section
  import Defk.TestKit, except: [kernel_c: 2]
  use Defk.Properties

  alias Defk.MultiClauseTest.{K, Ref}

  defp agrees(fun, args), do: Defk.Test.assert_agrees(K, fun, args)

  # the exception of `f.()`, or flunk
  defp raised(f) do
    f.()
    flunk("did not raise")
  rescue
    e -> e
  end

  # {:ok, value} | {:raise, exception} of `f.()`, a FunctionClauseError as
  # K would raise it (plain Elixir names Ref)
  defp outcome(f) do
    {:ok, f.()}
  rescue
    e in FunctionClauseError -> {:raise, %{e | module: K}}
    e -> {:raise, e}
  end

  # what plain Elixir raises for the same clauses, as K would raise it
  defp ref_raise(fun, args), do: %{raised(fn -> apply(Ref, fun, args) end) | module: K}

  @dods [0, 1, -1, 63, -63, 64, -64, 65, 255, -255, 256, -256, 257, 2047, -2047, 2048, -2048] ++
          [2049, 2 ** 31, -(2 ** 31), 2 ** 40, -(2 ** 40)]

  describe "Gorilla's dod_bits as a multi-clause helper" do
    test "each bucket gives the anchor's bits and the cond version's, in both modes" do
      in_both_modes do
        for d <- @dods do
          assert K.one_dod(d) == Ref.dod(<<>>, d), "dod #{d}"
          assert K.one_dod(d) == K.one_dod_cond(d), "dod #{d}"
        end
      end

      for d <- @dods, do: assert({:ok, _} = agrees(:one_dod, [d]))
    end

    test "a timestamp series through the helper from a reduce loop" do
      jitter = Enum.scan(1..300, 1_700_000_000, fn i, t -> t + 60 + rem(i * 7919, 41) - 20 end)
      gaps = [0, 10, 20, 20, 3_000, 3_010, 100_000, 100_000, 5, -2]

      for ts <- [[], [42], [1, 2], jitter, gaps] do
        expect = Ref.timestamps(ts)

        in_both_modes do
          assert K.timestamps(i64s(ts)) == expect
        end

        assert {:ok, ^expect} = agrees(:timestamps, [i64s(ts)])
      end
    end

    property "the multi-clause and cond helpers agree on any dod" do
      check all(d <- G.i64()) do
        expect = K.one_dod_cond(d)
        assert {:ok, ^expect} = agrees(:one_dod, [d])
      end
    end

    test "costs nothing over the cond: the same tests in the same order" do
      src = K.__defk_c_source__()
      multi = kernel_c(src, "one_dod")
      cond = kernel_c(src, "one_dod_cond")
      assert normalise(multi) == normalise(cond)
    end
  end

  # the body of an entry kernel's C function
  defp kernel_c(src, name) do
    [_, rest] = String.split(src, ~r/ int run_k\d+_#{name}\(/, parts: 2)
    [body | _] = String.split(rest, "\n#undef DEFK_SP", parts: 2)
    body
  end

  # the C without local names, and without the declarations and the plain
  # copies between locals, which the C compiler folds (a case binds its
  # subject to a local of its own, where the cond tests the parameter)
  defp normalise(c) do
    c
    |> String.replace(~r/\b(?:v|p|frame)_\w+/, "v")
    |> String.split("\n", trim: true)
    |> Enum.reject(&(&1 =~ ~r/^(v = v;|\w+ v = \{0\};)$/))
  end

  describe "entry kernels" do
    test "two parameters, literals and guards, as plain Elixir gives" do
      args = [[0, 5], [3, 0], [2, -3], [9, 7], [0, 0], [-4, 7], [3, -5], [4, -3], [-1, 0]]

      for [x, y] <- args do
        expect = outcome(fn -> Ref.pick(x, y) end)

        in_both_modes do
          assert outcome(fn -> K.pick(x, y) end) == expect, "pick(#{x}, #{y})"
        end

        assert agrees(:pick, [x, y]) == expect
      end
    end

    test "no clause matching raises Elixir's FunctionClauseError, field for field" do
      expect = ref_raise(:pick, [4, -3])
      assert %FunctionClauseError{module: K, function: :pick, arity: 2} = expect

      in_both_modes do
        assert raised(fn -> K.pick(4, -3) end) == expect
        assert raised(fn -> K.digit(5) end) == ref_raise(:digit, [5])
      end

      assert Exception.message(expect) == "no function clause matching in #{inspect(K)}.pick/2"
    end

    test "clauses that differ by guard, and a guard error failing its clause" do
      for {x, y} <- [{9, 2}, {9, 0}, {7, 3}, {-7, 0}, {5000, 0}, {5, 0}, {2000, 7}] do
        expect = outcome(fn -> Ref.classify(x, y) end)

        in_both_modes do
          assert outcome(fn -> K.classify(x, y) end) == expect, "classify(#{x}, #{y})"
        end
      end
    end

    test "bool literals, f64 guards, `_name` patterns and a tuple result" do
      in_both_modes do
        assert K.choose(true, 1.5, 2.0) === 1.5
        assert K.choose(false, 1.5, 2.0) === 4.0
        assert K.magnitude(-2.5, 3) === 2.5
        assert K.magnitude(2.5, 3) === 2.5
        assert K.stats(0, 9) == {0, 0}
        assert K.stats(4, 2) == {4, 20}

        assert raised(fn -> K.stats(-1, 2) end) ==
                 %FunctionClauseError{module: K, function: :stats, arity: 2}

        assert K.tiny(0) == 1
        assert K.tiny(5) == 5
      end
    end

    test "clause variables named like other head parameters" do
      for {a, b} <- [{5, 2}, {2, 5}, {3, 0}, {-3, 0}, {4, 4}] do
        expect = Ref.swap(a, b)

        in_both_modes do
          assert K.swap(a, b) == expect, "swap(#{a}, #{b})"
        end
      end
    end

    test "literal dispatch is one chain of tests on the parameter, without copies" do
      for d <- [0, 1, 2, -1] do
        in_both_modes do
          assert K.digit(d) == Ref.digit(d)
        end
      end

      # an if-chain testing each literal once, each arm one assignment, and
      # the clause error at its end (clang makes a switch where that pays)
      c = normalise(kernel_c(K.__defk_c_source__(), "digit"))
      tests = Enum.filter(c, &(&1 =~ "if ("))

      assert tests == for(l <- ["0", "1", "2", "-1"], do: "if ((v == INT64_C(#{l}))) {"),
             inspect(c)

      assert Enum.count(c, &(&1 =~ ~r/^v = INT64_C\(\d0\);$/)) == 4, inspect(c)
      assert Enum.count(c, &(&1 =~ "defk_no_fun_clause(")) == 1, inspect(c)
    end
  end

  describe "helper kernels" do
    test "a helper's FunctionClauseError names the helper, as a defp's does" do
      in_both_modes do
        assert K.steps(i64s([1, -1, 50])) == 2 + -2 + 51

        assert raised(fn -> K.steps(i64s([1, 100])) end) ==
                 %FunctionClauseError{module: K, function: :step, arity: 1}
      end

      assert ref_raise(:step, [100]) == %FunctionClauseError{module: K, function: :step, arity: 1}
    end
  end

  describe "the runtime contract" do
    test "no clause matching after yields raises, and the bits built so far are freed" do
      bits = for i <- 1..50_000, do: rem(i * 7, 3) |> min(1)
      expect = for b <- bits, into: <<>>, do: <<b::1>>

      forced(K, fn ->
        y0 = K.__defk_stats__().yields
        assert K.flags(i64s(bits)) == expect
        assert K.__defk_stats__().yields > y0 + 10, "the kernel never yielded"

        y1 = K.__defk_stats__().yields

        assert raised(fn -> K.flags(i64s(bits ++ [2])) end) ==
                 %FunctionClauseError{module: K, function: :flag, arity: 2}

        assert K.__defk_stats__().yields > y1 + 10, "the kernel never yielded"
      end)

      assert agrees(:flags, [i64s([1, 0, 1])]) == {:ok, <<1::1, 0::1, 1::1>>}

      assert {:raise, %FunctionClauseError{function: :flag}} =
               agrees(:flags, [i64s([1, 0, 1, -1])])

      :erlang.garbage_collect()
      assert_frames_live(K)
    end
  end

  describe "Elixir mode" do
    test "unused and `_name` clause variables give no warnings" do
      src = """
      defmodule Defk.MultiClauseTest.Warn do
        use Defk, elixir_mode: true

        defk f(x :: i64, y :: i64) :: i64
        defk f(_x, 0), do: 0
        defk f(x, _y) when x > 0, do: 1
        defk f(_, y), do: y
      end
      """

      out = ExUnit.CaptureIO.capture_io(:stderr, fn -> Code.compile_string(src) end)
      assert out == "", out
      warn = Module.concat(Defk.MultiClauseTest, Warn)
      assert warn.__defk_elixir__(:f, [5, 0]) == 0
      assert warn.__defk_elixir__(:f, [5, 1]) == 1
      assert warn.__defk_elixir__(:f, [-5, 3]) == 3
    end
  end

  describe "compile errors" do
    test "clauses without a head" do
      msg = reject(__MODULE__, "defk f(0), do: 1\ndefk f(x), do: x")
      assert codes(msg) == ["clause-head"], msg
      assert msg =~ "f/1 has clauses but no head", msg
      assert msg =~ "defk f(x :: i64) :: i64", msg

      msg = reject(__MODULE__, "defk f(0), do: 1\ndefk f(x :: i64) :: i64\ndefk f(x), do: x")
      assert codes(msg) == ["clause-head"], msg
      assert msg =~ "comes before the head of f/1", msg
    end

    test "binary and list clause patterns are reported, and the head hint does not guess i64" do
      msg =
        reject(__MODULE__, """
        defk decode(<<>>, 0, 0, acc), do: Enum.reverse(acc)
        defk decode(<<b, rest::binary>>, val, shift, acc), do: decode(rest, val + b, shift + 7, acc)
        """)

      assert "clause-head" in codes(msg), msg
      assert "clause-pattern" in codes(msg), msg
      assert msg =~ "binary pattern", msg
      assert msg =~ "`[u8]`", msg
      assert msg =~ "defk decode(x1 :: [u8], val :: i64, shift :: i64, acc :: i64) :: type", msg
      refute msg =~ "x1 :: i64", msg

      msg = reject(__MODULE__, "defk f([a | t]), do: a\ndefk f([]), do: 0")
      assert "clause-pattern" in codes(msg), msg
      assert msg =~ "list pattern", msg
      assert msg =~ "defk f(x1 :: type) :: type", msg
    end

    test "types in a clause" do
      msg = reject(__MODULE__, "defk f(x :: i64) :: i64\ndefk f(x :: i64) :: i64, do: x")
      assert codes(msg) == ["clause-types"], msg
      assert msg =~ "types go on the head", msg

      msg = reject(__MODULE__, "defk f(x :: i64, y :: i64) :: i64\ndefk f(0, y :: i64), do: y")
      assert codes(msg) == ["clause-types"], msg

      msg = reject(__MODULE__, "defk f(x :: i64) :: i64\ndefk f(x) :: i64, do: x")
      assert codes(msg) == ["clause-types"], msg
    end

    test "options on a clause, a head without clauses, two heads" do
      msg = reject(__MODULE__, "defk f(x :: i64) :: i64\ndefk f(x), yield: false, do: x")
      assert codes(msg) == ["unknown-option"], msg
      assert msg =~ "options go on the head", msg

      msg = reject(__MODULE__, "defk f(x :: i64) :: i64")
      assert codes(msg) == ["no-body"], msg
      assert msg =~ "f/1 has a head but no clauses", msg

      msg =
        reject(__MODULE__, "defk f(x :: i64) :: i64\ndefk f(x :: i64) :: i64\ndefk f(x), do: x")

      assert codes(msg) == ["duplicate-kernel"], msg
    end

    test "patterns a clause cannot have" do
      head = "defk f(x :: i64, y :: f64) :: i64\n"

      for {clause, what} <- [
            {"defk f(^x, _), do: 1", "^x"},
            {"defk f(_, 1.0), do: 1", "1.0"},
            {"defk f({a, b}, _), do: a", "{a, b}"},
            {"defk f(x, x), do: x", "x appears twice"},
            {"defk f(true, _), do: 1", "never matches"},
            {"defk f(_, 1), do: 1", "never matches"}
          ] do
        msg = reject(__MODULE__, head <> clause)
        assert codes(msg) == ["clause-pattern"], msg
        assert msg =~ what, msg
      end
    end

    test "a head parameter's name is not bound in a clause that names it otherwise" do
      msg = reject(__MODULE__, "defk f(x :: i64, y :: i64) :: i64\ndefk f(a, _), do: a + y")
      assert codes(msg) == ["undefined-variable"], msg
      assert msg =~ "undefined variable y", msg
    end

    test "a single kernel without a return type is still kernel-head" do
      msg = reject(__MODULE__, "defk f(x :: i64), do: x")
      assert codes(msg) == ["kernel-head"], msg
    end
  end

  agreement(K,
    one_dod: [],
    one_dod_cond: [],
    timestamps: [args: StreamData.fixed_list([G.array(:i64, of: G.i64(-(2 ** 40)..(2 ** 40)))])],
    pick: [args: StreamData.fixed_list([G.i64(-3..10), G.i64(-8..8)])],
    classify: [args: StreamData.fixed_list([G.i64(-20..2000), G.i64(-3..3)])],
    choose: [],
    magnitude: [],
    swap: [args: StreamData.fixed_list([G.i64(-50..50), G.i64(-3..3)])],
    digit: [args: StreamData.fixed_list([G.i64(-3..4)])],
    stats: [args: StreamData.fixed_list([G.i64(-2..40), G.i64(-1000..1000)])],
    step: [args: StreamData.fixed_list([G.i64(-200..120)])],
    steps: [args: StreamData.fixed_list([G.array(:i64, of: G.i64(-200..120))])],
    flags: [args: StreamData.fixed_list([G.array(:i64, of: G.i64(0..1, [2]))])],
    tiny: []
  )
end
