# cos and sin of one argument in one loop must not fuse into a platform
# sincos (Darwin's __sincos_stret, glibc's sincos), whose sin differs from
# libm's sin, and so from :math.sin, in the last bit (defk-6g6). The other
# libm builtins are probed for substitutions the same way: pow(x, 0.5) as
# sqrt, pow(x, 2.0) as x*x, exp(x) - 1.0 as expm1, log(1.0 + x) as log1p.

defmodule Defk.SincosTest.K do
  use Defk

  defk cs(a :: [f64]) :: {[f64], [f64]} do
    n = len(a)
    c = alloc(f64, n)
    s = alloc(f64, n)

    for i <- 0..(n - 1)//1 do
      c[i] = cos(a[i])
      s[i] = sin(a[i])
    end

    {c, s}
  end

  defk p_sqrt(a :: [f64]) :: [f64] do
    n = len(a)
    o = alloc(f64, n)

    for i <- 0..(n - 1)//1 do
      o[i] = sqrt(a[i])
    end

    o
  end

  defk p_exp(a :: [f64]) :: [f64] do
    n = len(a)
    o = alloc(f64, n)

    for i <- 0..(n - 1)//1 do
      o[i] = exp(a[i])
    end

    o
  end

  defk p_log(a :: [f64]) :: [f64] do
    n = len(a)
    o = alloc(f64, n)

    for i <- 0..(n - 1)//1 do
      o[i] = log(a[i])
    end

    o
  end

  defk p_log2(a :: [f64]) :: [f64] do
    n = len(a)
    o = alloc(f64, n)

    for i <- 0..(n - 1)//1 do
      o[i] = log2(a[i])
    end

    o
  end

  defk p_log10(a :: [f64]) :: [f64] do
    n = len(a)
    o = alloc(f64, n)

    for i <- 0..(n - 1)//1 do
      o[i] = :math.log10(a[i])
    end

    o
  end

  defk p_pow_half(a :: [f64]) :: [f64] do
    n = len(a)
    o = alloc(f64, n)

    for i <- 0..(n - 1)//1 do
      o[i] = pow(a[i], 0.5)
    end

    o
  end

  defk p_pow_two(a :: [f64]) :: [f64] do
    n = len(a)
    o = alloc(f64, n)

    for i <- 0..(n - 1)//1 do
      o[i] = pow(a[i], 2.0)
    end

    o
  end

  defk p_expm1(a :: [f64]) :: [f64] do
    n = len(a)
    o = alloc(f64, n)

    for i <- 0..(n - 1)//1 do
      o[i] = exp(a[i]) - 1.0
    end

    o
  end

  defk p_log1p(a :: [f64]) :: [f64] do
    n = len(a)
    o = alloc(f64, n)

    for i <- 0..(n - 1)//1 do
      o[i] = log(1.0 + a[i])
    end

    o
  end

  defk p_abs(a :: [f64]) :: [f64] do
    n = len(a)
    o = alloc(f64, n)

    for i <- 0..(n - 1)//1 do
      o[i] = abs(a[i])
    end

    o
  end

  defk p_round(a :: [f64]) :: [i64] do
    n = len(a)
    o = alloc(i64, n)

    for i <- 0..(n - 1)//1 do
      o[i] = round(a[i])
    end

    o
  end

  defk p_trunc(a :: [f64]) :: [i64] do
    n = len(a)
    o = alloc(i64, n)

    for i <- 0..(n - 1)//1 do
      o[i] = trunc(a[i])
    end

    o
  end
end

defmodule Defk.SincosTest do
  use ExUnit.Case, async: true
  use Defk.Properties

  alias Defk.SincosTest.K

  # the FFT example's twiddle arguments at n = 4096: native sin differed
  # from :math.sin in the last bit for 7 of these 2048
  defp twiddle_args(n) do
    for k <- 0..(div(n, 2) - 1), into: <<>> do
      <<-2.0 * 3.141592653589793 * k / n::float-native-64>>
    end
  end

  test "one-loop cos and sin agree with Elixir mode at the 4096-point FFT twiddles" do
    Defk.Test.assert_agrees(K, :cs, [twiddle_args(4096)])
  end

  test "the one-loop kernel's sin equals :math.sin for every twiddle" do
    {_c, s} = K.cs(twiddle_args(4096))

    expect =
      for k <- 0..2047,
          into: <<>>,
          do: <<:math.sin(-2.0 * 3.141592653589793 * k / 4096)::float-native-64>>

    assert s === expect
  end

  # |x| <= 1.0e6 keeps the run fast; huge arguments are fine too
  defp bounded, do: fixed_list([G.array(:f64, of: G.f64(1.0e6))])

  # the libm probes: the full edge mix (negative and huge arguments make
  # sqrt/log raise, which both modes must do alike) and the nearly-safe range
  defp probe_args, do: one_of([fixed_list([G.array(:f64)]), bounded()])

  # exp and pow overflow to inf for large arguments, which Elixir mode raises
  # on and the kernel does not (defk-i00): keep their arguments small
  # pow(x, 0.5) of a negative x is NaN, which an array store does not reject
  # (unlike a scalar result): not a libm substitution, so out of this probe
  defp non_negative do
    fixed_list([G.array(:f64, of: StreamData.map(G.f64(100.0), &abs/1))])
  end

  defp small, do: fixed_list([G.array(:f64, of: G.f64(100.0))])

  agreement(K,
    cs: [args: bounded()],
    p_sqrt: [args: probe_args()],
    p_exp: [args: small()],
    p_log: [args: probe_args()],
    p_log2: [args: probe_args()],
    p_log10: [args: probe_args()],
    p_pow_half: [args: non_negative()],
    p_pow_two: [args: small()],
    p_expm1: [args: small()],
    p_log1p: [args: probe_args()],
    p_abs: [args: probe_args()],
    p_round: [args: probe_args()],
    p_trunc: [args: probe_args()]
  )
end
