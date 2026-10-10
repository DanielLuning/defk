# u64 and masked arithmetic up to 64 bits (defk-wlu, decided in defk-dtw.10):
# a u64 scalar and [u64] element type; band(expr, 2^k - 1) for k <= 64 with
# + - * band bor bxor bnot bsl nesting freely inside (wrapping machine
# arithmetic, Elixir's exact result); the 64-bit mask gives a u64; a u64
# mixed with an i64 that may be negative outside a mask is a compile error
# pointing at the mask; a u64 used as an i64 is checked; and the Defk.Bits
# builtins with a width (clz/2, ctz/2, rotl/3, rotr/3) and f64_to_u64/1.

defmodule Defk.U64Test.K do
  use Defk
  import Bitwise

  @mask64 0xFFFFFFFFFFFFFFFF
  @c1 0x87C37B91114253D5
  @c2 0x4CF5AD432745937F

  # -- scalars: arguments, results, checked arithmetic
  defk(id(x :: u64) :: u64, do: x)
  defk(add(a :: u64, b :: u64) :: u64, do: a + b)
  defk(sub(a :: u64, b :: u64) :: u64, do: a - b)
  defk(mul(a :: u64, b :: u64) :: u64, do: a * b)
  defk(divrem(a :: u64, b :: u64) :: {u64, u64}, do: {div(a, b), rem(a, b)})
  # a literal >= 0 next to a u64 is a u64, and so is len(a)
  defk(inc(a :: u64, b :: [u8]) :: u64, do: a * 2 + 1 + len(b))
  defk(big_literal(a :: u64) :: u64, do: bxor(a, 0xCBF29CE484222325))
  defk(cmp(a :: u64, b :: i64) :: {bool, bool, bool, bool}, do: {a < b, a == b, a === b, b >= a})
  defk(cmpf(a :: u64, f :: f64) :: {bool, bool, bool}, do: {a < f, a == f, f <= a})
  defk(to_i64(a :: u64) :: i64, do: a)
  defk(from_i64(x :: i64) :: u64, do: x)
  defk(to_f(a :: u64) :: {f64, f64}, do: {float(a), a / 2})
  defk(shifts(a :: u64, n :: i64) :: {u64, u64}, do: {bsl(a, n), bsr(a, n)})
  defk(bits(a :: u64, b :: u64) :: {u64, u64, u64}, do: {band(a, b), bor(a, b), bxor(a, b)})
  defk(minmax(a :: u64, b :: u64) :: {u64, u64}, do: {min(a, b), max(a, b)})
  defk(pick(c :: bool, h :: u64) :: u64, do: if(c, do: h, else: 0))
  # a select: both arms are computed, an untaken arm's overflow is not raised
  defk(sel(c :: bool, a :: u64, b :: u64) :: u64, do: if(c, do: a + b, else: a - b))
  # bsr by 58 has the range 0..63: the index needs neither a check nor a conversion
  defk top(t :: [i64], h :: u64) :: i64 do
    t[bsr(h, 58)]
  end

  # -- masks at k = 32, 63, 64
  defk(mask32(x :: i64, y :: i64) :: i64, do: band(x * y + bsl(x, 40), 0xFFFFFFFF))
  defk(mask63(x :: i64, y :: i64) :: i64, do: band(x * y - x, (1 <<< 63) - 1))
  defk(mask64(x :: i64, y :: i64) :: u64, do: band(x * y - x, @mask64))
  defk(mask64_expr(x :: u64, y :: i64) :: u64, do: band(bxor(x, y) * 3, (1 <<< 64) - 1))
  # band(x, 2^64 - 1) is the i64 -> u64 conversion Elixir means
  defk(to_u64(x :: i64) :: u64, do: band(x, @mask64))
  defk(mask32_u(x :: u64) :: i64, do: band(x, 0xFFFFFFFF))

  # band bor bxor bnot and bsl by any count nest inside the mask
  defk bit_tree(x :: u64, y :: u64) :: u64 do
    band(bnot(bxor(x, y)) * 31 + bor(bsl(x, 7), y) - band(x * y, 0xFFFF0000FFFF), @mask64)
  end

  defk rot(x :: u64, r :: i64) :: u64 do
    band(bor(bsl(x, r), bsr(x, 64 - r)), @mask64)
  end

  # outside a mask a u64 is checked: the inner product here raises
  defk(leaf_checked(x :: u64, y :: u64) :: u64, do: band(div(x * y, 3), @mask64))

  # -- accumulators: a literal start becomes a u64 when the new value is one
  defk fnv1a64(b :: [u8]) :: u64 do
    for x <- b, reduce: 0xCBF29CE484222325 do
      h -> band(bxor(h, x) * 0x100000001B3, @mask64)
    end
  end

  defk hsum(hs :: [u64]) :: u64 do
    for h <- hs, reduce: 0 do
      acc -> band(acc + h * 3, @mask64)
    end
  end

  # a checked u64 sum from 0: acc + h makes acc a u64
  defk total(hs :: [u64]) :: u64 do
    for h <- hs, reduce: 0 do
      acc -> acc + h
    end
  end

  defk count_hash(b :: [u8]) :: {i64, u64} do
    for x <- b, reduce: {0, 0} do
      {n, h} -> {n + 1, band((h + x) * 31, @mask64)}
    end
  end

  defk hash_until(b :: [u8], stop :: i64) :: u64 do
    Enum.reduce_while(b, 0, fn x, h ->
      if x == stop,
        do: {:halt, h},
        else: {:cont, band(bxor(h, x) * 0x100000001B3, @mask64)}
    end)
  end

  # -- [u64] arrays
  defk scale(a :: [u64], k :: u64) :: [u64] do
    out = alloc(u64, len(a))
    for i <- 0..(len(a) - 1)//1, do: out[i] = band(a[i] * k, @mask64)
    out
  end

  defk put_i64(a :: [u64], i :: i64, x :: i64) :: [u64] do
    a[i] = x
    a
  end

  defk store(a :: [i64], b :: [u8], x :: u64) :: {[i64], [u8]} do
    a[0] = x
    b[0] = x
    {a, b}
  end

  # -- hashes against published vectors
  defk murmur3_32(data :: [u8], seed :: i64) :: i64 do
    n = len(data)
    nb = div(n, 4)

    h =
      for i <- 0..(nb - 1)//1, reduce: seed do
        h ->
          k = band(u32_le(data, i * 4) * 0xCC9E2D51, 0xFFFFFFFF)
          k = band(rotl(k, 15, 32) * 0x1B873593, 0xFFFFFFFF)
          band(Defk.Bits.rotl(bxor(h, k), 13, 32) * 5 + 0xE6546B64, 0xFFFFFFFF)
      end

    t = nb * 4
    r = n - t
    k = if r >= 3, do: bsl(data[t + 2], 16), else: 0
    k = if r >= 2, do: bxor(k, bsl(data[t + 1], 8)), else: k
    k = if r >= 1, do: bxor(k, data[t]), else: k

    h =
      if r >= 1,
        do:
          bxor(h, band(rotl(band(k * 0xCC9E2D51, 0xFFFFFFFF), 15, 32) * 0x1B873593, 0xFFFFFFFF)),
        else: h

    h = bxor(h, n)
    h = band(bxor(h, bsr(h, 16)) * 0x85EBCA6B, 0xFFFFFFFF)
    h = band(bxor(h, bsr(h, 13)) * 0xC2B2AE35, 0xFFFFFFFF)
    bxor(h, bsr(h, 16))
  end

  defk fmix64(k :: u64) :: u64 do
    k = band(bxor(k, bsr(k, 33)) * 0xFF51AFD7ED558CCD, @mask64)
    k = band(bxor(k, bsr(k, 33)) * 0xC4CEB9FE1A85EC53, @mask64)
    bxor(k, bsr(k, 33))
  end

  # the cnt (<= 8) bytes at `at`, little-endian
  defk tail_word(data :: [u8], at :: i64, cnt :: i64) :: u64 do
    for j <- 0..(cnt - 1)//1, reduce: 0 do
      k -> band(bor(k, bsl(data[at + j], 8 * j)), @mask64)
    end
  end

  # MurmurHash3_x64_128
  defk murmur3_128(data :: [u8], seed :: u64) :: {u64, u64} do
    n = len(data)
    nb = div(n, 16)

    {h1, h2} =
      for i <- 0..(nb - 1)//1, reduce: {seed, seed} do
        {h1, h2} ->
          k1 = band(u64_le(data, i * 16) * @c1, @mask64)
          k1 = band(rotl(k1, 31, 64) * @c2, @mask64)
          h1 = bxor(h1, k1)
          h1 = band((rotl(h1, 27, 64) + h2) * 5 + 0x52DCE729, @mask64)
          k2 = band(u64_le(data, i * 16 + 8) * @c2, @mask64)
          k2 = band(rotl(k2, 33, 64) * @c1, @mask64)
          h2 = bxor(h2, k2)
          h2 = band((rotl(h2, 31, 64) + h1) * 5 + 0x38495AB5, @mask64)
          {h1, h2}
      end

    t = nb * 16
    r = n - t
    k2 = tail_word(data, t + 8, r - 8)

    h2 =
      if r > 8, do: bxor(h2, band(rotl(band(k2 * @c2, @mask64), 33, 64) * @c1, @mask64)), else: h2

    k1 = tail_word(data, t, min(r, 8))

    h1 =
      if r > 0, do: bxor(h1, band(rotl(band(k1 * @c1, @mask64), 31, 64) * @c2, @mask64)), else: h1

    h1 = bxor(h1, n)
    h2 = bxor(h2, n)
    h1 = band(h1 + h2, @mask64)
    h2 = band(h2 + h1, @mask64)
    h1 = fmix64(h1)
    h2 = fmix64(h2)
    h1 = band(h1 + h2, @mask64)
    {h1, band(h2 + h1, @mask64)}
  end

  # -- Defk.Bits builtins
  defk(clz2(x :: u64, w :: i64) :: i64, do: clz(x, w))
  defk(clz2_i(x :: i64, w :: i64) :: i64, do: Defk.Bits.clz(x, w))
  defk(ctz2(x :: u64, w :: i64) :: i64, do: ctz(x, w))
  defk(ctz2_i(x :: i64, w :: i64) :: i64, do: Defk.Bits.ctz(x, w))
  defk(rotl3(x :: u64, n :: i64, w :: i64) :: u64, do: rotl(x, n, w))
  defk(rotl3_i(x :: i64, n :: i64, w :: i64) :: i64, do: rotl(x, n, w))
  defk(rotr3(x :: u64, n :: i64, w :: i64) :: u64, do: Defk.Bits.rotr(x, n, w))
  defk(rotr3_i(x :: i64, n :: i64, w :: i64) :: i64, do: rotr(x, n, w))
  defk(popcount_u(x :: u64) :: i64, do: Defk.Bits.popcount(x))
  defk(f64_bits(x :: f64) :: u64, do: f64_to_u64(x))
  defk(f64_bits_i(x :: i64) :: u64, do: Defk.Bits.f64_to_u64(x))
