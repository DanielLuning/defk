# The compiler's state lives in one process-dictionary key (defk-euu): a
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
end
