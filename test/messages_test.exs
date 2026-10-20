defmodule Defk.MessagesTest do
  # The runtime error messages have one source, Defk.Messages: the generated
  # priv/defk_messages.h is its text, the runtime header raises only with its
  # defines, Elixir mode interpolates its templates, and the agreement reason
  # of a message comes from the template it was raised with.
  use ExUnit.Case, async: true

  alias Defk.Messages
  require Messages

  @header "priv/defk_messages.h"
  @runtime "priv/defk_runtime.h"

  test "priv/defk_messages.h is the registry's text" do
    assert File.read!(@header) == Messages.header(),
           "regenerate with: mix defk.docs (docs/agents/generated-docs.md)"
  end

  test "each template names its holes once, in order, and names are unique" do
    entries = Messages.entries()

    for e <- entries do
      in_text = for {:hole, h} <- Messages.segments(e.text), do: h
      assert in_text == Keyword.keys(e.holes), "#{e.name}: holes #{inspect(in_text)}"
      assert Enum.uniq(in_text) == in_text, "#{e.name}: a hole is named twice"
    end

    names = Enum.map(entries, & &1.name)
    assert Enum.uniq(names) == names
  end

  test "the runtime header raises with the defines, never with a literal" do
    src = File.read!(@runtime)
    refute src =~ ~r/defk_fail\(ctx, \w+,\s*"/, "a defk_fail with a literal message"
    refute src =~ ~r/snprintf\(ctx->msg, sizeof ctx->msg,\s*"/, "a ctx->msg with a literal"
  end

  test "the runtime header uses every define raised from C, and no other" do
    used = ~r/DEFK_MSG_[A-Z0-9_]+/ |> Regex.scan(File.read!(@runtime)) |> List.flatten()
    defined = for e <- Messages.entries(), e.c, do: Messages.define(e.name)
    assert Enum.sort(Enum.uniq(used)) == Enum.sort(defined)
  end

  test "a rendered message maps back to its template's reason" do
    matched = Enum.filter(Messages.entries(), &(&1.exception in [ArgumentError, ArithmeticError]))

    for e <- matched do
      args = for {h, t} <- e.holes, do: {h, sample(t)}
      m = Messages.render(e.name, args)
      expected = e.reason || {:other, m}
      assert Messages.reason(struct(e.exception, message: m)) == expected, Atom.to_string(e.name)
    end
  end

  defp sample(:str), do: "copy/5"
  defp sample(:char), do: "/"
  defp sample(t) when t in [:f64, :f64_short], do: 1.5
  defp sample(_), do: 7

  test "Elixir's own exceptions and the module-level reasons" do
    assert Messages.reason(%ArithmeticError{message: "bad argument in arithmetic expression"}) ==
             :non_finite

    assert Messages.reason(%ArgumentError{
             message:
               "ranges (first..last//step) expect both sides to be integers and the step to be a non-zero integer, got: 1..2//0"
           }) == :zero_step

    assert Messages.reason(%Enum.OutOfBoundsError{}) == :index
    assert Messages.reason(%CaseClauseError{term: 1}) == :clause
    assert Messages.reason(%ArgumentError{message: "boom"}) == {:other, "boom"}
    assert Messages.reason(%RuntimeError{message: "boom"}) == {:other, "boom"}
  end

  test "text/2 is the template interpolated: to_string for :str holes, inspect otherwise" do
    assert Messages.text(:oob, i: 3, len: 2) == "index 3 out of bounds for array of length 2"
    assert Messages.text(:div_by_zero) == "div/2 by zero"

    assert Messages.text(:arg_binary, n: 1, p: :a, t: :i64) ==
             "argument 1 (a) must be a binary of packed i64"

    assert Messages.text(:value_f32, v: 1.0e39) == "value 1.0e39 does not fit in f32"

    assert Messages.text(:segment_fit, v: 9, n: 3, signed: " signed") ==
             "bitstring segment value 9 does not fit in 3 signed bits"
  end

  test "the C side: a define per hole type, and the literal for kernel C" do
    header = Messages.header()
    assert header =~ ~s(#define DEFK_MSG_OOB "index %lld out of bounds for array of length %lld")

    assert header =~
             ~s(#define DEFK_MSG_FLOAT_NONFINITE "float result of %.17g %c %.17g is inf or NaN")

    assert header =~
             ~s(#define DEFK_MSG_ARG_SIZE "argument %d \(%s\): byte size %zu is not a multiple of %zu \(%s\)")

    refute header =~ "DEFK_MSG_ROUND_FIT", "a template no C site raises has no define"
    assert Messages.c_literal(:range_step_zero) == ~s("range step cannot be zero")
  end
end
