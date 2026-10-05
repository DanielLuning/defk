# <name>: <the real-world job, in one line>
#
# Why people reach for a NIF here: <what makes plain Elixir too slow>
# Expected verdict: good | marginal | poor | out_of_scope
#
#   elixir examples/<name>.exs
#
# Elixir baseline: first pass | optimised. <What was tried to make the Elixir
# version fast, and what has not been tried yet.>
#
# Copy this file, keep the shape: Elixir version, defk version, same inputs,
# a correctness check, then Defk.Bench.report/1 as the last step.
#
# Before claiming defk is the better choice, make the Elixir version as fast
# as you can (stdlib, Erlang BIFs, established libraries, better data layout)
# and set `baseline: :optimized`. If Elixir ends up as good or as fast, that
# is the answer: Elixir is the right choice. See examples/README.md.

Mix.install([{:defk, path: Path.expand("..", __DIR__)}])

defmodule Example.Kernels do
  use Defk

  defk work(a :: [f64]) :: f64 do
    for x <- a, reduce: 0.0 do
      acc -> acc + x
    end
  end
end

defmodule Example.Elixir do
  def work(bin), do: for(<<x::float-64-native <- bin>>, reduce: 0.0, do: (acc -> acc + x))
end

input = for i <- 1..100_000, into: <<>>, do: <<i / 1.0::float-64-native>>

Defk.Bench.report(
  name: "template",
  expected: :good,
  baseline: :first_pass,
  elixir: fn -> Example.Elixir.work(input) end,
  defk: fn -> Example.Kernels.work(input) end,
  check: fn -> Example.Elixir.work(input) == Example.Kernels.work(input) end
)
