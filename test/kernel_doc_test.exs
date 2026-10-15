defmodule Defk.KernelDocTest do
  use ExUnit.Case, async: false

  # not async: capture_io(:stderr) sees every test's warnings
  import ExUnit.CaptureIO

  # A @doc before a defk is the kernel's function's doc, as before a def; it
  # does not move to the next def of the module

  @dir Path.join(System.tmp_dir!(), "defk_kernel_doc_test")

  # {warnings, %{{name, arity} => {line, doc}}} of the module `src` defines
  defp docs(src) do
    File.mkdir_p!(@dir)

    # the suite may compile without docs chunks
    docs? = Code.get_compiler_option(:docs)
    Code.put_compiler_option(:docs, true)

    {[{mod, bin}], warnings} =
      try do
        with_io(:stderr, fn -> Code.compile_string(src) |> Enum.filter(&kernel_module?/1) end)
      after
        Code.put_compiler_option(:docs, docs?)
      end

    path = Path.join(@dir, "#{mod}.beam")
    File.write!(path, bin)
    {:docs_v1, _, _, _, _, _, entries} = Code.fetch_docs(path)

    {warnings,
     Map.new(entries, fn {{_, name, arity}, line, _, doc, _} -> {{name, arity}, {line, doc}} end)}
  end

  defp kernel_module?({mod, _}), do: String.starts_with?(inspect(mod), "Defk.KernelDocTest.K")

  test "a @doc before a defk documents the kernel, at its line, and not the next def" do
    {warnings, docs} =
      docs("""
      defmodule Defk.KernelDocTest.K1 do
        use Defk

        @doc "Adds one."
        defk inc(x :: i64) :: i64, do: x + 1

        @doc "Plain."
        def plain, do: 1

        def undocumented, do: 2
      end
      """)

    assert warnings == ""
    assert docs[{:inc, 1}] == {4, %{"en" => "Adds one."}}
    assert {_, %{"en" => "Plain."}} = docs[{:plain, 0}]
    assert {_, :none} = docs[{:undocumented, 0}]
  end

  test "@doc false hides the kernel; a kernel without one has none" do
    {warnings, docs} =
      docs("""
      defmodule Defk.KernelDocTest.K2 do
        use Defk

        @doc false
        defk hidden(x :: i64) :: i64, do: x

        defk bare(x :: i64) :: i64, do: x

        def after_bare, do: 1
      end
      """)

    assert warnings == ""
    assert {_, :hidden} = docs[{:hidden, 1}]
    assert {_, :none} = docs[{:bare, 1}]
    assert {_, :none} = docs[{:after_bare, 0}]
  end

  test "a multi-clause kernel takes its @doc before the head, with @impl" do
    {warnings, docs} =
      docs("""
      defmodule Defk.KernelDocTest.B3 do
        @callback twice(integer) :: integer
      end

      defmodule Defk.KernelDocTest.K3 do
        use Defk
        @behaviour Defk.KernelDocTest.B3

        @doc "Twice."
        @impl true
        defk twice(a :: i64) :: i64
        defk twice(0), do: 0
        defk twice(n), do: n * 2
      end
      """)

    assert warnings == ""
    assert {_, %{"en" => "Twice."}} = docs[{:twice, 1}]
  end
end
