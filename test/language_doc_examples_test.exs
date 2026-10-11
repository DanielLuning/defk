defmodule Defk.LanguageDocExamplesTest do
  # Every example in docs/language.md and docs/scope.md runs (Defk.LanguageDoc
  # has the conventions): kernels with iex> lines run in native code and Elixir
  # mode, agree, and give the documented results; rejected examples fail with
  # their error code; an unannotated kernel block fails.
  use ExUnit.Case, async: true

  alias Defk.LanguageDoc

  @doc_paths ["docs/language.md", "docs/scope.md"]
  for path <- @doc_paths, do: @external_resource(path)

  # {doc path, example}; examples of different pages are told apart by path,
  # and their modules by source (Defk.LanguageDoc names them)
  @examples for path <- @doc_paths,
                ex <- LanguageDoc.extract(File.read!(path)),
                do: {path, ex}

  @dir Path.join(System.tmp_dir!(), "defk_language_doc_examples_test")

  # every example's module, compiled concurrently: %{line => compile result}
  setup_all do
    File.mkdir_p!(@dir)

    compiled =
      @examples
      |> Enum.filter(fn {_, ex} -> compiled?(ex) end)
      |> Task.async_stream(fn {path, ex} -> {{path, ex.line}, LanguageDoc.compile(ex, @dir)} end,
        timeout: :infinity,
        ordered: false
      )
      |> Map.new(fn {:ok, r} -> r end)

    %{compiled: compiled}
  end

  defp compiled?(%{check: check}),
    do: check == :run or match?({kind, _} when kind in [:compiles, :error], check)

  for {path, %{check: check} = ex} <- @examples, not match?({:skip, _}, check) do
    @path path
    @ex ex
    test "#{path}:#{ex.line} #{LanguageDoc.label(ex)}", %{compiled: compiled} do
      LanguageDoc.verify!(@ex, Map.get(compiled, {@path, @ex.line}))
    end
  end

  describe "the conventions" do
    defp checks(doc), do: doc |> LanguageDoc.extract() |> Enum.map(&{&1.line, &1.check})

    defp fence(body, info \\ "elixir"), do: "```#{info}\n#{body}\n```"

    @kernel "defk f(x :: i64) :: i64 do\n  x + 1\nend"

    test "a kernel block followed by an iex> block runs" do
      doc = Enum.join(["Text.", fence(@kernel), "", fence("iex> M.f(1)\n2", "")], "\n")
      assert [%{check: :run, name: "M", steps: [step]}] = LanguageDoc.extract(doc)
      assert step == %{line: 9, expr: "M.f(1)", expected: {:value, "2"}}
    end

    test "a kernel block with neither iex> lines nor an annotation is a failure" do
      assert [{1, {:invalid, _}}] = checks(fence(@kernel))

      assert [{1, {:invalid, _}}, {7, {:invalid, "an iex> block that follows no kernel" <> _}}] =
               checks(fence(@kernel) <> "\nprose\n" <> fence("iex> M.f(1)\n2"))
    end

    test "annotations" do
      doc =
        Enum.join(
          [
            "<!-- defk-example compiles: the point is the C -->",
            fence(@kernel),
            "<!-- defk-example error: unsupported-map -->",
            fence("defk g(x :: i64) :: i64, do: %{a: x}"),
            "  <!-- defk-example skip: a fragment -->",
            "  " <> fence("defk h(x :: i64) :: i64"),
            "<!-- defk-example compiles -->",
            fence(@kernel),
            "<!-- defk-example skip: no kernel here -->",
            fence("x = 1")
          ],
          "\n"
        )

      assert [
               {2, {:compiles, "the point is the C"}},
               {8, {:error, "unsupported-map"}},
               {12, {:skip, "a fragment"}},
               {16, {:invalid, "unknown annotation" <> _}},
               {22, {:invalid, "an annotation on a block with no kernel"}}
             ] = checks(doc)
    end

    test "steps: continuations, raises, bindings without output" do
      iex = "iex> a = 1\niex> M.f(\n...>   a)\n** (ArithmeticError) boom\n\niex> M.f(2)\n3"
      [%{steps: steps}] = LanguageDoc.extract(fence(@kernel) <> "\n\n" <> fence(iex))

      assert [
               %{expr: "a = 1", expected: nil},
               %{expr: "M.f(\n  a)", expected: {:raise, "ArithmeticError", "boom"}},
               %{expr: "M.f(2)", expected: {:value, "3"}}
             ] = steps
    end

    test "the generated error reference is left out" do
      doc =
        Enum.join(
          ["## 11. Compile errors", "", "### a-code", fence(@kernel), "## 12. Limits"],
          "\n"
        )

      assert checks(doc) == []
    end

    test "an error example, a wrong result and a known failure" do
      doc =
        Enum.join(
          [
            "<!-- defk-example error: unsupported-map -->",
            fence("defk g(x :: i64) :: i64, do: %{a: x}"),
            fence(@kernel),
            fence("iex> M.f(1)\n3"),
            "<!-- defk-example known-failure: defk-xyz -->",
            fence(@kernel <> "\n"),
            fence("iex> M.f(1)\n3")
          ],
          "\n"
        )

      # modules of their own, apart from the document's
      [error, wrong, known] =
        for ex <- LanguageDoc.extract(doc),
            do: %{ex | module: "#{inspect(__MODULE__)}.L#{ex.line}"}

      dir = @dir

      assert LanguageDoc.verify!(error, LanguageDoc.compile(error, dir))

      assert_raise ExUnit.AssertionError, ~r/documented 3, got 2/, fn ->
        LanguageDoc.verify!(wrong, LanguageDoc.compile(wrong, dir))
      end

      assert known.known_failure == "defk-xyz"
      LanguageDoc.verify!(known, LanguageDoc.compile(known, dir))
      fixed = %{known | steps: [%{hd(known.steps) | expected: {:value, "2"}}]}

      assert_raise ExUnit.AssertionError, ~r/remove its marker/, fn ->
        LanguageDoc.verify!(fixed, LanguageDoc.compile(fixed, dir))
      end
    end
  end
end
