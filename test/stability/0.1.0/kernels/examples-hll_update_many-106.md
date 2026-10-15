<!-- examples/hll_update_many.exs line 106 of v0.1.0. A frozen file is never edited. -->

<!-- defk-example compiles: a catalog kernel module -->
```elixir
defmodule Hll.Kernels do
  use Defk, elixir_mode: true

  @mask64 0xFFFFFFFFFFFFFFFF

  # ex_data_sketch's HLL state: a 4-byte header (version, p, 2 reserved
  # bytes) and 2^p one-byte registers. The top p bits of a hash pick the
  # register; the rank is 1 + the leading zeros of the low 64 - p bits,
  # counted in a (64 - p)-bit field, so an all-zero field gives 64 - p + 1.
  # clz of the field shifted to the top counts the same zeros, and 64 for
  # zero, which min/2 caps at 64 - p. The input state is copied once, before
  # the loop (the caller's binary is never changed), and written in place.
  defk update_many(state :: [u8], hashes :: [u64], p :: i64) :: [u8] do
    if p < 4 or p > 16 or length(state) != 4 + bsl(1, p) do
      raise ArgumentError, "invalid HLL state length or p"
    end

    bits = 64 - p

    for h <- hashes do
      j = 4 + bsr(h, bits)
      r = min(clz(band(bsl(h, p), @mask64)), bits) + 1
      state[j] = max(state[j], r)
    end

    state
  end
end
```
