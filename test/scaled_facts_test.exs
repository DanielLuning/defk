# Range facts for constant multiples and quotients of array lengths
# (defk-upc). In a hex encoder, out = alloc(u8, 2 * length(s)) and
# out[2 * i], out[2 * i + 1] for i <= length(s) - 1: the facts on `2 * i`
# relate it to 2 * length(s), the length of out records the same multiple, and
# the index needs no bounds check. The hex decoder's div(length(s), 2) gives
# the reverse. A product or sum whose operands' facts bound it inside i64
# (array lengths are below 2^61) needs no overflow check.
#
# The soundness properties compile generated kernels with random multiples,
# quotients and offsets and check every bounds and overflow check the
# compiler drops against the arithmetic: an unsound fact would be an
# out-of-bounds write.

defmodule Defk.ScaledFactsTest.K do
  use Defk

  @hex "0123456789ABCDEF"
  @dec16 for b <- 0..255,
             into: <<>>,
             do:
               <<min(
                   Enum.find_index(~c"0123456789ABCDEF", &(&1 == b)) || 255,
                   Enum.find_index(~c"0123456789abcdef", &(&1 == b)) || 255
                 )>>

  defk encode16(s :: [u8]) :: [u8] do
    n = length(s)
    out = alloc(u8, 2 * n)

    for i <- 0..(n - 1)//1 do
      b = s[i]
      out[2 * i] = @hex[band(bsr(b, 4), 15)]
      out[2 * i + 1] = @hex[band(b, 15)]
    end

    out
  end

  defk decode16(s :: [u8]) :: [u8] do
    n = length(s)
    _ = alloc(u8, if(rem(n, 2) == 0, do: 0, else: -1))
    m = div(n, 2)
    out = alloc(u8, m)

    bad =
      for i <- 0..(m - 1)//1, reduce: 0 do
        bad ->
          hi = @dec16[s[2 * i]]
          lo = @dec16[s[2 * i + 1]]
          out[i] = band(bor(bsl(hi, 4), lo), 255)
          bor(bad, bor(hi, lo))
      end

    _ = alloc(u8, if(bad < 16, do: 0, else: -1))
    out
  end

  # three i64 per input element, one more at the end; the multiple on the
  # right, and with an offset
  defk spread3(a :: [i64]) :: [i64] do
    out = alloc(i64, length(a) * 3 + 1)

    for i <- 0..(length(a) - 1)//1 do
      out[i * 3] = a[i]
      out[3 * i + 1] = a[i] * 2
      out[3 * i + 2] = 0
    end

    out[3 * length(a)] = length(a)
    out
  end

  # every other element, from a quotient of the length
  defk evens(a :: [i64]) :: [i64] do
    h = div(length(a) + 1, 2)
    out = alloc(i64, h)

    for i <- 0..(h - 1)//1 do
      out[i] = a[2 * i]
    end

    out
  end
end

