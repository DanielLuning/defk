# The sample of the test suite's kernels that `mix defk.stability.freeze`
# freezes under test/stability/<version>/kernels/test-<file>.md, with the
# results the release's code gives (docs/agents/stability.md, "The test
# sample"). Each entry is a module body (kernels and attributes, as a doc
# example without `defmodule`: the task wraps it in a module with `use Defk`)
# and the calls to record, as `iex>` expressions over `M`. The entries are
# after the test files `from` names; they are self-contained copies, since a
# frozen file holds one module and nothing from test/support.
#
# The task runs every call at the release's tag (dev/stability/eval.exs),
# natively and in Elixir mode, and records the native result: a value, or
# the exception with its message. A call the two modes disagree on stops the
# task. Edit this file to change what a future release freezes; the files a
# release already froze are never edited.
[
  # ----------------------------------------------------------- i64 --
  %{
    file: "i64-arithmetic",
    from: ["test/trunc_boundary_test.exs", "test/range_limit_test.exs", "test/defk_test.exs"],
    source: ~S"""
    defk add(a :: i64, b :: i64) :: i64 do
      a + b
    end

    defk mul(a :: i64, b :: i64) :: i64 do
      a * b
    end

    defk neg_abs(x :: i64) :: {i64, i64} do
      {-x, abs(x)}
    end

    defk divrem(a :: i64, b :: i64) :: {i64, i64} do
      {div(a, b), rem(a, b)}
    end

    defk trunc_round(x :: f64) :: {i64, i64} do
      {trunc(x), round(x)}
    end

    defk count(first :: i64, last :: i64, step :: i64) :: i64 do
      for _ <- first..last//step, reduce: 0 do
        acc -> acc + 1
      end
    end
    """,
    calls: [
      "M.add(9223372036854775806, 1)",
      "M.add(9223372036854775807, 1)",
      "M.add(-9223372036854775808, -1)",
      "M.add(9223372036854775808, 0)",
      "M.add(1.0, 0)",
      "M.mul(-4611686018427387904, 2)",
      "M.mul(4611686018427387904, 2)",
      "M.mul(-9223372036854775808, -1)",
      "M.neg_abs(-9223372036854775807)",
      "M.neg_abs(-9223372036854775808)",
      "M.divrem(-7, 2)",
      "M.divrem(7, -2)",
      "M.divrem(-9223372036854775808, -1)",
      "M.divrem(1, 0)",
      "M.trunc_round(-9223372036854775808.0)",
      "M.trunc_round(9223372036854774784.0)",
      "M.trunc_round(9223372036854775808.0)",
      "M.trunc_round(-9223372036854777856.0)",
      "M.trunc_round(-2.5)",
      "M.trunc_round(2.5)",
      "M.count(0, 9, 3)",
      "M.count(9, 0, -3)",
      "M.count(1, 0, 1)",
      "M.count(0, 9, 0)",
      "M.count(0, 9223372036854775807, 1)",
      "M.count(9223372036854775800, 9223372036854775806, 1)"
    ]
  },
  # ----------------------------------------------------------- u64 --
  %{
    file: "u64-arithmetic",
    from: ["test/u64_test.exs"],
    source: ~S"""
    @mask64 0xFFFFFFFFFFFFFFFF

    defk add(a :: u64, b :: u64) :: u64 do
      a + b
    end

    defk sub(a :: u64, b :: u64) :: u64 do
      a - b
    end

    defk mul(a :: u64, b :: u64) :: u64 do
      a * b
    end

    defk divrem(a :: u64, b :: u64) :: {u64, u64} do
      {div(a, b), rem(a, b)}
    end

    defk shifts(a :: u64, n :: i64) :: {u64, u64} do
      {bsl(a, n), bsr(a, n)}
    end

    defk minmax(a :: u64, b :: u64) :: {u64, u64} do
      {min(a, b), max(a, b)}
    end

    defk cmp(a :: u64, b :: i64) :: {bool, bool, bool, bool} do
      {a < b, a == b, a === b, b >= a}
    end

    defk cmpf(a :: u64, f :: f64) :: {bool, bool, bool} do
      {a < f, a == f, f <= a}
    end

    defk to_i64(a :: u64) :: i64 do
      a
    end

    defk from_i64(x :: i64) :: u64 do
      x
    end

    defk to_u64(x :: i64) :: u64 do
      band(x, @mask64)
    end

    defk to_f(a :: u64) :: {f64, f64} do
      {float(a), a / 2}
    end

    defk total(hs :: [u64]) :: u64 do
      for h <- hs, reduce: 0 do
        acc -> acc + h
      end
    end
    """,
    calls: [
      "M.add(18446744073709551615, 0)",
      "M.add(18446744073709551615, 1)",
      "M.add(-1, 0)",
      "M.sub(5, 5)",
      "M.sub(3, 5)",
      "M.mul(4294967296, 4294967295)",
      "M.mul(4294967296, 4294967296)",
      "M.divrem(18446744073709551615, 9223372036854775808)",
      "M.divrem(1, 0)",
      "M.shifts(1, 63)",
      "M.shifts(9223372036854775808, 0)",
      "M.shifts(9223372036854775808, 1)",
      "M.shifts(3, 63)",
      "M.shifts(18446744073709551615, 64)",
      "M.minmax(18446744073709551615, 0)",
      "M.cmp(9223372036854775808, -1)",
      "M.cmp(9223372036854775808, 9223372036854775807)",
      "M.cmp(5, 5)",
      "M.cmpf(9223372036854775808, 9223372036854775808.0)",
      "M.cmpf(9223372036854775809, 9223372036854775808.0)",
      "M.to_i64(9223372036854775807)",
      "M.to_i64(9223372036854775808)",
      "M.from_i64(0)",
      "M.from_i64(-1)",
      "M.to_u64(-1)",
      "M.to_u64(-9223372036854775808)",
      "M.to_f(18446744073709551615)",
      "M.total(<<9223372036854775808::unsigned-64-native, 1::unsigned-64-native>>)",
      "M.total(<<18446744073709551615::unsigned-64-native, 1::unsigned-64-native>>)"
    ]
  },
  # ------------------------------------------------- masks and bits --
  %{
    file: "masks-and-bits",
    from: ["test/u64_test.exs", "test/bit_builtins_test.exs", "test/masked_arith_test.exs"],
    source: ~S"""
    @mask64 0xFFFFFFFFFFFFFFFF

    defk mask32(x :: i64, y :: i64) :: i64 do
      band(x * y + bsl(x, 40), 0xFFFFFFFF)
    end

    defk mask64(x :: i64, y :: i64) :: u64 do
      band(x * y - x, @mask64)
    end

    defk wrap(x :: i64, y :: i64) :: i64 do
      wrap64(x * y + 1)
    end

    defk shift_in_mask(x :: i64, n :: i64) :: i64 do
      band(bsl(x, n), 0xFFFF)
    end

    defk unmasked(x :: i64, y :: i64) :: i64 do
      p = x * y
      band(p, 0xFFFF)
    end

    defk mulhi_f(a :: i64, b :: i64) :: i64 do
      mulhi(a, b)
    end

    defk counts(a :: i64) :: {i64, i64, i64} do
      {clz(a), ctz(a), popcount(a)}
    end

    defk rot(a :: i64, n :: i64) :: {i64, i64} do
      {rotl(a, n), rotr(a, n)}
    end

    defk counts_w(x :: u64, w :: i64) :: {i64, i64} do
      {clz(x, w), ctz(x, w)}
    end

    defk rot_w(x :: u64, n :: i64, w :: i64) :: {u64, u64} do
      {rotl(x, n, w), rotr(x, n, w)}
    end

    defk rot_w_i(x :: i64, n :: i64, w :: i64) :: i64 do
      rotl(x, n, w)
    end

    defk bits_of(x :: f64) :: u64 do
      f64_bits(x)
    end

    defk crc(crc :: i64, x :: i64, w :: i64) :: i64 do
      crc32c(crc, x, w)
    end

    defk words(b :: [u8], i :: i64) :: {i64, i64, i64} do
      {u64_le(b, i), u32_be(b, i), u16_le(b, i)}
    end
    """,
    calls: [
      "M.mask32(4294967295, 4294967295)",
      "M.mask32(9223372036854775807, 3)",
      "M.mask64(-1, 9223372036854775807)",
      "M.mask64(-9223372036854775808, 2)",
      "M.wrap(9223372036854775807, 2)",
      "M.wrap(-9223372036854775808, -1)",
      "M.shift_in_mask(1, 20)",
      "M.shift_in_mask(1, 64)",
      "M.shift_in_mask(1, -1)",
      "M.unmasked(65537, 2)",
      "M.unmasked(4611686018427387904, 2)",
      "M.mulhi_f(-1, -1)",
      "M.mulhi_f(9223372036854775807, 4)",
      "M.mulhi_f(-9223372036854775808, 2)",
      "M.counts(0)",
      "M.counts(1)",
      "M.counts(-1)",
      "M.counts(-9223372036854775808)",
      "M.rot(1, 63)",
      "M.rot(1, -1)",
      "M.rot(81985529216486895, 64)",
      "M.rot(1, 65)",
      "M.counts_w(1, 32)",
      "M.counts_w(0, 8)",
      "M.counts_w(256, 8)",
      "M.counts_w(1, 65)",
      "M.rot_w(2147483648, 1, 32)",
      "M.rot_w(1, -1, 32)",
      "M.rot_w(18446744073709551615, 7, 64)",
      "M.rot_w_i(2147483648, 1, 32)",
      "M.rot_w_i(1, 62, 64)",
      "M.rot_w_i(1, 63, 64)",
      "M.bits_of(1.0)",
      "M.bits_of(-0.0)",
      "M.bits_of(-2.0)",
      "M.crc(4294967295, 49, 8)",
      "M.crc(0, 4050765991979987505, 64)",
      "M.crc(0, 1, 12)",
      "M.crc(0, 256, 8)",
      "M.crc(4294967296, 0, 8)",
      "M.words(<<255, 255, 255, 255, 255, 255, 255, 255>>, 0)",
      "M.words(<<1, 2, 3, 4, 5, 6, 17, 18, 19>>, 1)",
      "M.words(<<1, 2, 3, 4, 5, 6, 17, 18>>, 1)",
      "M.words(<<1, 2, 3, 4, 5, 6, 17, 18>>, -1)"
    ]
  },
  # ------------------------------------------------ index and ranges --
  %{
    file: "index-errors",
    from: ["test/non_finite_test.exs", "test/range_copy_test.exs", "test/alloc_test.exs"],
    source: ~S"""
    defk get(a :: [f64], i :: i64) :: f64 do
      a[i]
    end

    defk bump(a :: [i64], i :: i64) :: [i64] do
      a[i] = a[i] + 1
      a
    end

    defk gather(a :: [f64], ix :: [i64], k :: i64) :: f64 do
      for i <- 0..(length(ix) - 1)//1, reduce: 0.0 do
        acc -> acc + a[ix[i] * k] * 2.0
      end
    end

    defk zeros(n :: i64) :: [u8] do
      alloc(u8, n)
    end

    defk splice(out :: [u8], at :: i64, src :: [u8], from :: i64, n :: i64) :: [u8] do
      out = copy(out, at, src, from, n)
      out
    end

    defk repeat(out :: [u8], at :: i64, off :: i64, n :: i64) :: [u8] do
      out = copy_back(out, at, off, n)
      out
    end
    """,
    calls: [
      "M.get(<<1.0::float-native, 2.0::float-native>>, 1)",
      "M.get(<<1.0::float-native, 2.0::float-native>>, 2)",
      "M.get(<<1.0::float-native, 2.0::float-native>>, -1)",
      "M.get(<<1, 2, 3>>, 0)",
      "M.bump(<<1::signed-64-native>>, 0)",
      "M.bump(<<>>, 0)",
      "M.gather(<<1.0::float-native, 2.0::float-native>>, <<1::signed-64-native>>, 1)",
      "M.gather(<<1.0::float-native, 2.0::float-native>>, <<1::signed-64-native>>, 2)",
      "M.gather(<<1.0::float-native>>, <<4611686018427387904::signed-64-native>>, 2)",
      "M.zeros(3)",
      "M.zeros(0)",
      "M.zeros(-1)",
      "M.zeros(281474976710657)",
      "M.splice(<<0, 0, 0, 0, 0>>, 1, <<200, 201, 202>>, 0, 3)",
      "M.splice(<<0, 0, 0, 0, 0>>, 3, <<200, 201, 202>>, 0, 3)",
      "M.splice(<<0, 0, 0, 0, 0>>, 0, <<200, 201, 202>>, 2, 2)",
      "M.splice(<<0, 0, 0, 0, 0>>, 0, <<200, 201, 202>>, 0, -1)",
      "M.splice(<<0, 0, 0, 0, 0>>, 5, <<200, 201, 202>>, 3, 0)",
      "M.repeat(<<1, 2, 3, 0, 0, 0, 0>>, 3, 3, 4)",
      "M.repeat(<<1, 2, 3, 0, 0, 0, 0>>, 3, 1, 4)",
      "M.repeat(<<1, 2, 3, 0, 0, 0, 0>>, 3, 0, 4)",
      "M.repeat(<<1, 2, 3, 0, 0, 0, 0>>, 3, 4, 4)",
      "M.repeat(<<1, 2, 3, 0, 0, 0, 0>>, 3, 3, 5)",
      "M.repeat(<<1, 2, 3>>, 3, 0, 0)"
    ]
  },
  # ------------------------------------------------------ non-finite --
  %{
    file: "non-finite",
    from: ["test/non_finite_test.exs", "test/log2_log10_test.exs"],
    source: ~S"""
    defk arith(x :: f64, y :: f64) :: {f64, f64, f64} do
      {x + y, x * y, x / y}
    end

    defk roots(x :: f64) :: {f64, f64, f64, f64} do
      {sqrt(x), log(x), log2(x), log10(x)}
    end

    defk growth(x :: f64, y :: f64) :: {f64, f64} do
      {exp(x), pow(x, y)}
    end

    defk at(a :: [f64], i :: i64) :: f64 do
      a[i]
    end

    defk sum_all(a :: [f64]) :: f64 do
      for x <- a, reduce: 0.0 do
        acc -> acc + x
      end
    end

    defk safe_div(x :: f64, y :: f64) :: f64 do
      if y != 0.0, do: x / y, else: 0.0
    end

    defk trunc_nan(x :: f64, y :: f64) :: i64 do
      trunc((x - y) / (x - y))
    end

    defk compare(i :: i64, x :: f64, y :: f64) :: bool do
      i > x * y
    end
    """,
    calls: [
      "M.arith(1.0, 2.0)",
      "M.arith(1.0e308, 10.0)",
      "M.arith(1.0, 0.0)",
      "M.arith(0.0, 0.0)",
      "M.arith(1.0, -0.0)",
      "M.arith(1.0e-308, 1.0e-308)",
      "M.arith(3, 2)",
      "M.roots(4.0)",
      "M.roots(-1.0)",
      "M.roots(0.0)",
      "M.roots(-0.0)",
      "M.growth(1.0, 2.0)",
      "M.growth(1000.0, 0.0)",
      "M.growth(-1000.0, 0.0)",
      "M.growth(10.0, 400.0)",
      "M.growth(-8.0, 0.5)",
      "M.at(<<0x7FF8000000000000::64-native>>, 0)",
      "M.at(<<0x7FF0000000000000::64-native, 1.0::float-native>>, 1)",
      "M.at(<<0xFFF0000000000000::64-native>>, 0)",
      "M.sum_all(<<1.0::float-native, 0x7FF8000000000000::64-native>>)",
      "M.sum_all(<<1.0e308::float-native, 1.0e308::float-native>>)",
      "M.sum_all(<<>>)",
      "M.safe_div(1.0, 0.0)",
      "M.safe_div(1.0, 4.0)",
      "M.trunc_nan(1.0, 1.0)",
      "M.trunc_nan(3.0, 1.0)",
      "M.compare(1, 1.0e308, 10.0)",
      "M.compare(1, 0.5, 0.5)"
    ]
  },
  # ----------------------------------------------------- comparisons --
  %{
    file: "comparisons",
    from: ["test/comparison_test.exs"],
    source: ~S"""
    defk cmp_if(a :: i64, b :: f64) :: {bool, bool, bool, bool, bool, bool, bool, bool} do
      {a === b, a !== b, a == b, a != b, a < b, a <= b, a > b, a >= b}
    end

    defk cmp_ff(a :: f64, b :: f64) :: {bool, bool, bool, bool, bool, bool, bool, bool} do
      {a === b, a !== b, a == b, a != b, a < b, a <= b, a > b, a >= b}
    end

    defk cmp_ii(a :: i64, b :: i64) :: {bool, bool, bool, bool} do
      {a === b, a == b, a < b, a >= b}
    end

    defk minmax_f(a :: f64, b :: f64) :: {f64, f64} do
      {min(a, b), max(a, b)}
    end

    defk minmax_i(a :: i64, b :: i64) :: {i64, i64} do
      {min(a, b), max(a, b)}
    end

    defk count_below(xs :: [i64], t :: f64) :: i64 do
      for i <- 0..(length(xs) - 1)//1, reduce: 0 do
        acc -> if xs[i] < t, do: acc + 1, else: acc
      end
    end

    defk clip(x :: i64) :: i64 do
      min(max(x, -32_768), 32_767)
    end
    """,
    calls: [
      "M.cmp_if(9007199254740993, 9007199254740992.0)",
      "M.cmp_if(9223372036854775807, 9.223372036854776e18)",
      "M.cmp_if(-9223372036854775808, -9.223372036854776e18)",
      "M.cmp_if(0, -0.0)",
      "M.cmp_if(1, 1.0)",
      "M.cmp_ff(-0.0, 0.0)",
      "M.cmp_ff(0.0, 0.0)",
      "M.cmp_ff(1.0e300, -1.0e300)",
      "M.cmp_ii(-9223372036854775808, 9223372036854775807)",
      "M.cmp_ii(3, 3)",
      "M.minmax_f(-0.0, 0.0)",
      "M.minmax_f(0.0, -0.0)",
      "M.minmax_f(1.0, -1.0e300)",
      "M.minmax_i(-9223372036854775808, 9223372036854775807)",
      "M.minmax_i(3, 3)",
      "M.count_below(<<9007199254740993::64-signed-native, 9007199254740992::64-signed-native, -1::64-signed-native>>, 9007199254740992.0)",
      "M.count_below(<<>>, 0.0)",
      "M.clip(40000)",
      "M.clip(-40000)",
      "M.clip(5)"
    ]
  },
  # ------------------------------------------------------ bitstrings --
  %{
    file: "bitstrings",
    from: ["test/bitstring_test.exs"],
    source: ~S"""
    defk pack(xs :: [i64], n :: i64) :: bitstring do
      for x <- xs, reduce: <<>> do
        acc -> <<acc::bitstring, x::size(n)>>
      end
    end

    defk pack_u64(xs :: [u64], n :: i64) :: bitstring do
      for x <- xs, reduce: <<>> do
        acc -> <<acc::bitstring, x::size(n)>>
      end
    end

    defk pack_signed(xs :: [i64], n :: i64) :: bitstring do
      for x <- xs, reduce: <<>> do
        acc -> <<acc::bitstring, x::size(n)-signed>>
      end
    end

    defk mixed_signed(x :: i64, y :: i64) :: bitstring do
      acc = <<>>
      <<acc::bitstring, x::5-signed, y::3, x::signed-integer-big-size(5), y::signed-8>>
    end

    defk flags(xs :: [i64]) :: {bitstring, i64} do
      acc = <<>>

      acc =
        for x <- xs, reduce: acc do
          acc ->
            if x > 0, do: <<acc::bitstring, 1::1, band(x, 127)::7>>, else: <<acc::bitstring, 0::1>>
        end

      bits = bit_size(acc)
      pad = rem(8 - rem(bits, 8), 8)
      {<<acc::bitstring, 0::size(pad)>>, bits}
    end

    defk forks(x :: i64) :: {bitstring, bitstring, bitstring} do
      a = <<>>
      a = <<a::bitstring, band(x, 7)::3>>
      b = <<a::bitstring, 1::1>>
      c = <<a::bitstring, 0::2>>
      b = <<b::bitstring, x::64>>
      {a, b, c}
    end

    defk zero_width(x :: i64) :: bitstring do
      acc = <<>>
      acc = <<acc::bitstring, 0::0, x::size(0)>>
      if bit_size(acc) == 0, do: <<>>, else: acc
    end

    defk until_negative(xs :: [i64]) :: bitstring do
      Enum.reduce_while(xs, <<>>, fn x, acc ->
        if x < 0, do: {:halt, acc}, else: {:cont, <<acc::bitstring, band(x, 15)::4>>}
      end)
    end
    """,
    calls: [
      "M.pack(<<1::64-native, 2::64-native, 3::64-native>>, 3)",
      "M.pack(<<>>, 3)",
      "M.pack(<<8::64-native>>, 3)",
      "M.pack(<<-1::64-native>>, 64)",
      "M.pack(<<1::64-native>>, 65)",
      "M.pack(<<1::64-native>>, -1)",
      "M.pack_u64(<<18446744073709551615::64-native>>, 64)",
      "M.pack_u64(<<9223372036854775808::64-native>>, 63)",
      "M.pack_signed(<<-1::64-native, -64::64-native, 63::64-native>>, 7)",
      "M.pack_signed(<<64::64-native>>, 7)",
      "M.pack_signed(<<-9223372036854775808::64-native>>, 64)",
      "M.pack_signed(<<-1::64-native>>, 1)",
      "M.pack_signed(<<0::64-native>>, 0)",
      "M.pack_signed(<<1::64-native>>, 0)",
      "M.mixed_signed(-3, 5)",
      "M.mixed_signed(-16, 7)",
      "M.mixed_signed(16, 5)",
      "M.mixed_signed(-1, 8)",
      "M.flags(<<5::64-native, -1::64-native, 200::64-native>>)",
      "M.flags(<<>>)",
      "M.forks(5)",
      "M.forks(-1)",
      "M.zero_width(0)",
      "M.zero_width(7)",
      "M.until_negative(<<1::64-native, 2::64-native, -1::64-native, 3::64-native>>)",
      "M.until_negative(<<>>)"
    ]
  },
  # --------------------------------------------- early exit and case --
  %{
    file: "early-exit-and-case",
    from: ["test/early_exit_test.exs", "test/case_in_test.exs", "test/case_guard_errors_test.exs"],
    source: ~S"""
    defk abs_sum_until(n :: i64, limit :: i64) :: i64 do
      Enum.reduce_while(-n..n//1, 0, fn x, acc ->
        next = if x > 0, do: acc + x, else: acc - x
        if next > limit, do: {:halt, acc}, else: {:cont, next}
      end)
    end

    defk first_div(x :: i64) :: i64 do
      Enum.reduce_while(2..x//1, x, fn d, _ ->
        if rem(x, d) == 0, do: {:halt, d}, else: {:cont, x}
      end)
    end

    defk sum_first_divs(n :: i64) :: i64 do
      for i <- 2..n//1, reduce: 0 do
        acc -> acc + first_div(i)
      end
    end

    defk all_any(n :: i64, k :: i64) :: {bool, bool} do
      {Enum.all?(1..n//1, fn x -> rem(x, k) != 0 end), Enum.any?(1..n//1, fn x -> x * x == k end)}
    end

    defk prime?(x :: i64) :: bool do
      Enum.all?(2..trunc(sqrt(x))//1, fn d -> rem(x, d) != 0 end)
    end

    defk find_at_least(a :: [i64], t :: i64) :: i64 do
      Enum.reduce_while(0..(length(a) - 1)//1, -1, fn i, _ ->
        if a[i] >= t, do: {:halt, i}, else: {:cont, -1}
      end)
    end

    defk sum_until(a :: [i64], stop :: i64, n :: i64) :: i64 do
      Enum.reduce_while(0..n//1, 0, fn i, acc ->
        if i == stop, do: {:halt, acc}, else: {:cont, acc + a[i]}
      end)
    end

    defk until_negative(a :: [f64]) :: {i64, f64} do
      Enum.reduce_while(a, {0, 0.0}, fn x, {n, s} ->
        if x < 0.0, do: {:halt, {n, s}}, else: {:cont, {n + 1, s + x}}
      end)
    end

    defk case_val(x :: i64) :: i64 do
      case x do
        0 -> 10
        -1 -> 30
        n when n > 100 and rem(n, 2) == 0 -> n * 2
        n when n in 1..9 -> n
        _ -> 40
      end
    end

    defk case_guard(x :: i64, y :: i64) :: i64 do
      case x do
        n when div(n, y) > 2 -> 1
        n when rem(n, y) == 1 or n < 0 -> 2
        n when n > 1000 -> 3
        _ -> 0
      end
    end
    """,
    calls: [
      "M.abs_sum_until(3, 100)",
      "M.abs_sum_until(10, 20)",
      "M.first_div(91)",
      "M.first_div(97)",
      "M.first_div(1)",
      "M.sum_first_divs(10)",
      "M.all_any(10, 3)",
      "M.all_any(10, 4)",
      "M.all_any(0, 0)",
      "M.all_any(5, 0)",
      "M.prime?(97)",
      "M.prime?(91)",
      "M.prime?(2)",
      "M.prime?(-1)",
      "M.find_at_least(<<1::64-native, 5::64-native, 9::64-native>>, 5)",
      "M.find_at_least(<<1::64-native, 5::64-native, 9::64-native>>, 10)",
      "M.find_at_least(<<>>, 0)",
      "M.sum_until(<<1::64-native, 2::64-native>>, 2, 5)",
      "M.sum_until(<<1::64-native, 2::64-native>>, 3, 5)",
      "M.sum_until(<<>>, 0, 5)",
      "M.until_negative(<<1.0::float-native, 2.0::float-native, -1.0::float-native, 4.0::float-native>>)",
      "M.until_negative(<<>>)",
      "M.case_val(0)",
      "M.case_val(-1)",
      "M.case_val(102)",
      "M.case_val(101)",
      "M.case_val(9)",
      "M.case_val(10)",
      "M.case_guard(10, 3)",
      "M.case_guard(7, 3)",
      "M.case_guard(2000, 0)",
      "M.case_guard(7, 0)",
      "M.case_guard(-5, 0)",
      "M.case_guard(-5, 1)"
    ]
  },
  # ---------------------------------------------------- multi-clause --
  %{
    file: "multi-clause",
    from: ["test/multi_clause_test.exs"],
    source: ~S"""
    defk pick(x :: i64, y :: i64) :: i64
    defk pick(0, y), do: y
    defk pick(x, 0) when x > 0, do: x * 10
    defk pick(x, y) when x in [1, 2, 3] and y in -5..-1, do: x - y
    defk pick(_x, 7), do: -7

    defk classify(x :: i64, y :: i64) :: i64
    defk classify(x, y) when div(x, y) > 2, do: 1
    defk classify(x, y) when rem(x, y) == 1 or x < 0, do: 2
    defk classify(x, _) when x > 1000, do: 3

    defk choose(c :: bool, a :: f64, b :: f64) :: f64
    defk choose(true, a, _), do: a
    defk choose(false, _, b), do: b * 2.0

    defk swap(a :: i64, b :: i64) :: i64
    defk swap(b, a) when b > a, do: b - a

    defk swap(x, 0) do
      b = x * 2
      b + 1
    end

    defk swap(a, b), do: a * 100 + b

    defk stats(n :: i64, k :: i64) :: {i64, i64}
    defk stats(0, _), do: {0, 0}

    defk stats(n, k) when n > 0 do
      s =
        for i <- 1..n//1, reduce: 0 do
          acc -> acc + i * k
        end

      {n, s}
    end

    defk step(x :: i64) :: i64
    defk step(x) when x >= 0 and x < 100, do: x + 1
    defk step(x) when x < 0, do: x - 1

    defk steps(xs :: [i64]) :: i64 do
      for x <- xs, reduce: 0 do
        acc -> acc + step(x)
      end
    end

    defk dod_bits(acc :: bitstring, dod :: i64) :: bitstring
    defk dod_bits(acc, 0), do: <<acc::bitstring, 0::1>>
    defk dod_bits(acc, dod) when dod >= -64 and dod <= 63, do: <<acc::bitstring, 0b10::2, dod::7-signed>>
    defk dod_bits(acc, dod), do: <<acc::bitstring, 0b11::2, band(dod, 0xFFFFFFFF)::32>>

    defk dods(ds :: [i64]) :: bitstring do
      for d <- ds, reduce: <<>> do
        acc -> dod_bits(acc, d)
      end
    end
    """,
    calls: [
      "M.pick(0, 5)",
      "M.pick(4, 0)",
      "M.pick(2, -3)",
      "M.pick(4, 7)",
      "M.pick(-1, 0)",
      "M.pick(1, -6)",
      "M.classify(10, 3)",
      "M.classify(7, 3)",
      "M.classify(2000, 0)",
      "M.classify(7, 0)",
      "M.choose(true, 1.5, 2.0)",
      "M.choose(false, 1.5, 2.0)",
      "M.swap(5, 3)",
      "M.swap(3, 0)",
      "M.swap(3, 5)",
      "M.swap(0, 0)",
      "M.stats(0, 9)",
      "M.stats(4, 3)",
      "M.stats(-1, 3)",
      "M.steps(<<1::64-native, -1::64-native>>)",
      "M.steps(<<100::64-native>>)",
      "M.dods(<<0::64-native, -1::64-native, 100::64-native>>)",
      "M.dods(<<>>)"
    ]
  },
  # ----------------------------------------------------------- raise --
  %{
    file: "raise",
    from: ["test/raise_test.exs"],
    source: ~S"""
    defk arg(x :: i64) :: i64 do
      if x < 0, do: raise(ArgumentError, "x must not be negative")
      x * 2
    end

    defk arith(x :: i64) :: i64 do
      if x == 0, do: raise(ArithmeticError, "x is zero")
      div(100, x)
    end

    defk runtime(x :: i64) :: i64 do
      if x > 9, do: raise("x is too big")
      x
    end

    defk defaults(x :: i64) :: i64 do
      if x == 1, do: raise(ArgumentError)
      if x == 2, do: raise(ArithmeticError)
      if x == 3, do: raise(RuntimeError)
      x
    end

    defk odd_message(x :: i64) :: i64 do
      if x < 0, do: raise(ArgumentError, "a \"quoted\" \\ back??=slash %s %d, é ünïcode")
      x
    end

    defk in_case(x :: i64) :: i64 do
      case rem(x, 3) do
        0 -> raise ArgumentError, "multiple of three"
        1 -> x
        _ -> x
      end

      x + 1
    end

    defk in_reduce_while(a :: [i64]) :: i64 do
      Enum.reduce_while(0..(length(a) - 1)//1, 0, fn i, acc ->
        if a[i] < 0, do: raise(ArgumentError, "negative element")
        if a[i] == 0, do: {:halt, acc}, else: {:cont, acc + a[i]}
      end)
    end

    defk in_loop(n :: i64, at :: i64) :: i64 do
      for i <- 0..(n - 1)//1, reduce: 0 do
        acc ->
          if i == at, do: raise(RuntimeError, "reached at")
          rem(acc + i * i, 1_000_003)
      end
    end

    defk callee(x :: i64) :: i64 do
      if x == 7, do: raise(ArgumentError, "seven")
      x
    end

    defk caller(x :: i64) :: i64 do
      callee(x) + 1
    end
    """,
    calls: [
      "M.arg(3)",
      "M.arg(-1)",
      "M.arith(5)",
      "M.arith(0)",
      "M.runtime(9)",
      "M.runtime(10)",
      "M.defaults(0)",
      "M.defaults(1)",
      "M.defaults(2)",
      "M.defaults(3)",
      "M.odd_message(-1)",
      "M.in_case(4)",
      "M.in_case(3)",
      "M.in_reduce_while(<<1::64-native, 2::64-native, 0::64-native, 5::64-native>>)",
      "M.in_reduce_while(<<1::64-native, -2::64-native>>)",
      "M.in_loop(10, 100)",
      "M.in_loop(100_000, 99_999)",
      "M.caller(1)",
      "M.caller(7)"
    ]
  },
  # --------------------------------------------------- element types --
  %{
    file: "element-types",
    from: ["test/element_types_test.exs", "test/u64_test.exs"],
    source: ~S"""
    defk at(a :: [i16], b :: [i32], c :: [f32], i :: i64) :: {i64, i64, f64} do
      {a[i], b[i], c[i]}
    end

    defk put16(v :: i64) :: [i16] do
      out = alloc(i16, 2)
      out[1] = v
      out
    end

    defk put32(v :: i64) :: [i32] do
      out = alloc(i32, 2)
      out[1] = v
      out
    end

    defk put8(v :: i64) :: [u8] do
      out = alloc(u8, 2)
      out[1] = v
      out
    end

    defk putf32(v :: f64) :: [f32] do
      out = alloc(f32, 1)
      out[0] = v
      out
    end

    defk roundtrip(v :: f64) :: f64 do
      out = alloc(f32, 1)
      out[0] = v
      out[0] * 2.0
    end

    defk set16(a :: [i16], i :: i64, v :: i64) :: [i16] do
      a[i] = v
      a
    end

    defk sums(a :: [i16], b :: [i32], c :: [f32]) :: {i64, i64, f64} do
      sa =
        for x <- a, reduce: 0 do
          acc -> acc + x
        end

      sb =
        for x <- b, reduce: 0 do
          acc -> acc + x
        end

      sc =
        for x <- c, reduce: 0.0 do
          acc -> acc + x
        end

      {sa, sb, sc}
    end

    defk mix(a :: [i16], b :: [i16]) :: [i16] do
      out = alloc(i16, length(a))

      for i <- 0..(min(length(a), length(b)) - 1)//1 do
        out[i] = max(min(a[i] + b[i], 32_767), -32_768)
      end

      out
    end

    defk put_u64(a :: [u64], i :: i64, x :: i64) :: [u64] do
      a[i] = x
      a
    end

    defk store(a :: [i64], b :: [u8], x :: u64) :: {[i64], [u8]} do
      a[0] = x
      b[0] = x
      {a, b}
    end
    """,
    calls: [
      "M.at(<<-32768::16-native, 1::16-native>>, <<-2147483648::32-native, 1::32-native>>, <<1.5::float-32-native, -0.0::float-32-native>>, 0)",
      "M.at(<<-32768::16-native, 1::16-native>>, <<-2147483648::32-native, 1::32-native>>, <<1.5::float-32-native, -0.0::float-32-native>>, 1)",
      "M.at(<<-32768::16-native, 1::16-native>>, <<-2147483648::32-native, 1::32-native>>, <<1.5::float-32-native, -0.0::float-32-native>>, 2)",
      "M.at(<<1>>, <<>>, <<>>, 0)",
      "M.put16(32767)",
      "M.put16(32768)",
      "M.put16(-32769)",
      "M.put32(-2147483648)",
      "M.put32(2147483648)",
      "M.put8(255)",
      "M.put8(256)",
      "M.put8(-1)",
      "M.putf32(0.1)",
      "M.putf32(3.4028234663852886e38)",
      "M.putf32(1.0e40)",
      "M.putf32(1.0e-50)",
      "M.roundtrip(0.1)",
      "M.roundtrip(1.0e-40)",
      "M.set16(<<1::16-native, 2::16-native>>, 1, -1)",
      "M.set16(<<1::16-native, 2::16-native>>, 2, 0)",
      "M.sums(<<-32768::16-native, -32768::16-native>>, <<-2147483648::32-native, -2147483648::32-native>>, <<0.1::float-32-native, 0.2::float-32-native>>)",
      "M.sums(<<>>, <<>>, <<0x7FC00000::32-native>>)",
      "M.mix(<<30000::16-native, -30000::16-native>>, <<30000::16-native, -30000::16-native>>)",
      "M.mix(<<1::16-native>>, <<>>)",
      "M.put_u64(<<0::64-native>>, 0, 9223372036854775807)",
      "M.put_u64(<<0::64-native>>, 0, -1)",
      "M.store(<<0::64-native>>, <<0>>, 255)",
      "M.store(<<0::64-native>>, <<0>>, 256)",
      "M.store(<<0::64-native>>, <<0>>, 9223372036854775808)"
    ]
  }
]
