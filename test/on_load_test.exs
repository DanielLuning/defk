defmodule Defk.OnLoadTest do
  use ExUnit.Case, async: false

  # defk-6c4: a module's own @on_load is chained after defk's load

  defp compile(n, hook_body) do
    Code.compile_string("""
    defmodule Defk.OnLoadTest.M#{n} do
      use Defk
      @on_load :init
      def init do
        #{hook_body}
      end

      defk ident(x :: i64) :: i64 do
        x
      end
    end
    """)
  end

  test "the module's own @on_load runs, after the kernels are usable" do
    key = {__MODULE__, :ran}
    on_exit(fn -> :persistent_term.erase(key) end)

    compile(1, """
    :persistent_term.put(#{inspect(key)}, {:ran, ident(41) + 1})
    :ok
    """)

    # the hook calls the kernel locally (a remote call to the module being
    # loaded is not possible inside its on_load)
    mod = Module.concat(Defk.OnLoadTest, M1)
    assert mod.ident(7) == 7
    assert :persistent_term.get(key) == {:ran, 42}
  end

  test "an @on_load given as {name, 0} is chained too" do
    [{mod, _}] =
      Code.compile_string("""
      defmodule Defk.OnLoadTest.Tuple do
        use Defk
        @on_load {:init, 0}
        defp init, do: :ok
        defk ident(x :: i64) :: i64, do: x
      end
      """)

    assert mod.ident(3) == 3
  end

  test "a hook returning something other than :ok keeps the module from loading" do
    # the failure is logged (asynchronously) and the module stays unloaded
    ExUnit.CaptureLog.capture_log(fn -> compile(2, "{:error, :nope}") end)

    refute Code.ensure_loaded?(Defk.OnLoadTest.M2)
  after
    :code.purge(Defk.OnLoadTest.M2)
    :code.delete(Defk.OnLoadTest.M2)
  end
end
