defmodule Defk.Facts do
  # The range-facts lattice (defk-k4x): what the compiler knows a kernel
  # value satisfies, used to drop bounds and overflow checks. Extracted
  # verbatim from Defk.Compiler's range-facts section as the byte-identical
  # step before the ADR-0007 representation migration, which happens inside
  # this module. Pure: no process dictionary, no emission.
  @moduledoc false

  @i64_min -0x8000000000000000
  @i64_max 0x7FFFFFFFFFFFFFFF

  # An i64 value may carry facts that let a[i] skip its bounds check:
  #   lo, hi - constants with lo <= v <= hi (nil = unknown)
  #   lb, ub - %{array_cvar => k}: v >= len(array) + k, v <= len(array) + k;
  #            a multiple or quotient of a length (defk-upc) has the key
  #            {array_cvar, p, q}, p >= 0 and q >= 1 coprime and not both 1:
  #            q * v >= p * len(array) + k, q * v <= p * len(array) + k
  # An array may carry len_lo / len_lb: the same lower bounds for its length.
  # Facts are exact for checked arithmetic (an overflow raises, never wraps).
  # They name array C variables, which are assigned in one place, never change
  # length, and stay in scope only where every fact about them was derived.
  # Every length is below 2^61 (DEFK_ALLOC_MAX_BYTES, and the largest
  # binary), so an ub fact also bounds v by a constant (hi_of/1).

  def lb(v), do: v[:lb] || %{}
  def ub(v), do: v[:ub] || %{}
  def len_lb(a), do: a[:len_lb] || %{}

  @len_max 2 ** 61 - 1

  def scale({_arr, _p, _q} = key), do: key
  def scale(arr), do: {arr, 1, 1}

  # the fact q * v <= p * len(arr) + k (dir :ub) or >= (:lb), with p and q
  # made coprime: dividing by their gcd rounds k down for ub, up for lb
  def norm_fact(arr, p, q, k, dir) do
    g = Integer.gcd(p, q)
    k = if dir == :ub, do: Integer.floor_div(k, g), else: -Integer.floor_div(-k, g)

    case {div(p, g), div(q, g)} do
      {1, 1} -> {arr, k}
      {p, q} -> {{arr, p, q}, k}
    end
  end

  # the constant bounds v's facts give, its lb/ub facts included
  def lo_of(v) do
    Enum.reduce(lb(v), v[:lo], fn {key, k}, lo ->
      {_, _, q} = scale(key)
      either(lo, -Integer.floor_div(-k, q), &max/2)
    end)
  end

  def hi_of(v) do
    Enum.reduce(ub(v), v[:hi], fn {key, k}, hi ->
      {_, p, q} = scale(key)
      either(hi, Integer.floor_div(p * @len_max + k, q), &min/2)
    end)
  end

  # a value within lo..hi needs no i64 overflow check
  def in_i64?(lo, hi),
    do: is_integer(lo) and is_integer(hi) and lo >= @i64_min and hi <= @i64_max

  # 0 <= i < len(a); with a width w (a word load), 0 <= i and i + w <= len(a)
  def in_bounds?(a, i, w \\ 1) do
    lo = lo_of(i)
    i = if w == 1, do: i, else: %{lo: i[:lo], hi: add(i[:hi], w - 1), ub: shift(ub(i), w - 1)}
    hi = hi_of(i)

    below? =
      (is_integer(a[:len_lo]) and is_integer(hi) and hi < a[:len_lo]) or
        Enum.any?(ub(i), &below_len?(&1, a.c, len_lb(a)))

    is_integer(lo) and lo >= 0 and below?
  end

  # q * i <= p * len(y) + o proves i < len(a): y is a with p <= q and o < 0,
  # or len(a) has a lower bound q1 * len(a) >= p1 * len(y) + d with
  # p / q <= p1 / q1 and o / q < d / q1
  def below_len?({key, o}, arr, len_lb) do
    {y, p, q} = scale(key)

    (y == arr and p <= q and o < 0) or
      Enum.any?(len_lb, fn {key1, d} ->
        {y1, p1, q1} = scale(key1)
        y1 == y and p * q1 <= p1 * q and o * q1 < d * q
      end)
  end

  def add_facts(a, b) do
    %{
      lo: add(a[:lo], b[:lo]),
      hi: add(a[:hi], b[:hi]),
      lb: Map.merge(shift(lb(a), b[:lo]), shift(lb(b), a[:lo]), fn _, x, y -> max(x, y) end),
      ub: Map.merge(shift(ub(a), b[:hi]), shift(ub(b), a[:hi]), fn _, x, y -> min(x, y) end)
    }
  end

  def sub_facts(a, b) do
    %{
      lo: add(a[:lo], neg(b[:hi])),
      hi: add(a[:hi], neg(b[:lo])),
      lb: shift(lb(a), neg(b[:hi])),
      ub: shift(ub(a), neg(b[:lo]))
    }
  end

  # a product: lo..hi from the operands' (nil when one is unbounded), and
  # for a constant k >= 1 times v, v's facts scaled by k
  def mul_facts(a, b) do
    case {a, b} do
      {%{lo: k, hi: k}, v} when is_integer(k) and k > 0 ->
        scaled(v, k)

      {v, %{lo: k, hi: k}} when is_integer(k) and k > 0 ->
        scaled(v, k)

      _ ->
        Map.new(
          Enum.zip([:lo, :hi], Tuple.to_list(mul_bounds({a[:lo], a[:hi]}, {b[:lo], b[:hi]})))
        )
    end
  end

  def scaled(v, k) do
    %{
      lo: v[:lo] && v[:lo] * k,
      hi: v[:hi] && v[:hi] * k,
      lb: scale_facts(lb(v), k, :lb),
      ub: scale_facts(ub(v), k, :ub)
    }
  end

  # every value of a * b, with the bounds lb/ub facts give (lo_of, hi_of)
  def mul_range(a, b), do: mul_bounds({lo_of(a), hi_of(a)}, {lo_of(b), hi_of(b)})

  def mul_bounds({a1, a2}, {b1, b2})
      when is_integer(a1) and is_integer(a2) and is_integer(b1) and is_integer(b2) do
    ps = [a1 * b1, a1 * b2, a2 * b1, a2 * b2]
    {Enum.min(ps), Enum.max(ps)}
  end

  def mul_bounds(_a, _b), do: {nil, nil}

  # div(v, k) for a literal k >= 1: div is monotonic, and v's facts divided
  # (ub only for v >= 0, where div rounds down rather than towards zero)
  def div_facts_of(v, k) do
    ub = if is_integer(lo_of(v)) and lo_of(v) >= 0, do: div_facts(ub(v), k, :ub), else: %{}

    %{
      lo: v[:lo] && div(v[:lo], k),
      hi: v[:hi] && div(v[:hi], k),
      lb: div_facts(lb(v), k, :lb),
      ub: ub
    }
  end

  def minmax_facts(:min, a, b) do
    %{
      lo: both(a[:lo], b[:lo], &min/2),
      hi: either(a[:hi], b[:hi], &min/2),
      lb: Map.intersect(lb(a), lb(b), fn _, x, y -> min(x, y) end),
      ub: Map.merge(ub(a), ub(b), fn _, x, y -> min(x, y) end)
    }
  end

  def minmax_facts(:max, a, b) do
    %{
      lo: either(a[:lo], b[:lo], &max/2),
      hi: both(a[:hi], b[:hi], &max/2),
      lb: Map.merge(lb(a), lb(b), fn _, x, y -> max(x, y) end),
      ub: Map.intersect(ub(a), ub(b), fn _, x, y -> max(x, y) end)
    }
  end

  # band with a non-negative operand is in 0..that operand's hi; bor/bxor of
  # two non-negative values stay below the next power of two above both
  def bit_facts(:band, a, b) do
    case Enum.filter([a, b], &nonneg?/1) do
      [] ->
        %{}

      nn ->
        %{
          lo: 0,
          hi: nn |> Enum.map(& &1[:hi]) |> Enum.filter(&is_integer/1) |> Enum.min(fn -> nil end)
        }
    end
  end

  def bit_facts(_bor_or_bxor, a, b) do
    cond do
      not (nonneg?(a) and nonneg?(b)) -> %{}
      is_integer(a[:hi]) and is_integer(b[:hi]) -> %{lo: 0, hi: ones(max(a[:hi], b[:hi]))}
      true -> %{lo: 0}
    end
  end

  # a non-negative value shifted right by a non-negative amount shrinks
  def bsr_facts(a, n) do
    if nonneg?(a) and nonneg?(n) do
      lo = if is_integer(n[:hi]), do: Bitwise.bsr(a[:lo], n[:hi]), else: 0
      %{lo: lo, hi: Bitwise.bsr(a[:hi] || 0x7FFFFFFFFFFFFFFF, n[:lo])}
    else
      %{}
    end
  end

  def nonneg?(v), do: is_integer(v[:lo]) and v[:lo] >= 0

  # 2^k - 1 for the bit length k of h >= 0: every value of at most k bits
  def ones(h), do: Bitwise.bsl(1, length(Integer.digits(h, 2))) - 1

  def bnot(x) when is_integer(x), do: -x - 1
  def bnot(_), do: nil

  def add(x, y), do: both(x, y, &+/2)

  def neg(x) when is_integer(x), do: -x
  def neg(_), do: nil

  # the facts of v + k from those of v
  def shift(_facts, nil), do: %{}

  def shift(facts, k) do
    Map.new(facts, fn {key, o} ->
      {_, _, q} = scale(key)
      {key, o + q * k}
    end)
  end

  # the facts of v * k, k >= 1, or div(v, k), k >= 1 (the ub facts only for
  # v >= 0, where div rounds down): q * div(v, k) * k <= q * v, and
  # q * div(v, k) * k >= q * (v - k + 1)
  def scale_facts(facts, k, dir) do
    Map.new(facts, fn {key, o} ->
      {arr, p, q} = scale(key)
      norm_fact(arr, k * p, q, k * o, dir)
    end)
  end

  def div_facts(facts, k, dir) do
    Map.new(facts, fn {key, o} ->
      {arr, p, q} = scale(key)
      norm_fact(arr, p, k * q, if(dir == :ub, do: o, else: o - q * (k - 1)), dir)
    end)
  end

  # combine optional bounds: `both` needs both known, `either` is valid with one
  def both(x, y, f) when is_integer(x) and is_integer(y), do: f.(x, y)
  def both(_, _, _), do: nil

  def either(nil, y, _), do: y
  def either(x, nil, _), do: x
  def either(x, y, f), do: f.(x, y)
end
