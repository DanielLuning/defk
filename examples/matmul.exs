# matmul: dense matrix multiply, C = A x B, as a poor-fit entry: use Nx
#
# Why people reach for a NIF here: neural-net layers, least squares, graph
# algorithms and simulation all bottom out in dense matrix products. In Elixir
# the answer is Nx (with EXLA or Torchx for speed), so this example is not a
# target workload: it records where the boundary lies.
# Expected verdict: good (against pure Elixir; the easy part). The entry's real
# message is in `native_speedup`, defk against Nx.
#
#   elixir examples/matmul.exs
#
# Recommendation (the catalog's): for tensor work use Nx with EXLA, which is
# 6x faster than defk at 256x256 and 108x at 1024x1024 here; defk fits a
# custom loop beside it, and wins only below ~100x100, where EXLA's dispatch
# and buffer copies outweigh the product. docs/research/nx-boundary.md
# (branch research/nx-boundary) puts the line here: "Nx is the right tool when the work is whole-tensor,
# shape-static, and big enough to amortise a compile and a dirty-scheduler
# round trip: elementwise maps, reductions, windows, cumulative sums,
# sort/argsort, linear algebra, convolutions, anything with gradients,
# anything that should run on a GPU. defk should not compete there". What Nx
# leaves open is the scalar loop with data dependencies, small or irregular
# inputs, byte-exact work and normal-scheduler yielding. A matmul is none of
# these.
#
# Kernels (row-major packed f64; a is n x m, b is m x p, result n x p):
#
#   matmul          i-k-j loop order: the inner loop runs along row k of b and
#                   row i of the result, both contiguous, so the compiler can
#                   vectorise it. The result starts zeroed (alloc) and every
#                   element accumulates k in ascending order.
#   matmul_blocked  the same loops tiled 64 x 64 over k and j, so a tile of b
#                   stays in cache while all n rows of a use it. Each element
#                   still accumulates k in ascending order, so the result is
#                   bit-identical to matmul.
#
# Both raise ArgumentError when a size is not positive or an array length does
# not match its shape. Only matmul is reported; the blocked variant is timed
# with MATMUL_VARIANTS=1 (below).
#
# Elixir baselines (:optimized after three variants), all from and to packed
# f64 binaries, like the kernels, and timed with MATMUL_VARIANTS=1 elixir
# examples/matmul.exs. M-series Mac (12 cores), OTP 29, Elixir 1.20, best of
# 3; the EXLA rows measured 2026-10-15 under load (load average ~3.3, one
# unrelated BEAM at 100% of a core: provisional), the rest on 2026-10-13:
#
#                                  64x64       256x256
#   lists of rows, Enum.zip transpose of b, one
#     tail-recursive dot per element       3.7 ms      333 ms   <- reported
#   i-k-j on lists (axpy per k, no transpose)  4.3 ms      483 ms
#   :binary rows/columns, binary-pattern dot   5.4 ms      948 ms
#   defk matmul (i-k-j)                    0.20 ms      13.4 ms
#   defk matmul_blocked (64 x 64 tiles)    0.27 ms      13.9 ms
#   Nx.dot, binary backend                    36 ms     2790 ms
#   Nx + EXLA, from packed binaries        0.77 ms     2.2 ms   <- native row
#   Nx + EXLA, operands resident           0.09 ms     0.28 ms
#
# The report's sweep (one run per size, Elixir = the reported variant):
# 64: 4.2 vs 0.21 ms (20x), 256: 320 vs 13.1 ms (24x), 512: 2.7 s vs 103 ms
# (26x), 1024: 29 s vs 833 ms (35x); the blocked kernel is no faster at 1024
# (941 ms, one run), so only the plain loop is reported. defk's 13.1 ms at 256
# is ~2.5 GFLOP/s (2 x 256^3 flops): one scalar-width f64 multiply-add per
# cycle, far below a BLAS.
#
# Verdict at 256x256: defk 25x over the best Elixir (good). The native row is
# Nx with EXLA: defk is 0.16x of it (EXLA 6x faster, 2.1-2.2 vs 13.1-15.5
# ms), and the gap widens with size: 512: 2.9 vs 106 ms (37x), 1024: 7.7 vs
# 833 ms (108x; ~280 GFLOP/s, XLA's multithreaded SIMD GEMM on all cores).
# With both operands already resident on EXLA.Backend the 256 product is
# 0.28 ms, 50x defk. Only at 64x64 does defk win (0.21 vs 0.77 ms from
# binaries): there the copies into XLA buffers and the dispatch cost more
# than the product, the "small inputs" case of the research note. The resident
# form wins even there (0.09 ms). Nx's binary backend is Elixir and ~8x slower
# than plain lists, so its 150-200x against defk says nothing about Nx.
#
# Nx: Nx 0.13.1 and EXLA 0.13.1, both dependencies of this script
# (Mix.install works from the hex cache with HEX_OFFLINE=1; EXLA builds its
# NIF in ~25 s on first install, against the precompiled XLA 0.10.0 for
# aarch64-darwin-cpu). The binary backend row (Nx.BinaryBackend, which is
# Elixir, not native) runs end to end from the same packed binaries:
# Nx.from_binary |> Nx.reshape |> Nx.dot |> Nx.to_binary; it is kept as a
# check, not reported. The EXLA row is Nx.dot jitted with compiler: EXLA (the
# CPU client), timed the same way from the packed binaries a caller holds, so
# the copies into XLA buffers and the copy of the result back are inside the
# timing; the "resident" row has both operands already on EXLA.Backend and
# only reads the result back. XLA compiles one executable per shape on the
# first call (26-40 ms at 64x64 including the client start, ~5 ms at 256x256);
# the script makes that call before any timing and prints it, so no timed run
# includes a compile. ({:exla, "0.10.0"} did not compile on this machine
# against Apple clang's -Winvalid-specialization; 0.13.1 passes
# -Wno-invalid-specialization itself.)
#
# Agreement: every implementation is checked against a pure-Elixir reference
# (plain sum over k, ascending) with a 1e-9 relative tolerance per element,
# and against Nx.dot on the binary backend and with EXLA. Bit-exactness is not expected
# across implementations: the summation order differs (each Elixir
# dot sums k ascending from 0.0, the same order as the kernel, so these
# usually match to the last bit, but Nx's accumulation order is its own). The inputs are positive,
# so there is no cancellation and a relative tolerance is meaningful. Shapes
# checked: 64x64, 256x256 and a non-square 7x5 times 5x9.
#
# Kernel notes: nothing special needed; 2D indexing is row * n + col.