end

defmodule Defk.U64Test do
  use ExUnit.Case, async: true
  use Defk.Properties

  import Bitwise

  alias Defk.U64Test.K

  @max 0x7FFFFFFFFFFFFFFF
  @min -0x8000000000000000
  @umax 0xFFFFFFFFFFFFFFFF
  @u64s [0, 1, 2, 3, 255, 2 ** 32 - 1, 2 ** 32, @max - 1, @max, @max + 1, @umax - 1, @umax] ++
          [0x5555555555555555, 0xCBF29CE484222325]
  @i64s [0, 1, -1, 2, 255, -256, 2 ** 32, @min, @min + 1, @max, @max - 1, 3_037_000_500]

  defp agrees(fun, args), do: Defk.Test.assert_agrees(K, fun, args)

  # the exact result, or :overflow for an ArithmeticError of that reason
  defp outcome(fun, args) do
    case agrees(fun, args) do
      {:raise, %ArithmeticError{} = e} -> {:raise, Defk.Test.reason(e)}
      {:raise, %ArgumentError{} = e} -> {:raise, Defk.Test.reason(e)}
      other -> other
    end
  end

  defp u64?(x), do: x in 0..@umax
  defp checked(x), do: if(u64?(x), do: {:ok, x}, else: {:raise, :overflow})

  test "u64 arguments, results and checked arithmetic" do
    for a <- @u64s, b <- @u64s do
      assert outcome(:id, [a]) == {:ok, a}
      assert outcome(:add, [a, b]) == checked(a + b)
      assert outcome(:sub, [a, b]) == checked(a - b)
      assert outcome(:mul, [a, b]) == checked(a * b)
      assert outcome(:bits, [a, b]) == {:ok, {band(a, b), bor(a, b), bxor(a, b)}}
      assert outcome(:minmax, [a, b]) == {:ok, {min(a, b), max(a, b)}}

      if b == 0,
        do: assert(outcome(:divrem, [a, b]) == {:raise, :zero_divisor}),
        else: assert(outcome(:divrem, [a, b]) == {:ok, {div(a, b), rem(a, b)}})
    end

    assert outcome(:inc, [5, "abc"]) == {:ok, 14}
    assert outcome(:inc, [@max, ""]) == {:ok, @umax}
    assert outcome(:inc, [@max, "a"]) == {:raise, :overflow}
    assert outcome(:big_literal, [0]) == {:ok, 0xCBF29CE484222325}

    assert_raise ArgumentError, "argument 1 (x) must be an integer fitting in u64", fn ->
      K.id(-1)
    end

    assert_raise ArgumentError, fn -> K.id(2 ** 64) end
    assert_raise ArithmeticError, "u64 overflow in #{@umax} + 1", fn -> K.add(@umax, 1) end
    assert_raise ArithmeticError, "u64 overflow in 3 - 5", fn -> K.sub(3, 5) end
  end

  test "a u64 compares with an i64 or f64 by exact value; === holds for equal integers" do
    for a <- @u64s, b <- @i64s ++ @u64s, b in @min..@max do
      assert outcome(:cmp, [a, b]) == {:ok, {a < b, a == b, a === b, b >= a}}
    end

    fs = [0.0, -1.0, 1.0, 9_223_372_036_854_775_808.0, 18_446_744_073_709_551_616.0, 1.0e300]

    for a <- @u64s, f <- fs do
      assert outcome(:cmpf, [a, f]) == {:ok, {a < f, a == f, f <= a}}
    end
  end

  test "a u64 where an i64 is expected is checked, and back" do
    for a <- @u64s,
        do:
          assert(outcome(:to_i64, [a]) == if(a <= @max, do: {:ok, a}, else: {:raise, :overflow}))

    for x <- @i64s,
        do: assert(outcome(:from_i64, [x]) == if(x >= 0, do: {:ok, x}, else: {:raise, :overflow}))

    assert_raise ArithmeticError, "#{@max + 1} does not fit in i64", fn -> K.to_i64(@max + 1) end
  end

  test "u64 to float rounds as Elixir does" do
    for a <- @u64s ++ [2 ** 63 + 1025, 2 ** 63 + 1024, 2 ** 64 - 1025, 2 ** 53 + 1] do
      assert outcome(:to_f, [a]) == {:ok, {:erlang.float(a), a / 2}}
    end

    for _ <- 1..200, do: agrees(:to_f, [:rand.uniform(2 ** 64) - 1])
  end

  test "u64 shifts are exact: bsr is logical, bsl raises past 2^64 - 1" do
    for a <- @u64s, n <- [0, 1, 5, 31, 32, 63, 64, 65, 200, -1, -63, -64, -65, @min, @max] do
      exact = fn f -> if n > 128 or n < -128, do: :big, else: f.(a, n) end
      l = exact.(&bsl/2)
      r = exact.(&bsr/2)

      expect_l =
        cond do
          l == :big and n > 0 -> if a == 0, do: 0, else: :overflow
          l == :big -> 0
          u64?(l) -> l
          true -> :overflow
        end

      expect_r =
        cond do
          r == :big and n < 0 -> if a == 0, do: 0, else: :overflow
          r == :big -> 0
          u64?(r) -> r
          true -> :overflow
        end

      expect =
        if :overflow in [expect_l, expect_r],
          do: {:raise, :overflow},
          else: {:ok, {expect_l, expect_r}}

      assert outcome(:shifts, [a, n]) == expect
    end
  end

  test "an if of a u64 and an i64 literal is a u64; a bounded bsr indexes without a check" do
    for c <- [true, false],
        h <- @u64s,
        do: assert(outcome(:pick, [c, h]) == {:ok, if(c, do: h, else: 0)})

    for c <- [true, false], a <- @u64s, b <- @u64s do
      assert outcome(:sel, [c, a, b]) == checked(if(c, do: a + b, else: a - b))
    end

    t = Defk.Generators.pack(:i64, Enum.to_list(100..163))
    for h <- @u64s, do: assert(outcome(:top, [t, h]) == {:ok, 100 + bsr(h, 58)})

    src = K.__defk_source__()
    [top] = Regex.run(~r/---- top\/2.*?---- /s, src)
    refute top =~ "defk_get_i64("
    refute top =~ "defk_u64_to_i64("
  end

  test "masks at k = 32, 63 and 64 give Elixir's exact result" do
    for x <- @i64s, y <- @i64s do
      assert outcome(:mask32, [x, y]) == {:ok, band(x * y + (x <<< 40), 0xFFFFFFFF)}
      assert outcome(:mask63, [x, y]) == {:ok, band(x * y - x, @max)}
      assert outcome(:mask64, [x, y]) == {:ok, band(x * y - x, @umax)}
      assert outcome(:to_u64, [x]) == {:ok, band(x, @umax)}
    end

    for x <- @u64s, y <- @i64s do
      assert outcome(:mask64_expr, [x, y]) == {:ok, band(bxor(x, y) * 3, @umax)}
      assert outcome(:mask32_u, [x]) == {:ok, band(x, 0xFFFFFFFF)}
    end

    # the boundaries themselves
    assert K.mask64(-1, 2) == @umax
    assert K.mask64(-1, 3) == @umax - 1
    assert K.to_u64(-1) == @umax
    assert K.to_u64(@min) == 2 ** 63
    assert K.mask63(-1, 2) == @max
    assert K.mask63(@min, 3) == 0
    assert K.mask32(@max, @max) == band(@max * @max + (@max <<< 40), 0xFFFFFFFF)
  end

  test "band, bor, bxor, bnot and bsl by a variable count nest inside the mask" do
    for x <- @u64s, y <- @u64s do
      expect =
        band(bnot(bxor(x, y)) * 31 + bor(x <<< 7, y) - band(x * y, 0xFFFF0000FFFF), @umax)

      assert outcome(:bit_tree, [x, y]) == {:ok, expect}
    end

    for x <- @u64s, r <- 0..64 do
      assert outcome(:rot, [x, r]) == {:ok, band(bor(x <<< r, x >>> (64 - r)), @umax)}
    end

    # a negative count inside a mask raises (a limit); bsr's count is a leaf
    assert outcome(:rot, [5, -1]) == {:raise, :negative_shift}
    assert outcome(:rot, [5, 65]) == {:ok, 10}
    assert outcome(:rot, [@umax, 65]) == {:raise, :overflow}
    assert outcome(:rot, [0, 140]) == {:ok, 0}
  end

  test "a leaf of a masked expression stays checked" do
    assert outcome(:leaf_checked, [@max, 2]) == {:ok, div(@max * 2, 3)}
    assert outcome(:leaf_checked, [@max, 3]) == {:raise, :overflow}
  end

  # FNV-1a over bignums, as written without a kernel
  defp fnv1a(bytes),
    do:
      for(<<b <- bytes>>,
        reduce: 0xCBF29CE484222325,
        do: (h -> band(bxor(h, b) * 0x100000001B3, @umax))
      )

  test "FNV-1a 64 as a u64 agrees with bignums and the published vectors" do
    for bytes <- ["", "a", "foobar", :crypto.strong_rand_bytes(1000)] do
      assert outcome(:fnv1a64, [bytes]) == {:ok, fnv1a(bytes)}
    end

    # http://www.isthe.com/chongo/tech/comp/fnv/ test vectors
    assert K.fnv1a64("") == 0xCBF29CE484222325
    assert K.fnv1a64("a") == 0xAF63DC4C8601EC8C
    assert K.fnv1a64("foobar") == 0x85944171F73967E8
  end

  test "an accumulator starting from a literal becomes a u64 when it meets one" do
    for n <- [0, 1, 5, 100] do
      hs = for _ <- 1..n//1, do: :rand.uniform(2 ** 64) - 1
      bin = Defk.Generators.pack(:u64, hs)
      assert outcome(:hsum, [bin]) == {:ok, Enum.reduce(hs, 0, &band(&2 + &1 * 3, @umax))}
      total = Enum.sum(hs)
      assert outcome(:total, [bin]) == checked(total)
    end

    assert outcome(:total, [Defk.Generators.pack(:u64, [@umax])]) == {:ok, @umax}

    for bytes <- ["", "abc", :crypto.strong_rand_bytes(300)] do
      h = for <<b <- bytes>>, reduce: 0, do: (h -> band((h + b) * 31, @umax))
      assert outcome(:count_hash, [bytes]) == {:ok, {byte_size(bytes), h}}

      stop = 7
      prefix = bytes |> :binary.split(<<stop>>) |> hd()
      expect = for <<b <- prefix>>, reduce: 0, do: (h -> band(bxor(h, b) * 0x100000001B3, @umax))
      assert outcome(:hash_until, [bytes, stop]) == {:ok, expect}
    end
  end

  test "[u64] arrays: reads, writes, alloc, and element range" do
    a = Defk.Generators.pack(:u64, @u64s)
    expect = Defk.Generators.pack(:u64, Enum.map(@u64s, &band(&1 * 0x100000001B3, @umax)))
    assert outcome(:scale, [a, 0x100000001B3]) == {:ok, expect}
    assert outcome(:put_i64, [a, 0, 5]) |> elem(0) == :ok
    assert outcome(:put_i64, [a, 0, -1]) == {:raise, :element_range}
    assert {:raise, %Enum.OutOfBoundsError{}} = outcome(:put_i64, [a, 99, 1])

    i = Defk.Generators.pack(:i64, [0])
    b = <<0>>
    assert outcome(:store, [i, b, 200]) == {:ok, {Defk.Generators.pack(:i64, [200]), <<200>>}}
    assert outcome(:store, [i, b, 300]) == {:raise, :element_range}
    assert outcome(:store, [i, b, @max + 1]) == {:raise, :element_range}
    assert_raise ArgumentError, "value -1 does not fit in u64", fn -> K.put_i64(a, 0, -1) end
  end

  @mm32 [
    {"", 0, 0x00000000},
    {"", 1, 0x514E28B7},
    {"", 0xFFFFFFFF, 0x81F16F39},
    {"a", 0x9747B28C, 0x7FA09EA6},
    {"abc", 0, 0xB3DD93FA},
    {"test", 0, 0xBA6BD213},
    {"Hello, world!", 0x9747B28C, 0x24884CBA},
    {"The quick brown fox jumps over the lazy dog", 0, 0x2E4FF723},
    {"0123456789abcdefg", 1, 0x22799205}
  ]

  # MurmurHash3_x64_128 of the reference implementation (SMHasher)
  @mm128 [
    {"", 0, 0x0000000000000000, 0x0000000000000000},
    {"", 1, 0x4610ABE56EFF5CB5, 0x51622DAA78F83583},
    {"a", 0x9747B28C, 0x5CE8D8512DB25A1D, 0x9E6DAB0F9208F004},
    {"abc", 0xFFFFFFFF, 0x5A2D798580260F18, 0x5BF10E33D36C3789},
    {"Hello, world!", 0, 0xF1512DD1D2D665DF, 0x2C326650A8F3C564},
    {"The quick brown fox jumps over the lazy dog", 0, 0xE34BBC7BBC071B6C, 0x7A433CA9C49A9347},
    {"0123456789abcdef", 1, 0xFDFF0577812EBB41, 0x12C6078B2336AAE6},
    {"0123456789abcdefg", 0x9747B28C, 0xC0BF962BFD77A52B, 0xBD74AF14707CE362}
  ]

  test "MurmurHash3 x86_32 and x64_128 match the reference vectors in both modes" do
    for {s, seed, h} <- @mm32, do: assert(outcome(:murmur3_32, [s, seed]) == {:ok, h})

    for {s, seed, h1, h2} <- @mm128,
        do: assert(outcome(:murmur3_128, [s, seed]) == {:ok, {h1, h2}})

    for n <- [0, 1, 7, 8, 9, 15, 16, 17, 31, 33, 100] do
      bytes = :crypto.strong_rand_bytes(n)
      agrees(:murmur3_32, [bytes, :rand.uniform(2 ** 32) - 1])
      agrees(:murmur3_128, [bytes, :rand.uniform(2 ** 64) - 1])
    end
  end

  test "u64 accumulators and [u64] loops survive forced yields" do
    bytes = :crypto.strong_rand_bytes(5000)
    hs = for _ <- 1..3000, do: :rand.uniform(2 ** 50)
    bin = Defk.Generators.pack(:u64, hs)

    expect = %{
      fnv: fnv1a(bytes),
      hsum: Enum.reduce(hs, 0, &band(&2 + &1 * 3, @umax)),
      total: Enum.sum(hs),
      count: K.count_hash(bytes),
      until: K.hash_until(bytes, 300),
      mm: K.murmur3_128(bytes, 7),
      scale: K.scale(bin, 3)
    }

    K.__defk_force_yields__(true)

    try do
      y0 = K.__defk_stats__().yields

      got = %{
        fnv: K.fnv1a64(bytes),
        hsum: K.hsum(bin),
        total: K.total(bin),
        count: K.count_hash(bytes),
        until: K.hash_until(bytes, 300),
        mm: K.murmur3_128(bytes, 7),
        scale: K.scale(bin, 3)
      }

      assert K.__defk_stats__().yields - y0 > 0
      assert got == expect
    after
      K.__defk_force_yields__(false)
    end
  end

  # -------------------------------------------------------------- Defk.Bits --

  defp bits_outcome(f) do
    {:ok, f.()}
  rescue
    e -> {:raise, e.__struct__, Defk.Test.reason(e)}
  end

  # the kernel's result is the Elixir function's (and both modes agree)
  defp same_as_bits(fun, bits_fun, args) do
    native = agrees(fun, args)

    got =
      case native do
        {:ok, v} -> {:ok, v}
        {:raise, e} -> {:raise, e.__struct__, Defk.Test.reason(e)}
      end

    assert got == bits_outcome(fn -> apply(Defk.Bits, bits_fun, args) end),
           "#{fun}#{inspect(args)}"
  end

  test "clz/2, ctz/2, rotl/3, rotr/3, popcount/1 and f64_to_u64/1 are their Elixir bodies" do
    ws = [-1, 0, 1, 7, 8, 31, 32, 33, 63, 64, 65]
    ns = [0, 1, -1, 13, 31, 32, 63, 64, 65, -64, @min, @max]

    for x <- @u64s, w <- ws do
      same_as_bits(:clz2, :clz, [x, w])
      same_as_bits(:ctz2, :ctz, [x, w])
      for n <- ns, do: same_as_bits(:rotl3, :rotl, [x, n, w])
      for n <- ns, do: same_as_bits(:rotr3, :rotr, [x, n, w])
    end

    # an i64 x: negative raises ArgumentError; rotl/rotr of an i64 give an
    # i64, checked, so a 64-bit rotation past 2^63 - 1 raises
    for x <- @i64s, w <- ws do
      same_as_bits(:clz2_i, :clz, [x, w])
      same_as_bits(:ctz2_i, :ctz, [x, w])

      for n <- ns do
        agrees(:rotl3_i, [x, n, w])
        agrees(:rotr3_i, [x, n, w])
      end
    end

    assert outcome(:rotl3_i, [1, 63, 64]) == {:raise, :overflow}
    assert outcome(:rotl3_i, [1, 62, 64]) == {:ok, 2 ** 62}
    assert outcome(:rotl3_i, [-1, 1, 32]) == {:raise, :bits_range}

    for x <- @u64s, do: assert(outcome(:popcount_u, [x]) == {:ok, Defk.Bits.popcount(x)})

    for x <- [0.0, -0.0, 1.0, -2.5, 1.0e300, 5.0e-324, 2.2250738585072014e-308] do
      assert outcome(:f64_bits, [x]) == {:ok, Defk.Bits.f64_to_u64(x)}
    end

    for x <- @i64s, do: assert(outcome(:f64_bits_i, [x]) == {:ok, Defk.Bits.f64_to_u64(x)})
  end

  test "plain Elixir can call the Defk.Bits functions; bad arguments raise ArgumentError" do
    assert Defk.Bits.clz(1, 32) == 31
    assert Defk.Bits.rotl(0xDEADBEEF, 8, 32) == 0xADBEEFDE

    assert_raise ArgumentError, "Defk.Bits.clz/2: width 0 is not in 1..64", fn ->
      Defk.Bits.clz(1, 0)
    end

    assert_raise ArgumentError, "Defk.Bits.rotl/3: 256 does not fit in a 8-bit field", fn ->
      Defk.Bits.rotl(256, 1, 8)
    end
  end

  # ------------------------------------------------------------ rejections --

  @dir Path.join(System.tmp_dir!(), "defk_u64_test")

  defp rejection(body, sig, ret \\ "u64") do
    File.mkdir_p!(@dir)
    mod = "Defk.U64Test.Rej#{System.unique_integer([:positive])}"
    path = Path.join(@dir, "#{String.replace(mod, ".", "_")}.ex")

    File.write!(path, """
    defmodule #{mod} do
      use Defk

      defk f(#{sig}) :: #{ret} do
        #{body}
      end
    end
    """)

    e = assert_raise CompileError, fn -> Code.compile_file(path) end
    Exception.message(e)
  end

  defp codes(msg),
    do: Regex.scan(~r/^\(defk ([a-z0-9-]+)[:;] /m, msg) |> Enum.map(&Enum.at(&1, 1))

  test "mixing a u64 with an i64 that may be negative outside a mask is rejected with the mask as the fix" do
    msg = rejection("h * 31 + x", "h :: u64, x :: i64")
    assert codes(msg) == ["u64-mix"]
    assert msg =~ "mixes a u64 with an i64 that may be negative"
    assert msg =~ "band(h * 31 + x, 0xFFFFFFFFFFFFFFFF)"
    assert msg =~ "inside band"

    assert codes(rejection("bxor(h, x)", "h :: u64, x :: i64")) == ["u64-mix"]
    assert codes(rejection("div(h, x)", "h :: u64, x :: i64")) == ["u64-mix"]
    assert codes(rejection("-h", "h :: u64")) == ["operand-type"]
    assert codes(rejection("bnot(h)", "h :: u64")) == ["operand-type"]

    assert codes(rejection("if c, do: h, else: x", "c :: bool, h :: u64, x :: i64")) == [
             "branch-types"
           ]

    assert codes(rejection("band(x, 0x1FFFFFFFFFFFFFFFF)", "x :: i64")) == ["integer-literal"]
  end

  # ---------------------------------------------------- agreement properties --

  defp bytes, do: G.array(:u8, max_length: 100)
  defp u64s, do: G.array(:u64, max_length: 40)
  defp seed32, do: G.i64(0..0xFFFFFFFF)

  agreement(K,
    id: [],
    add: [],
    sub: [],
    mul: [],
    divrem: [],
    inc: [],
    big_literal: [],
    cmp: [],
    cmpf: [],
    to_i64: [],
    from_i64: [],
    to_f: [],
    shifts: [args: fixed_list([G.u64(), G.i64(-130..130, [@min, @max])])],
    bits: [],
    minmax: [],
    pick: [],
    sel: [],
    top: [args: fixed_list([G.array(:i64, length: 64), G.u64()])],
    mask32: [],
    mask63: [],
    mask64: [],
    mask64_expr: [],
    to_u64: [],
    mask32_u: [],
    bit_tree: [],
    rot: [args: fixed_list([G.u64(), G.i64(-70..140)])],
    leaf_checked: [],
    fnv1a64: [args: fixed_list([bytes()])],
    hsum: [args: fixed_list([u64s()])],
    total: [args: fixed_list([u64s()])],
    count_hash: [args: fixed_list([bytes()])],
    hash_until: [args: fixed_list([bytes(), G.i64(0..255)])],
    scale: [args: fixed_list([u64s(), G.u64()])],
    put_i64: [args: fixed_list([u64s(), G.i64(-2..50), G.i64()])],
    store: [args: fixed_list([G.array(:i64, length: 1), G.array(:u8, length: 1), G.u64()])],
    murmur3_32: [args: fixed_list([bytes(), seed32()])],
    fmix64: [],
    tail_word: [args: fixed_list([bytes(), G.i64(-2..120), G.i64(-1..8)])],
    murmur3_128: [args: fixed_list([bytes(), G.u64()])],
    clz2: [args: fixed_list([G.u64(), G.i64(-1..65)])],
    clz2_i: [args: fixed_list([G.i64(), G.i64(-1..65)])],
    ctz2: [args: fixed_list([G.u64(), G.i64(-1..65)])],
    ctz2_i: [args: fixed_list([G.i64(), G.i64(-1..65)])],
    rotl3: [args: fixed_list([G.u64(), G.i64(), G.i64(-1..65)])],
    rotl3_i: [args: fixed_list([G.i64(), G.i64(), G.i64(-1..65)])],
    rotr3: [args: fixed_list([G.u64(), G.i64(), G.i64(-1..65)])],
    rotr3_i: [args: fixed_list([G.i64(), G.i64(), G.i64(-1..65)])],
    popcount_u: [],
    f64_bits: [],
    f64_bits_i: []
  )
end
