defmodule Defk.ImplTest do
  use ExUnit.Case, async: false

  # not async: capture_io(:stderr) sees every test's warnings
  import ExUnit.CaptureIO

  # defk-ltt: @impl before a defk is for the kernel's function, not for the
  # generated __defk_load__/0

  @behaviour_src """
  defmodule Defk.ImplTest.B%{n} do
    @callback mask(integer, integer) :: integer
    @callback twice(integer) :: integer
  end
  """

  defp compile(n, body) do
    src = String.replace(@behaviour_src, "%{n}", "#{n}") <> body
    capture_io(:stderr, fn -> Code.compile_string(src) end)
  end

  test "@impl true before a defk implements the callback without warnings" do
    assert compile(1, """
           defmodule Defk.ImplTest.K1 do
             use Defk
             @behaviour Defk.ImplTest.B1
             @impl true
             defk mask(a :: i64, b :: i64) :: i64, do: bxor(a, b)
             @impl true
             defk twice(a :: i64) :: i64, do: a * 2
           end
           """) == ""

    assert Module.concat(Defk.ImplTest, K1).mask(6, 3) == 5
  end

  test "@impl with the behaviour module works the same" do
    assert compile(2, """
           defmodule Defk.ImplTest.K2 do
             use Defk
             @behaviour Defk.ImplTest.B2
             @impl Defk.ImplTest.B2
             defk mask(a :: i64, b :: i64) :: i64, do: bxor(a, b)
             @impl Defk.ImplTest.B2
             defk twice(a :: i64) :: i64, do: a * 2
           end
           """) == ""
  end

  test "a multi-clause kernel takes @impl before its head" do
    assert compile(3, """
           defmodule Defk.ImplTest.K3 do
             use Defk
             @behaviour Defk.ImplTest.B3
             @impl true
             defk twice(a :: i64) :: i64
             defk twice(0), do: 0
             defk twice(n), do: n * 2
             @impl true
             defk mask(a :: i64, b :: i64) :: i64, do: bxor(a, b)
           end
           """) == ""

    assert Module.concat(Defk.ImplTest, K3).twice(4) == 8
  end

  test "@impl true before a defk that matches no callback names the kernel" do
    err =
      compile(4, """
      defmodule Defk.ImplTest.K4 do
        use Defk
        @behaviour Defk.ImplTest.B4
        @impl true
        defk other(a :: i64) :: i64, do: a
        @impl true
        defk mask(a :: i64, b :: i64) :: i64, do: bxor(a, b)
        @impl true
        defk twice(a :: i64) :: i64, do: a
      end
      """)

    assert err =~ "other/1"
    refute err =~ "__defk_load__"
  end

  test "works in Elixir mode and with a bitstring result" do
    assert compile(5, """
           defmodule Defk.ImplTest.K5 do
             use Defk, elixir_mode: true
             @behaviour Defk.ImplTest.B5
             @impl true
             defk mask(a :: i64, b :: i64) :: i64, do: bxor(a, b)
             @impl true
             defk twice(a :: i64) :: i64, yield: false, do: a * 2
           end
           """) == ""
  end
end
