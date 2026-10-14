# Defk.Errors.Rewrites suggests kernel-subset rewrites for constructs and
# calls outside the subset. The property this file pins: every
# rejection names a registered code, and every suggested rewrite is valid
# Elixir — a suggestion the developer cannot paste is worse than none.
# compile_rewrites_test.exs stays the end-to-end net (the compiler shows
# only a rewrite that actually compiles in place).
defmodule Defk.RewritesTest do
  use ExUnit.Case, async: true

  alias Defk.Errors.Rewrites

  @registered Enum.map(Defk.Errors.entries(), & &1.code)

  # a corpus across the call_rejection table and the construct rejections
  defp corpus do
    arr = fn _ -> {:arr, :f64} end
    int = fn _ -> :i64 end

    [
      {quote(do: Enum.map(a, fn x -> x * 2.0 end)), arr},
      {quote(do: Enum.sum(a)), arr},
      {quote(do: Enum.product(a)), arr},
      {quote(do: Enum.min(a)), arr},
      {quote(do: Enum.max([a, b, c])), int},
      {quote(do: Enum.with_index(a)), arr},
      # credo:disable-for-next-line ExSlop.Check.Refactor.ExplicitSumReduce
      {quote(do: Enum.reduce(a, 0, fn x, acc -> acc + x end)), arr},
      {quote(do: Enum.reduce(a, 0, &+/2)), arr},
      {quote(do: Enum.find(a, fn x -> x > 0 end)), arr},
      {quote(do: Enum.count(a, fn x -> x > 0 end)), arr},
      {quote(do: Enum.each(a, fn x -> g(x) end)), arr},
      {quote(do: Enum.min_by(a, fn x -> x end)), arr},
      {quote(do: :math.erf(x)), int},
      {quote(do: Map.get(m, k)), fn _ -> nil end},
      {quote(do: String.length(s)), fn _ -> nil end},
      # credo:disable-for-next-line Credo.Check.Warning.IoInspect
      {quote(do: IO.inspect(x)), int},
      {quote(do: unknown_helper(x, y)), int}
    ]
  end

  defp rewrites(nil), do: []
  defp rewrites(opts), do: opts |> Keyword.get_values(:rewrite) |> List.flatten()

  # a remote call routes through unsupported/2 (form -> call_rejection);
  # a local name through unsupported_local/2
  test "every call rejection names a registered code and parses as a suggestion" do
    for {node, type_of} <- corpus() do
      {code, what, opts} = Rewrites.unsupported(node, type_of)
      assert code in @registered, "#{inspect(code)} is not a registered code"
      assert is_binary(what)

      for r <- rewrites(opts) do
        assert {:ok, _} = Code.string_to_quoted(r),
               "unparseable rewrite for #{Macro.to_string(node)}:\n#{r}"
      end
    end
  end

  test "local rejections do the same" do
    for node <- [
          quote(do: unknown_helper(x, y)),
          quote(do: unless(c, do: 1)),
          quote(do: throw(:x)),
          quote(do: a ++ b)
        ] do
      case Rewrites.unsupported_local(node, fn _ -> :i64 end) do
        # a local with no idiom here: the compiler has its own rejection
        nil ->
          :ok

        {code, _what, opts} ->
          assert code in @registered

          for r <- rewrites(opts) do
            assert {:ok, _} = Code.string_to_quoted(r)
          end
      end
    end
  end

  test "construct rejections do the same" do
    for node <- [
          quote(do: a ** b),
          quote(do: %{a: x}),
          quote(do: [x | rest]),
          quote(do: {:ok, x} = f(y))
        ] do
      {code, _what, opts} = Rewrites.unsupported(node, fn _ -> :i64 end)
      assert code in @registered

      for r <- rewrites(opts) do
        assert {:ok, _} = Code.string_to_quoted(r)
      end
    end
  end

  test "the for-collect recovery suggests parseable loops" do
    src = quote(do: a)
    x = quote(do: x)
    body = quote(do: x * 2.0)

    for suggestion <-
          List.wrap(Rewrites.collect_rewrites(src, x, body, nil, fn _ -> {:arr, :f64} end)) do
      assert {:ok, _} = Code.string_to_quoted(suggestion)
    end
  end
end
