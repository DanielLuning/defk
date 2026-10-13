defmodule Defk.DocsChecksTest do
  # Checks that keep the docs true (defk-djy.7), beside the example runner
  # (test/language_doc_examples_test.exs) and `mix docs --warnings-as-errors`:
  #
  #   - every link between extras, and to repo files, resolves, anchors included,
  #     and every relative link names a page that exists in the built docs
  #   - every module with `iex>` in its docs has a `doctest` call in the suite
  #   - every error code has an example and a rewrite
  #   - every public function of a documented module has a @doc
  use ExUnit.Case, async: true

  alias Defk.LanguageDoc

  @repo_url "https://github.com/DanielLuning/defk/blob/main/"

  # the library's modules (not the examples of test/support)
  defp lib_modules do
    lib = Path.expand("lib")

    for mod <- Application.spec(:defk, :modules),
        String.starts_with?(to_string(mod.module_info(:compile)[:source]), lib),
        do: mod
  end

  # ----------------------------------------------------------------- links --

  describe "links" do
    test "every relative link in an extra resolves to a file and, where it names one, a heading" do
      broken =
        for page <- LanguageDoc.extras(),
            target <- page |> File.read!() |> LanguageDoc.links(),
            reason = broken_link(page, target),
            do: "#{page}: (#{target}) #{reason}"

      assert broken == [], Enum.join(["broken links:" | broken], "\n  ")
    end

    # HexDocs is flat: every page is doc/<name>.html (and .md), and a relative
    # link resolves there only when it names another extra (mix.exs rewrites
    # the Markdown copies by file name; `mix docs` then fails on any relative
    # link in doc/ that leads nowhere). A repo file that is not an extra needs
    # its GitHub URL.
    test "every relative link in an extra names a page of the built docs" do
      unresolved =
        for page <- LanguageDoc.extras(),
            target <- page |> File.read!() |> LanguageDoc.links(),
            not String.match?(target, ~r/^([a-z]+:|#)/),
            Defk.MixProject.hexdocs_link(target) == :error,
            do: "#{page}: (#{target})"

      assert unresolved == [],
             Enum.join(
               ["not a page in HexDocs (link a GitHub URL instead):" | unresolved],
               "\n  "
             )
    end

    test "links to extras become their page in the built docs" do
      assert Defk.MixProject.hexdocs_link("../language.md#3-types") ==
               {:ok, "language.md#3-types"}

      assert Defk.MixProject.hexdocs_link("cheatsheet.cheatmd") == {:ok, "cheatsheet.md"}
      assert Defk.MixProject.hexdocs_link("../README.md") == {:ok, "readme.md"}
      assert Defk.MixProject.hexdocs_link("../../examples/_template.exs") == :error
    end

    test "the link checker catches a missing file, a missing anchor and a stale repo link" do
      page = "README.md"
      assert broken_link(page, "docs/no-such-page.md") =~ "no such file"
      assert broken_link(page, "docs/language.md#no-such-heading") =~ "no heading"
      assert broken_link(page, "#no-such-heading") =~ "no heading"
      assert broken_link(page, @repo_url <> "lib/no_such.ex") =~ "no such file"
      assert broken_link(page, @repo_url <> "mix.exs") == nil
      assert broken_link(page, "https://hexdocs.pm/elixir") == nil
    end
  end

  # nil, or why `target`, linked from `page`, is broken
  defp broken_link(_, @repo_url <> path), do: check_file(path, nil)
  defp broken_link(_, "http" <> _), do: nil
  defp broken_link(_, "mailto:" <> _), do: nil
  defp broken_link(page, "#" <> anchor), do: check_anchor(page, anchor)

  defp broken_link(page, target) do
    [path | fragment] = String.split(target, "#", parts: 2)

    check_file(
      page |> Path.dirname() |> Path.join(path) |> Path.expand("/") |> Path.relative_to("/"),
      fragment
    )
  end

  defp check_file(path, fragment) do
    {path, fragment} =
      case String.split(path, "#", parts: 2) do
        [p, f] -> {p, [f]}
        [p] -> {p, fragment || []}
      end

    cond do
      not File.exists?(path) -> "no such file #{path}"
      fragment != [] and Path.extname(path) == ".md" -> check_anchor(path, hd(fragment))
      true -> nil
    end
  end

  defp check_anchor(path, anchor) do
    unless anchor in LanguageDoc.anchors(File.read!(path)), do: "no heading ##{anchor} in #{path}"
  end

  # --------------------------------------------------------------- doctests --

  describe "doctests" do
    # the modules of the app whose docs have an `iex>` example
    defp modules_with_examples do
      for mod <- lib_modules(),
          {:docs_v1, _, _, _, moduledoc, _, docs} <- [Code.fetch_docs(mod)],
          Enum.any?([moduledoc | for({_, _, _, d, _} <- docs, do: d)], &iex?/1),
          do: mod
    end

    defp iex?(%{"en" => text}), do: text =~ ~r/^\s*iex>/m
    defp iex?(_), do: false

    # the modules a test file runs doctests of
    defp doctested do
      for file <- Path.wildcard("test/**/*.exs"),
          [_, mod] <- Regex.scan(~r/^\s*doctest\s+([A-Z][\w.]*)/m, File.read!(file)),
          do: Module.concat([mod])
    end

    test "every module with iex> examples in its docs has a doctest call" do
      missing = modules_with_examples() -- doctested()
      assert missing == [], "add `doctest #{inspect(missing)}` to a test file"
    end

    test "the examples are found at all" do
      assert Defk.Bits in modules_with_examples()
    end
  end

  # ------------------------------------------------------- error catalogue --

  describe "the error catalogue" do
    # codes raised by the build environment, not by a kernel, so no example
    @no_example ["no-c-compiler"]

    test "every error code has a failing example and a rewrite (compile_errors_test runs them)" do
      for %{code: code, example: example, rewrite: rewrite} <- Defk.Errors.codes() do
        if code in @no_example do
          assert example == nil and rewrite == nil,
                 "#{code} has an example: remove it from @no_example"
        else
          assert is_binary(example) and example != "", "#{code}: no example"
          assert is_binary(rewrite) and rewrite != "", "#{code}: no rewrite"
          assert example != rewrite, "#{code}: the rewrite is the example"
        end
      end
    end
  end

  # --------------------------------------------------- generated functions --

  describe "generated functions" do
    # the `__defk_*__/n` names in the first column of the Markdown table that
    # follows `heading` in `text`
    defp table_names(text, heading) do
      [_, after_heading] = String.split(text, heading, parts: 2)

      after_heading
      |> String.split("\n")
      |> Enum.drop_while(&(not String.starts_with?(String.trim(&1), "|")))
      |> Enum.take_while(&String.starts_with?(String.trim(&1), "|"))
      |> Enum.flat_map(&Regex.scan(~r/^\s*\| `(__defk_\w+__\/\d)`/, &1, capture: :all_but_first))
      |> List.flatten()
      |> Enum.sort()
    end

    # what a kernel module with Elixir mode exports, less the hidden ones
    # (ADR-0006: the loader, the native entry points, the test-only fault hooks)
    defp exported do
      for {name, arity} <- Examples.Kernels.__info__(:functions),
          s = Atom.to_string(name),
          String.starts_with?(s, "__defk_"),
          not String.starts_with?(s, "__defk_native_"),
          name not in [
            :__defk_load__,
            :__defk_load_nif__,
            :__defk_corrupt_tags__,
            :__defk_inject_fault__
          ],
          do: "#{name}/#{arity}"
    end

    test "the Defk moduledoc and the language reference list every generated function" do
      {:docs_v1, _, _, _, %{"en" => moduledoc}, _, _} = Code.fetch_docs(Defk)
      in_moduledoc = table_names(moduledoc, "## Generated functions")
      in_language = table_names(File.read!("docs/language.md"), "### What `use Defk` generates")

      assert in_moduledoc == Enum.sort(exported())
      assert in_language == in_moduledoc
    end
  end

  # ------------------------------------------------------ public function docs --

  describe "public API docs" do
    # Functions still waiting for a @doc. A new undocumented function is not
    # on this list, so it fails.
    @known_gaps []

    defp undocumented do
      for mod <- lib_modules(),
          {:docs_v1, _, _, _, moduledoc, _, docs} <- [Code.fetch_docs(mod)],
          moduledoc != :hidden,
          {{kind, name, arity}, _, _, :none, _} <- docs,
          kind in [:function, :macro],
          do: {mod, name, arity}
    end

    test "every public function and macro of a documented module has a @doc or is @doc false" do
      new = undocumented() -- @known_gaps
      assert new == [], "document these (or mark them @doc false): #{inspect(new)}"
    end

    test "the known gaps list holds only functions that are still undocumented" do
      fixed = @known_gaps -- undocumented()
      assert fixed == [], "remove from @known_gaps: #{inspect(fixed)}"
    end
  end
end
