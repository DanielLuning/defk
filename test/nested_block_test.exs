# A plain parenthesised block binds into the enclosing scope, as in Elixir
# (defk-pvp): `(x = a + 1; x); x * 2` sees x. Macro-generated bodies often
# arrive as a nested block. if/case/for keep their own scope. Each kernel is
# checked against Elixir mode.

defmodule Defk.NestedBlockTest.Macros do
  # a kernel whose body splices in two statements that bind x and y: the
  # spliced AST is a block nested in the kernel's body
  defmacro defsteps(name) do
    [a, x, y] = for n <- [:a, :x, :y], do: Macro.var(n, nil)

    steps =
      quote do
        unquote(x) = unquote(a) + 1
        unquote(y) = unquote(x) * 2
      end

    quote do
      defk unquote(name)(a :: i64) :: i64 do
        unquote(steps)
        x + y
      end
    end
  end
end

defmodule Defk.NestedBlockTest.K do
  use Defk
  import Defk.NestedBlockTest.Macros

  # the ticket's repro: x bound in the block is read after it
  defk used_after(a :: i64) :: i64 do
    (
      x = a + 1
      x
    )

    x * 2
  end

  # the block is the kernel's last expression
  defk last_expr(a :: i64) :: i64 do
    b = a * 3

    (
      c = b + 1
      c - a
    )
  end

  # the block's value is bound, and what it bound stays visible
  defk value_and_binding(a :: i64) :: i64 do
    v =
      (
        t = a + 5
        t * 2
      )

    v + t
  end

  defsteps(:macro_body)

  # a block that binds an existing variable again
  defk rebind(a :: i64) :: i64 do
    x = a

    (
      x = x + 1
      x = x * 2
    )

    x
  end

  # a nested block in a loop body: its bindings are the body's
  defk in_loop(n :: i64) :: i64 do
    for i <- 0..(n - 1)//1, reduce: 0 do
      acc ->
        (
          d = i * 2
          e = d + 1
        )

        acc + d + e
    end
  end

  # the block writes an array bound outside it
  defk writes_array(n :: i64) :: i64 do
    a = alloc(i64, n)
    b = a

    (
      a[0] = 7
      m = a[0] + 1
    )

    b[0] + a[0] + m
  end

  # an array bound in the block is read after it
  defk array_after(n :: i64) :: i64 do
    (
      a = alloc(i64, n)
      a[n - 1] = 4
      a
    )

    a[n - 1] + length(a)
  end

  # the block binds an input array's alias that is then written
  defk alias_input(a :: [i64]) :: i64 do
    (
      z = 1
      b = a
    )

    a[0] = 9
    b[0] + a[0] + z
  end

  # if keeps its own scope: the branch's x does not reach the outer x
  defk if_scope(a :: i64) :: i64 do
    x = a

    if a > 0 do
      y = x

      (
        x = y + 100
        x
      )
    end

    x
  end
end

defmodule Defk.NestedBlockTest do
  use ExUnit.Case, async: true
  use Defk.Properties

  import Defk.TestKit

  alias Defk.NestedBlockTest.K

  test "a binding in a nested block is visible after it" do
    assert {:ok, 12} = Defk.Test.assert_agrees(K, :used_after, [5])
  end

  test "a nested block as the kernel's last expression" do
    assert {:ok, 11} = Defk.Test.assert_agrees(K, :last_expr, [5])
  end

  test "the block's value and its bindings" do
    assert {:ok, 30} = Defk.Test.assert_agrees(K, :value_and_binding, [5])
  end

  test "a macro-generated body spliced as a block" do
    assert {:ok, 18} = Defk.Test.assert_agrees(K, :macro_body, [5])
  end

  test "a nested block that rebinds an existing variable" do
    assert {:ok, 12} = Defk.Test.assert_agrees(K, :rebind, [5])
  end

  test "a nested block inside a loop body" do
    assert {:ok, 28} = Defk.Test.assert_agrees(K, :in_loop, [4])
  end

  test "array writes and bindings in a nested block keep value semantics" do
    assert {:ok, 15} = Defk.Test.assert_agrees(K, :writes_array, [3])
    assert {:ok, 7} = Defk.Test.assert_agrees(K, :array_after, [3])
    assert {:ok, 10} = Defk.Test.assert_agrees(K, :alias_input, [i64s([0, 1])])
  end

  test "if keeps its own scope" do
    assert {:ok, 5} = Defk.Test.assert_agrees(K, :if_scope, [5])
  end

  test "a name bound only in an if branch is still undefined after it" do
    msg =
      reject(__MODULE__, """
        defk f(a :: i64) :: i64 do
          if a > 0 do
            (
              z = a
              z
            )
          end

          z
        end
      """)

    assert msg =~ "undefined variable z"
  end

  test "an array bound again in a nested block inside a loop body is still an error" do
    msg =
      reject(__MODULE__, """
        defk f(n :: i64) :: [i64] do
          prev = alloc(i64, n)
          cur = alloc(i64, n)

          for _ <- 1..3//1 do
            (
              {prev, cur} = {cur, prev}
              cur[0] = prev[0] + 1
            )
          end

          cur
        end
      """)

    assert msg =~ "the array cur is bound again inside this loop body"
    assert msg =~ "(defk array-rebind-in-loop"
  end

  agreement(K, [
    :used_after,
    :last_expr,
    :value_and_binding,
    :macro_body,
    :rebind,
    :if_scope,
    {:in_loop,
     args: StreamData.tuple({StreamData.integer(0..40)}) |> StreamData.map(&Tuple.to_list/1)},
    {:writes_array,
     args: StreamData.tuple({StreamData.integer(1..20)}) |> StreamData.map(&Tuple.to_list/1)},
    {:array_after,
     args: StreamData.tuple({StreamData.integer(1..20)}) |> StreamData.map(&Tuple.to_list/1)},
    :alias_input
  ])
end
