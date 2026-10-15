# defk: testing kernels

Elixir mode is the oracle. Each kernel also compiles to plain Elixir with
the subset's limits applied, in every module in `:test` (elsewhere with
`use Defk, elixir_mode: true`). A kernel and its Elixir mode agree when both
return `===` values (floats bit for bit), or both raise the same exception
module. Elixir mode is for tests only, never a fallback in production.
[Testing kernels](https://hexdocs.pm/defk/0.1.0/testing.html)

## One call, both ways

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
iex> Bytes.__defk_elixir__(:count_below, ["hello", 105])
2
iex> Defk.Test.assert_agrees(Bytes, :count_below, ["hello", 105])
{:ok, 2}
```

`Defk.ElixirMode.with_mode(:elixir, fun)` runs every kernel call of the
current process inside `fun` in Elixir mode.

## In a test file

An agreement property over generated inputs, with the boundary values mixed
in:

<!-- defk-example exunit: Bytes from usage-rules/testing.md -->
```elixir
defmodule BytesTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Defk.Test, only: [assert_agrees: 3]

  @edges [0, 1, 2047, 2048, 2049]

  test "agrees at the boundary lengths" do
    for n <- @edges, limit <- [0, 255, 256] do
      assert_agrees(Bytes, :count_below, [:crypto.strong_rand_bytes(n), limit])
    end
  end

  property "agrees on generated binaries" do
    check all(bytes <- binary(), limit <- integer(-1..257)) do
      assert_agrees(Bytes, :count_below, [bytes, limit])
    end
  end
end
```

Inputs that find disagreements:

- the integer limits (`-2**63`, `2**63 - 1`) and values around `2**53`;
- `0.0`, `-0.0`, the largest floats, and sums that overflow to inf;
- empty arrays, one element, and lengths around 2048, where loops switch to
  strips;
- binaries whose size is not a multiple of the element size;
- the edges of the kernel's own structure: for windows of `k` elements,
  lengths `k - 1`, `k`, `k + 1` and `2k`.

## The whole suite in Elixir mode

Set `config :defk, mode: :elixir` in `config/test.exs` and run the suite
again. It is refused outside `:dev` and `:test`.

## Forced yields

A long kernel yields and resumes; most tests never reach those paths.
`Mod.__defk_force_yields__(true)` makes the module's kernels yield at every
safepoint. The switch holds for every process, so use it in a test module
with `async: false`, and turn it off in an `after`. Check that
`Mod.__defk_stats__().yields` grew, so you know the kernel did yield.