Mix.install([
  {:defk, path: Path.expand("..", __DIR__)},
  {:nx, "== 0.13.1"},
  {:exla, "== 0.13.1"}
])

defmodule Matmul.Kernels do
  use Defk

  defk matmul(a :: [f64], b :: [f64], n :: i64, m :: i64, p :: i64) :: [f64] do
    if not (n > 0 and m > 0 and p > 0 and length(a) == n * m and length(b) == m * p),
      do: raise(ArgumentError, "matmul: sizes must be positive and match the array lengths")

    out = alloc(f64, n * p)

    for i <- 0..(n - 1)//1, k <- 0..(m - 1)//1 do
      aik = a[i * m + k]

      for j <- 0..(p - 1)//1 do
        out[i * p + j] = out[i * p + j] + aik * b[k * p + j]
      end
    end

    out
  end

  defk matmul_blocked(a :: [f64], b :: [f64], n :: i64, m :: i64, p :: i64) :: [f64] do
    if not (n > 0 and m > 0 and p > 0 and length(a) == n * m and length(b) == m * p),
      do: raise(ArgumentError, "matmul: sizes must be positive and match the array lengths")

    out = alloc(f64, n * p)

    for kk <- 0..(m - 1)//64, jj <- 0..(p - 1)//64 do
      kend = min(kk + 64, m)
      jend = min(jj + 64, p)

      for i <- 0..(n - 1)//1, k <- kk..(kend - 1)//1 do
        aik = a[i * m + k]

        for j <- jj..(jend - 1)//1 do
          out[i * p + j] = out[i * p + j] + aik * b[k * p + j]
        end
      end
    end

    out
  end
end

