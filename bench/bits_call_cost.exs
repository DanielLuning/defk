# Per-call cost of a kernel by the kind of result it returns, so the fixed
# cost of a buffer-returning call can be told from the work: a scalar, an
# empty bitstring (tuple + wrapper match only), a one-byte bitstring (one
# owned buffer, copied out), a one-byte array (one owned buffer, transferred),
# and 57 or 450 one-byte appends (accumulator growth).
# `REPS=15 mix run bench/bits_call_cost.exs`; docs/performance.md 5.2.
defmodule BitsCallCost.Kernels do
  use Defk

  defk one(p :: [i64]) :: i64 do
    length(p)
  end

  defk bits1(p :: [i64]) :: bitstring do
    acc = <<>>
    <<acc::bitstring, length(p)::8>>
  end

  defk bits_empty(p :: [i64]) :: bitstring do
    acc = <<>>
    if length(p) < 0, do: acc = <<acc::bitstring, 1::1>>
    acc
  end

  defk arr1(p :: [i64]) :: [u8] do
    out = alloc(u8, 1)
    out[0] = 1
    out
  end

  defk bits_n(p :: [i64], n :: i64) :: bitstring do
    acc = <<>>

    for i <- 0..(n - 1)//1, reduce: acc do
      acc -> <<acc::bitstring, band(i, 255)::8>>
    end
  end
end

p = <<1::64-native>>
n = 100_000
reps = String.to_integer(System.get_env("REPS") || "15")

variants = [
  one: fn -> BitsCallCost.Kernels.one(p) end,
  bits_empty: fn -> BitsCallCost.Kernels.bits_empty(p) end,
  bits1: fn -> BitsCallCost.Kernels.bits1(p) end,
  arr1: fn -> BitsCallCost.Kernels.arr1(p) end,
  bits_n57: fn -> BitsCallCost.Kernels.bits_n(p, 57) end,
  bits_n450: fn -> BitsCallCost.Kernels.bits_n(p, 450) end
]

loop = fn f ->
  Enum.each(1..n, fn _ -> f.() end)
end

for {name, f} <- variants, do: {name, f.()} |> IO.inspect(label: "result")

best =
  for _ <- 1..reps, reduce: %{} do
    acc ->
      for {name, f} <- variants, reduce: acc do
        acc ->
          {us, _} = :timer.tc(fn -> loop.(f) end)
          Map.update(acc, name, us, &min(&1, us))
      end
  end

IO.puts("\nbest of #{reps}, ns per call over #{n} calls")

for {name, _} <- variants do
  IO.puts(
    "  #{String.pad_trailing(to_string(name), 12)} #{Float.round(best[name] * 1000 / n, 1)} ns"
  )
end
