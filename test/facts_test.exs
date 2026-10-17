# Defk.Facts is the range-facts module: the compiler states what it knows
# about a value and asks prove_in_bounds / prove_i64 before dropping a
# check. These properties are the module's spec, stated against ground
# truth: build facts that are TRUE of concrete integers and arrays by
# construction, push them through each derivation, and check the derived
# facts still hold of the derived concrete value. holds?/3 below restates
# what a fact means independently of the module's internals, so an unsound
# derivation or proof fails here without compiling a kernel
# (scaled_facts_test.exs stays the end-to-end net for the compiler's
# sites).
defmodule Defk.FactsTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Defk.Facts

  # ------------------------------------------------------------ oracle ----
  # What facts mean, restated for concrete values. `lens` maps an array's C
  # variable to its concrete length. A bound {q, form} reads q * v <= form
  # (an upper bound) or q * v >= form (a lower bound), the form evaluated at
  # the concrete lengths.

  defp eval(%{k: k, t: t}, lens),
    do: Enum.reduce(t, k, fn {{:len, arr}, c}, acc -> acc + c * Map.fetch!(lens, arr) end)

  defp holds?(carrier, v, lens) do
    [lo, hi] = [Facts.lo(carrier), Facts.hi(carrier)]

    (lo == nil or v >= lo) and (hi == nil or v <= hi) and
      Enum.all?(Facts.lbs(carrier), fn {q, p} -> q * v >= eval(p, lens) end) and
      Enum.all?(Facts.ubs(carrier), fn {q, p} -> q * v <= eval(p, lens) end)
  end

  defp len_holds?(carrier, len, lens) do
    len_lo = Facts.len_lo(carrier)

    (len_lo == nil or len >= len_lo) and
      Enum.all?(Facts.len_lbs(carrier), fn {q, p} -> q * len >= eval(p, lens) end)
  end

  # -------------------------------------------------------- generators ----

  # concrete array lengths for one or two arrays
  defp lens_gen do
    gen all(a <- integer(0..60), b <- integer(0..60)) do
      %{"p_a" => a, "v_b_2" => b}
    end
  end

  # the bound q * v (<= | >=) p * len(arr) + k, in normal form (p and q
  # coprime), with k derived from the reduced pair so the stored bound
  # means what was computed
  defp bound(arr, p0, q0, v, len, r, dir) do
    g = Integer.gcd(p0, q0)
    {p, q} = {div(p0, g), div(q0, g)}
    k = if dir == :ub, do: q * v - p * len + r, else: q * v - p * len - r
    form = Facts.form_add(Facts.form_scale(Facts.form_len(arr), p), Facts.form_const(k))
    {q, form}
  end

  # a carrier whose facts are true of the concrete integer it returns
  defp int_gen(lens) do
    gen all(
          v <- integer(-50..50),
          dlo <- one_of([constant(nil), integer(0..20)]),
          dhi <- one_of([constant(nil), integer(0..20)]),
          arrs <- list_of(member_of(Map.keys(lens)), max_length: 2),
          ps <- list_of(integer(0..3), length: length(arrs)),
          qs <- list_of(integer(1..3), length: length(arrs)),
          rs <- list_of(integer(0..9), length: length(arrs)),
          dirs <- list_of(member_of([:lb, :ub]), length: length(arrs))
        ) do
      rel = Enum.zip([arrs, ps, qs, rs, dirs])

      lbs =
        for {arr, p, q, r, :lb} <- rel, do: bound(arr, p, q, v, Map.fetch!(lens, arr), r, :lb)

      ubs =
        for {arr, p, q, r, :ub} <- rel, do: bound(arr, p, q, v, Map.fetch!(lens, arr), r, :ub)

      facts = %Facts{lo: dlo && v - dlo, hi: dhi && v + dhi, lbs: lbs, ubs: ubs}
      {Facts.put(%{c: "v"}, facts), v}
    end
  end

  # an array carrier whose length facts are true of its concrete length
  defp arr_gen(lens, name) do
    len = Map.fetch!(lens, name)

    gen all(
          dlo <- one_of([constant(nil), integer(0..10)]),
          rel? <- boolean(),
          other <- member_of(Map.keys(lens) -- [name]),
          q <- integer(1..3),
          p <- integer(0..3),
          r <- integer(0..9)
        ) do
      len_lbs = if rel?, do: [bound(other, p, q, len, Map.fetch!(lens, other), r, :lb)], else: []
      facts = %Facts{len_lo: dlo && len - dlo, len_lbs: len_lbs}
      {Facts.put(%{c: name}, facts), len}
    end
  end

  # ------------------------------------------------------- derivations ----

  property "add_facts holds of the sum" do
    check all(
            lens <- lens_gen(),
            {a, x} <- int_gen(lens),
            {b, y} <- int_gen(lens)
          ) do
      assert holds?(Facts.put(%{}, Facts.add_facts(a, b)), x + y, lens)
    end
  end

  property "sub_facts holds of the difference" do
    check all(
            lens <- lens_gen(),
            {a, x} <- int_gen(lens),
            {b, y} <- int_gen(lens)
          ) do
      assert holds?(Facts.put(%{}, Facts.sub_facts(a, b)), x - y, lens)
    end
  end

  property "mul_facts holds of the product" do
    check all(
            lens <- lens_gen(),
            {a, x} <- int_gen(lens),
            {b, y} <- int_gen(lens)
          ) do
      assert holds?(Facts.put(%{}, Facts.mul_facts(a, b)), x * y, lens)
    end
  end

  property "minmax_facts holds of min and max" do
    check all(
            lens <- lens_gen(),
            {a, x} <- int_gen(lens),
            {b, y} <- int_gen(lens)
          ) do
      assert holds?(Facts.put(%{}, Facts.minmax_facts(:min, a, b)), min(x, y), lens)
      assert holds?(Facts.put(%{}, Facts.minmax_facts(:max, a, b)), max(x, y), lens)
    end
  end

  property "div_facts_of holds of div by a positive literal" do
    check all(
            lens <- lens_gen(),
            {a, x} <- int_gen(lens),
            k <- integer(1..7)
          ) do
      assert holds?(Facts.put(%{}, Facts.div_facts_of(a, k)), div(x, k), lens)
    end
  end

  property "bit_facts and bsr_facts hold of the bitwise result" do
    check all(
            lens <- lens_gen(),
            {a, x} <- int_gen(lens),
            {b, y} <- int_gen(lens),
            f <- member_of([:band, :bor, :bxor])
          ) do
      r = apply(Bitwise, f, [x, y])
      assert holds?(Facts.put(%{}, Facts.bit_facts(f, a, b)), r, lens)

      if y >= 0 do
        assert holds?(Facts.put(%{}, Facts.bsr_facts(a, b)), Bitwise.bsr(x, y), lens)
      end
    end
  end

  property "the sources hold of what they describe" do
    check all(
            lens <- lens_gen(),
            name <- member_of(Map.keys(lens)),
            {a, len} <- arr_gen(lens, name),
            {n, nv} <- int_gen(lens),
            {s, sv} <- int_gen(lens),
            own? <- boolean()
          ) do
      # length(a) is a's length
      assert holds?(Facts.len_value(%{c: "v_len_9"}, a, own?), len, lens)
      # alloc(e, n) is an array of length n, where n is a's length: n >= 0
      if nv == len, do: assert(len_holds?(Facts.len_from(%{c: "v_alloc_9"}, n), nv, lens))
      # a copy has the same length
      assert len_holds?(Facts.len_like(%{c: "v_copy_9"}, a), len, lens)
      assert len_holds?(Facts.len_facts_of(%{c: "v_acc_9"}, a), len, lens)
      # a counter between s and n (counting up)
      if sv <= nv do
        for i <- sv..nv//1 do
          assert holds?(Facts.between(%{c: "v_i_9"}, s, n, Facts.lo(s), Facts.hi(n)), i, lens)
        end
      end
    end
  end

  # ----------------------------------------------------------- proving ----

  property "a proven index is in bounds, and the support names known arrays" do
    check all(
            lens <- lens_gen(),
            name <- member_of(Map.keys(lens)),
            {a, len} <- arr_gen(lens, name),
            {i, iv} <- int_gen(lens),
            w <- member_of([1, 2, 4, 8])
          ) do
      case Facts.prove_in_bounds(a, i, w) do
        :unproven ->
          assert Facts.in_bounds?(a, i, w) == false

        {:proven, support} ->
          assert Facts.in_bounds?(a, i, w)
          assert iv >= 0 and iv + w <= len
          assert support != []
          assert Enum.all?(support, &is_map_key(lens, &1))
      end
    end
  end

  property "prove_i64 admits exactly the values the bounds admit" do
    check all(lo <- integer(), hi <- integer(), v <- integer()) do
      if Facts.prove_i64(lo, hi) and v in lo..hi//1 do
        assert v >= -0x8000000000000000 and v <= 0x7FFFFFFFFFFFFFFF
      end
    end
  end

  property "what missing/3 names is what makes the proof go through" do
    check all(
            lens <- lens_gen(),
            name <- member_of(Map.keys(lens)),
            {a, _len} <- arr_gen(lens, name),
            {i, _iv} <- int_gen(lens),
            w <- member_of([1, 8])
          ) do
      high = Facts.form_sub(Facts.form_len(a.c), Facts.form_const(w))

      case Facts.missing(a, i, w) do
        :none ->
          assert Facts.in_bounds?(a, i, w)

        :low ->
          assert Facts.in_bounds?(a, Facts.assert(i, lo: max(Facts.lo(i) || 0, 0)), w)

        :high ->
          f = %{Facts.facts(i) | ubs: [{1, high} | Facts.ubs(i)]}
          assert Facts.in_bounds?(a, Facts.put(i, f), w)

        :both ->
          refute Facts.in_bounds?(a, i, w)
      end
    end
  end

  # the proofs the per-kind rules made before ADR-0007 still go through
  test "the scaled forms: a multiple of a length against a multiple, a quotient" do
    a = %{c: "p_a"}
    n = Facts.len_value(%{c: "v_n_1"}, a, true)
    two = Facts.assert(%{c: "2"}, lo: 2, hi: 2)
    one = Facts.assert(%{c: "1"}, lo: 1, hi: 1)
    zero = Facts.assert(%{c: "0"}, lo: 0, hi: 0)
    two_n = Facts.put(%{c: "v_op_2"}, Facts.mul_facts(two, n))
    o = Facts.len_from(%{c: "v_alloc_3"}, two_n)
    stop = Facts.put(%{c: "v_stop_4"}, Facts.sub_facts(n, one))
    i = Facts.between(%{c: "v_i_5"}, zero, stop, 0, nil)
    two_i = Facts.put(%{c: "v_op_6"}, Facts.mul_facts(two, i))
    two_i1 = Facts.put(%{c: "v_op_7"}, Facts.add_facts(two_i, one))

    assert {:proven, _} = Facts.prove_in_bounds(o, two_i)
    assert {:proven, _} = Facts.prove_in_bounds(o, two_i1)
    assert {:proven, _} = Facts.prove_in_bounds(a, i)
    assert :unproven = Facts.prove_in_bounds(a, two_i)

    # a third of a length: 3 * j <= len(a) - 3, over an array of div(len(a), 3)
    three = Facts.assert(%{c: "3"}, lo: 3, hi: 3)
    third = Facts.put(%{c: "v_q_8"}, Facts.div_facts_of(n, 3))
    out = Facts.len_from(%{c: "v_alloc_9"}, third)
    stop3 = Facts.put(%{c: "v_stop_10"}, Facts.sub_facts(third, one))
    j = Facts.between(%{c: "v_j_11"}, zero, stop3, 0, nil)
    three_j = Facts.put(%{c: "v_op_12"}, Facts.mul_facts(three, j))
    assert {:proven, _} = Facts.prove_in_bounds(out, j)
    assert {:proven, _} = Facts.prove_in_bounds(a, three_j)

    assert {:proven, _} =
             Facts.prove_in_bounds(a, Facts.put(%{c: "v_op_13"}, Facts.add_facts(three_j, two)))

    assert :unproven =
             Facts.prove_in_bounds(a, Facts.put(%{c: "v_op_14"}, Facts.add_facts(three_j, three)))
  end

  # ------------------------------------------------- the carry protocol ----

  property "weaken drops exactly what carries? reports" do
    check all(
            lens <- lens_gen(),
            name <- member_of(Map.keys(lens)),
            {a, len} <- arr_gen(lens, name)
          ) do
      assert Facts.carries?(a) == (is_integer(Facts.len_lo(a)) or Facts.len_lbs(a) != [])
      # the relative facts go first, the constant one keeps
      w = Facts.weaken(a)
      assert Facts.len_lbs(w) == []
      assert Facts.weakest?(w)
      if Facts.len_lbs(a) != [], do: assert(Facts.len_lo(w) == Facts.len_lo(a))
      assert len_holds?(w, len, lens)
      # at most two steps drop every length assumption
      w2 = if Facts.carries?(w), do: Facts.weaken(w), else: w
      refute Facts.carries?(w2)
      assert len_holds?(w2, len, lens)
    end
  end

  property "covers? accepts a value whose length keeps every assumption" do
    check all(
            lens <- lens_gen(),
            name <- member_of(Map.keys(lens)),
            {a, _} <- arr_gen(lens, name),
            {r, _} <- arr_gen(lens, name)
          ) do
      # sound: every length r's facts admit satisfies a's
      implied? =
        Enum.all?(0..200, fn l -> not len_holds?(r, l, lens) or len_holds?(a, l, lens) end)

      if Facts.covers?(a, r) do
        assert implied?
        if is_integer(Facts.len_lo(a)), do: assert(Facts.len_lo(r) >= Facts.len_lo(a))
      end

      # complete for the plain case: the same shape with a constant at
      # least as large, and r's own constant bound, are always enough
      same_shapes? =
        Enum.all?(Facts.len_lbs(a), fn {q, p} ->
          Enum.any?(Facts.len_lbs(r), fn {q1, p1} -> q1 == q and p1.t == p.t and p1.k >= p.k end)
        end)

      constant? =
        not is_integer(Facts.len_lo(a)) or
          (is_integer(Facts.len_lo(r)) and Facts.len_lo(r) >= Facts.len_lo(a))

      if same_shapes? and constant?, do: assert(Facts.covers?(a, r))

      none = Facts.put(r, %Facts{})
      refute Facts.covers?(Facts.assert(a, len_lo: 1), none)
    end
  end

  # ------------------------------------------------------ the branch join ----

  property "join holds of every arm's value, and keeps what every arm has" do
    check all(
            lens <- lens_gen(),
            name <- member_of(Map.keys(lens)),
            {a, la} <- arr_gen(lens, "p_a"),
            {b, lb} <- arr_gen(lens, "v_b_2"),
            {c, lc} <- arr_gen(lens, name),
            {x, xv} <- int_gen(lens),
            {y, yv} <- int_gen(lens),
            {z, zv} <- int_gen(lens)
          ) do
      # arrays: sound for whichever arm is taken, and complete
      arrs = [a, b, c]
      ja = Facts.join(%{c: "v_if_1"}, arrs)
      for len <- [la, lb, lc], do: assert(len_holds?(ja, len, lens))
      assert Facts.len_lo(ja) == loosest(arrs, &Facts.len_lo/1, &min/2)
      assert same_bounds?(Facts.len_lbs(ja), common(arrs, &Facts.len_lbs/1, &min/2))

      # numbers: the same for lo/hi and the relative bounds
      ints = [x, y, z]
      ji = Facts.join(%{c: "v_if_2"}, ints)
      for v <- [xv, yv, zv], do: assert(holds?(ji, v, lens))
      assert Facts.lo(ji) == loosest(ints, &Facts.lo/1, &min/2)
      assert Facts.hi(ji) == loosest(ints, &Facts.hi/1, &max/2)
      assert same_bounds?(Facts.lbs(ji), common(ints, &Facts.lbs/1, &min/2))
      assert same_bounds?(Facts.ubs(ji), common(ints, &Facts.ubs/1, &max/2))

      # one arm: its own facts; no arm: none
      assert Facts.facts(Facts.join(%{}, [x])) == Facts.facts(x)
      assert Facts.facts(Facts.join(%{}, [a])) == Facts.facts(a)
      assert Facts.join(%{c: "x"}, []) == %{c: "x"}
    end
  end

  # the spec's own join: the loosest constant bound when every arm has one
  defp loosest(arms, get, pick) do
    bounds = Enum.map(arms, get)
    if Enum.all?(bounds, &is_integer/1), do: Enum.reduce(bounds, pick)
  end

  # ... and each shape (q and terms) every arm has, at its loosest constant
  defp common(arms, get, pick) do
    shapes =
      arms
      |> Enum.map(&MapSet.new(get.(&1), fn {q, p} -> {q, p.t} end))
      |> Enum.reduce(&MapSet.intersection/2)

    for {q, t} <- shapes do
      k =
        arms
        |> Enum.map(fn arm ->
          Enum.find_value(get.(arm), fn {q1, p} -> (q1 == q and p.t == t) && p.k end)
        end)
        |> Enum.reduce(pick)

      {q, %{k: k, t: t}}
    end
  end

  defp same_bounds?(xs, ys), do: Enum.sort(xs) == Enum.sort(ys)

  # the generators themselves state true facts (the spec's own floor)
  property "generated carriers satisfy their own facts" do
    check all(
            lens <- lens_gen(),
            name <- member_of(Map.keys(lens)),
            {a, len} <- arr_gen(lens, name),
            {i, iv} <- int_gen(lens)
          ) do
      assert len_holds?(a, len, lens)
      assert holds?(i, iv, lens)
    end
  end
end