defmodule Defk.ScaledFactsTest do
  use ExUnit.Case, async: true
  use Defk.Properties

  alias Defk.ScaledFactsTest.K

  # lengths are below 2^61 (DEFK_ALLOC_MAX_BYTES, and the largest binary)
  @len_max 2 ** 61 - 1
  @i64_min -0x8000000000000000
  @i64_max 0x7FFFFFFFFFFFFFFF

  defp kernel_c(name) do
    [_, c] = String.split(K.__defk_c_source__(), "/* ---- #{name}/", parts: 2)
    c |> String.split("/* ---- ", parts: 2) |> hd()
  end

  describe "the hex encoder" do
    test "encodes as Base.encode16, in both modes" do
      for s <- ["", <<0>>, "hello", :crypto.strong_rand_bytes(3000)] do
        assert K.encode16(s) == Base.encode16(s)
        Defk.Test.assert_agrees(K, :encode16, [s])
      end
    end

    test "writes out[2 * i] and out[2 * i + 1] with no bounds check" do
      refute kernel_c("encode16") =~ "defk_put_"
      refute kernel_c("encode16") =~ "defk_get_"
    end

    test "computes 2 * i and 2 * i + 1 with no overflow check" do
      refute kernel_c("encode16") =~ "defk_mul_i64"
      refute kernel_c("encode16") =~ "defk_add_i64"
    end

    test "stores a byte read from a binary attribute with no u8 range check" do
      refute kernel_c("encode16") =~ "defk_to_u8"
    end
  end

  describe "the hex decoder" do
    test "decodes as Base.decode16!(case: :mixed), in both modes" do
      for s <- ["", "00", "48656c6C6f", Base.encode16(:crypto.strong_rand_bytes(3000))] do
        assert K.decode16(s) == Base.decode16!(s, case: :mixed)
        Defk.Test.assert_agrees(K, :decode16, [s])
      end

      for s <- ["0", "0g", "abc"] do
        assert_raise ArgumentError, fn -> K.decode16(s) end
        Defk.Test.assert_agrees(K, :decode16, [s])
      end
    end

    test "reads s[2 * i], s[2 * i + 1] and writes out[i] with no bounds check" do
      refute kernel_c("decode16") =~ "defk_put_"
      refute kernel_c("decode16") =~ "defk_get_"
    end

    test "computes 2 * i and 2 * i + 1 with no overflow check" do
      refute kernel_c("decode16") =~ "defk_mul_i64"
      refute kernel_c("decode16") =~ "defk_add_i64"
    end
  end

  describe "other multiples and quotients" do
    test "a multiple on either side, with offsets, keeps no bounds check" do
      a = G.pack(:i64, [5, -7, 9])
      assert K.spread3(a) == G.pack(:i64, [5, 10, 0, -7, -14, 0, 9, 18, 0, 3])
      Defk.Test.assert_agrees(K, :spread3, [a])
      Defk.Test.assert_agrees(K, :spread3, [G.pack(:i64, [@i64_max])])
      refute kernel_c("spread3") =~ "defk_put_"
      refute kernel_c("spread3") =~ "defk_get_"
    end

    test "a quotient of a length keeps no bounds check" do
      for n <- 0..5 do
        a = G.pack(:i64, Enum.to_list(1..n//1))
        assert K.evens(a) == G.pack(:i64, Enum.take_every(Enum.to_list(1..n//1), 2))
        Defk.Test.assert_agrees(K, :evens, [a])
      end

      refute kernel_c("evens") =~ "defk_put_"
      refute kernel_c("evens") =~ "defk_get_"
    end
  end

  agreement(K, [
    :encode16,
    :spread3,
    :evens,
    decode16: [
      args:
        StreamData.fixed_list([
          StreamData.one_of([
            G.array(:u8),
            StreamData.map(G.array(:u8), &Base.encode16(&1, case: :lower))
          ])
        ])
    ]
  ])

  # ------------------------------------------------------ soundness --

  # a kernel writing out[idx] for i in 0..last, out = alloc(u8, size); size
  # is an expression of length(a), last of length(a) or length(out), idx of i
  defp kernel(size, last, idx) do
    body =
      quote do
        out = alloc(u8, unquote(size))

        for i <- 0..unquote(last)//1 do
          out[unquote(idx)] = 1
        end

        out
      end

    %{head: quote(do: f(a :: [u8]) :: [u8]), opts: [], body: body, line: 1}
  end

  defp c_of(kernel) do
    {c, _, _} = Defk.Compiler.compile(Defk.ScaledFactsTest.Probe, [kernel], nil)
    c
  end

  # an expression of x (an AST), and the values of its operations (the
  # last is its value) as a function of x's value
  defp shape(x, offsets) do
    StreamData.bind(
      StreamData.tuple({
        StreamData.integer(0..5),
        StreamData.integer(offsets),
        StreamData.integer(1..5),
        StreamData.member_of([:mul_left, :mul_right, :div, :div_sum])
      }),
      fn {p, c, q, form} -> StreamData.constant(build(form, x, p, c, q)) end
    )
  end

  defp build(:mul_left, x, p, c, _q),
    do: {quote(do: unquote(p) * unquote(x) + unquote(c)), &[p * &1, p * &1 + c]}

  defp build(:mul_right, x, p, c, _q),
    do: {quote(do: unquote(x) * unquote(p) + unquote(c)), &[&1 * p, &1 * p + c]}

  defp build(:div, x, p, c, q),
    do:
      {quote(do: div(unquote(p) * unquote(x), unquote(q)) + unquote(c)),
       &[p * &1, div(p * &1, q), div(p * &1, q) + c]}

  defp build(:div_sum, x, p, c, q),
    do:
      {quote(do: div(unquote(p) * unquote(x) + unquote(c), unquote(q))),
       &[p * &1, p * &1 + c, div(p * &1 + c, q)]}

  # {size, last, idx, base}: each an {ast, ops} shape; base is :a when
  # last is an expression of length(a), :out when of length(out)
  defp probe do
    StreamData.bind(StreamData.member_of([:a, :a, :out]), fn base ->
      x = if base == :a, do: quote(do: length(a)), else: quote(do: length(out))

      StreamData.tuple({
        shape(quote(do: length(a)), -3..7),
        shape(x, -7..2),
        shape(quote(do: i), -3..4),
        StreamData.constant(base)
      })
    end)
  end

  # the lengths where a fact is tightest: the smallest, and those next to
  # the 2^61 bound (each expression is linear up to a quotient's remainder)
  @lengths Enum.to_list(0..40) ++ Enum.to_list((@len_max - 40)..@len_max) ++ [2 ** 32, 2 ** 48]

  defp fits?(ops), do: Enum.all?(ops, &(&1 >= @i64_min and &1 <= @i64_max))

  # every length(a) whose alloc succeeds: {length(a), length(out), last's operations}
  defp lengths(size_v, last_v, base) do
    for l <- @lengths,
        fits?(size_v.(l)),
        n = List.last(size_v.(l)),
        n >= 0 and n <= @len_max,
        do: {l, n, last_v.(if base == :a, do: l, else: n)}
  end

  # every (length(a), length(out), i) the loop reaches, with the index's
  # operations; an index is monotonic in i, so i = 0 and i = last are the
  # extremes
  defp reached(size_v, last_v, idx_v, base) do
    for {l, n, last} <- lengths(size_v, last_v, base),
        fits?(last),
        e = List.last(last),
        k <- if(e >= 0, do: [0, e], else: []),
        do: {l, n, k, idx_v.(k)}
  end

  defp shown(size, last),
    do: "alloc(u8, #{Macro.to_string(size)}), i <- 0..#{Macro.to_string(last)}"

  # Each case compiles a kernel (C codegen) and walks ~100 lengths, about
  # 0.5 ms (bounds) to 1 ms (overflow) of pure CPU. The default suite runs
  # @runs cases; the :deep twins run @deep_runs (defk-o4n: 4_000 cases took
  # 60 s under load and hit ExUnit's per-test timeout).
  @runs 500
  @deep_runs 4_000

  property "a dropped bounds check is never wrong" do
    check(all(case <- probe(), max_runs: @runs, do: bounds_sound(case)))
  end

  @tag deep: true, timeout: 600_000
  property "a dropped bounds check is never wrong (deep)" do
    check(all(case <- probe(), max_runs: @deep_runs, do: bounds_sound(case)))
  end

  property "a dropped overflow check is never wrong" do
    check(all(case <- probe(), max_runs: @runs, do: overflow_sound(case)))
  end

  @tag deep: true, timeout: 600_000
  property "a dropped overflow check is never wrong (deep)" do
    check(all(case <- probe(), max_runs: @deep_runs, do: overflow_sound(case)))
  end

  defp bounds_sound({{size, size_v}, {last, last_v}, {idx, idx_v}, base}) do
    # an index past i64 raises in its checked arithmetic (and the overflow
    # property covers an unchecked one)
    if not (c_of(kernel(size, last, idx)) =~ "defk_put_u8") do
      for {l, n, k, ops} <- reached(size_v, last_v, idx_v, base), fits?(ops) do
        assert List.last(ops) in 0..(n - 1)//1,
               "out[#{Macro.to_string(idx)}] is unchecked, but for length(a) = #{l}, " <>
                 "i = #{k} it is #{List.last(ops)}, outside 0..#{n - 1} (#{shown(size, last)})"
      end
    end
  end

  defp overflow_sound({{size, size_v}, {last, last_v}, {idx, idx_v}, base}) do
    c = c_of(kernel(size, last, idx))

    # none checked: the length expressions never overflow
    if not (c =~ ~r/defk_(mul|add)_i64\(/) do
      for l <- @lengths, n = List.last(size_v.(l)), n in 0..@len_max//1 do
        assert fits?(size_v.(l)) and fits?(last_v.(if base == :a, do: l, else: n)),
               "#{shown(size, last)} has no overflow check, but overflows for length(a) = #{l}"
      end
    end

    # the index's multiply and add unchecked: they never overflow
    if not (c =~ ~r/defk_(mul|add)_i64\(ctx, [^;]*v_i_\d+/) do
      for {l, _n, k, ops} <- reached(size_v, last_v, idx_v, base) do
        assert fits?(ops),
               "#{Macro.to_string(idx)} has no overflow check, but overflows for " <>
                 "length(a) = #{l}, i = #{k} (#{shown(size, last)})"
      end
    end
  end
end
