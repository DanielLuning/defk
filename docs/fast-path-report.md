# Fast-path report

When a kernel is slower than you expected, the fast-path report shows what
the compiler did to its hot path: which bounds checks stayed and what fact
would drop them, which branches became selects, where safepoints and copies
went, and, with clang, which loops vectorised. It is in the spirit of
Julia's `@code_warntype`. It is a tool for explaining measurements, not
part of the kernel subset: a kernel's meaning never depends on it
(CONTEXT.md, "Fast-path report").

```elixir
Defk.Report.print(Examples.Kernels)
```

```text
dot/2  lib/examples.ex:18
  18 |   defk dot(a :: [f64], b :: [f64]) :: f64 do
  19 |     n = min(len(a), len(b))
  20 |
  21 |     for i <- 0..(n - 1)//1, reduce: 0.0 do    # loop: strips of DEFK_STRIP trips, one safepoint per strip; flagged
     |                                               # non-finite: float checks set a flag tested once per strip; a set flag replays the strip with raising checks
  22 |       acc -> acc + a[i] * b[i]                # a[i]: no bounds check
     |                                               # b[i]: no bounds check
  23 |     end
  24 |   end
```

A kept check names the fact the compiler could not prove:

```text
next_sum/1  test/report_test.exs:16
  16 |   defk next_sum(a :: [i64]) :: i64 do
  17 |     for i <- 0..(len(a) - 1)//1, reduce: 0 do  # loop: strips of DEFK_STRIP trips, one safepoint per strip
  18 |       acc -> acc + a[i + 1]                    # a[i + 1]: bounds check kept; nothing proves i + 1 < len(a)
  19 |     end
  20 |   end
```

## The data

Every module that uses `Defk` has `__defk_report__/0`, a list of
`{kernel, line, fact}`, so a test can assert that a hot loop is as tight as
a NIF's:

```elixir
for {{:dot, 2}, _line, {:bounds, :kept, _} = fact} <- Mod.__defk_report__(),
    do: flunk("dot keeps a bounds check: #{inspect(fact)}")
```

`kernel` is `{name, arity}` of a kernel called from Elixir. A note inside an
inlined call keeps the callee's line and belongs to the kernel it is inlined
into; `print/1` lists those after the kernel. `fact` is
`{topic, verdict, text}`; `Defk.Report` lists the topics: `:kernel`,
`:bounds`, `:branch`, `:loop`, `:nonfinite`, `:inline`, `:copy`, `:alloc`,
`:owned` (an `alloc` or a copy inside a loop, which keeps a buffer per
iteration until the kernel returns) and `:vectorize`.

defk's own facts are noted while the kernel is lowered. They cost no extra
compiler pass and nothing at run time.

## Vectorisation: `report: :full`

```elixir
defmodule Stats do
  use Defk, report: :full
  # ...
end
```

This adds a `{:vectorize, verdict, text}` fact to each loop, taken from
clang's `-Rpass=loop-vectorize`, `-Rpass-missed=loop-vectorize` and
`-Rpass-analysis=loop-vectorize` remarks. The verdict is `:vectorized`,
`:missed` (with clang's reasons), `:partial` (some of the loop's C forms,
such as the short loop and the strip loop, vectorised and some did not) or
`:unknown`. The cost is one extra compile of the module's C to a discarded
object file. Its result is cached beside the library, and the library is
built and cached exactly as without the option. When `CC` is not clang,
each loop reports `vectorised: unknown (CC is not clang)`. The report never
guesses.

The remarks are clang's: "vectorised" means the loop vectoriser rewrote the
loop. A float reduction such as `dot`'s stays in Elixir's order
(`-ffp-contract=off`, no reassociation), so clang vectorises its loads and
multiplies and keeps the adds in order.

The tests for this part are tagged `:clang` and are skipped when `CC` is not
clang. `mix test --only clang` runs only them.
