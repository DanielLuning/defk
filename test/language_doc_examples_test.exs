defmodule Defk.LanguageDocExamplesTest do
  # Every example in every extra of the docs config (Defk.LanguageDoc.extras/0:
  # README.md, the guides, docs/language.md, ...) runs, and so does every
  # example in docs/performance.md, which is not an extra but a page people
  # copy kernels from (Defk.LanguageDoc has the conventions; a page opts a
  # fragment out with a skip: annotation). Kernels with iex> lines run in
  # native code and Elixir mode, agree, and give the documented results;
  # rejected examples fail with their error code; an unannotated kernel block
  # fails.
  use ExUnit.Case, async: true

  alias Defk.LanguageDoc

  @doc_paths Defk.LanguageDoc.extras() ++ ["docs/performance.md"]
  for path <- @doc_paths, do: @external_resource(path)

  # {doc path, example}; examples of different pages are told apart by path,
  # and their modules by source (Defk.LanguageDoc names them)
  @examples for path <- @doc_paths,
                ex <- LanguageDoc.extract(File.read!(path)),
                do: {path, ex}

  @dir Path.join(System.tmp_dir!(), "defk_language_doc_examples_test")

  @isolated LanguageDoc.isolated_jobs(@examples)

  # every example's module, compiled concurrently: %{line => compile result};
  # and the blocks that run in a BEAM of their own (sketches, ExUnit files,
  # scripts), started first, as they take longest
  setup_all do
    File.mkdir_p!(@dir)
    isolated = Task.async(fn -> Defk.LanguageDoc.Isolated.run(@isolated, @dir) end)

    compiled =
      @examples
      |> Enum.filter(fn {_, ex} -> compiled?(ex) end)
      |> Task.async_stream(fn {path, ex} -> {{path, ex.line}, LanguageDoc.compile(ex, @dir)} end,
        timeout: :infinity,
        ordered: false
      )
      |> Map.new(fn {:ok, r} -> r end)

    %{compiled: compiled, isolated: Task.await(isolated, :infinity)}
  end

  defp compiled?(%{check: check}),
    do: check == :run or match?({kind, _} when kind in [:compiles, :error], check)

  for {path, %{check: check} = ex} <- @examples, not match?({:skip, _}, check) do
    @path path
    @ex ex
    test "#{path}:#{ex.line} #{LanguageDoc.label(ex)}", %{compiled: compiled, isolated: isolated} do
      case Map.fetch(isolated, {@path, @ex.line}) do
        {:ok, :ok} -> :ok
        {:ok, {:error, why}} -> flunk("line #{@ex.line}: #{why}")
        :error -> LanguageDoc.verify!(@ex, Map.get(compiled, {@path, @ex.line}))
      end
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
            fence("x = 1", "text")
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

    test "plain Elixir blocks: sketches, test files and scripts" do
      doc =
        Enum.join(
          [
            fence("x = 1"),
            "<!-- defk-example run: a = 1 | defs: defp f, do: 1 -->",
            fence("a"),
            "<!-- defk-example skip: a fragment -->",
            fence("foo(...)"),
            fence("use ExUnit.Case"),
            "<!-- defk-example exunit: Stats from README.md -->",
            fence("use ExUnit.Case"),
            "<!-- defk-example script: the note -->",
            fence(@kernel),
            fence("not elixir", "text")
          ],
          "\n"
        )

      assert [
               {:sketch, %{setup: "", defs: ""}},
               {:sketch, %{setup: "a = 1", defs: "defp f, do: 1"}},
               {:skip, "a fragment"},
               {:exunit, nil},
               {:exunit, "Stats from README.md"},
               {:script, "the note"}
             ] = Enum.map(checks(doc), &elem(&1, 1))
    end

    test "a skip needs a reason" do
      for marker <- ["skip", "skip:", "skip:   ", "compiles", "script"],
          block <- [@kernel, "x = 1"] do
        doc = "<!-- defk-example #{marker} -->\n" <> fence(block)
        assert [{2, {:invalid, _}}] = checks(doc), "#{marker} on #{block}"
      end
    end

    test "sketches, test files and scripts run in a BEAM of their own, and fail there" do
      ok = %{
        id: :ok,
        kind: :sketch,
        source: "y = x + 1\ny # => 2",
        setup: "x = 1",
        defs: ""
      }

      module_level = %{
        id: :module_level,
        kind: :sketch,
        source: "def twice(x), do: 2 * x",
        setup: "twice(2) # => 4",
        defs: ""
      }

      wrong = %{ok | id: :wrong, source: "y = x + 1\ny # => 3"}
      broken = %{ok | id: :broken, source: "undefined_function()"}

      test_file = fn id, assertion ->
        %{
          id: id,
          kind: :exunit,
          needs: nil,
          deps: [],
          source:
            "defmodule T#{id} do\n  use ExUnit.Case\n  test \"t\", do: assert(#{assertion})\nend"
        }
      end

      script = fn id, last ->
        %{id: id, kind: :script, source: "Mix.install([])\n#{last}"}
      end

      jobs = [
        ok,
        module_level,
        wrong,
        broken,
        test_file.(:test_ok, "1 + 1 == 2"),
        test_file.(:test_bad, "1 + 1 == 3"),
        script.(:script_ok, "%{correct: true}"),
        script.(:script_bad, "%{correct: false}")
      ]

      results = Defk.LanguageDoc.Isolated.run(jobs, @dir)

      for id <- [:ok, :module_level, :test_ok, :script_ok], do: assert(results[id] == :ok)

      assert {:error, wrong_why} = results[:wrong]
      assert wrong_why =~ "documented # => 3, got 2"
      assert {:error, broken_why} = results[:broken]
      assert broken_why =~ "undefined"
      assert {:error, test_why} = results[:test_bad]
      assert test_why =~ "1 of 1 tests failed"
      assert {:error, script_why} = results[:script_bad]
      assert script_why =~ "the script's last value"
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
          ["## Codes", "", "### a-code", fence(@kernel), "## 12. Limits"],
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
            "<!-- defk-example known-failure: f/1 gives 2 -->",
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

      assert known.known_failure == "f/1 gives 2"
      LanguageDoc.verify!(known, LanguageDoc.compile(known, dir))
      fixed = %{known | steps: [%{hd(known.steps) | expected: {:value, "2"}}]}

      assert_raise ExUnit.AssertionError, ~r/remove its marker/, fn ->
        LanguageDoc.verify!(fixed, LanguageDoc.compile(fixed, dir))
      end
    end
  end
end
