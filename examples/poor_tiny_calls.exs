# poor_tiny_calls: clamp every sensor reading with a kernel call per element
#
# The trap: calling native code inside Enum.map. Each NIF call adds ~10 ns,
# about as much as the entire per-element cost of the Elixir version (map
# step included), so the boundary dominates.
# Expected verdict: poor
#
#   elixir examples/poor_tiny_calls.exs
#
# Fix: one call per batch (pass the whole packed array), never one per element.

Mix.install([{:defk, path: Path.expand("..", __DIR__)}])

defmodule Clamp.Kernels do
  use Defk

  defk clamp(x :: f64, lo :: f64, hi :: f64) :: f64 do
    min(max(x, lo), hi)
  end
end

readings = for i <- 1..1_000_000, do: rem(i * 7919, 2000) / 10 - 50

elixir_clamp = fn -> Enum.map(readings, &min(max(&1, -10.0), 90.0)) end
defk_clamp = fn -> Enum.map(readings, &Clamp.Kernels.clamp(&1, -10.0, 90.0)) end

Defk.Bench.report(
  name: "poor_tiny_calls",
  expected: :poor,
  elixir: elixir_clamp,
  defk: defk_clamp,
  check: fn -> elixir_clamp.() == defk_clamp.() end,
  reason: "one NIF call per element: the call overhead is larger than the work"
)
