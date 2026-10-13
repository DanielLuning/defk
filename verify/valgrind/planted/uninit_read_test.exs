# A planted bug, NOT part of the suite (it lives outside test/). planted/run.sh
# plants a C bug in this kernel's generated code and runs it through the
# runner, which must fail. The kernel itself is correct: encode16's output is
# an unzeroed alloc/2 (every element is written by the loop), so defk skips
# the zeroing, and the plant makes the loop skip the odd bytes. Elixir then
# compares the result, which is what turns the unwritten bytes into a
# Memcheck "Conditional jump or move depends on uninitialised value(s)" with
# the origin at defk_alloc_raw_u8 in the generated C.
defmodule Defk.Planted.Hex do
  use Defk

  @hex "0123456789ABCDEF"

  defk encode16(s :: [u8]) :: [u8] do
    n = len(s)
    out = alloc(u8, 2 * n)

    for i <- 0..(n - 1)//1 do
      b = s[i]
      out[2 * i] = @hex[band(bsr(b, 4), 15)]
      out[2 * i + 1] = @hex[band(b, 15)]
    end

    out
  end
end

defmodule Defk.Planted.UninitReadTest do
  use ExUnit.Case, async: false

  test "encode16 agrees with Base.encode16" do
    src = :binary.copy(<<0x5A, 0xC3, 0x01, 0xFE>>, 25)
    assert Defk.Planted.Hex.encode16(src) == Base.encode16(src)
  end
end
