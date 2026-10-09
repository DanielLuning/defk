# Cost of raising on inf/NaN like Elixir (defk-i00): each kernel built with
# the float checks (every float op that can make inf or NaN, every [f64]
# input read) and with them compiled out (-DDEFK_NO_FLOAT_CHECKS, a macro for
# this measurement only, passed through a CC wrapper). Interleaved rounds,
# best-of per round, so machine noise hits both builds alike.
# `mix run bench/float_checks.exs [rounds]`

rounds = String.to_integer(List.first(System.argv()) || "9")
n = 1_000_000

body =
  quote do
    use Defk

    defk dot(a :: [f64], b :: [f64]) :: f64 do
      n = min(len(a), len(b))

      for i <- 0..(n - 1)//1, reduce: 0.0 do
        acc -> acc + a[i] * b[i]
      end
    end

    defk cosine(a :: [f64], b :: [f64]) :: f64 do
      n = min(len(a), len(b))

      {d, na, nb} =
        for i <- 0..(n - 1)//1, reduce: {0.0, 0.0, 0.0} do
          {d, na, nb} -> {d + a[i] * b[i], na + a[i] * a[i], nb + b[i] * b[i]}
        end

      d / (sqrt(na) * sqrt(nb))
    end

    # examples/rolling_stats.exs
    defk mean_std(x :: [f64], w :: i64) :: [f64] do
      n = len(x)
      m = n - w + 1
      out = alloc(f64, 2 * m)

      _ =
        for i <- 0..(n - 1)//1, reduce: {0.0, 0.0} do
          {s, q} ->
            v = x[i]
            old = if i >= w, do: x[i - w], else: 0.0
            s2 = s + v - old
            q2 = q + v * v - old * old

            if i >= w - 1 do
              mean = s2 / w
              out[i - w + 1] = mean
              out[m + i - w + 1] = sqrt(max(q2 / w - mean * mean, 0.0))
            end

            {s2, q2}
        end

      out
    end

    # an element-wise map: the one shape whose loop clang vectorises
    defk scale(a :: [f64], k :: f64) :: [f64] do
      out = alloc(f64, len(a))

      for i <- 0..(len(a) - 1)//1 do
        out[i] = a[i] * k
      end

      out
    end
  end

Module.create(FloatChecks.On, body, Macro.Env.location(__ENV__))

cc = System.get_env("CC", "cc")
wrapper = Path.join(System.tmp_dir!(), "defk-cc-no-float-checks")
File.write!(wrapper, "#!/bin/sh\nexec #{cc} -DDEFK_NO_FLOAT_CHECKS \"$@\"\n")
File.chmod!(wrapper, 0o755)
System.put_env("CC", wrapper)
Module.create(FloatChecks.Off, body, Macro.Env.location(__ENV__))
if cc == "cc", do: System.delete_env("CC"), else: System.put_env("CC", cc)

:rand.seed(:exsss, {1, 2, 3})
pack = fn -> for _ <- 1..n, into: <<>>, do: <<:rand.uniform() * 2 - 1::float-64-native>> end
a = pack.()
b = pack.()

cases = [
  dot: [a, b],
  cosine: [a, b],
  mean_std: [a, 100],
  scale: [a, 1.5]
]

for {f, args} <- cases do
  on = apply(FloatChecks.On, f, args)
  off = apply(FloatChecks.Off, f, args)
  on === off || raise "#{f}: the two builds disagree"
end

best = fn mod, f, args ->
  for(_ <- 1..5, do: elem(:timer.tc(fn -> apply(mod, f, args) end), 0)) |> Enum.min()
end

runs =
  for r <- 1..rounds, {f, args} <- cases do
    # alternate which build goes first
    [x, y] = if rem(r, 2) == 0, do: [FloatChecks.On, FloatChecks.Off], else: [FloatChecks.Off, FloatChecks.On]
    tx = best.(x, f, args)
    ty = best.(y, f, args)
    {on, off} = if x == FloatChecks.On, do: {tx, ty}, else: {ty, tx}
    {f, on, off}
  end

med = fn l -> Enum.at(Enum.sort(l), div(length(l), 2)) end

IO.puts("#{n} elements, #{rounds} rounds, best of 5 per round (us); cost = checks on / off - 1")

for {f, _} <- cases do
  rs = for {^f, on, off} <- runs, do: {on, off}
  costs = Enum.map(rs, fn {on, off} -> 100 * (on / off - 1) end)
  ons = Enum.map(rs, &elem(&1, 0))
  offs = Enum.map(rs, &elem(&1, 1))

  IO.puts(
    String.pad_trailing("#{f}", 9) <>
      " on #{med.(ons)} (min #{Enum.min(ons)})  off #{med.(offs)} (min #{Enum.min(offs)})  " <>
      "cost median #{Float.round(med.(costs), 1)}%  range #{Float.round(Enum.min(costs), 1)}..#{Float.round(Enum.max(costs), 1)}%  " <>
      "min/min #{Float.round(100 * (Enum.min(ons) / Enum.min(offs) - 1), 1)}%"
  )
end
