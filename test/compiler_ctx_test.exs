# The compiler's state lives in one process-dictionary key: a
# %Defk.Compiler.Ctx{} under :defk_ctx, snapshotted and restored as one
# value by probing and backtracking. This test pins the invariant that no
# other defk-prefixed key survives a compile, so no state can leak past the
# ctx again without failing here.
defmodule Defk.CompilerCtxTest do
  use ExUnit.Case, async: false

  defp defk_keys do
    for {k, _} <- Process.get(),
        is_atom(k) and String.starts_with?(Atom.to_string(k), "defk_"),
        do: k
  end

  test "after compile/4, the ctx is the only defk-prefixed key" do
    for k <- defk_keys(), do: Process.delete(k)

    kernel = %{
      head: quote(do: double(x :: i64) :: i64),
      name: :double,
      arity: 1,
      params: [x: :i64],
      ret: :i64,
      yield: true,
      body: quote(do: x + x),
      opts: []
    }

    {_c, _sigs, report} = Defk.Compiler.compile(Defk.CompilerCtxTest.K, [kernel], nil)

    assert defk_keys() == [:defk_ctx]
    assert is_list(report)
  end

  # Elixir mode's translation keeps its own state the same way, in one key
  # (:defk_em) holding one struct, fresh per kernel and gone when
  # definitions/3 returns: no translation state outlives a compile either.
  test "after ElixirMode.definitions/3, the ctx is still the only defk-prefixed key" do
    for k <- defk_keys(), do: Process.delete(k)

    kernel = %{
      head: quote(do: total(xs :: [i64]) :: i64),
      name: :total,
      arity: 1,
      params: [xs: {:arr, :i64}],
      ret: :i64,
      yield: true,
      body:
        quote do
          Enum.reduce_while(xs, 0, fn x, acc ->
            if acc > 100, do: {:halt, acc}, else: {:cont, acc + x}
          end)
        end,
      opts: []
    }

    {_c, sigs, _report} = Defk.Compiler.compile(Defk.CompilerCtxTest.E, [kernel], nil)
    defs = Defk.ElixirMode.definitions([kernel], sigs, "ctx_test.ex")

    assert match?([_ | _], defs)
    assert defk_keys() == [:defk_ctx]
  end
end