defmodule Matmul.Elixir do
  def decode(bin), do: for(<<x::float-native-64 <- bin>>, do: x)

  def rows(bin, cols) do
    for i <- 0..(div(byte_size(bin), 8 * cols) - 1)//1 do
      decode(binary_part(bin, i * cols * 8, cols * 8))
    end
  end

  def encode_rows(rows), do: for(r <- rows, x <- r, into: <<>>, do: <<x::float-native-64>>)

  # reference: the textbook definition, one dot product per element, k ascending
  def reference(a, b, n, m, p) do
    ar = a |> rows(m) |> Enum.map(&List.to_tuple/1) |> List.to_tuple()
    bt = b |> rows(p) |> Enum.map(&List.to_tuple/1) |> List.to_tuple()

    for i <- 0..(n - 1), j <- 0..(p - 1), into: <<>> do
      s =
        Enum.reduce(0..(m - 1), 0.0, fn k, s ->
          s + elem(elem(ar, i), k) * elem(elem(bt, k), j)
        end)

      <<s::float-native-64>>
    end
  end

  # variant 1: lists of rows; transpose b with Enum.zip, one tail-recursive
  # dot per element
  def lists_dot(a, b, _n, m, p) do
    ar = rows(a, m)
    bc = b |> rows(p) |> Enum.zip() |> Enum.map(&Tuple.to_list/1)

    for row <- ar, col <- bc, into: <<>> do
      <<dot(row, col, 0.0)::float-native-64>>
    end
  end

  defp dot([x | xs], [y | ys], s), do: dot(xs, ys, s + x * y)
  defp dot([], [], s), do: s

  # variant 2: i-k-j on lists of rows: row i of the result is the sum over k
  # of a[i][k] * row k of b, accumulated with one list pass per k (the same
  # access pattern as the kernel, no transpose)
  def lists_ikj(a, b, _n, m, p) do
    ar = rows(a, m)
    br = rows(b, p)
    zero = List.duplicate(0.0, p)

    for row <- ar, into: <<>> do
      acc =
        row
        |> Enum.zip(br)
        |> Enum.reduce(zero, fn {aik, brow}, acc -> axpy(aik, brow, acc) end)

      for x <- acc, into: <<>>, do: <<x::float-native-64>>
    end
  end

  defp axpy(s, [y | ys], [c | cs]), do: [c + s * y | axpy(s, ys, cs)]
  defp axpy(_s, [], []), do: []

  # variant 3: binaries throughout. b is transposed once into column binaries,
  # a is cut into row binaries with binary_part, each element is one
  # binary-pattern dot product, no intermediate lists of floats.
  def binary_cols(a, b, n, m, p) do
    cols =
      for j <- 0..(p - 1)//1 do
        for k <- 0..(m - 1)//1, into: <<>> do
          binary_part(b, (k * p + j) * 8, 8)
        end
      end

    for i <- 0..(n - 1)//1, into: <<>> do
      row = binary_part(a, i * m * 8, m * 8)
      for col <- cols, into: <<>>, do: <<bdot(row, col, 0.0)::float-native-64>>
    end
  end

  defp bdot(<<x::float-native-64, xs::binary>>, <<y::float-native-64, ys::binary>>, s),
    do: bdot(xs, ys, s + x * y)

  defp bdot(<<>>, <<>>, s), do: s
end

