# Testing kernels

A kernel must give the result Elixir would, or raise where its types can't
hold that result. The way to check this is to run the same kernel as plain
Elixir and compare. This guide shows how, from one call to generated inputs,
and how to test the code paths a kernel takes when it yields.

## Elixir mode is the oracle

Each kernel body is also compiled to plain Elixir, with the kernel subset's
limits applied: a value that does not fit its type raises there too. This is
**Elixir mode**. It is for tests and debugging only, never a fallback in
production. Its results define what the kernel should give, and a kernel and
its Elixir mode **agree** on an input when:

- both return identical values (`===`, so floats must be bit-exact), or
- both raise the same exception module for the same reason. The messages
  may differ: Elixir's own float errors say "bad argument in arithmetic
  expression" where the kernel names the operation.

Elixir mode is compiled into every kernel module in the `:test` environment.
Elsewhere, add `use Defk, elixir_mode: true` (in a `Mix.install` script, for
example). The details are in [Elixir mode](../language.md#10-elixir-mode).

## Running a call both ways

Take a kernel that counts the bytes of a binary below a limit.
`Mod.__defk_elixir__(name, args)` runs one call in Elixir mode,
`Defk.ElixirMode.with_mode/2` runs every kernel call of the current process
in the mode you name, and `Defk.Test.assert_agrees(mod, fun, args)` runs a
call both ways, asserts that they agree, and returns the native outcome,
`{:ok, value}` or `{:raise, exception}`:

```elixir
defmodule Bytes do
  use Defk

  defk count_below(bytes :: [u8], limit :: i64) :: i64 do
    for b <- bytes, reduce: 0 do
      n -> if b < limit, do: n + 1, else: n
    end
  end
end
```

```elixir
iex> Bytes.count_below("hello", 105)
2
iex> Bytes.__defk_elixir__(:count_below, ["hello", 105])
2
iex> Defk.ElixirMode.with_mode(:elixir, fn -> Bytes.count_below("hello", 105) end)
2
iex> Defk.Test.assert_agrees(Bytes, :count_below, ["hello", 105])
{:ok, 2}
iex> {:raise, e} = Defk.Test.assert_agrees(Bytes, :count_below, [:hello, 105])
iex> e.__struct__
ArgumentError
```

When they disagree, the assertion fails with both outcomes in the message.

## In a test file

The same calls in an ExUnit module, with an agreement property over inputs
from `stream_data`:

<!-- defk-example exunit: Stats from docs/guides/getting-started.md -->
```elixir
defmodule StatsTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Defk.Test, only: [assert_agrees: 3]

  defp pack(xs), do: for(x <- xs, into: <<>>, do: <<x::float-64-native>>)

  test "sums a few values" do
    assert Stats.sum(pack([1.5, 2.5, 4.0])) == 8.0
  end

  test "agrees with Elixir mode where it raises" do
    assert_agrees(Stats, :sum, [pack([1.0e308, 1.0e308])])
    assert_agrees(Stats, :sum, [<<1, 2, 3>>])
  end

  property "agrees with Elixir mode on generated inputs" do
    check all(xs <- list_of(float())) do
      assert_agrees(Stats, :sum, [pack(xs)])
    end
  end
end
```

(`Stats` is the kernel from [Getting started](getting-started.md).)

### Choosing inputs

Random inputs rarely hit the places where native code and Elixir part ways.
Mix them with edge values:

- the `i64` limits and their neighbours (`-2**63`, `2**63 - 1`), and
  values around `2**53`, where a float stops holding every integer;
- `0.0` and `-0.0`, subnormals, the largest floats, and inputs whose
  arithmetic overflows to inf (both sides must raise at the same operation);
- empty arrays, arrays of one element, and lengths around 2048, where a
  flat loop switches from one plain loop to strips
  ([yielding](../language.md#9-yielding-and-the-runtime-contract-in-practice));
- binaries whose size is not a multiple of the element size, and values
  that do not fit a narrow element type on write.
- the boundaries of your kernel's own structure: for a kernel that works in
  windows or rows of `k` elements, lengths `k - 1`, `k`, `k + 1` and `2k`,
  and a last window that is cut short.

For a `[u8]` kernel, the input is the binary itself, so `stream_data`'s
`binary/1` generates it directly. Mix generated lengths with the boundary
ones (here 2048, the strip length, and the edges of the byte values that
`limit` cuts at):

<!-- defk-example exunit: Bytes from docs/guides/testing.md -->
```elixir
defmodule BytesTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Defk.Test, only: [assert_agrees: 3]

  @edges [0, 1, 2047, 2048, 2049, 4096]

  test "agrees at the boundary lengths" do
    for n <- @edges, limit <- [0, 1, 255, 256] do
      assert_agrees(Bytes, :count_below, [:crypto.strong_rand_bytes(n), limit])
    end
  end

  property "agrees on generated binaries" do
    check all(
            n <- one_of([integer(0..100), member_of(@edges)]),
            bytes <- binary(length: n),
            limit <- integer(-1..257)
          ) do
      assert_agrees(Bytes, :count_below, [bytes, limit])
    end
  end
end
```

defk's own suite draws from such generators
([`test/support/generators.ex`](https://github.com/DanielLuning/defk/blob/main/test/support/generators.ex))
and writes one agreement property per kernel
([`test/support/properties.ex`](https://github.com/DanielLuning/defk/blob/main/test/support/properties.ex)).
They are test support, not part of the library, but you can copy the
approach.

### Running a whole suite in Elixir mode

To run the whole suite in Elixir mode, set `config :defk, mode: :elixir` in
`config/test.exs`. It is refused outside `:dev` and `:test`.

## Forced yields

A long kernel yields to its scheduler and later resumes where it stopped
(see [The runtime contract](runtime-contract.md)). Resuming must never change
the result, but on most inputs a kernel never yields in a test, so those code
paths go untested. `Mod.__defk_force_yields__(true)` makes the module's
kernels yield at every clock read, so every resume path runs. Here a loop over rows, which
can yield after each row:

```elixir
defmodule Grid do
  use Defk

  defk row_max_sum(cells :: [i64], width :: i64) :: i64 do
    rows = div(length(cells), width)

    for r <- 0..(rows - 1)//1, reduce: 0 do
      total ->
        best =
          for c <- 0..(width - 1)//1, reduce: cells[r * width] do
            m -> max(m, cells[r * width + c])
          end

        total + best
    end
  end
end
```

```elixir
iex> cells = for i <- 1..20_000, into: <<>>, do: <<rem(i * 7, 100)::signed-64-native>>
iex> expected = Grid.row_max_sum(cells, 100)
iex> Grid.__defk_force_yields__(true)
:ok
iex> Grid.row_max_sum(cells, 100) === expected
true
iex> Grid.__defk_force_yields__(false)
:ok
```

The switch is per module and holds for every process, so a test that uses
it should not run beside other tests of the same module: give it a module of
its own with `async: false`, and turn it off in an `after`. Check
`__defk_stats__/0` to make sure the kernel really yielded; a kernel with no
loops, or an input too short to reach a safepoint, never does:

<!-- defk-example exunit: Stats from docs/guides/getting-started.md -->
```elixir
defmodule StatsYieldTest do
  use ExUnit.Case, async: false

  test "a forced yield at every safepoint gives the same result" do
    xs = for i <- 1..100_000, into: <<>>, do: <<i * 0.5::float-64-native>>
    expected = Stats.sum(xs)

    Stats.__defk_force_yields__(true)

    try do
      yields = Stats.__defk_stats__().yields
      assert Stats.sum(xs) === expected
      assert Stats.__defk_stats__().yields > yields
    after
      Stats.__defk_force_yields__(false)
    end
  end
end
```

## Debugging

In Elixir mode, `dbg/1` and `IO.inspect/1,2` inside a kernel body print as
they would in Elixir (native code ignores them), and
`Mod.__defk_elixir_source__/0` returns the generated Elixir. Use
`Defk.ElixirMode.with_mode(:elixir, fn -> ... end)` to run a failing call
that way.

To check that a hot loop stays fast, not only correct, a test can assert on
`Mod.__defk_report__/0`, the fast-path report (`Defk.Report`) as data:
which bounds checks were dropped, which loops vectorised.
