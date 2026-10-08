defmodule DefkTest do
  use ExUnit.Case, async: true

  test "Defk.Test.assert_agrees works" do
    defmodule T do
      use Defk

      defk add1(x :: i64) :: i64 do
        x + 1
      end
    end

    assert Defk.Test.assert_agrees(T, :add1, [5]) == {:ok, 6}
  end
end
