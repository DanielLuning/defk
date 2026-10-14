defmodule Defk.GuardIn do
  @moduledoc false
  # `in` in a case guard, shared by the kernel compiler and Elixir
  # mode so both lower it to the same comparisons: `x in [1, 2]` to
  # `x === 1 or x === 2`, and `x in first..last//step` to bounds plus a
  # remainder test, exactly the integers Enum.member?/2 finds in the range.
  #
  # The right side is a literal list of integers (or of booleans), or a
  # range. A range's bounds may be variables or any guard-safe integer
  # expressions with an explicit step of 1 or -1 (Elixir rejects `a..b` with
  # variable bounds in a guard, as the direction is only known at runtime).
  # Any other step needs literal bounds, and so does a range without a step;
  # a literal `a..b` counts down when a > b, as in Elixir. The
  # last element that is reached is computed here, so no runtime arithmetic
  # can overflow. A step is nonzero and within +-(2^63 - 1).

  @min -0x8000000000000000
  @max 0x7FFFFFFFFFFFFFFF
  @i64 @min..@max

  @doc """
  Checks the shape of the `{:in, meta, [lhs, rhs]}` node: `:ok`, or
  `{:error, node, message, opts}`. The caller checks the types of `lhs` and of
  the non-literal range bounds, which are returned by `operands/1`.
  """
  def check({:in, _, [_lhs, rhs]} = node) do
    case classify(rhs) do
      {:list, _} ->
        :ok

      {:range, first, last, step} ->
        check_range(node, rhs, first, last, step)

      :other ->
        {:error, node,
         "#{Macro.to_string(node)} in a case guard needs a literal list of integers or booleans, or a range",
         [hint: "write the list out, or compare with each value"] ++ rewrite_hint(node)}
    end
  end

  @doc "The expressions `in` evaluates: the left side, then any non-literal range bound."
  def operands({:in, _, [lhs, rhs]}) do
    case classify(rhs) do
      {:range, first, last, _} -> [lhs | Enum.reject([first, last], &is_integer(literal(&1)))]
      _ -> [lhs]
    end
  end

  @doc "The kind of the right side: `:bool_list`, `:int_list` (an empty list is one), or `:range`."
  def kind({:in, _, [_, rhs]}) do
    case classify(rhs) do
      {:list, [b | _]} when is_boolean(b) -> :bool_list
      {:list, _} -> :int_list
      {:range, _, _, _} -> :range
    end
  end

  @doc "Replaces every `in` in a guard by comparisons."
  def lower(guard) do
    Macro.prewalk(guard, fn
      {:in, m, [lhs, rhs]} -> lower_in(m, lhs, classify(rhs))
      other -> other
    end)
  end

  # -- shapes

  defp classify(list) when is_list(list) do
    elems = Enum.map(list, &literal/1)

    cond do
      elems == [] -> {:list, []}
      Enum.all?(elems, &is_integer/1) and Enum.all?(elems, &(&1 in @i64)) -> {:list, elems}
      Enum.all?(elems, &is_boolean/1) -> {:list, elems}
      true -> :other
    end
  end

  defp classify({:.., _, [first, last]}), do: {:range, first, last, nil}
  defp classify({:..//, _, [first, last, step]}), do: {:range, first, last, step}
  defp classify(_), do: :other

  # the value of an integer or boolean literal (-n included), else :none
  defp literal(n) when is_integer(n) or is_boolean(n), do: n
  defp literal({:-, _, [n]}) when is_integer(n), do: -n
  defp literal(_), do: :none

  defp check_range(node, range, first, last, step) do
    lits = Enum.map([first, last, step], &literal/1)
    ints = Enum.filter(lits, &is_integer/1)
    s = literal(step)

    cond do
      Enum.any?(ints, &(&1 not in @i64)) ->
        {:error, node,
         "the range #{Macro.to_string(range)} in a case guard needs literals within the i64 range",
         []}

      s == 0 ->
        {:error, node, "the step of #{Macro.to_string(range)} must not be zero", []}

      is_integer(s) and abs(s) > @max ->
        {:error, node,
         "a step must be within -9223372036854775807..9223372036854775807, as in #{Macro.to_string(range)}",
         []}

      step == nil and not Enum.all?(Enum.take(lits, 2), &is_integer/1) ->
        {:error, node,
         "the range #{Macro.to_string(range)} in a case guard needs literal first and last, or an explicit step of 1 or -1",
         hint:
           "write #{Macro.to_string({:..//, [], [first, last, 1]})}, as Elixir also requires in a guard"}

      step != nil and s not in [1, -1] and not Enum.all?(lits, &is_integer/1) ->
        {:error, node,
         "the stepped range #{Macro.to_string(range)} in a case guard needs literal first, last and step",
         hint: "give the first, last and step as integer literals, or use a step of 1 or -1"}

      true ->
        :ok
    end
  end

  defp rewrite_hint({:in, _, [x, list]}) when is_list(list) and list != [] do
    list
    |> Enum.map(&{:==, [], [x, &1]})
    |> Enum.reduce(&{:or, [], [&2, &1]})
    |> Macro.to_string()
    |> then(&[rewrite: &1])
  end

  defp rewrite_hint(_), do: []

  # -- lowering

  defp lower_in(_m, _x, {:list, []}), do: false

  defp lower_in(m, x, {:list, elems}) do
    elems
    |> Enum.uniq()
    |> Enum.map(&{:===, m, [x, &1]})
    |> Enum.reduce(&{:or, m, [&2, &1]})
  end

  defp lower_in(m, x, {:range, first, last, step}) do
    s = if step, do: literal(step)
    lits = Enum.map([first, last], &literal/1)

    cond do
      Enum.all?(lits, &is_integer/1) and (step == nil or is_integer(s)) ->
        [a, b] = lits
        literal_range(m, x, a, b, s || if(a <= b, do: 1, else: -1))

      s == 1 ->
        both(m, {:<=, m, [first, x]}, {:<=, m, [x, last]})

      s == -1 ->
        both(m, {:<=, m, [last, x]}, {:<=, m, [x, first]})
    end
  end

  defp both(m, a, b), do: {:and, m, [a, b]}

  # the elements a, a + s, ... up to b: empty, one, or [lo, hi] with every
  # |s|-th integer between them
  defp literal_range(_m, _x, a, b, s) when (s > 0 and a > b) or (s < 0 and a < b), do: false

  defp literal_range(m, x, a, b, s) do
    k = abs(s)
    far = a + div(b - a, s) * s
    {lo, hi} = if s > 0, do: {a, far}, else: {far, a}
    rem_x = {:rem, m, [x, k]}
    r = Integer.mod(lo, k)

    tests =
      [
        lo > @min && {:>=, m, [x, lo]},
        hi < @max && {:<=, m, [x, hi]},
        k > 1 && residue(m, rem_x, r, k)
      ]

    case Enum.filter(tests, & &1) do
      _ when lo == hi -> {:===, m, [x, lo]}
      [] -> true
      tests -> Enum.reduce(tests, &both(m, &2, &1))
    end
  end

  # rem keeps the dividend's sign: x is r (mod k) when rem(x, k) is r or r - k
  defp residue(_m, rem_x, 0, _k), do: {:==, [], [rem_x, 0]}

  defp residue(m, rem_x, r, k),
    do: {:or, m, [{:==, m, [rem_x, r]}, {:==, m, [rem_x, r - k]}]}
end
