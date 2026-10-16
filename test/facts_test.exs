# Defk.Facts is the range-facts lattice: the compiler asserts what it knows
# about a value and asks prove_in_bounds / prove_i64 before dropping a
# check. These properties are the module's spec, stated against
# ground truth: build facts that are TRUE of concrete integers and arrays
# by construction, push them through each derivation, and check the derived
# facts still hold of the derived concrete value. holds?/3 below restates
# what a fact means independently of the module's representation, so an
# unsound derivation or proof fails here without compiling a kernel
# (scaled_facts_test.exs stays the end-to-end net for the compiler's
# assert sites).
defmodule Defk.FactsTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Defk.Facts

  # ------------------------------------------------------------ oracle ----
  # What facts mean, restated for concrete values. `lens` maps an array's C
  # variable to its concrete length.

  defp holds?(carrier, v, lens) do
    [lo, hi] = [Facts.lo(carrier), Facts.hi(carrier)]

    (lo == nil or v >= lo) and (hi == nil or v <= hi) and
      Enum.all?(Facts.lb(carrier), fn {key, k} ->
        {arr, p, q} = scale(key)
        q * v >= p * Map.fetch!(lens, arr) + k
      end) and
      Enum.all?(Facts.ub(carrier), fn {key, k} ->
        {arr, p, q} = scale(key)
        q * v <= p * Map.fetch!(lens, arr) + k
      end)
  end

  defp len_holds?(carrier, len, lens) do
    len_lo = Facts.len_lo(carrier)

    (len_lo == nil or len >= len_lo) and
      Enum.all?(Facts.len_lb(carrier), fn {key, k} ->
        {arr, p, q} = scale(key)
        q * len >= p * Map.fetch!(lens, arr) + k
      end)
  end

  defp scale({_arr, _p, _q} = key), do: key
  defp scale(arr), do: {arr, 1, 1}

  # -------------------------------------------------------- generators ----

  # concrete array lengths for one or two arrays
  defp lens_gen do
    gen all(a <- integer(0..60), b <- integer(0..60)) do
      %{"a" => a, "b" => b}
    end
  end

  # reduce p/q to the representation's normal form (coprime; the bare array
  # name for p = q = 1), and derive k from the REDUCED pair so the stored
  # fact means what was computed even when two raw pairs normalize to one key
  defp coprime(p, q) do
    g = Integer.gcd(p, q)
    {div(p, g), div(q, g)}
  end

  defp key(arr, 1, 1), do: arr
  defp key(arr, p, q), do: {arr, p, q}

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
      rel =
        for {arr, p0, q0, r, dir} <- Enum.zip([arrs, ps, qs, rs, dirs]) do
          {p, q} = coprime(p0, q0)
          {arr, p, q, r, dir}
        end

      lb =
        for {arr, p, q, r, :lb} <- rel,
            into: %{},
            do: {key(arr, p, q), q * v - p * Map.fetch!(lens, arr) - r}

      ub =
        for {arr, p, q, r, :ub} <- rel,
            into: %{},
            do: {key(arr, p, q), q * v - p * Map.fetch!(lens, arr) + r}

      carrier =
        Facts.assert(%{c: "v"},
          lo: dlo && v - dlo,
          hi: dhi && v + dhi,
          lb: lb,
          ub: ub
        )

      {carrier, v}
    end
  end

  # an array carrier whose length facts are true of its concrete length
  defp arr_gen(lens, name) do
    len = Map.fetch!(lens, name)

    gen all(
          dlo <- one_of([constant(nil), integer(0..10)]),
          rel? <- boolean(),
          other <- member_of(Map.keys(lens)),
          q0 <- integer(1..3),
          p0 <- integer(0..3),
          r <- integer(0..9)
        ) do
      {p, q} = coprime(p0, q0)

      len_lb =
        if rel?,
          do: %{key(other, p, q) => q * len - p * Map.fetch!(lens, other) - r},
          else: %{}

      carrier = Facts.assert(%{c: name}, len_lo: dlo && len - dlo, len_lb: len_lb)
      {carrier, len}
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
      case Facts.missing(a, i, w) do
        :none -> assert Facts.in_bounds?(a, i, w)
        :low -> assert Facts.in_bounds?(a, Facts.assert(i, lo: max(Facts.lo(i) || 0, 0)), w)
        :high -> assert Facts.in_bounds?(a, Facts.assert(i, ub: Map.put(Facts.ub(i), a.c, -w)), w)
        :both -> refute Facts.in_bounds?(a, i, w)
      end
    end
  end

  # ------------------------------------------------- the carry protocol ----

  property "weaken drops exactly what carries? reports" do
    check all(
            lens <- lens_gen(),
            name <- member_of(Map.keys(lens)),
            {a, len} <- arr_gen(lens, name)
          ) do
      assert Facts.carries?(a) == (is_integer(Facts.len_lo(a)) or Facts.len_lb(a) != %{})
      # the relative facts go first, the constant one keeps
      w = Facts.weaken(a)
      assert Facts.len_lb(w) == %{}
      assert Facts.weakest?(w)
      if Facts.len_lb(a) != %{}, do: assert(Facts.len_lo(w) == Facts.len_lo(a))
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
      if Facts.covers?(a, r) do
        if is_integer(Facts.len_lo(a)), do: assert(Facts.len_lo(r) >= Facts.len_lo(a))

        # each relative bound of `a` is in `r`, at least as strong
        for {key, d} <- Facts.len_lb(a), do: assert(Facts.len_lb(r)[key] >= d)
      end

      none = Facts.assert(r, len_lo: nil, len_lb: %{})
      refute Facts.covers?(Facts.assert(a, len_lo: 1), none)
      if Facts.len_lb(a) != %{}, do: refute(Facts.covers?(a, none))
    end
  end

  # ------------------------------------------------------ the branch join ----

  property "join holds of every arm's value, and keeps what every arm has" do
    check all(
            lens <- lens_gen(),
            name <- member_of(Map.keys(lens)),
            {a, la} <- arr_gen(lens, "a"),
            {b, lb} <- arr_gen(lens, "b"),
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
      assert Facts.len_lb(ja) == common(arrs, &Facts.len_lb/1, &min/2)

      # numbers: the same for lo/hi and lb/ub
      ints = [x, y, z]
      ji = Facts.join(%{c: "v_if_2"}, ints)
      for v <- [xv, yv, zv], do: assert(holds?(ji, v, lens))
      assert Facts.lo(ji) == loosest(ints, &Facts.lo/1, &min/2)
      assert Facts.hi(ji) == loosest(ints, &Facts.hi/1, &max/2)
      assert Facts.lb(ji) == common(ints, &Facts.lb/1, &min/2)
      assert Facts.ub(ji) == common(ints, &Facts.ub/1, &max/2)

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

  # ... and each key every arm has, at its loosest offset
  defp common(arms, get, pick) do
    keys =
      arms
      |> Enum.map(&MapSet.new(Map.keys(get.(&1))))
      |> Enum.reduce(&MapSet.intersection/2)

    for key <- keys, into: %{} do
      {key, arms |> Enum.map(&get.(&1)[key]) |> Enum.reduce(pick)}
    end
  end

  # the generators themselves state true facts (the spec's own floor)
  property "generated carriers satisfy their own facts" do
    check all(
            lens <- lens_gen(),
            name <- member_of(Map.keys(lens)),
            {i, iv} <- int_gen(lens),
            {a, len} <- arr_gen(lens, name)
          ) do
      assert holds?(i, iv, lens)
      assert len_holds?(a, len, lens)
    end
  end
end
