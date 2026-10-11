# Measuring

defk exists to help Elixir, not to beat it. Before you use a kernel, measure
whether it helps, and be ready for the answer to be "use Elixir". This guide
is the workflow; the rules and the evidence behind them live in two places it
links to:

- [examples/README.md, "Measuring correctly"](https://github.com/DanielLuning/defk/blob/main/examples/README.md#measuring-correctly)
  has the rules and the verdict table the project's example catalog uses.
- [Performance on the BEAM](../performance.md) collects what has been
  measured so far: fast and slow Elixir spellings, BIFs that are already
  native, schedulers, the cost of a call, and what makes a kernel fast.

## The question

Every measurement answers one question: **after making the Elixir version as
fast as you can, is the kernel still clearly better?** The project's bar is
2x:

- at least 2x faster than the best Elixir version: the kernel helps;
- between 1x and 2x (`marginal`): use Elixir, the gain does not pay for
  native code;
- slower, or not expressible as a kernel: use Elixir.

A result where Elixir wins is a result, not a failure.

## 1. Make the Elixir version fast first

A kernel compared with a first attempt in Elixir proves little. Before you
time the kernel:

- try the standard library, Erlang BIFs and modules (`:binary`, `:crypto`,
  `:erlang.crc32/1`, ETS, `:atomics`) and established libraries: many byte
  and number jobs are already native in OTP
  ([section 3](../performance.md#3-bifs-and-otp-libraries-that-are-already-native));
- try a better data layout or algorithm, and give the kernel the same one;
- time the alternatives instead of assuming which is fastest, and write down
  what you tried.

Until that is done, call the Elixir side a first pass and treat any win as
provisional.

## 2. Measure the right build

Time kernels in `:dev` or `:prod`. In `:test`, and in a module with
`use Defk, elixir_mode: true`, every kernel call first checks whether the
process runs in Elixir mode. That costs little next to a long loop but
distorts the cost of short calls. Elixir mode itself is never a baseline: it
is the kernel's meaning in Elixir, not the best Elixir solution.

## 3. Measure end to end, from the data the caller has

- If the data arrives as a list, packing it into a binary is part of the
  kernel's cost. It often costs more than the kernel
  ([section 5](../performance.md#5-the-nif-boundary)).
- A call costs tens of nanoseconds or more. One kernel call per element
  inside `Enum.map/2` loses; batch the work into one call.
- Keep shared data where a real application keeps it (`:persistent_term`,
  ETS), not on the benchmark process's heap, where garbage collection
  inflates the Elixir time
  ([section 1](../performance.md#1-measuring-honestly)).
- Compare like with like: one process against one call, or both sides split
  over all schedulers.
- When you split a kernel over schedulers, give each call a few milliseconds
  of work. Kernel calls shorter than about 1 ms started from
  `Task.async_stream/3` stay on a few schedulers (ticket `defk-6lr`;
  [section 4](../performance.md#4-parallelism-and-schedulers)).

## 4. A measuring script

`Defk.Bench.report/1` is what the project's examples use. It checks that the
two sides agree, times each end to end (best of several runs, with a full
garbage collection before each), and prints the speedup and the verdict.
Copy [the example template](https://github.com/DanielLuning/defk/blob/main/examples/_template.exs)
to start; its shape is:

<!-- defk-example script: run with its Mix.install line removed (the project is loaded); the report must say the two sides agree -->
```elixir
Mix.install([{:defk, path: "../defk"}])

defmodule Sum.Kernels do
  use Defk, elixir_mode: true

  defk sum(xs :: [f64]) :: f64 do
    for x <- xs, reduce: 0.0 do
      acc -> acc + x
    end
  end
end

defmodule Sum.Elixir do
  def sum(bin), do: for(<<x::float-64-native <- bin>>, reduce: 0.0, do: (acc -> acc + x))
end

input = for i <- 1..100_000, into: <<>>, do: <<i / 1.0::float-64-native>>

Defk.Bench.report(
  name: "sum",
  expected: :good,
  baseline: :first_pass,
  elixir: fn -> Sum.Elixir.sum(input) end,
  defk: fn -> Sum.Kernels.sum(input) end,
  check: fn ->
    Sum.Kernels.sum(input) === Sum.Elixir.sum(input) and
      Sum.Kernels.sum(input) === Sum.Kernels.__defk_elixir__(:sum, [input])
  end,
  reason: "a float sum over a packed binary"
)
```

Set `baseline: :optimized` only once you have tried to make the Elixir side
as fast as it can be. `responsiveness: true` adds the worst gap a 1 ms ticker
on one scheduler sees while each side runs, which tells you whether the work
keeps other processes waiting. The options are documented on
`Defk.Bench.report/1`.

Any benchmarking tool works as well (Benchee, `:timer.tc/1`); the rules above
matter more than the tool.

## 5. Explain the number

When a kernel is slower than you expect, `Defk.Report.print(Mod)` prints
each kernel's source with notes on what the compiler did to the hot path:
which bounds checks stayed and why, which branches became selects, where the
safepoints and copies are, and (with `use Defk, report: :full`) which loops
the C compiler vectorised. See the
[fast-path report](https://github.com/DanielLuning/defk/blob/main/docs/fast-path-report.md)
and [Making a defk kernel fast](../performance.md#6-making-a-defk-kernel-fast).

## 6. Record what you learned

If you work on defk itself, add what a measurement taught you, including
what didn't help, to [Performance on the BEAM](../performance.md), with the
numbers, the conditions (mark runs on a loaded machine provisional) and the
source.
