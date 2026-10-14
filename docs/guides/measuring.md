# Measuring

defk exists to help Elixir, not to beat it. Before you use a kernel, measure
whether it helps, and be ready for the answer to be "use Elixir". This guide
is the workflow; the rules and the evidence behind them live in two places it
links to:

- [examples/README.md, "Measuring correctly"](https://github.com/DanielLuning/defk/blob/main/examples/README.md#measuring-correctly)
  has the rules and the verdict table the project's example catalog uses.
- [Performance on the BEAM](https://github.com/DanielLuning/defk/blob/main/docs/performance.md) collects what has been
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
  ([section 3](https://github.com/DanielLuning/defk/blob/main/docs/performance.md#3-bifs-and-otp-libraries-that-are-already-native));
- try a better data layout or algorithm, and give the kernel the same one;
- look up the job's kind in
  [Fast Elixir on binaries and numbers](https://github.com/DanielLuning/defk/blob/main/docs/performance.md#2-fast-elixir-on-binaries-and-numbers):
  counting bytes, for instance, is "2.16 Counting bytes" there (16-bit
  pairs into `:atomics`, not a map), and counting keys "2.12 Dense
  counters";
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
  ([section 5](https://github.com/DanielLuning/defk/blob/main/docs/performance.md#5-the-nif-boundary)).
- A call costs tens of nanoseconds or more. One kernel call per element
  inside `Enum.map/2` loses; batch the work into one call.
- Keep shared data where a real application keeps it (`:persistent_term`,
  ETS), not on the benchmark process's heap, where garbage collection
  inflates the Elixir time
  ([section 1](https://github.com/DanielLuning/defk/blob/main/docs/performance.md#1-measuring-honestly)).
- Compare like with like: one process against one call, or both sides split
  over all schedulers ([below](#comparing-over-all-schedulers)). Elixir
  split over a machine's schedulers often closes much of a one-call gap, so
  report both when the job could run in parallel.
- When you split a kernel over schedulers, give each call a few milliseconds
  of work. Kernel calls shorter than about 1 ms started from
  `Task.async_stream/3` stay on a few schedulers
  ([section 4](https://github.com/DanielLuning/defk/blob/main/docs/performance.md#4-parallelism-and-schedulers)).

## 4. A measuring script

Any benchmarking tool works (Benchee, `:timer.tc/1`); the rules above matter
more than the tool. `Defk.Bench.report/1` is the small harness the project's
own examples use: it checks that the two sides agree, times each end to end
(best of several runs, with a full garbage collection before each), and
prints the speedup and the verdict. It is marked unstable because its options
and output may change between versions, not because its numbers are
unreliable; it is fine for checking your own kernel.

Its `check:` option is a function of no arguments that returns `true` when
the two sides give the same answer. Compare with `===` where the two compute
the same thing the same way (as below). Where the Elixir side is a different
but equivalent formula, for example `log(p) / log(2.0)` against
`:math.log2(p)`, results can differ in the last bit: compare those
within a tolerance, and keep the exact check between the kernel and its own
Elixir mode (`Mod.__defk_elixir__/2`).

Here is a whole script. Run it as `elixir sum.exs` beside a defk checkout. In
your own Mix project, drop the `Mix.install` line, put the file outside
`lib/` and `test/` (say `bench/sum.exs`), and run it with `mix run bench/sum.exs`,
which uses `:dev`; the kernel module can live in `lib/` as usual.

<!-- defk-example script: run with its Mix.install line removed (the project is loaded); the report must say the two sides agree -->
```elixir
Mix.install([{:defk, "~> 0.1"}])

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

### Comparing over all schedulers

To compare both sides split over the machine's schedulers, give each the
same chunks and start them all at once (`Task.async` and
`Task.await_many/2`, which spread better than `Task.async_stream/3` for
short calls). `binary_part/3` gives each chunk without copying the data:

<!-- defk-example script: run with its Mix.install line removed (the project is loaded); the report must say the two sides agree -->
```elixir
Mix.install([{:defk, "~> 0.1"}])

defmodule ParSum.Kernels do
  use Defk, elixir_mode: true

  defk sum(xs :: [f64]) :: f64 do
    for x <- xs, reduce: 0.0 do
      acc -> acc + x
    end
  end
end

defmodule ParSum do
  def elixir_sum(bin), do: for(<<x::float-64-native <- bin>>, reduce: 0.0, do: (acc -> acc + x))

  # one chunk per scheduler, each a sub-binary of whole elements
  def chunks(bin, elem_size) do
    n = System.schedulers_online()
    count = div(byte_size(bin), elem_size)
    per = max(div(count + n - 1, n), 1)

    for start <- 0..(count - 1)//per do
      binary_part(bin, start * elem_size, min(per, count - start) * elem_size)
    end
  end

  # every chunk started at once; the partial sums are added in chunk order
  def run(chunks, fun) do
    chunks
    |> Enum.map(fn chunk -> Task.async(fn -> fun.(chunk) end) end)
    |> Task.await_many(:infinity)
    |> Enum.sum()
  end
end

input = for i <- 1..1_000_000, into: <<>>, do: <<i / 1.0::float-64-native>>
chunks = ParSum.chunks(input, 8)

Defk.Bench.report(
  name: "sum, all schedulers",
  expected: :good,
  baseline: :first_pass,
  elixir: fn -> ParSum.run(chunks, &ParSum.elixir_sum/1) end,
  defk: fn -> ParSum.run(chunks, &ParSum.Kernels.sum/1) end,
  check: fn ->
    ParSum.run(chunks, &ParSum.Kernels.sum/1) === ParSum.run(chunks, &ParSum.elixir_sum/1)
  end,
  reason: "the same float sum, split the same way on both sides"
)
```

Both sides add the partial sums in the same order, so they agree exactly
(a split sum can differ from the one-call sum in the last bits). Give each
chunk a few milliseconds of work at your real input size: kernel calls much
shorter than that may stay on a few schedulers, so a
small input understates what the kernel can do in parallel. What helps, and
what Elixir gains from chunking, is in
[Parallelism and schedulers](https://github.com/DanielLuning/defk/blob/main/docs/performance.md#4-parallelism-and-schedulers).

## 5. Explain the number

When a kernel is slower than you expect, `Defk.Report.print(Mod)` prints
each kernel's source with notes on what the compiler did to the hot path:
which bounds checks stayed and why, which branches became selects, where the
safepoints and copies are, and (with `use Defk, report: :full`) which loops
the C compiler vectorised. See the
[fast-path report](https://github.com/DanielLuning/defk/blob/main/docs/fast-path-report.md)
and [Making a defk kernel fast](https://github.com/DanielLuning/defk/blob/main/docs/performance.md#6-making-a-defk-kernel-fast).

## 6. Record what you learned

If you work on defk itself, add what a measurement taught you, including
what didn't help, to [Performance on the BEAM](https://github.com/DanielLuning/defk/blob/main/docs/performance.md), with the
numbers, the conditions (mark runs on a loaded machine provisional) and the
source.
