defmodule Examples.Kernels do
  @moduledoc "PROTOTYPE example kernels, each exercising one defk feature."
  use Defk

  # boundary cost: smallest possible kernel
  defk add(a :: i64, b :: i64) :: i64 do
    a + b
  end

  # element generator: index in range by construction, no bounds checks
  defk sum(a :: [f64]) :: f64 do
    for x <- a, reduce: 0.0 do
      acc -> acc + x
    end
  end

  # indexed access: bounds-checked a[i]
  defk dot(a :: [f64], b :: [f64]) :: f64 do
    n = min(len(a), len(b))

    for i <- 0..(n - 1)//1, reduce: 0.0 do
      acc -> acc + a[i] * b[i]
    end
  end

  # tuple accumulator + tuple return (Welford, one pass)
  defk mean_var(a :: [f64]) :: {f64, f64} do
    {_n, mean, m2} =
      for x <- a, reduce: {0, 0.0, 0.0} do
        {n, mean, m2} ->
          n1 = n + 1
          d = x - mean
          mean1 = mean + d / n1
          {n1, mean1, m2 + d * (x - mean1)}
      end

    {mean, m2 / len(a)}
  end

  # allocate + write + return a new packed array (zero-copy back to Elixir)
  defk scale(a :: [f64], k :: f64) :: [f64] do
    out = alloc(f64, len(a))

    for i <- 0..(len(a) - 1)//1 do
      out[i] = a[i] * k
    end

    out
  end

  # u8 input, i64 output, checked integer arithmetic
  defk histogram(bytes :: [u8]) :: [i64] do
    h = alloc(i64, 256)

    for b <- bytes do
      h[b] = h[b] + 1
    end

    h
  end

  # long-running integer kernel: automatic yielding + kernel-to-kernel calls
  defk count_primes(n :: i64) :: i64 do
    for i <- 2..n//1, reduce: 0 do
      count -> if prime?(i), do: count + 1, else: count
    end
  end

  # same kernel with safepoints compiled out: blocks its scheduler
  defk count_primes_noyield(n :: i64) :: i64, yield: false do
    for i <- 2..n//1, reduce: 0 do
      count -> if prime?(i), do: count + 1, else: count
    end
  end

  defk prime?(x :: i64) :: bool do
    limit = trunc(:math.sqrt(x))

    for d <- 2..limit//1, reduce: true do
      p -> p and rem(x, d) != 0
    end
  end

  # error paths
  defk oob(a :: [f64]) :: f64 do
    a[len(a)]
  end

  defk overflow(a :: i64) :: i64 do
    a * a
  end
end
