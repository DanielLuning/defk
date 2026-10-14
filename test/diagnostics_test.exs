# Defk.Errors.Diagnostics turns an AST node into line, column, span and
# source text. These units state the location rules on
# pathological source directly — what used to be reachable only by
# compiling a failing kernel and reading the rendered frame.
defmodule Defk.DiagnosticsTest do
  use ExUnit.Case, async: true

  alias Defk.Errors.Diagnostics

  defp lines(src), do: src |> String.split("\n") |> List.to_tuple()

  test "a positioned node gets its line, column and the span that parses back" do
    src = "defmodule M do\n  x = alpha + beta\nend"

    node =
      {:+, [line: 2, column: 13],
       [{:alpha, [line: 2, column: 7], nil}, {:beta, [line: 2, column: 15], nil}]}

    {line, col, width, text} = Diagnostics.locate(node, nil, lines(src))

    assert line == 2
    assert text == "  x = alpha + beta"
    # the span covers the whole expression from its earliest position
    assert col == 7
    assert width == String.length("alpha + beta")
  end

  test "without source lines the position survives with width 1" do
    node = {:x, [line: 4, column: 3], nil}
    assert Diagnostics.locate(node, nil, nil) == {4, 3, 1, nil}
  end

  test "an unpositioned node is found as a literal inside its statement" do
    src = "defmodule M do\n  y = f(a, 42)\nend"
    ctx = {:f, [line: 2, column: 7], [{:a, [line: 2, column: 9], nil}, 42]}

    {line, col, width, text} = Diagnostics.locate(42, ctx, lines(src))

    assert {line, text} == {2, "  y = f(a, 42)"}
    assert binary_part(text, col - 1, width) == "42"
  end

  test "an unpositioned node in an unpositioned statement reports line 0" do
    assert Diagnostics.locate(42, nil, nil) == {0, nil, 1, nil}
  end

  test "a position past the source's end degrades to the bare position" do
    node = {:x, [line: 99, column: 5], nil}
    assert Diagnostics.locate(node, nil, lines("one\ntwo")) == {99, 5, 1, nil}
  end

  test "a line-only position (no column) stays line-only" do
    node = {:x, [line: 3], nil}
    assert {3, nil, 1, nil} = Diagnostics.locate(node, nil, lines("a\nb\nc"))
  end

  test "compile_error caps the diagnostics shown and keeps the code's footer" do
    diags =
      for n <- 1..12 do
        %{
          code: "untyped-parameter",
          what: "parameter p#{n} has no type",
          file: "nofile",
          module: M,
          fun: {:f, 1},
          line: n,
          col: 1,
          width: 1,
          text: nil,
          key: {"untyped-parameter", n, 1}
        }
      end

    e = Diagnostics.compile_error(M, "nofile", diags)

    assert %CompileError{} = e
    assert e.description =~ "untyped-parameter"
    # at most 10 are rendered; the rest are counted
    assert e.description =~ "2 more"
  end
end
