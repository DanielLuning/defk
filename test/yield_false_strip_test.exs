defmodule Defk.YieldFalseStripTest do
  use ExUnit.Case, async: true

  # defk-5dd: a strip loop in a yield: false kernel computes v_rem_N, which
  # DEFK_SHORT(R) ignores under no-yield; it must still count as used, or
  # clang warns "variable set but not used".

  defmodule K do
    use Defk

    defk sum_nb(a :: [i64]) :: i64, yield: false do
      for x <- a, reduce: 0 do
        acc -> acc + x
      end
    end
  end

  defp i64s(list), do: for(x <- list, into: <<>>, do: <<x::64-signed-native>>)

  test "a yield: false strip loop compiles without set-but-not-used" do
    src = K.__defk_source__()
    assert src =~ "DEFK_SHORT(v_rem_"

    dir = Path.join(System.tmp_dir!(), "defk_yield_false_strip_test")
    File.mkdir_p!(dir)
    c = Path.join(dir, "k.c")
    File.write!(c, src)
    priv = Path.expand("../priv", __DIR__)

    {out, status} =
      System.cmd(
        System.get_env("CC", "cc"),
        ~w(-fsyntax-only -std=gnu11 -Werror=unused-but-set-variable) ++
          ["-I", Defk.Build.erts_include(), "-I", priv, c],
        stderr_to_stdout: true
      )

    assert status == 0, out
    refute out =~ "set but not used"
    assert K.sum_nb(i64s([1, 2, 3, 4, 5])) == 15
  end
end
