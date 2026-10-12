defmodule Defk.Facts do
  # The range-facts lattice (defk-k4x): what the compiler knows a kernel
  # value satisfies, used to drop bounds and overflow checks. A value map
  # carries one opaque %Defk.Facts{} under :facts; only this module reads
  # or writes its insides, so the ADR-0007 representation migration happens
  # here alone. Pure: no process dictionary, no emission.
  #
  # An i64 value's facts:
  #   lo, hi - constants with lo <= v <= hi (nil = unknown)
  #   lb, ub - %{array_cvar => k}: v >= len(array) + k, v <= len(array) + k;
  #            a multiple or quotient of a length (defk-upc) has the key
  #            {array_cvar, p, q}, p >= 0 and q >= 1 coprime and not both 1:
  #            q * v >= p * len(array) + k, q * v <= p * len(array) + k
  # An array's facts: len_lo / len_lb, the same lower bounds for its length.
  # Facts are exact for checked arithmetic (an overflow raises, never wraps).
  # They name array C variables, which are assigned in one place, never change
  # length, and stay in scope only where every fact about them was derived.
  # Every length is below 2^61 (DEFK_ALLOC_MAX_BYTES, and the largest
  # binary), so an ub fact also bounds v by a constant (hi_of/1).
  @moduledoc false

  defstruct lo: nil, hi: nil, lb: %{}, ub: %{}, len_lo: nil, len_lb: %{}

  @i64_min -0x8000000000000000
  @i64_max 0x7FFFFFFFFFFFFFFF
  @len_max 2 ** 61 - 1

  # ---------------------------------------------------------- carrier API --
  # A carrier is any value map; its facts live under :facts (absent = none).

  def none, do: %__MODULE__{}

  def facts(carrier), do: carrier[:facts] || %__MODULE__{}

  def put(carrier, %__MODULE__{} = f), do: Map.put(carrier, :facts, f)

  # set the named facts on the carrier, keeping the rest
  def assert(carrier, kw), do: put(carrier, struct!(facts(carrier), kw))

  # ------------------------------------------------------------- queries --
  # lo/hi/len_lo are the raw constant bounds; lo_of/hi_of fold lb/ub facts
  # in, so they may know more. The split is load-bearing: a caller that only
  # accepts a literal constant (narrowed stores, the div-by-k rule) asks for
  # the raw bound.

  def lo(carrier), do: facts(carrier).lo
  def hi(carrier), do: facts(carrier).hi
  def len_lo(carrier), do: facts(carrier).len_lo

  def lb(carrier), do: facts(carrier).lb
  def ub(carrier), do: facts(carrier).ub
  def len_lb(carrier), do: facts(carrier).len_lb

  # the one constant a value is known to be, or nil
  def const(carrier) do
    f = facts(carrier)
    if is_integer(f.lo) and f.lo == f.hi, do: f.lo
  end

  def nonneg?(carrier) do
    f = facts(carrier)
    is_integer(f.lo) and f.lo >= 0
  end

  # the constant bounds a value's facts give, its lb/ub facts included
  def lo_of(carrier), do: lo_of_f(facts(carrier))
  def hi_of(carrier), do: hi_of_f(facts(carrier))

  defp lo_of_f(f) do
    Enum.reduce(f.lb, f.lo, fn {key, k}, lo ->
      {_, _, q} = scale(key)
      either(lo, -Integer.floor_div(-k, q), &max/2)
    end)
  end

  defp hi_of_f(f) do
    Enum.reduce(f.ub, f.hi, fn {key, k}, hi ->
      {_, p, q} = scale(key)
      either(hi, Integer.floor_div(p * @len_max + k, q), &min/2)
    end)
  end

  # ------------------------------------------------------------- proving --

  # a value within lo..hi needs no i64 overflow check
  def in_i64?(lo, hi),
    do: is_integer(lo) and is_integer(hi) and lo >= @i64_min and hi <= @i64_max

  # 0 <= i < len(a); with a width w (a word load), 0 <= i and i + w <= len(a)
  def in_bounds?(a, i, w \\ 1) do
    fa = facts(a)
    fi = facts(i)
    lo = lo_of_f(fi)
    fi = if w == 1, do: fi, else: %{fi | hi: add(fi.hi, w - 1), ub: shift(fi.ub, w - 1)}
    hi = hi_of_f(fi)

    below? =
      (is_integer(fa.len_lo) and is_integer(hi) and hi < fa.len_lo) or
        Enum.any?(fi.ub, &below_len?(&1, a.c, fa.len_lb))

    is_integer(lo) and lo >= 0 and below?
  end

  # q * i <= p * len(y) + o proves i < len(a): y is a with p <= q and o < 0,
  # or len(a) has a lower bound q1 * len(a) >= p1 * len(y) + d with
  # p / q <= p1 / q1 and o / q < d / q1
  defp below_len?({key, o}, arr, len_lb) do
    {y, p, q} = scale(key)

    (y == arr and p <= q and o < 0) or
      Enum.any?(len_lb, fn {key1, d} ->
        {y1, p1, q1} = scale(key1)
        y1 == y and p * q1 <= p1 * q and o * q1 < d * q
      end)
  end

  # ------------------------------------------------- the accumulator carry --
  # A loop body may assume an array accumulator's facts (with_acc_facts in
  # the compiler, which owns the re-lowering protocol; fin is a contents
  # fact and stays on the carrier).

  # the accumulator carries facts a new value may not have
  def carries?(carrier), do: is_integer(len_lo(carrier))

  # a new value `r` keeps every length assumption the body made about `a`
  def covers?(a, r) do
    al = len_lo(a)
    not is_integer(al) or (is_integer(len_lo(r)) and len_lo(r) >= al)
  end

  # drop what the body may no longer assume
  def weaken(carrier), do: assert(carrier, len_lo: nil)

  # --------------------------------------------------------- derivations --

  def add_facts(a, b) do
    {fa, fb} = {facts(a), facts(b)}

    %__MODULE__{
      lo: add(fa.lo, fb.lo),
      hi: add(fa.hi, fb.hi),
      lb: Map.merge(shift(fa.lb, fb.lo), shift(fb.lb, fa.lo), fn _, x, y -> max(x, y) end),
      ub: Map.merge(shift(fa.ub, fb.hi), shift(fb.ub, fa.hi), fn _, x, y -> min(x, y) end)
    }
  end

  def sub_facts(a, b) do
    {fa, fb} = {facts(a), facts(b)}

    %__MODULE__{
      lo: add(fa.lo, neg(fb.hi)),
      hi: add(fa.hi, neg(fb.lo)),
      lb: shift(fa.lb, neg(fb.hi)),
      ub: shift(fa.ub, neg(fb.lo))
    }
  end

  # a product: lo..hi from the operands' (nil when one is unbounded), and
  # for a constant k >= 1 times v, v's facts scaled by k
  def mul_facts(a, b) do
    {fa, fb} = {facts(a), facts(b)}

    cond do
      is_integer(fa.lo) and fa.lo == fa.hi and fa.lo > 0 ->
        scaled(fb, fa.lo)

      is_integer(fb.lo) and fb.lo == fb.hi and fb.lo > 0 ->
        scaled(fa, fb.lo)

      true ->
        {lo, hi} = mul_bounds({fa.lo, fa.hi}, {fb.lo, fb.hi})
        %__MODULE__{lo: lo, hi: hi}
    end
  end

  defp scaled(f, k) do
    %__MODULE__{
      lo: f.lo && f.lo * k,
      hi: f.hi && f.hi * k,
      lb: scale_facts(f.lb, k, :lb),
      ub: scale_facts(f.ub, k, :ub)
    }
  end

  # every value of a * b, with the bounds lb/ub facts give (lo_of, hi_of)
  def mul_range(a, b), do: mul_bounds({lo_of(a), hi_of(a)}, {lo_of(b), hi_of(b)})

  defp mul_bounds({a1, a2}, {b1, b2})
       when is_integer(a1) and is_integer(a2) and is_integer(b1) and is_integer(b2) do
    ps = [a1 * b1, a1 * b2, a2 * b1, a2 * b2]
    {Enum.min(ps), Enum.max(ps)}
  end

  defp mul_bounds(_a, _b), do: {nil, nil}

  # div(v, k) for a literal k >= 1: div is monotonic, and v's facts divided
  # (ub only for v >= 0, where div rounds down rather than towards zero)
  def div_facts_of(v, k) do
    f = facts(v)
    ub = if is_integer(lo_of_f(f)) and lo_of_f(f) >= 0, do: div_facts(f.ub, k, :ub), else: %{}

    %__MODULE__{
      lo: f.lo && div(f.lo, k),
      hi: f.hi && div(f.hi, k),
      lb: div_facts(f.lb, k, :lb),
      ub: ub
    }
  end

  def minmax_facts(:min, a, b) do
    {fa, fb} = {facts(a), facts(b)}

    %__MODULE__{
      lo: both(fa.lo, fb.lo, &min/2),
      hi: either(fa.hi, fb.hi, &min/2),
      lb: Map.intersect(fa.lb, fb.lb, fn _, x, y -> min(x, y) end),
      ub: Map.merge(fa.ub, fb.ub, fn _, x, y -> min(x, y) end)
    }
  end

  def minmax_facts(:max, a, b) do
    {fa, fb} = {facts(a), facts(b)}

    %__MODULE__{
      lo: either(fa.lo, fb.lo, &max/2),
      hi: both(fa.hi, fb.hi, &max/2),
      lb: Map.merge(fa.lb, fb.lb, fn _, x, y -> max(x, y) end),
      ub: Map.intersect(fa.ub, fb.ub, fn _, x, y -> max(x, y) end)
    }
  end

  # band with a non-negative operand is in 0..that operand's hi; bor/bxor of
  # two non-negative values stay below the next power of two above both
  def bit_facts(:band, a, b) do
    case Enum.filter([a, b], &nonneg?/1) do
      [] ->
        %__MODULE__{}

      nn ->
        %__MODULE__{
          lo: 0,
          hi: nn |> Enum.map(&hi/1) |> Enum.filter(&is_integer/1) |> Enum.min(fn -> nil end)
        }
    end
  end

  def bit_facts(_bor_or_bxor, a, b) do
    {ha, hb} = {hi(a), hi(b)}

    cond do
      not (nonneg?(a) and nonneg?(b)) -> %__MODULE__{}
      is_integer(ha) and is_integer(hb) -> %__MODULE__{lo: 0, hi: ones(max(ha, hb))}
      true -> %__MODULE__{lo: 0}
    end
  end

  # a non-negative value shifted right by a non-negative amount shrinks
  def bsr_facts(a, n) do
    if nonneg?(a) and nonneg?(n) do
      {fa, fn_} = {facts(a), facts(n)}
      lo = if is_integer(fn_.hi), do: Bitwise.bsr(fa.lo, fn_.hi), else: 0
      %__MODULE__{lo: lo, hi: Bitwise.bsr(fa.hi || 0x7FFFFFFFFFFFFFFF, fn_.lo)}
    else
      %__MODULE__{}
    end
  end

  # 2^k - 1 for the bit length k of h >= 0: every value of at most k bits
  defp ones(h), do: Bitwise.bsl(1, length(Integer.digits(h, 2))) - 1

  def bnot(x) when is_integer(x), do: -x - 1
  def bnot(_), do: nil

  def add(x, y), do: both(x, y, &+/2)

  def neg(x) when is_integer(x), do: -x
  def neg(_), do: nil

  # ------------------------------------------------------------ plumbing --

  defp scale({_arr, _p, _q} = key), do: key
  defp scale(arr), do: {arr, 1, 1}

  # the fact q * v <= p * len(arr) + k (dir :ub) or >= (:lb), with p and q
  # made coprime: dividing by their gcd rounds k down for ub, up for lb
  defp norm_fact(arr, p, q, k, dir) do
    g = Integer.gcd(p, q)
    k = if dir == :ub, do: Integer.floor_div(k, g), else: -Integer.floor_div(-k, g)

    case {div(p, g), div(q, g)} do
      {1, 1} -> {arr, k}
      {p, q} -> {{arr, p, q}, k}
    end
  end

  # the facts of v + k from those of v
  defp shift(_facts, nil), do: %{}

  defp shift(facts, k) do
    Map.new(facts, fn {key, o} ->
      {_, _, q} = scale(key)
      {key, o + q * k}
    end)
  end

  # the facts of v * k, k >= 1, or div(v, k), k >= 1 (the ub facts only for
  # v >= 0, where div rounds down): q * div(v, k) * k <= q * v, and
  # q * div(v, k) * k >= q * (v - k + 1)
  defp scale_facts(facts, k, dir) do
    Map.new(facts, fn {key, o} ->
      {arr, p, q} = scale(key)
      norm_fact(arr, k * p, q, k * o, dir)
    end)
  end

  defp div_facts(facts, k, dir) do
    Map.new(facts, fn {key, o} ->
      {arr, p, q} = scale(key)
      norm_fact(arr, p, k * q, if(dir == :ub, do: o, else: o - q * (k - 1)), dir)
    end)
  end

  # combine optional bounds: `both` needs both known, `either` is valid with one
  defp both(x, y, f) when is_integer(x) and is_integer(y), do: f.(x, y)
  defp both(_, _, _), do: nil

  defp either(nil, y, _), do: y
  defp either(x, nil, _), do: x
  defp either(x, y, f), do: f.(x, y)
end