defmodule Matmul.Check do
  # per-element relative tolerance; inputs are positive, so no cancellation
  def close?(x, y, tol \\ 1.0e-9) do
    byte_size(x) == byte_size(y) and
      Enum.all?(Enum.zip(Matmul.Elixir.decode(x), Matmul.Elixir.decode(y)), fn {u, v} ->
        abs(u - v) <= tol * max(abs(u), abs(v))
      end)
  end

  def nx_dot(a, b, n, m, p) do
    ta = a |> Nx.from_binary(:f64) |> Nx.reshape({n, m})
    tb = b |> Nx.from_binary(:f64) |> Nx.reshape({m, p})
    ta |> Nx.dot(tb) |> Nx.to_binary()
  end

  # Nx.dot jitted with EXLA (XLA's CPU client), end to end from the packed
  # binaries a caller holds: the copies into XLA buffers and the copy of the
  # result back are inside the timing, as a caller with binaries pays them.
  # The jitted fun is built once (exla_dot_fun/0) and warmed before timing, so
  # XLA's compile is not in any measured run; it is reported on its own.
  def exla_dot(a, b, n, m, p) do
    ta = a |> Nx.from_binary(:f64) |> Nx.reshape({n, m})
    tb = b |> Nx.from_binary(:f64) |> Nx.reshape({m, p})
    exla_dot_fun().(ta, tb) |> Nx.to_binary()
  end

  # the same with both operands already resident on EXLA.Backend (what an
  # app that keeps its tensors in Nx pays), the result read back
  def exla_dot_resident(ta, tb), do: exla_dot_fun().(ta, tb) |> Nx.to_binary()

  def exla_tensor(bin, rows, cols),
    do: bin |> Nx.from_binary(:f64, backend: EXLA.Backend) |> Nx.reshape({rows, cols})

  def exla_dot_fun do
    case :persistent_term.get({__MODULE__, :exla_dot}, nil) do
      nil ->
        f = Nx.Defn.jit(&Nx.dot/2, compiler: EXLA)
        :persistent_term.put({__MODULE__, :exla_dot}, f)
        f

      f ->
        f
    end
  end

  # XLA compiles one executable per shape: the first call at a shape pays it
  def exla_warm(n) do
    {a, b} = {gen(n * n, 5), gen(n * n, 6)}
    {us, _} = :timer.tc(fn -> exla_dot(a, b, n, n, n) end)
    {us2, _} = :timer.tc(fn -> exla_dot(a, b, n, n, n) end)
    {us / 1000, us2 / 1000}
  end

  def gen(count, seed) do
    :rand.seed(:exsss, {seed, 2, 3})
    for _ <- 1..count, into: <<>>, do: <<:rand.uniform()::float-native-64>>
  end
end

inputs = fn n -> {Matmul.Check.gen(n * n, 1), Matmul.Check.gen(n * n, 2)} end
{a64, b64} = inputs.(64)
{a256, b256} = inputs.(256)

# EXLA's compile per shape, before any timing (reported, never timed)
for n <- [64, 256] do
  {first, second} = Matmul.Check.exla_warm(n)

  IO.puts(
    "EXLA #{n}x#{n}: first call #{Float.round(first, 1)} ms (XLA compile + run), second #{Float.round(second, 2)} ms"
  )
end

if System.get_env("MATMUL_VARIANTS") do
  time = fn label, f ->
    best =
      Enum.min(
        for _ <- 1..3 do
          :erlang.garbage_collect()
          elem(:timer.tc(f), 0)
        end
      )

    IO.puts("  #{String.pad_trailing(label, 24)} #{Float.round(best / 1000, 2)} ms")
  end

  for {n, a, b} <- [{64, a64, b64}, {256, a256, b256}] do
    IO.puts("#{n}x#{n}")
    time.("lists_dot", fn -> Matmul.Elixir.lists_dot(a, b, n, n, n) end)
    time.("lists_ikj", fn -> Matmul.Elixir.lists_ikj(a, b, n, n, n) end)
    time.("binary_cols", fn -> Matmul.Elixir.binary_cols(a, b, n, n, n) end)
    time.("defk matmul", fn -> Matmul.Kernels.matmul(a, b, n, n, n) end)
    time.("defk matmul_blocked", fn -> Matmul.Kernels.matmul_blocked(a, b, n, n, n) end)

    if n <= 256 do
      time.("Nx binary backend", fn -> Matmul.Check.nx_dot(a, b, n, n, n) end)
    end

    time.("Nx + EXLA, from binaries", fn -> Matmul.Check.exla_dot(a, b, n, n, n) end)
    {ta, tb} = {Matmul.Check.exla_tensor(a, n, n), Matmul.Check.exla_tensor(b, n, n)}
    time.("Nx + EXLA, resident", fn -> Matmul.Check.exla_dot_resident(ta, tb) end)
  end

  for n <- [512, 1024] do
    {a, b} = inputs.(n)
    IO.puts("#{n}x#{n} (one run each)")

    time1 = fn label, f ->
      IO.puts("  #{String.pad_trailing(label, 24)} #{Float.round(elem(:timer.tc(f), 0) / 1000, 1)} ms")
    end

    time1.("defk matmul", fn -> Matmul.Kernels.matmul(a, b, n, n, n) end)
    time1.("defk matmul_blocked", fn -> Matmul.Kernels.matmul_blocked(a, b, n, n, n) end)
    Matmul.Check.exla_warm(n)
    time1.("Nx + EXLA, from binaries", fn -> Matmul.Check.exla_dot(a, b, n, n, n) end)
  end
