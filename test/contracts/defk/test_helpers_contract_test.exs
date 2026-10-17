defmodule Defk.Contract.TestHelpersTest do
  # The meaning of Defk.Test and Defk.ElixirMode.with_mode/2
  # (public_api.obligations.md, I9 and I10). A kernel agrees with its Elixir
  # mode by design, so the disagreements assert_agrees must catch come from
  # Fake: a plain module with a kernel module's interface (the function, and
  # the generated __defk_elixir__/2 and __defk_force_yields__/1) whose native
  # and Elixir answers are set per test. Like every contract test it calls
  # only defk's public API and Defk.ContractKit (test/contracts/README.md).
  #
  # async: false: Fake's answers and the forced-yields flag are global.
  use Covenant.Case, component: "defk.public_api", async: false

  import ExUnit.CaptureIO

  defmodule K do
    @moduledoc false
    use Defk, elixir_mode: true

    defk(double(x :: i64) :: i64, do: x * 2)

    defk(at(a :: [i64], i :: i64) :: i64, do: a[i])

    defk pick(x :: i64) :: i64 do
      case x do
        0 -> 10
        1 -> 11
      end
    end

    # prints in Elixir mode only, so a test sees which mode ran
    defk show(x :: i64) :: i64 do
      # the fixture's point: the print shows which mode ran (ADR-0004)
      # credo:disable-for-next-line Credo.Check.Warning.IoInspect
      IO.inspect(x)
    end
  end

  defmodule Fake do
    @moduledoc false
    # the outcome of a call, per mode: {:ok, value} or {:raise, exception}
    def set(native, elixir, forced \\ nil),
      do: :persistent_term.put(__MODULE__, %{native: native, elixir: elixir, forced: forced})

    def f(_x) do
      %{native: native, forced: forced} = :persistent_term.get(__MODULE__)

      give(
        if :persistent_term.get({__MODULE__, :yields}, false), do: forced || native, else: native
      )
    end

    def __defk_elixir__(:f, [_x]), do: give(:persistent_term.get(__MODULE__).elixir)

    def __defk_force_yields__(on), do: :persistent_term.put({__MODULE__, :yields}, on)

    def forced?, do: :persistent_term.get({__MODULE__, :yields}, false)

    defp give({:ok, value}), do: value
    defp give({:raise, e}), do: raise(e)
  end

  # a failed or broken run may leave forced yields on
  setup do
    Fake.__defk_force_yields__(false)
    K.__defk_force_yields__(false)
    :ok
  end

  defp disagrees(fun),
    do: assert_raise(ExUnit.AssertionError, fun)

  describe "I9: Defk.Test detects a disagreement" do
    @tag obligation: "defk.public_api.I9"
    test "agreement returns the native outcome, values and raises alike" do
      assert Defk.Test.assert_agrees(K, :double, [21]) == {:ok, 42}

      assert {:raise, e} = Defk.Test.assert_agrees(K, :double, [2 ** 62])
      assert {e.__struct__, Defk.Test.agreement_reason(e)} == {ArithmeticError, :overflow}

      assert {:raise, e} = Defk.Test.assert_agrees(K, :at, [<<1::signed-64-native>>, 3])
      assert {e.__struct__, Defk.Test.agreement_reason(e)} == {Enum.OutOfBoundsError, :index}

      assert {:raise, e} = Defk.Test.assert_agrees(K, :pick, [7], forced_yields: true)
      assert {e.__struct__, Defk.Test.agreement_reason(e)} == {CaseClauseError, :clause}
    end

    @tag obligation: "defk.public_api.I9"
    test "a different value, or a raise against a value, fails" do
      Fake.set({:ok, 1}, {:ok, 1})
      assert Defk.Test.assert_agrees(Fake, :f, [0]) == {:ok, 1}

      Fake.set({:ok, 1}, {:ok, 2})
      disagrees(fn -> Defk.Test.assert_agrees(Fake, :f, [0]) end)

      # identical, not equal: 1 and 1.0 differ
      Fake.set({:ok, 1}, {:ok, 1.0})
      disagrees(fn -> Defk.Test.assert_agrees(Fake, :f, [0]) end)

      Fake.set({:raise, %ArithmeticError{}}, {:ok, 1})
      disagrees(fn -> Defk.Test.assert_agrees(Fake, :f, [0]) end)

      Fake.set({:ok, 1}, {:raise, %ArithmeticError{}})
      disagrees(fn -> Defk.Test.assert_agrees(Fake, :f, [0]) end)
    end

    @tag obligation: "defk.public_api.I9"
    test "another exception module or reason fails; another message only under message: :exact" do
      Fake.set({:raise, %ArgumentError{message: "a"}}, {:raise, %ArithmeticError{}})
      disagrees(fn -> Defk.Test.assert_agrees(Fake, :f, [0]) end)

      overflow = %ArithmeticError{message: "i64 overflow in 1 + 2"}
      index = %Enum.OutOfBoundsError{message: "index 3 out of bounds for array of length 1"}
      assert Defk.Test.agreement_reason(overflow) == :overflow
      assert Defk.Test.agreement_reason(index) == :index

      other = %ArithmeticError{message: "i64 overflow in 5 + 6"}
      Fake.set({:raise, overflow}, {:raise, other})
      assert {:raise, ^overflow} = Defk.Test.assert_agrees(Fake, :f, [0])
      disagrees(fn -> Defk.Test.assert_agrees(Fake, :f, [0], message: :exact) end)
    end

    @tag obligation: "defk.public_api.I9"
    test "forced_yields: true also compares a forced run, and turns forced yields off after" do
      Fake.set({:ok, 1}, {:ok, 1}, {:ok, 9})
      assert Defk.Test.assert_agrees(Fake, :f, [0]) == {:ok, 1}
      disagrees(fn -> Defk.Test.assert_agrees(Fake, :f, [0], forced_yields: true) end)
      refute Fake.forced?()

      Fake.set({:ok, 1}, {:ok, 1}, {:ok, 1})
      assert Defk.Test.assert_agrees(Fake, :f, [0], forced_yields: true) == {:ok, 1}
      refute Fake.forced?()
    end

    @tag obligation: "defk.public_api.I9"
    test "a function that is not exported fails" do
      disagrees(fn -> Defk.Test.assert_agrees(K, :double, [1, 2]) end)
      disagrees(fn -> Defk.Test.assert_agrees(K, :no_such_kernel, [1]) end)
    end
  end

  describe "I10: with_mode/2 switches the calling process only" do
    @tag obligation: "defk.public_api.I10"
    test "a kernel runs in the given mode inside fun, and fun's value is returned" do
      out =
        capture_io(fn -> assert Defk.ElixirMode.with_mode(:elixir, fn -> K.show(3) end) == 3 end)

      assert out == "3\n"

      out =
        capture_io(fn -> assert Defk.ElixirMode.with_mode(:native, fn -> K.show(4) end) == 4 end)

      assert out == ""
    end

    @tag obligation: "defk.public_api.I10"
    test "other processes keep their mode, and the previous mode comes back, also after a raise" do
      out =
        capture_io(fn ->
          Defk.ElixirMode.with_mode(:elixir, fn ->
            Task.await(Task.async(fn -> K.show(5) end))
            Defk.ElixirMode.with_mode(:native, fn -> K.show(6) end)
            K.show(7)
          end)
        end)

      assert out == "7\n"

      assert_raise RuntimeError, fn ->
        Defk.ElixirMode.with_mode(:elixir, fn -> raise "inside" end)
      end

      assert capture_io(fn -> K.show(8) end) == ""
    end
  end
end
