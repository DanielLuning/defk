defmodule Defk.Facts do
  # The range facts (ADR-0007): what the compiler knows a kernel value
  # satisfies, used to drop bounds and overflow checks. A value map carries
  # one opaque %Defk.Facts{} under :facts; only this module reads or writes
  # its insides. Pure: no process dictionary, no emission.
  #
  # Representation:
  #   monomial - an atom of the symbolic bounds. Today: {:len, c}, the length
  #              of the array in C variable c. (Later steps add i64 bindings
  #              and products of two atoms.) Each has a rank, its binding's
  #              order: parameters first, then fresh/2's counter.
  #   form     - a polynomial over monomials with integer coefficients plus a
  #              constant: %{k: integer, t: %{monomial => coefficient}}
  #   bound    - {q, form}: q * v <= form (an upper bound, in ubs) or
  #              q * v >= form (a lower bound, in lbs), q >= 1, the
  #              coefficients and q with no common divisor
  # An i64 value's facts: lo, hi (constants, nil = unknown) and ubs, lbs.
  # An array's facts: len_lo, a constant lower bound on its length, and
  # len_lbs, lower bounds on its length. Every length is in 0..2^61 - 1
  # (DEFK_ALLOC_MAX_BYTES, and the largest binary), so a bound over lengths
  # also bounds a value by a constant (lo_of/1, hi_of/1).
  #
  # Facts are exact for checked arithmetic (an overflow raises, never
  # wraps). They name array C variables, which are assigned in one place,
  # never change length, and stay in scope only where every fact about them
  # was derived.
  #
  # The prover (le?/4) decides `form <= 0` by replacing the newest monomial
  # by one of its bounds until a constant is left, within a step budget; an
  # unproven query keeps the check. The facts of before map onto it one to
  # one (`i <= length(a) + k` is {1, len(a) + k}; a scaled fact
  # `q * i <= p * length(a) + k` is {q, p * len(a) + k}), and the proofs
  # in_bounds?/3 makes are those the per-kind rules made.
  @moduledoc false

  defstruct lo: nil, hi: nil, ubs: [], lbs: [], len_lo: nil, len_lbs: []

  @i64_min -0x8000000000000000
  @i64_max 0x7FFFFFFFFFFFFFFF
  @len_max 2 ** 61 - 1

  # the prover's step budget per query (one step: one monomial replaced);
  # measured on the suite and the examples, see docs/performance.md
  @budget 64

  # ---------------------------------------------------------- carrier API --
  # A carrier is any value map; its facts live under :facts (absent = none).

  def none, do: %__MODULE__{}

  def facts(carrier), do: carrier[:facts] || %__MODULE__{}

  def put(carrier, %__MODULE__{} = f), do: Map.put(carrier, :facts, f)

  # set the constant facts (lo, hi, len_lo) on the carrier, keeping the rest
  def assert(carrier, kw) do
    Enum.each(kw, fn {k, _} ->
      k in [:lo, :hi, :len_lo] ||
        raise ArgumentError, "Facts.assert/2: #{k} is not a constant fact"
    end)

    put(carrier, struct!(facts(carrier), kw))
  end

  # ------------------------------------------------------------- queries --
  # lo/hi/len_lo are the raw constant bounds; lo_of/hi_of fold the relative
  # bounds in, so they may know more. The split is load-bearing: a caller
  # that only accepts a literal constant (narrowed stores, the div-by-k
  # rule) asks for the raw bound.

  def lo(carrier), do: facts(carrier).lo
  def hi(carrier), do: facts(carrier).hi
  def len_lo(carrier), do: facts(carrier).len_lo

  # the relative bounds, for tests and the report
  def ubs(carrier), do: facts(carrier).ubs
  def lbs(carrier), do: facts(carrier).lbs
  def len_lbs(carrier), do: facts(carrier).len_lbs

  # the one constant a value is known to be, or nil
  def const(carrier) do
    f = facts(carrier)
    if is_integer(f.lo) and f.lo == f.hi, do: f.lo
  end

  def nonneg?(carrier) do
    f = facts(carrier)
    is_integer(f.lo) and f.lo >= 0
  end

  # the constant bounds a value's facts give, its relative bounds included
  def lo_of(carrier), do: lo_of_f(facts(carrier))
  def hi_of(carrier), do: hi_of_f(facts(carrier))

  defp lo_of_f(f) do
    Enum.reduce(f.lbs, f.lo, fn {q, p}, lo -> either(lo, ceil_div(form_min(p), q), &max/2) end)
  end

  defp hi_of_f(f) do
    Enum.reduce(f.ubs, f.hi, fn {q, p}, hi -> either(hi, floor_div(form_max(p), q), &min/2) end)
  end

  # ------------------------------------------------------------ sources --
  # How the compiler states what it knows: the facts a construct gives.

  # `length(a)`: a value in 0..2^61 - 1 with a's length facts; with `own?`
  # (a is a binding), it is len(a) exactly
  def len_value(carrier, a, own?) do
    fa = facts(a)
    eq = {1, form_len(a.c)}

    put(carrier, %__MODULE__{
      lo: max(fa.len_lo || 0, 0),
      lbs: if(own?, do: fa.len_lbs ++ [eq], else: fa.len_lbs),
      ubs: if(own?, do: [eq], else: [])
    })
  end

  # `alloc(e, n)`: the array's length has n's lower bounds
  def len_from(arr, n) do
    fn_ = facts(n)
    put(arr, %{facts(arr) | len_lo: fn_.lo, len_lbs: fn_.lbs})
  end

  # a copy `b` of array `a`: a's length facts, and len(b) >= len(a)
  def len_like(b, a) do
    fa = facts(a)
    put(b, %{facts(b) | len_lo: fa.len_lo, len_lbs: fa.len_lbs ++ [{1, form_len(a.c)}]})
  end

  # an accumulator takes the length facts of its initial value
  def len_facts_of(carrier, v) do
    fv = facts(v)
    put(carrier, %{facts(carrier) | len_lo: fv.len_lo, len_lbs: fv.len_lbs})
  end

  # a range counter counting up from `start` to `stop`: the lower bounds of
  # the start and the upper bounds of the stop (the constants given)
  def between(carrier, start, stop, lo, hi) do
    put(carrier, %__MODULE__{lo: lo, hi: hi, lbs: facts(start).lbs, ubs: facts(stop).ubs})
  end

  # ------------------------------------------------------------- proving --
  # The only functions whose answers may drop a check. A proof carries its
  # support: the C variables of the arrays whose lengths it reasoned about,
  # which the flagged-strip classifier must see (ADR-0007).

  # a value within lo..hi needs no i64 overflow check
  def prove_i64(lo, hi),
    do: is_integer(lo) and is_integer(hi) and lo >= @i64_min and hi <= @i64_max

  # 0 <= i < length(a); with a width w (a word load), 0 <= i and
  # i + w <= length(a)
  def in_bounds?(a, i, w \\ 1), do: prove_in_bounds(a, i, w) != :unproven

  def prove_in_bounds(a, i, w \\ 1) do
    lookup = %{{:len, a.c} => facts(a)}

    with {:ok, s1} <- value_le(-1, i, form_const(0), lookup),
         {:ok, s2} <- value_le(1, i, form_sub(form_const(w), form_len(a.c)), lookup) do
      {:proven, Enum.uniq([a.c | s1 ++ s2])}
    else
      _ -> :unproven
    end
  end

  # the fact that would drop the check `0 <= i` / `i + w <= length(a)` when
  # nothing does: the report names it (the perturbations stay in here, where
  # the representation is)
  def missing(a, i, w \\ 1) do
    low = assert(i, lo: max(lo(i) || 0, 0))
    high = put(i, %{facts(i) | ubs: [{1, form_sub(form_len(a.c), form_const(w))} | ubs(i)]})

    cond do
      in_bounds?(a, i, w) -> :none
      in_bounds?(a, low, w) -> :low
      in_bounds?(a, high, w) -> :high
      true -> :both
    end
  end

  # Prove c * v + rest <= 0 for a value v (c = 1 or -1): v is replaced by
  # each of its bounds in c's direction, then by its constant bound, and the
  # form left is handed to the prover. Gives {:ok, support} or :no.
  defp value_le(c, v, rest, lookup) do
    f = facts(v)

    candidates =
      if c > 0,
        do: Enum.map(f.ubs, &replace_upper(c, &1, rest)) ++ [constant(c, f.hi, rest)],
        else: Enum.map(f.lbs, &replace_lower(c, &1, rest)) ++ [constant(c, f.lo, rest)]

    Enum.find_value(candidates, :no, fn
      nil ->
        nil

      form ->
        case le?(form, lookup, @budget, []) do
          {true, support, _left} -> {:ok, support}
          _ -> nil
        end
    end)
  end

  # The prover. `form <= 0`? A constant answers itself. Otherwise the newest
  # monomial x with coefficient c is replaced: by each of its bounds in c's
  # direction, then by its constant bound. Each step replaces a monomial by
  # older ones, so the search ends; the budget bounds it anyway, and an
  # exhausted budget is "not proven". Gives {true, support, budget_left} or
  # {false, budget_left}.
  defp le?(%{t: t, k: k}, _lookup, budget, support) when map_size(t) == 0,
    do: if(k <= 0, do: {true, support, budget}, else: {false, budget})

  defp le?(_form, _lookup, 0, _support), do: {false, 0}

  defp le?(form, lookup, budget, support) do
    {x, c} = Enum.max_by(form.t, fn {m, _} -> rank(m) end)
    rest = %{form | t: Map.delete(form.t, x)}
    fx = Map.get(lookup, x, %__MODULE__{})
    {lo, hi} = monomial_range(x, fx)
    {lbs, ubs} = monomial_bounds(x, fx)

    candidates =
      if c > 0,
        do: Enum.map(ubs, &replace_upper(c, &1, rest)) ++ [constant(c, hi, rest)],
        else: Enum.map(lbs, &replace_lower(c, &1, rest)) ++ [constant(c, lo, rest)]

    support = [support_of(x) | support]

    Enum.reduce_while(candidates, {false, budget - 1}, fn
      nil, acc ->
        {:cont, acc}

      cand, {false, left} ->
        case le?(cand, lookup, left, support) do
          {true, _, _} = ok -> {:halt, ok}
          {false, left} -> {:cont, {false, left}}
        end
    end)
  end

  # c * x + rest <= 0 given q * x <= p (c > 0). For c = 1 the integer
  # rounding is kept: x <= floor(p / q), and floor(p / q) + rest <= 0 holds
  # exactly when p + q * rest <= q - 1. For c > 1, q * (c * x + rest) <=
  # c * p + q * rest, a sufficient test.
  defp replace_upper(1, {q, p}, rest),
    do: form_add(p, form_scale(rest, q)) |> form_add(form_const(1 - q))

  defp replace_upper(c, {q, p}, rest), do: form_add(form_scale(p, c), form_scale(rest, q))

  # c * x + rest <= 0 given q * x >= p (c < 0). For c = -1: x >= ceil(p / q),
  # and rest <= ceil(p / q) holds exactly when q * rest - p <= q - 1.
  defp replace_lower(-1, {q, p}, rest),
    do: form_sub(form_scale(rest, q), p) |> form_add(form_const(1 - q))

  defp replace_lower(c, {q, p}, rest), do: form_add(form_scale(p, c), form_scale(rest, q))

  # c * x + rest <= 0 given x's constant bound b in c's direction, or nil
  defp constant(_c, nil, _rest), do: nil
  defp constant(c, b, rest), do: form_add(rest, form_const(c * b))

  # a monomial's constant bounds: a length is always in 0..2^61 - 1
  defp monomial_range({:len, _}, f), do: {max(f.len_lo || 0, 0), @len_max}

  # a monomial's relative bounds: {lower, upper}; a length has only lower ones
  defp monomial_bounds({:len, _}, f), do: {f.len_lbs, []}

  defp support_of({:len, c}), do: c

  # the newest monomial is replaced first: parameters are the oldest, then
  # the bindings in fresh/2's order (their C names carry its counter)
  defp rank({:len, "p_" <> _ = c}), do: {0, c}

  defp rank({:len, c}) do
    case Regex.run(~r/_(\d+)$/, c) do
      [_, n] -> {1, String.to_integer(n)}
      _ -> {0, c}
    end
  end

  # ------------------------------------------------- the accumulator carry --
  # A loop body may assume an array accumulator's facts (with_acc_facts in
  # the compiler, which owns the re-lowering protocol; fin is a contents
  # fact and stays on the carrier).

  # The length facts are len_lo, a constant lower bound, and len_lbs, lower
  # bounds relative to other arrays. A relative bound names an array's C
  # variable, assigned before the loop and never changed while it runs (the
  # accumulator's own variable is fresh, so no bound names it), which is
  # what makes the fact true at every iteration when every new value has it.

  # the accumulator carries facts a new value may not have
  def carries?(carrier), do: is_integer(len_lo(carrier)) or len_lbs(carrier) != []

  # A new value `r` keeps every length assumption the body made about `a`.
  # A relative bound is kept by one of the same form with a constant at
  # least as large, or any bounds the prover can combine into it; what it
  # cannot show counts as lost (sound, if weak: the loop is lowered again
  # without it). The constant bound asks for r's own len_lo, as before.
  # len(r) is also replaced first, by each of its lower bounds: the prover
  # replaces the newest monomial first, and r's variable may rank below the
  # atoms of a bound (a value bound before them).
  def covers?(a, r) do
    al = len_lo(a)
    lookup = %{{:len, r.c} => facts(r)}

    (not is_integer(al) or (is_integer(len_lo(r)) and len_lo(r) >= al)) and
      Enum.all?(len_lbs(a), fn {q, p} ->
        # q * len(r) >= p: p - q * len(r) <= 0
        [
          form_sub(p, form_scale(form_len(r.c), q))
          | Enum.map(len_lbs(r), &replace_lower(-q, &1, p))
        ]
        |> Enum.any?(&match?({true, _, _}, le?(&1, lookup, @budget, [])))
      end)
  end

  # Drop what the body may no longer assume, in two steps, so that losing a
  # relative fact does not cost the constant one: first the relative
  # bounds, and on a second retry len_lo (weakest?/1 says which step is left).
  def weaken(carrier) do
    if len_lbs(carrier) != [],
      do: put(carrier, %{facts(carrier) | len_lbs: []}),
      else: assert(carrier, len_lo: nil)
  end

  # the next weaken/1 drops the last length fact
  def weakest?(carrier), do: len_lbs(carrier) == []

  # ------------------------------------------------------ the branch join --
  # The value of an if, cond or case whose arms give `arms` has the facts
  # every arm's value has, each true of whichever arm is taken: the loosest
  # constant bounds (the smallest lo and len_lo, the largest hi) when every
  # arm has one, and each relative bound every arm has, at its loosest
  # constant (the smallest for a lower bound, the largest for an upper). A
  # bound every arm has names an array bound before the branch, since an
  # array bound inside one arm is unknown to the others, so it is in scope
  # after the branch; an accumulator keeps such a length fact across
  # iterations (covers?/2) when the branch's value has it with a constant
  # as large.
  def join(carrier, []), do: carrier

  def join(carrier, arms) do
    fs = Enum.map(arms, &facts/1)

    put(carrier, %__MODULE__{
      lo: joined(fs, & &1.lo, &min/2),
      hi: joined(fs, & &1.hi, &max/2),
      lbs: common(fs, & &1.lbs, &min/2),
      ubs: common(fs, & &1.ubs, &max/2),
      len_lo: joined(fs, & &1.len_lo, &min/2),
      len_lbs: common(fs, & &1.len_lbs, &min/2)
    })
  end

  # the constant bound every arm has, at its loosest; nil when one lacks it
  defp joined(fs, get, loosest) do
    bounds = Enum.map(fs, get)
    if Enum.all?(bounds, &is_integer/1), do: Enum.reduce(bounds, loosest)
  end

  # the relative bounds whose form every arm has, each at its loosest constant
  defp common(fs, get, loosest) do
    fs
    |> Enum.map(get)
    |> Enum.reduce(fn bs, acc -> intersect(acc, bs, loosest) end)
  end

  # --------------------------------------------------------- derivations --

  def add_facts(a, b) do
    {fa, fb} = {facts(a), facts(b)}

    %__MODULE__{
      lo: add(fa.lo, fb.lo),
      hi: add(fa.hi, fb.hi),
      lbs: merge(shift(fa.lbs, fb.lo), shift(fb.lbs, fa.lo), &max/2),
      ubs: merge(shift(fa.ubs, fb.hi), shift(fb.ubs, fa.hi), &min/2)
    }
  end

  def sub_facts(a, b) do
    {fa, fb} = {facts(a), facts(b)}

    %__MODULE__{
      lo: add(fa.lo, neg(fb.hi)),
      hi: add(fa.hi, neg(fb.lo)),
      lbs: shift(fa.lbs, neg(fb.hi)),
      ubs: shift(fa.ubs, neg(fb.lo))
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

  # q * v <= p scaled by k: q * (k * v) <= k * p
  defp scaled(f, k) do
    %__MODULE__{
      lo: f.lo && f.lo * k,
      hi: f.hi && f.hi * k,
      lbs: Enum.map(f.lbs, fn {q, p} -> norm(q, form_scale(p, k), :lb) end),
      ubs: Enum.map(f.ubs, fn {q, p} -> norm(q, form_scale(p, k), :ub) end)
    }
  end

  # every value of a * b, with the bounds the relative facts give (lo_of, hi_of)
  def mul_range(a, b), do: mul_bounds({lo_of(a), hi_of(a)}, {lo_of(b), hi_of(b)})

  defp mul_bounds({a1, a2}, {b1, b2})
       when is_integer(a1) and is_integer(a2) and is_integer(b1) and is_integer(b2) do
    ps = [a1 * b1, a1 * b2, a2 * b1, a2 * b2]
    {Enum.min(ps), Enum.max(ps)}
  end

  defp mul_bounds(_a, _b), do: {nil, nil}

  # div(v, k) for a literal k >= 1: div is monotonic, and v's facts divided.
  # From q * v >= p: q * k * div(v, k) >= q * (v - k + 1) >= p - q * (k - 1).
  # From q * v <= p, for v >= 0 where div rounds down: q * k * div(v, k) <= p.
  def div_facts_of(v, k) do
    f = facts(v)

    ubs =
      if is_integer(lo_of_f(f)) and lo_of_f(f) >= 0,
        do: Enum.map(f.ubs, fn {q, p} -> norm(k * q, p, :ub) end),
        else: []

    %__MODULE__{
      lo: f.lo && div(f.lo, k),
      hi: f.hi && div(f.hi, k),
      lbs:
        Enum.map(f.lbs, fn {q, p} ->
          norm(k * q, form_add(p, form_const(-q * (k - 1))), :lb)
        end),
      ubs: ubs
    }
  end

  def minmax_facts(:min, a, b) do
    {fa, fb} = {facts(a), facts(b)}

    %__MODULE__{
      lo: both(fa.lo, fb.lo, &min/2),
      hi: either(fa.hi, fb.hi, &min/2),
      lbs: intersect(fa.lbs, fb.lbs, &min/2),
      ubs: merge(fa.ubs, fb.ubs, &min/2)
    }
  end

  def minmax_facts(:max, a, b) do
    {fa, fb} = {facts(a), facts(b)}

    %__MODULE__{
      lo: either(fa.lo, fb.lo, &max/2),
      hi: both(fa.hi, fb.hi, &max/2),
      lbs: merge(fa.lbs, fb.lbs, &max/2),
      ubs: intersect(fa.ubs, fb.ubs, &max/2)
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

  # --------------------------------------------------------------- forms --

  def form_const(k), do: %{k: k, t: %{}}
  def form_len(c), do: %{k: 0, t: %{{:len, c} => 1}}

  def form_add(a, b),
    do: %{k: a.k + b.k, t: Map.merge(a.t, b.t, fn _, x, y -> x + y end) |> drop_zeros()}

  def form_sub(a, b), do: form_add(a, form_scale(b, -1))

  def form_scale(%{k: k, t: t}, c), do: %{k: k * c, t: Map.new(t, fn {m, x} -> {m, x * c} end)}

  defp drop_zeros(t), do: Map.reject(t, fn {_, x} -> x == 0 end)

  # the least and greatest values a form takes over its monomials' ranges
  defp form_min(%{k: k, t: t}) do
    Enum.reduce(t, k, fn {m, c}, acc ->
      {lo, hi} = default_range(m)
      acc + c * if(c > 0, do: lo, else: hi)
    end)
  end

  defp form_max(%{k: k, t: t}) do
    Enum.reduce(t, k, fn {m, c}, acc ->
      {lo, hi} = default_range(m)
      acc + c * if(c > 0, do: hi, else: lo)
    end)
  end

  defp default_range({:len, _}), do: {0, @len_max}

  # a bound in normal form: q and the coefficients with no common divisor
  # (the constant rounded down for an upper bound, up for a lower one)
  defp norm(q, %{k: k, t: t}, dir) do
    g = Enum.reduce(Map.values(t), q, &Integer.gcd/2)
    k = if dir == :ub, do: floor_div(k, g), else: ceil_div(k, g)
    {div(q, g), %{k: k, t: Map.new(t, fn {m, c} -> {m, div(c, g)} end)}}
  end

  # the bounds of v + k from those of v
  defp shift(_bounds, nil), do: []

  defp shift(bounds, k),
    do: Enum.map(bounds, fn {q, p} -> {q, form_add(p, form_const(q * k))} end)

  # the bounds of both lists, one per shape (q and terms) at the tighter constant
  defp merge(xs, ys, tighter) do
    Enum.reduce(ys, xs, fn {q, p} = y, acc ->
      case Enum.split_with(acc, &same_shape?(&1, y)) do
        {[], _} -> acc ++ [y]
        {[{_, p0} | _], rest} -> rest ++ [{q, %{p | k: tighter.(p0.k, p.k)}}]
      end
    end)
  end

  # the bounds both lists have, each at the looser constant
  defp intersect(xs, ys, looser) do
    for {q, p} = x <- xs, {_, p1} <- Enum.filter(ys, &same_shape?(&1, x)), uniq: true do
      {q, %{p | k: looser.(p.k, p1.k)}}
    end
  end

  defp same_shape?({q, p}, {q1, p1}), do: q == q1 and p.t == p1.t

  # ------------------------------------------------------------ plumbing --

  defp floor_div(a, b), do: Integer.floor_div(a, b)
  defp ceil_div(a, b), do: -Integer.floor_div(-a, b)

  # combine optional bounds: `both` needs both known, `either` is valid with one
  defp both(x, y, f) when is_integer(x) and is_integer(y), do: f.(x, y)
  defp both(_, _, _), do: nil

  defp either(nil, y, _), do: y
  defp either(x, nil, _), do: x
  defp either(x, y, f), do: f.(x, y)
end