end

best_elixir = &Matmul.Elixir.lists_dot/5

agree = fn ->
  # 7x5 times 5x9, and both sizes the report measures
  {sa, sb} = {Matmul.Check.gen(7 * 5, 3), Matmul.Check.gen(5 * 9, 4)}
  sref = Matmul.Elixir.reference(sa, sb, 7, 5, 9)

  small =
    Matmul.Check.close?(Matmul.Kernels.matmul(sa, sb, 7, 5, 9), sref) and
      Matmul.Check.close?(Matmul.Kernels.matmul_blocked(sa, sb, 7, 5, 9), sref) and
      Matmul.Check.close?(Matmul.Check.nx_dot(sa, sb, 7, 5, 9), sref) and
      Matmul.Check.close?(Matmul.Check.exla_dot(sa, sb, 7, 5, 9), sref) and
      Matmul.Check.close?(Matmul.Elixir.lists_dot(sa, sb, 7, 5, 9), sref) and
      Matmul.Check.close?(Matmul.Elixir.lists_ikj(sa, sb, 7, 5, 9), sref) and
      Matmul.Check.close?(Matmul.Elixir.binary_cols(sa, sb, 7, 5, 9), sref)

  big =
    for {n, a, b} <- [{64, a64, b64}, {256, a256, b256}] do
      ref = Matmul.Elixir.reference(a, b, n, n, n)
      d = Matmul.Kernels.matmul(a, b, n, n, n)

      Matmul.Check.close?(d, ref) and
        Matmul.Check.close?(Matmul.Kernels.matmul_blocked(a, b, n, n, n), ref) and
        d == Matmul.Kernels.matmul_blocked(a, b, n, n, n) and
        Matmul.Check.close?(Matmul.Check.nx_dot(a, b, n, n, n), ref) and
        Matmul.Check.close?(Matmul.Check.nx_dot(a, b, n, n, n), d) and
        Matmul.Check.close?(Matmul.Check.exla_dot(a, b, n, n, n), ref) and
        Matmul.Check.close?(Matmul.Check.exla_dot(a, b, n, n, n), d) and
        Matmul.Check.close?(Matmul.Elixir.lists_dot(a, b, n, n, n), ref) and
        Matmul.Check.close?(Matmul.Elixir.binary_cols(a, b, n, n, n), ref) and
        Matmul.Check.close?(Matmul.Elixir.lists_ikj(a, b, n, n, n), d)
    end

  bad =
    try do
      Matmul.Kernels.matmul(sa, sb, 7, 5, 8)
      false
    rescue
      ArgumentError -> true
    end

  small and Enum.all?(big) and bad
end

sweep_fun = fn n ->
  {a, b} = inputs.(n)
  {fn -> best_elixir.(a, b, n, n, n) end, fn -> Matmul.Kernels.matmul(a, b, n, n, n) end}
end

Defk.Bench.report(
  name: "matmul",
  expected: :good,
  baseline: :optimized,
  runs: 3,
  realistic_size: "256x256",
  elixir: fn -> best_elixir.(a256, b256, 256, 256, 256) end,
  defk: fn -> Matmul.Kernels.matmul(a256, b256, 256, 256, 256) end,
  native:
    {fn -> Matmul.Check.exla_dot(a256, b256, 256, 256, 256) end,
     "Nx 0.13.1 + EXLA 0.13.1 (CPU), from packed binaries"},
  check: agree,
  sweep: {[64, 256, 512, 1024], sweep_fun},
  sweep_runs: 1,
  reason:
    "good against pure Elixir, but the tensor answer is Nx: with EXLA, Nx.dot is 6x faster than defk at 256x256 and 108x at 1024x1024 (defk wins only at 64x64, where EXLA's dispatch and copies cost more than the product); for tensor work use Nx with EXLA, defk fits a custom loop beside it"
)
