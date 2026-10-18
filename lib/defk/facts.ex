defmodule Defk.Facts do
  # The range facts (ADR-0007): what the compiler knows a kernel value
  # satisfies, used to drop bounds and overflow checks. A value map carries
  # one opaque %Defk.Facts{} under :facts; only this module reads or writes
  # its insides. Pure: no process dictionary, no emission.
  #
  # Representation:
  #   monomial - an atom of the symbolic bounds: {:len, c}, the length of the
  #              array in C variable c, or {:var, c}, the i64 in C variable
  #              c. (A later step adds products of two atoms.) Each has a
  #              rank, its binding's order: parameters first, then
  #              fresh/2's counter.
  #   form     - a polynomial over monomials with integer coefficients plus a
  #              constant: %{k: integer, t: %{monomial => coefficient}}
  #   bound    - {q, form}: q * v <= form (an upper bound, in ubs) or
  #              q * v >= form (a lower bound, in lbs), q >= 1, the
  #              coefficients and q with no common divisor
  # An i64 value's facts: lo, hi (constants, nil = unknown), eq (the form it
  # is exactly, nil = none) and ubs, lbs. An array's facts: len_lo, a
  # constant lower bound on its length, and len_lbs, len_ubs, lower and upper
  # bounds on its length. Every length is in 0..2^61 - 1
  # (DEFK_ALLOC_MAX_BYTES, and the largest binary) and every i64 in
  # -2^63..2^63 - 1, so a bound over atoms also bounds a value by a constant
  # (lo_of/1, hi_of/1).
  #
  # Facts are exact for checked arithmetic (an overflow raises, never
  # wraps); a case guard's checked arithmetic flags and computes on, so the
  # compiler drops its exact form (inexact/1). An i64 value whose C is a C
  # variable is that atom (eq/1). An atom's facts are its binding's, found
  # in the scope the compiler passes (its env: atoms for i64 bindings by C
  # variable, vars for arrays): a binding is assigned in one place, or is a
  # loop counter or an accumulator, whose facts hold wherever the binding is
  # in scope, and an array never changes length. A fact whose atom is out of
  # scope finds no binding and proves nothing (sound, if weak).
  #
  # The prover (le?/4) decides `form <= 0` by replacing the newest monomial
  # by one of its bounds until a constant is left, within a step budget; an
  # unproven query keeps the check. The facts of before map onto it one to
  # one (`i <= length(a) + k` is {1, len(a) + k}; a scaled fact
  # `q * i <= p * length(a) + k` is {q, p * len(a) + k}).
  @moduledoc false

  defstruct lo: nil, hi: nil, eq: nil, ubs: [], lbs: [], len_lo: nil, len_lbs: [], len_ubs: []

  @i64_min -0x8000000000000000
  @i64_max 0x7FFFFFFFFFFFFFFF
  @len_max 2 ** 61 - 1

  # the prover's step budget per query (one step: one monomial replaced);
  # measured on the suite and the examples, see docs/performance.md
  @budget 64

  # the relative bounds a value keeps of each kind: the first ones, and a
  # derivation lists the bounds shifted by constants (those of before) first
  @max_bounds 4

  # the report's hint names a residual whose constant is at most this: one
  # from an i64 or length limit names no fact a kernel states
  @hint_max 2 ** 32

  # the hint's search budget: a residual small enough to name is a few
  # replacements from the goal, and a kept check is searched for it again
  # (the whole search fails), so it gets less than a proof
  @hint_budget 16

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

  # the facts a binding of value v keeps: v's, with the form v is exactly
  def bound(v), do: %{facts(v) | eq: eq(v)}

  # v without its exact form: a case guard's checked arithmetic, which
  # flags an overflow and computes on
  def inexact(v), do: put(v, %{facts(v) | eq: nil})

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
  def len_ubs(carrier), do: facts(carrier).len_ubs

  # the one constant a value is known to be, or nil
  def const(carrier) do
    f = facts(carrier)
    if is_integer(f.lo) and f.lo == f.hi, do: f.lo
  end

  # The form an i64 value is exactly, or nil: its recorded form, its one
  # constant, or the atom of the C variable it reads.
  def eq(carrier) do
    f = facts(carrier)

    cond do
      f.eq != nil -> f.eq
      is_integer(f.lo) and f.lo == f.hi -> form_const(f.lo)
      c_var?(carrier) -> form_var(carrier.c)
      true -> nil
    end
  end

  # a C variable's name: p_ or v_ and one or more word characters
  defp c_var?(%{t: :i64, c: <<p, ?_, rest::binary>>}) when p in [?p, ?v] and rest != "",
    do: word?(rest)

  defp c_var?(_), do: false

  defp word?(<<>>), do: true

  defp word?(<<ch, rest::binary>>)
       when ch in ?a..?z or ch in ?A..?Z or ch in ?0..?9 or ch == ?_,
       do: word?(rest)

  defp word?(_), do: false

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
      eq: if(own?, do: form_len(a.c)),
      lbs: if(own?, do: fa.len_lbs ++ [eq], else: fa.len_lbs),
      ubs: if(own?, do: [eq], else: fa.len_ubs)
    })
  end

  # `alloc(e, n)`: the array's length is n (an alloc with any other length
  # raises), so it has n's bounds both ways and n's exact form
  def len_from(arr, n) do
    fn_ = facts(n)
    e = exact_bound(n)

    put(arr, %{
      facts(arr)
      | len_lo: fn_.lo,
        len_lbs: cap(fn_.lbs ++ e),
        len_ubs: cap(fn_.ubs ++ e)
    })
  end

  # a copy `b` of array `a`: a's length facts, and len(b) == len(a)
  def len_like(b, a) do
    fa = facts(a)
    same = [{1, form_len(a.c)}]

    put(b, %{
      facts(b)
      | len_lo: fa.len_lo,
        len_lbs: fa.len_lbs ++ same,
        len_ubs: cap(fa.len_ubs ++ same)
    })
  end

  # an accumulator takes the length facts of its initial value (the lower
  # ones: covers?/2 is what keeps them across iterations)
  def len_facts_of(carrier, v) do
    fv = facts(v)
    put(carrier, %{facts(carrier) | len_lo: fv.len_lo, len_lbs: fv.len_lbs})
  end

  # a range counter between `low` and `high` (start and stop counting up,
  # stop and start counting down): the lower bounds of `low` and the upper
  # bounds of `high`, their exact forms included, and the constants given
  def between(carrier, low, high, lo, hi) do
    put(carrier, %__MODULE__{
      lo: lo,
      hi: hi,
      lbs: cap(facts(low).lbs ++ exact_bound(low)),
      ubs: cap(facts(high).ubs ++ exact_bound(high))
    })
  end

  # ---------------------------------------------------------- conditions --
  # What a condition says when it is true (or false): a relation is
  # {:cmp, op, a, b} for a comparison of two exact i64 forms, {:and, x, y},
  # {:or, x, y} or {:not, x} over relations, or nil (nothing known). The
  # compiler makes a comparison's relation only from operands computed
  # without a check that a flagged strip could run on past (ADR-0007), and
  # narrows the scope of a taken branch by it (narrowing/1).

  @cmp_ops [:<, :<=, :==, :===, :>=, :>, :!=, :!==]

  # the relation of `a op b`, or nil when an operand has no exact form
  def relation(op, a, b) when op in @cmp_ops do
    {ea, eb} = {eq(a), eq(b)}
    if ea && eb, do: {:cmp, op, ea, eb}
  end

  # The forms D with D <= 0 that hold when relation `rel` is `true?`: a
  # comparison, and both sides of an `and` that holds or an `or` that does
  # not. A disjunction and `!=` give nothing; a constant form (a test that
  # is always or never true) gives nothing either.
  def holds(nil, _true?), do: []
  def holds({:not, x}, true?), do: holds(x, not true?)
  def holds({:and, x, y}, true), do: holds(x, true) ++ holds(y, true)
  def holds({:or, x, y}, false), do: holds(x, false) ++ holds(y, false)
  def holds({op, _, _}, _true?) when op in [:and, :or], do: []

  def holds({:cmp, op, a, b}, true?) do
    op = if true?, do: op, else: negated_op(op)

    case op do
      :< -> [form_add(form_sub(a, b), form_const(1))]
      :<= -> [form_sub(a, b)]
      :> -> [form_add(form_sub(b, a), form_const(1))]
      :>= -> [form_sub(b, a)]
      eq when eq in [:==, :===] -> [form_sub(a, b), form_sub(b, a)]
      _ne -> []
    end
    |> Enum.filter(&(map_size(&1.t) > 0))
  end

  defp negated_op(op),
    do: %{<: :>=, <=: :>, >: :<=, >=: :<, ==: :!=, ===: :!==, !=: :==, !==: :===}[op]

  # D <= 0 as a fact on D's newest monomial x, over older ones only:
  # {x, :lo | :hi, constant} when the rest of D is a constant, else
  # {x, :lb | :ub, {q, form}}
  def narrowing(%{t: t} = d) when map_size(t) > 0 do
    {x, c} = Enum.max_by(t, fn {m, _} -> rank(m) end)
    rest = %{d | t: Map.delete(t, x)}
    const? = map_size(rest.t) == 0

    cond do
      # c * x <= -rest
      c > 0 and const? -> {x, :hi, floor_div(-rest.k, c)}
      c > 0 -> {x, :ub, norm(c, form_scale(rest, -1), :ub)}
      # -c * x >= rest
      const? -> {x, :lo, ceil_div(rest.k, -c)}
      true -> {x, :lb, norm(-c, rest, :lb)}
    end
  end

  # the carrier (a binding of atom x) with the fact `kind`, `b` added; a
  # narrowed bound comes first, as it is the one the branch is about
  def narrow(carrier, {:var, _}, kind, b) do
    f = facts(carrier)

    put(
      carrier,
      case kind do
        :lo -> %{f | lo: either(f.lo, b, &max/2)}
        :hi -> %{f | hi: either(f.hi, b, &min/2)}
        :lb -> %{f | lbs: cap([b | f.lbs])}
        :ub -> %{f | ubs: cap([b | f.ubs])}
      end
    )
  end

  def narrow(carrier, {:len, _}, kind, b) do
    f = facts(carrier)

    put(
      carrier,
      case kind do
        :lo -> %{f | len_lo: either(f.len_lo, b, &max/2)}
        :hi -> %{f | len_ubs: cap([{1, form_const(b)} | f.len_ubs])}
        :lb -> %{f | len_lbs: cap([b | f.len_lbs])}
        :ub -> %{f | len_ubs: cap([b | f.len_ubs])}
      end
    )
  end

  # ------------------------------------------------------------- proving --
  # The only functions whose answers may drop a check. A proof carries its
  # support: the C variables of the atoms it reasoned about, which the
  # flagged-strip classifier must see (ADR-0007). `scope` is the compiler's
  # env: where an atom's facts are (atom_facts/2).

  # a value within lo..hi needs no i64 overflow check
  def prove_i64(lo, hi),
    do: is_integer(lo) and is_integer(hi) and lo >= @i64_min and hi <= @i64_max

  # An i64 value v whose facts keep it inside i64, by the prover. A value
  # with constant bounds only was decided by prove_i64/2 already.
  def fits_i64?(v, scope) do
    f = facts(v)
    lookup = lookup(scope, nil)

    (f.ubs != [] or f.lbs != [] or rel_eq(v) != nil) and
      match?({:ok, _}, value_le(1, v, form_const(-@i64_max), lookup)) and
      match?({:ok, _}, value_le(-1, v, form_const(@i64_min), lookup))
  end

  # 0 <= i < length(a); with a width w (a word load), 0 <= i and
  # i + w <= length(a)
  def in_bounds?(a, i, w \\ 1, scope \\ %{}), do: prove_in_bounds(a, i, w, scope) != :unproven

  def prove_in_bounds(a, i, w \\ 1, scope \\ %{}) do
    case check(a, i, w, scope) do
      {:proven, _} = proven -> proven
      {:unproven, _} -> :unproven
    end
  end

  # An access's proof, or the half of it that fails, for the report:
  # {:proven, support} or {:unproven, :low | :high | :both}. Each half is
  # proven once.
  def check(a, i, w, scope) do
    lookup = lookup(scope, a)

    case {low_half(i, lookup), fn -> high_half(a, i, w, lookup) end} do
      {{:ok, s1}, high} ->
        case high.() do
          {:ok, s2} -> {:proven, Enum.uniq([a.c | s1 ++ s2])}
          :no -> {:unproven, :high}
        end

      {:no, high} ->
        {:unproven, if(match?({:ok, _}, high.()), do: :low, else: :both)}
    end
  end

  # the two halves of the check: 0 <= i, and i + w <= length(a)
  defp low_half(i, lookup), do: value_le(-1, i, form_const(0), lookup)

  defp high_half(a, i, w, lookup),
    do: value_le(1, i, form_sub(form_const(w), form_len(a.c)), lookup)

  # The fact that would drop the check `0 <= i` / `i + w <= length(a)` when
  # nothing does: the report names it. Each half is proven on its own, so a
  # half that fails is the fact missing (supplying `lo >= 0`, or the bound
  # `i <= length(a) - w`, proves that half and leaves the other as it is).
  def missing(a, i, w \\ 1, scope \\ %{}) do
    case check(a, i, w, scope) do
      {:proven, _} -> :none
      {:unproven, half} -> half
    end
  end

  # The fact the failing half `half` (:low or :high) of a's check would
  # follow from, for the report: of the forms the search reached by
  # replacing at least one bound, the one with the fewest monomials, when it
  # has at most two and a small constant; else nil. A residual in the
  # accessed array's length alone (`length(a) >= 12` for `a[11]`) restates
  # the check at an extreme of the index, so it is no hint; an index with
  # no relative bound and no exact form over atoms can only give that one,
  # and is not searched. A hint, not a promise: another fact could also do.
  # Gives a form D, the hint being D <= 0.
  def residual(a, i, w, half, scope) do
    {c, rest} =
      case half do
        :low -> {-1, form_const(0)}
        :high -> {1, form_sub(form_const(w), form_len(a.c))}
      end

    f = facts(i)

    {bounds, b, replace} =
      if c > 0, do: {f.ubs, f.hi, &replace_upper/3}, else: {f.lbs, f.lo, &replace_lower/3}

    if bounds != [] or rel_eq(i) != nil do
      # the exact form restates the goal (:goal): only what follows from it
      # is a hint
      candidates =
        Enum.map(bounds, &{replace.(c, &1, rest), :ok}) ++
          [{constant(c, b, rest), :ok}] ++
          for e <- [rel_eq(i)], e, do: {replace.(c, {1, e}, rest), :goal}

      walk = {lookup(scope, a), [{:len, a.c}]}

      {_, best} =
        Enum.reduce(candidates, {@hint_budget, nil}, fn
          {nil, _}, acc -> acc
          {form, state}, {left, best} -> walk(form, walk, left, state, best)
        end)

      if best != nil and map_size(best.t) <= 2 and abs(best.k) <= @hint_max, do: best
    end
  end

  # le?/4's search to its end (it fails), keeping the best residual. A form
  # reached through a limit no fact states (an i64 or length limit, a length
  # at least 0) names nothing a kernel could state, and nor does what
  # follows from it (:tainted). `own`: the monomials of a restated goal.
  defp walk(%{t: t}, _walk, budget, _state, best) when map_size(t) == 0, do: {budget, best}
  defp walk(_form, _walk, 0, _state, best), do: {0, best}

  defp walk(form, {lookup, own} = walk, budget, state, best) do
    best =
      if state == :ok and Map.keys(form.t) != own and
           (best == nil or map_size(form.t) < map_size(best.t)),
         do: form,
         else: best

    {x, c} = Enum.max_by(form.t, fn {m, _} -> rank(m) end)
    rest = %{form | t: Map.delete(form.t, x)}
    fx = lookup.(x)
    {lo, hi} = monomial_range(x, fx)
    {lbs, ubs} = monomial_bounds(x, fx)
    stated = if state == :tainted, do: :tainted, else: :ok
    by_limit = if stated_range?(x, fx, c), do: stated, else: :tainted

    candidates =
      if c > 0,
        do:
          Enum.map(ubs, &{replace_upper(c, &1, rest), stated}) ++
            [{constant(c, hi, rest), by_limit}],
        else:
          Enum.map(lbs, &{replace_lower(c, &1, rest), stated}) ++
            [{constant(c, lo, rest), by_limit}]

    Enum.reduce(candidates, {budget - 1, best}, fn
      {nil, _}, acc -> acc
      {cand, st}, {left, best} -> walk(cand, walk, left, st, best)
    end)
  end

  # the constant bound of x in c's direction is a fact, not a limit
  defp stated_range?({:var, _}, f, c), do: if(c > 0, do: f.hi, else: f.lo) != nil
  defp stated_range?({:len, _}, f, c), do: c < 0 and is_integer(f.len_lo) and f.len_lo > 0

  # An atom's facts: array a's own (the one a proof is about), else its
  # binding's in scope, else none. A binding's exact form is never its own
  # atom (bound/1 records the value's), so it is a bound over older atoms.
  defp lookup(scope, a) do
    fn
      {:len, c} when a != nil and c == a.c -> facts(a)
      m -> atom_facts(scope, m)
    end
  end

  # scope: the compiler's env, whose atoms map an i64 binding's C variable
  # to its facts, and whose vars hold the array bindings
  defp atom_facts(scope, {:var, c}), do: (scope[:atoms] || %{})[c] || %__MODULE__{}

  defp atom_facts(scope, {:len, c}) do
    Enum.find_value(scope[:vars] || %{}, %__MODULE__{}, fn
      {_, %{c: ^c, t: {:arr, _}} = b} -> facts(b)
      _ -> nil
    end)
  end

  # Prove c * v + rest <= 0 for a value v (c = 1 or -1): v is replaced by
  # each of its bounds in c's direction, then by its constant bound, then by
  # its exact form, and the form left is handed to the prover. Gives
  # {:ok, support} or :no.
  defp value_le(c, v, rest, lookup) do
    f = facts(v)
    # a value that reads its own C variable has that binding's facts, but
    # its atom is also what newer atoms' facts name (a condition that
    # narrowed length(a) by it), so it is tried last
    exact = for e <- [rel_eq(v)], e, do: {1, e}

    candidates =
      if c > 0,
        do:
          Enum.map(f.ubs, &replace_upper(c, &1, rest)) ++
            [constant(c, f.hi, rest)] ++ Enum.map(exact, &replace_upper(c, &1, rest)),
        else:
          Enum.map(f.lbs, &replace_lower(c, &1, rest)) ++
            [constant(c, f.lo, rest)] ++ Enum.map(exact, &replace_lower(c, &1, rest))

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
    fx = lookup.(x)
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

  # a monomial's constant bounds: a length is always in 0..2^61 - 1, an i64
  # in -2^63..2^63 - 1
  defp monomial_range({:len, _}, f), do: {max(f.len_lo || 0, 0), @len_max}
  defp monomial_range({:var, _}, f), do: {f.lo || @i64_min, f.hi || @i64_max}

  # a monomial's relative bounds, {lower, upper}; an i64 binding's exact
  # form bounds it both ways
  defp monomial_bounds({:len, _}, f), do: {f.len_lbs, f.len_ubs}

  defp monomial_bounds({:var, c}, f) do
    exact = if f.eq != nil and f.eq != form_var(c), do: [{1, f.eq}], else: []
    {exact ++ f.lbs, exact ++ f.ubs}
  end

  defp support_of({_, c}), do: c

  # the newest monomial is replaced first: parameters are the oldest, then
  # the bindings in fresh/2's order (their C names carry its counter)
  defp rank({_, "p_" <> _ = c}), do: {0, c}
  defp rank({_, c}), do: counter(c, byte_size(c), 0, 1)

  # the number after the last "_" of c, read from the end: {1, n}, or
  # {0, c} for a name without one
  defp counter(c, i, n, m) when i > 0 do
    case :binary.at(c, i - 1) do
      d when d in ?0..?9 -> counter(c, i - 1, n + (d - ?0) * m, m * 10)
      ?_ when m > 1 -> {1, n}
      _ -> {0, c}
    end
  end

  defp counter(c, _i, _n, _m), do: {0, c}

  # ------------------------------------------------- the accumulator carry --
  # A loop body may assume an array accumulator's facts (with_acc_facts in
  # the compiler, which owns the re-lowering protocol; fin is a contents
  # fact and stays on the carrier).

  # The length facts are len_lo, a constant lower bound, and len_lbs, lower
  # bounds relative to other atoms. A relative bound names atoms bound
  # before the loop and never changed while it runs (the accumulator's own
  # variable is fresh, so no bound names it), which is what makes the fact
  # true at every iteration when every new value has it.

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
    lookup = lookup(%{}, r)

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
  # arm has one, the exact form when every arm has the same one, and each
  # relative bound every arm has (an arm's exact form counts as a bound both
  # ways), at its loosest constant (the smallest for a lower bound, the
  # largest for an upper). A bound every arm has names atoms bound before
  # the branch, since an atom bound inside one arm is unknown to the others,
  # so it is in scope after the branch; an accumulator keeps such a length
  # fact across iterations (covers?/2) when the branch's value has it with a
  # constant as large.
  def join(carrier, []), do: carrier

  def join(carrier, arms) do
    fs = Enum.map(arms, &facts/1)
    rel = Enum.map(arms, &%{facts(&1) | lbs: lbs_of(&1), ubs: ubs_of(&1)})
    # a constant every arm is stays in lo and hi
    eqs = Enum.map(arms, &rel_eq/1)

    put(carrier, %__MODULE__{
      lo: joined(fs, & &1.lo, &min/2),
      hi: joined(fs, & &1.hi, &max/2),
      eq: if(Enum.all?(eqs, &(&1 == hd(eqs))), do: hd(eqs)),
      lbs: common(rel, & &1.lbs, &min/2),
      ubs: common(rel, & &1.ubs, &max/2),
      len_lo: joined(fs, & &1.len_lo, &min/2),
      len_lbs: common(fs, & &1.len_lbs, &min/2),
      len_ubs: common(fs, & &1.len_ubs, &max/2)
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
  # Each operation's exact form is the operands' combined, when both have
  # one; the relative bounds of before (shifted by the other operand's
  # constant bounds) come first, then those shifted by its exact form.

  def add_facts(a, b) do
    {fa, fb} = {facts(a), facts(b)}
    {ea, eb} = {eq(a), eq(b)}
    {ra, rb} = {atoms_of(ea), atoms_of(eb)}

    %__MODULE__{
      lo: add(fa.lo, fb.lo),
      hi: add(fa.hi, fb.hi),
      eq: both(ea, eb, &form_add/2),
      lbs:
        merge(shift(fa.lbs, fb.lo), shift(fb.lbs, fa.lo), &max/2)
        |> merge(
          shift_by(plus_exact(fa.lbs, ra), rb) ++ shift_by(plus_exact(fb.lbs, rb), ra),
          &max/2
        )
        |> cap(),
      ubs:
        merge(shift(fa.ubs, fb.hi), shift(fb.ubs, fa.hi), &min/2)
        |> merge(
          shift_by(plus_exact(fa.ubs, ra), rb) ++ shift_by(plus_exact(fb.ubs, rb), ra),
          &min/2
        )
        |> cap()
    }
  end

  # a - b: a's bounds shifted by -b, and b's bounds flipped and shifted by
  # a (q * b >= p gives q * (a - b) <= q * a - p)
  def sub_facts(a, b) do
    {fa, fb} = {facts(a), facts(b)}
    {ea, eb} = {eq(a), eq(b)}
    ra = atoms_of(ea)
    nb = negated(fb, eb)
    rn = atoms_of(nb.eq)

    %__MODULE__{
      lo: add(fa.lo, neg(fb.hi)),
      hi: add(fa.hi, neg(fb.lo)),
      eq: both(ea, eb, &form_sub/2),
      lbs:
        shift(fa.lbs, neg(fb.hi))
        |> merge(shift_by(plus_exact(fa.lbs, ra), rn) ++ shift_by(nb.lbs, ra), &max/2)
        |> cap(),
      ubs:
        shift(fa.ubs, neg(fb.lo))
        |> merge(shift_by(plus_exact(fa.ubs, ra), rn) ++ shift_by(nb.ubs, ra), &min/2)
        |> cap()
    }
  end

  # -a: the bounds swapped and negated, the exact form negated
  def neg_facts(a), do: negated(facts(a), eq(a))

  defp negated(fa, ea) do
    flip = fn {q, p} -> {q, form_scale(p, -1)} end
    r = atoms_of(ea)

    %__MODULE__{
      lo: neg(fa.hi),
      hi: neg(fa.lo),
      eq: ea && form_scale(ea, -1),
      lbs: Enum.map(plus_exact(fa.ubs, r), flip),
      ubs: Enum.map(plus_exact(fa.lbs, r), flip)
    }
  end

  # a product: lo..hi from the operands' (nil when one is unbounded), and
  # for a constant k >= 1 times v, v's facts scaled by k; times a constant,
  # the exact form scaled (a product of two atoms has none: degree 2 is a
  # later step)
  def mul_facts(a, b) do
    {fa, fb} = {facts(a), facts(b)}

    f =
      cond do
        is_integer(fa.lo) and fa.lo == fa.hi and fa.lo > 0 ->
          scaled(fb, fa.lo)

        is_integer(fb.lo) and fb.lo == fb.hi and fb.lo > 0 ->
          scaled(fa, fb.lo)

        true ->
          {lo, hi} = mul_bounds({fa.lo, fa.hi}, {fb.lo, fb.hi})
          %__MODULE__{lo: lo, hi: hi}
      end

    eq =
      case {const(a), const(b)} do
        {k, _} when is_integer(k) -> (e = eq(b)) && form_scale(e, k)
        {_, k} when is_integer(k) -> (e = eq(a)) && form_scale(e, k)
        _ -> nil
      end

    %{f | eq: eq}
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

  # min(a, b) is at most each operand (their exact forms included) and at
  # least what both are at least; max the mirror
  def minmax_facts(:min, a, b) do
    {fa, fb} = {facts(a), facts(b)}

    %__MODULE__{
      lo: both(fa.lo, fb.lo, &min/2),
      hi: either(fa.hi, fb.hi, &min/2),
      lbs: intersect(lbs_of(a), lbs_of(b), &min/2) |> cap(),
      ubs:
        merge(fa.ubs, fb.ubs, &min/2) |> merge(exact_bound(a) ++ exact_bound(b), &min/2) |> cap()
    }
  end

  def minmax_facts(:max, a, b) do
    {fa, fb} = {facts(a), facts(b)}

    %__MODULE__{
      lo: either(fa.lo, fb.lo, &max/2),
      hi: both(fa.hi, fb.hi, &max/2),
      lbs:
        merge(fa.lbs, fb.lbs, &max/2) |> merge(exact_bound(a) ++ exact_bound(b), &max/2) |> cap(),
      ubs: intersect(ubs_of(a), ubs_of(b), &max/2) |> cap()
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

  # a value's exact form as a bound, when it has atoms (a constant one is
  # its lo and hi)
  defp exact_bound(v), do: plus_exact([], rel_eq(v))

  # the exact form, when it has atoms
  defp rel_eq(v), do: atoms_of(eq(v))

  defp atoms_of(%{t: t} = e) when map_size(t) > 0, do: e
  defp atoms_of(_), do: nil

  # bounds with an exact form (with atoms, or nil) among them
  defp plus_exact(bounds, nil), do: bounds
  defp plus_exact(bounds, e), do: bounds ++ [{1, e}]

  # the relative bounds with the exact form among them
  defp lbs_of(v), do: plus_exact(facts(v).lbs, rel_eq(v))
  defp ubs_of(v), do: plus_exact(facts(v).ubs, rel_eq(v))

  # --------------------------------------------------------------- forms --

  def form_const(k), do: %{k: k, t: %{}}
  def form_len(c), do: %{k: 0, t: %{{:len, c} => 1}}
  def form_var(c), do: %{k: 0, t: %{{:var, c} => 1}}

  # a coefficient that sums to 0 drops its monomial (only a shared one can)
  def form_add(a, %{t: tb} = b) when map_size(tb) == 0, do: %{a | k: a.k + b.k}
  def form_add(%{t: ta} = a, b) when map_size(ta) == 0, do: %{b | k: a.k + b.k}

  def form_add(a, b) do
    t =
      Enum.reduce(b.t, a.t, fn {m, y}, t ->
        case t do
          %{^m => x} when x + y == 0 -> Map.delete(t, m)
          %{^m => x} -> %{t | m => x + y}
          _ -> Map.put(t, m, y)
        end
      end)

    %{k: a.k + b.k, t: t}
  end

  def form_sub(a, b), do: form_add(a, form_scale(b, -1))

  def form_scale(form, 1), do: form
  def form_scale(_form, 0), do: form_const(0)
  def form_scale(%{k: k, t: t}, c), do: %{k: k * c, t: Map.new(t, fn {m, x} -> {m, x * c} end)}

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
  defp default_range({:var, _}), do: {@i64_min, @i64_max}

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

  # the bounds of v + e from those of v, for an exact form e with atoms
  defp shift_by(_bounds, nil), do: []

  defp shift_by(bounds, e),
    do: Enum.map(bounds, fn {q, p} -> {q, form_add(p, form_scale(e, q))} end)

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

  defp cap(bounds), do: Enum.take(bounds, @max_bounds)

  # ------------------------------------------------------------ plumbing --

  defp floor_div(a, b), do: Integer.floor_div(a, b)
  defp ceil_div(a, b), do: -Integer.floor_div(-a, b)

  # combine optional bounds: `both` needs both known, `either` is valid with one
  defp both(x, y, f) when x != nil and y != nil, do: f.(x, y)
  defp both(_, _, _), do: nil

  defp either(nil, y, _), do: y
  defp either(x, nil, _), do: x
  defp either(x, y, f), do: f.(x, y)
end
