defmodule Defk.LanguageDoc do
  @moduledoc false
  # The examples of docs/language.md and docs/scope.md, extracted
  # doctest-style (test/language_doc_examples_test.exs runs them), and the
  # heading anchors the doc tests check links against.
  #
  # A fenced block with a kernel in it (a line starting with `defk name`) is an
  # example. What is checked is said by the block itself or by an annotation,
  # an HTML comment on the line just above its opening fence:
  #
  #   - followed by a block of `iex>` lines (only blank lines between the two):
  #     the kernels are compiled, and each `iex>` expression runs in native code
  #     and in Elixir mode; the two must agree, and the native result must be
  #     the documented one (a value, `===`, or `** (Module) message`)
  #   - `<!-- defk-example compiles: <reason> -->`: compiled only (native and
  #     Elixir mode), where a run makes no sense, such as an example whose point
  #     is the generated C
  #   - `<!-- defk-example error: <code> -->`: must fail to compile with exactly
  #     that error code
  #   - `<!-- defk-example skip: <reason> -->`: not checked (a fragment); the
  #     reason is required, and the tests list every skip
  #   - `<!-- defk-example known-failure: <reason> -->`, above a runnable or
  #     compile-only block: checked as usual, and the check must fail; the
  #     reason names the compiler bug in words, and the marker comes off when
  #     it is fixed
  #
  #
  # Blocks with no kernel in them are checked too, in a separate BEAM (see
  # `Defk.LanguageDoc.Isolated`), where they can define modules and global
  # state freely:
  #
  #   - an `elixir` block is a sketch: it is compiled as the body of a function
  #     and run, and a trailing `# => value` on a line is checked against that
  #     line's value. What it needs is said by
  #     `<!-- defk-example run: <bindings> | defs: <module-level code> -->`
  #     (both parts optional): `bindings` is code run before the block (the
  #     variables it reads), and `defs` sits at module level (helper
  #     functions, attributes, stub modules). A block that starts with `def`,
  #     `defp` or an attribute is module-level code instead, and `run:` is the
  #     code that calls it. A sketch that cannot run (a fragment, kernel-only
  #     syntax) says so with `skip:`. Timing claims are not checked.
  #   - a block with `use ExUnit.Case` is a test file: it runs as real tests.
  #     `<!-- defk-example exunit: Stats from docs/guides/getting-started.md -->`
  #     adds the kernel module (the first `defmodule Stats` example of that
  #     page) it tests
  #   - `<!-- defk-example script: <note> -->`, above a kernel block that is a
  #     whole script: run with `Mix.install` removed (the project is already
  #     loaded), and its last value, a `Defk.Bench.report/1` result, must have
  #     agreed
  #
  # Anything else is a failure: a kernel block with no iex block and no
  # annotation, an iex block that follows no kernel, an annotation on a block
  # with no kernel, or one that doesn't parse. Kernels without a `defmodule`
  # are wrapped in one with `use Defk`, and the iex lines call it as `M`; a
  # block's own `defmodule Name` is renamed and the iex lines call it as
  # `Name`. The generated error catalogue (docs/compile-errors.md, "Codes") is
  # the registry's text (test/compile_errors_doc_test.exs) and its examples are
  # checked from the registry (test/contracts/defk/error_codes_contract_test.exs), so it is left
  # out here.

  import ExUnit.Assertions

  @kernel ~r/^\s*defk\s+[a-z_]/m
  @elixir_langs ["elixir", "ex", "exs"]
  @annotation ~r/^\s*<!--\s*defk-example\s+(.*?)\s*-->\s*$/

  defmodule Example do
    @moduledoc false
    # check: :run | {:compiles, reason} | {:error, code} | {:skip, reason} | {:invalid, why}
    #   | {:sketch, %{setup:, defs:}} | {:exunit, needs | nil} | {:script, note}
    defstruct [:line, :check, :known_failure, :source, :name, :module, steps: []]
  end

  # ------------------------------------------------------------ extraction --

  @doc """
  The examples of a Markdown document, in order.
  """
  def extract(doc) do
    lines = String.split(doc, "\n")
    skip = registry_span(lines)

    lines
    |> blocks()
    |> Enum.reject(fn b -> b.line in skip end)
    |> pair([])
    |> name_modules()
  end

  # lines of the generated error reference: from the first ### of the
  # "Codes" section (docs/compile-errors.md) to the next ## heading
  defp registry_span(lines) do
    numbered = Enum.with_index(lines, 1)

    with {_, h} <- Enum.find(numbered, fn {l, _} -> l =~ ~r/^## Codes$/ end),
         {_, first} <-
           Enum.find(numbered, fn {l, n} -> n > h and String.starts_with?(l, "### ") end) do
      last =
        Enum.find_value(numbered, length(lines), fn {l, n} ->
          if n > first and String.starts_with?(l, "## "), do: n
        end)

      first..last//1
    else
      _ -> []
    end
  end

  # fenced blocks: %{line:, body:, annotation:, adjacent?:} where line is the
  # opening fence's line and adjacent? whether only blank lines separate it
  # from the previous block's closing fence
  defp blocks(lines) do
    {blocks, _} =
      lines
      |> Enum.with_index(1)
      |> Enum.reduce({[], {:out, nil, nil}}, &fence/2)

    blocks |> Enum.filter(&is_map/1) |> Enum.reverse()
  end

  defp fence({line, n}, {acc, {:out, prev, last_close}}) do
    case Regex.run(~r/^(\s*)(```+|~~~+)/, line) do
      [_, indent, marker] ->
        # only blank lines since the last block closed (a prose line pushes :text)
        adjacent? = last_close != nil and match?([%{} | _], acc)

        lang =
          line
          |> String.trim()
          |> String.trim_leading(String.first(marker))
          |> String.split()
          |> List.first("")

        open = %{line: n, indent: String.length(indent), marker: marker, prev: prev, lang: lang}
        {acc, {:in, open, [], adjacent?}}

      nil ->
        acc = if String.trim(line) == "", do: acc, else: [:text | acc]
        {acc, {:out, line, last_close}}
    end
  end

  defp fence({line, n}, {acc, {:in, open, body, adjacent?}}) do
    closing = String.trim(line)

    if String.starts_with?(closing, open.marker) and closing =~ ~r/^(`+|~+)$/ do
      block = %{
        line: open.line,
        body: body |> Enum.reverse() |> Enum.join("\n"),
        annotation: annotation(open.prev),
        lang: open.lang,
        adjacent?: adjacent?
      }

      {[block | acc], {:out, nil, n}}
    else
      {acc, {:in, open, [dedent(line, open.indent) | body], adjacent?}}
    end
  end

  defp dedent(line, indent) do
    {lead, rest} = String.split_at(line, indent)
    if String.trim(lead) == "", do: rest, else: line
  end

  defp annotation(nil), do: nil

  defp annotation(line) do
    case Regex.run(@annotation, line) do
      [_, spec] -> parse_annotation(spec)
      nil -> nil
    end
  end

  defp parse_annotation(spec) do
    case ~r/^([a-z-]+)(?::\s*(.*))?$/ |> Regex.run(spec) |> with_argument() do
      [_, "compiles", reason] when is_binary(reason) and reason != "" ->
        {:compiles, reason}

      [_, "error", code] when is_binary(code) ->
        if code =~ ~r/^[a-z0-9-]+$/, do: {:error, code}, else: {:bad, spec}

      [_, "skip", reason] when is_binary(reason) and reason != "" ->
        {:skip, reason}

      [_, "run", spec] ->
        parse_run(spec || "")

      [_, "exunit", needs] ->
        {:exunit, needs}

      [_, "script", note] when is_binary(note) and note != "" ->
        {:script, note}

      [_, "known-failure", t] when is_binary(t) and t != "" ->
        {:known_failure, t}

      _ ->
        {:bad, spec}
    end
  end

  # Regex.run leaves out an unmatched trailing group: the argument is then nil
  defp with_argument([whole, name]), do: [whole, name, nil]
  defp with_argument(match), do: match

  # run: <bindings> | defs: <module-level code>
  defp parse_run(spec) do
    {setup, defs} =
      case String.split(spec, ~r/(^|\s)\|\s*defs:\s*/, parts: 2) do
        [setup, defs] -> {setup, defs}
        [setup] -> {setup, ""}
      end

    {:sketch, %{setup: String.trim(setup), defs: defs}}
  end

  defp kernel?(%{body: body}), do: body =~ @kernel
  defp iex?(%{body: body}), do: String.trim_leading(body) |> String.starts_with?("iex>")

  # pair each kernel block with the iex block right after it
  defp pair([], acc), do: Enum.reverse(acc)

  defp pair([k, i | rest], acc) do
    if kernel?(k) and iex?(i) and i.adjacent? and i.annotation == nil do
      pair(rest, [example(k, i) | acc])
    else
      pair([i | rest], add(k, acc))
    end
  end

  defp pair([b | rest], acc), do: pair(rest, add(b, acc))

  defp add(b, acc) do
    cond do
      kernel?(b) -> [example(b, nil) | acc]
      iex?(b) and not match?({:skip, _}, b.annotation) -> [orphan(b) | acc]
      b.lang in @elixir_langs -> [plain(b) | acc]
      b.annotation != nil -> [stray(b) | acc]
      true -> acc
    end
  end

  defp example(k, iex) do
    {check, known} =
      case {k.annotation, iex} do
        {nil, nil} ->
          {{:invalid, "a kernel block with no iex> block and no annotation"}, nil}

        {nil, _} ->
          {:run, nil}

        {{:known_failure, t}, nil} ->
          {{:compiles, "a known failure"}, t}

        {{:known_failure, t}, _} ->
          {:run, t}

        {{:bad, spec}, _} ->
          {{:invalid, "unknown annotation #{inspect(spec)}"}, nil}

        {other, nil} ->
          {other, nil}

        {other, _} ->
          {{:invalid, "annotated #{inspect(other)}, but followed by an iex> block"}, nil}
      end

    %Example{
      line: k.line,
      check: check,
      known_failure: known,
      source: k.body,
      steps: if(iex && check == :run, do: steps(iex), else: [])
    }
  end

  # an Elixir block with no kernel: a test file, a skipped fragment, or a sketch
  defp plain(%{annotation: ann} = b) do
    check =
      case ann do
        nil -> if b.body =~ "use ExUnit.Case", do: {:exunit, nil}, else: {:sketch, no_spec()}
        {:bad, spec} -> {:invalid, "unknown annotation #{inspect(spec)}"}
        {kind, _} = other when kind in [:skip, :exunit] -> other
        {:sketch, _} = other -> other
        _ -> {:invalid, "an annotation on a block with no kernel"}
      end

    %Example{line: b.line, source: b.body, check: check}
  end

  defp no_spec, do: %{setup: "", defs: ""}

  defp orphan(b),
    do: %Example{
      line: b.line,
      source: b.body,
      check: {:invalid, "an iex> block that follows no kernel block (annotate it skip: if meant)"}
    }

  defp stray(b),
    do: %Example{
      line: b.line,
      source: b.body,
      check: {:invalid, "an annotation on a block with no kernel"}
    }

  # iex> lines: %{line:, expr:, expected: nil | {:value, src} | {:raise, module, message}}
  defp steps(%{line: line, body: body}) do
    body
    |> String.split("\n")
    |> Enum.with_index(line + 1)
    |> Enum.reduce([], &step/2)
    |> Enum.map(&finish_step/1)
    |> Enum.reverse()
  end

  defp step({"iex> " <> expr, n}, acc), do: [%{line: n, expr: [expr], out: []} | acc]
  defp step({"iex>", n}, acc), do: [%{line: n, expr: [""], out: []} | acc]

  defp step({"...> " <> more, _}, [%{out: []} = s | acc]),
    do: [%{s | expr: [more | s.expr]} | acc]

  defp step({"", _}, acc), do: acc
  defp step({out, _}, [s | acc]), do: [%{s | out: [out | s.out]} | acc]

  defp finish_step(%{line: n, expr: expr, out: out}) do
    expr = expr |> Enum.reverse() |> Enum.join("\n")
    out = out |> Enum.reverse() |> Enum.join("\n")

    expected =
      case {out, Regex.run(~r/^\*\* \(([\w.]+)\) (.*)$/s, out)} do
        {"", _} -> nil
        {_, [_, mod, msg]} -> {:raise, mod, msg}
        {_, nil} -> {:value, out}
      end

    %{line: n, expr: expr, expected: expected}
  end

  # a module per example, named after its source so an unchanged example
  # reuses its native build (the build cache keys on the C source)
  defp name_modules(examples) do
    {named, _} =
      Enum.map_reduce(examples, MapSet.new(), fn ex, seen ->
        hash = :crypto.hash(:md5, ex.source) |> Base.encode16(case: :lower) |> binary_part(0, 8)
        mod = "Defk.LanguageDoc.Ex#{hash}"
        mod = if mod in seen, do: "#{mod}L#{ex.line}", else: mod

        name =
          case Regex.run(~r/^\s*defmodule\s+([\w.]+)\s+do/m, ex.source) do
            [_, name] -> name
            nil -> "M"
          end

        {%{ex | module: mod, name: name}, MapSet.put(seen, mod)}
      end)

    named
  end

  @doc """
  A short test name for an example: its check and its first kernel.
  """
  def label(%Example{} = ex) do
    kernel =
      case Regex.run(~r/^\s*defk\s+([a-z_][\w?!]*)/m, ex.source) do
        [_, k] -> k
        nil -> first_line(ex.source)
      end

    check =
      case ex.check do
        {kind, arg} when is_binary(arg) -> "#{kind} #{arg}"
        {kind, _} -> to_string(kind)
        kind -> to_string(kind)
      end

    known = if ex.known_failure, do: " (known failure #{ex.known_failure})", else: ""
    "#{check}: #{kernel}#{known}"
  end

  defp first_line(source) do
    source
    |> String.split("\n")
    |> Enum.find("-", &(String.trim(&1) != "" and not String.starts_with?(String.trim(&1), "#")))
    |> String.trim()
    |> String.slice(0, 40)
  end

  # ------------------------------------------------------ isolated checks --

  @doc """
  The jobs for `Defk.LanguageDoc.Isolated.run/2`: one per sketch, test file
  and script among `examples` (`{path, example}`).
  """
  def isolated_jobs(examples) do
    for {path, %{check: check} = ex} <- examples,
        job = isolated_job(check, ex, examples),
        do: Map.put(job, :id, {path, ex.line})
  end

  defp isolated_job({:sketch, spec}, ex, _),
    do: %{kind: :sketch, source: ex.source, setup: spec.setup, defs: spec.defs}

  defp isolated_job({:script, _}, ex, _), do: %{kind: :script, source: ex.source}

  defp isolated_job({:exunit, needs}, ex, examples),
    do: %{kind: :exunit, source: ex.source, needs: needs, deps: needed(needs, examples)}

  defp isolated_job(_, _, _), do: nil

  # "Stats from docs/guides/getting-started.md": the source of that page's
  # first runnable example defining the module
  defp needed(nil, _), do: []
  defp needed("", _), do: []

  defp needed(spec, examples) do
    with [_, name, page] <- Regex.run(~r/^([\w.]+) from (\S+)$/, spec),
         {_, ex} <-
           Enum.find(examples, fn {path, ex} ->
             path == page and ex.check == :run and ex.name == name
           end) do
      [ex.source]
    else
      _ ->
        raise ArgumentError,
              "exunit: #{inspect(spec)} names no `defmodule` example (NAME from PAGE)"
    end
  end

  # ---------------------------------------------------------------- extras --

  @doc """
  The Markdown extras (`.md` and cheatsheets, `.cheatmd`) of the HexDocs build, from the project's `:docs` config
  (the one list in mix.exs), so a new page is covered by the doc checks as soon
  as it is an extra.
  """
  def extras do
    for path <- Mix.Project.config()[:docs][:extras],
        Path.extname(path) in [".md", ".cheatmd"],
        do: path
  end

  @doc """
  The usage rules a dependent's agent reads (`mix usage_rules.sync` in their
  project): the main file and the sub-rules. They are not extras; they are
  inlined into another project's AGENTS.md, so their links are URLs.
  """
  def usage_rules, do: ["usage-rules.md" | Enum.sort(Path.wildcard("usage-rules/*.md"))]

  # ----------------------------------------------------------------- links --

  @doc """
  The link targets of a Markdown document's inline links (`[text](target)`),
  outside fenced code blocks and inline code.
  """
  def links(doc) do
    {_, kept} =
      doc
      |> String.split("\n")
      |> Enum.reduce({false, []}, fn line, {fenced?, acc} ->
        cond do
          Regex.match?(~r/^\s*(```|~~~)/, line) -> {not fenced?, acc}
          fenced? -> {fenced?, acc}
          true -> {fenced?, [line | acc]}
        end
      end)

    # a link's text may wrap over lines, so scan the joined prose
    kept
    |> Enum.reverse()
    |> Enum.join("\n")
    |> String.replace(~r/`[^`\n]*`/, "")
    |> then(&Regex.scan(~r/\]\(([^)\s]+)(?:\s+"[^"]*")?\)/, &1, capture: :all_but_first))
    |> List.flatten()
  end

  # ---------------------------------------------------------------- tables --

  @doc """
  The rows of the first Markdown table after `heading` in `doc`, without
  the header and the separator row, each the trimmed text of its cells (a
  cell holds no `|`).
  """
  def table(doc, heading) do
    [_, rest] = String.split(doc, heading, parts: 2)

    rest
    |> String.split("\n")
    |> Enum.drop_while(&(not row?(&1)))
    |> Enum.take_while(&row?/1)
    |> Enum.drop(2)
    |> Enum.map(&cells/1)
  end

  defp row?(line), do: String.starts_with?(String.trim(line), "|")

  defp cells(line),
    do: line |> String.trim() |> String.trim("|") |> String.split("|") |> Enum.map(&String.trim/1)

  # --------------------------------------------------------------- anchors --

  @doc """
  `{level, text}` of every Markdown heading outside fenced code blocks.
  """
  def headings(doc) do
    {hs, _} =
      doc
      |> String.split("\n")
      |> Enum.reduce({[], false}, fn line, {acc, fenced?} ->
        cond do
          String.starts_with?(line, "```") ->
            {acc, not fenced?}

          fenced? ->
            {acc, fenced?}

          m = Regex.run(~r/^(#+) (.*)$/, line) ->
            {[{String.length(Enum.at(m, 1)), Enum.at(m, 2)} | acc], fenced?}

          true ->
            {acc, fenced?}
        end
      end)

    Enum.reverse(hs)
  end

  @doc """
  The anchor of every heading, as GitHub makes it: lowercase, punctuation
  dropped, spaces to hyphens, and -1, -2, ... appended to repeats.
  """
  def anchors(doc) do
    {as, _} =
      doc
      |> headings()
      |> Enum.map_reduce(%{}, fn {_, text}, seen ->
        slug =
          text
          |> String.downcase()
          |> String.replace(~r/[^a-z0-9 _-]/u, "")
          |> String.replace(" ", "-")

        n = Map.get(seen, slug, 0)
        {if(n == 0, do: slug, else: "#{slug}-#{n}"), Map.put(seen, slug, n + 1)}
      end)

    as
  end

  # ------------------------------------------------------------- compiling --

  @doc """
  Compiles an example's module from a file in `dir`. Returns `:ok` or the
  `CompileError` message.
  """
  def compile(%Example{} = ex, dir) do
    source =
      if ex.name == "M" do
        "defmodule #{ex.module} do\n  use Defk\n\n#{ex.source}\nend\n"
      else
        String.replace(ex.source, ~r/^(\s*defmodule\s+)[\w.]+/m, "\\1#{ex.module}", global: false)
      end

    path = Path.join(dir, "#{ex.module}.ex")
    File.write!(path, source)

    # the diagnostics (unused variables in fragments of a kernel) are not ours
    {result, _diagnostics} =
      Code.with_diagnostics(fn ->
        try do
          Code.compile_file(path)
          :ok
        rescue
          e in CompileError -> Exception.message(e)
        end
      end)

    result
  end

  # --------------------------------------------------------------- checking --

  @doc """
  Checks a compiled example, and that a known failure still fails.
  """
  def verify!(%Example{known_failure: nil} = ex, compiled), do: check!(ex, compiled)

  def verify!(%Example{known_failure: ticket} = ex, compiled) do
    passed? =
      try do
        check!(ex, compiled)
        true
      rescue
        ExUnit.AssertionError -> false
      end

    refute passed?, "line #{ex.line}: a known failure (#{ticket}) passes: remove its marker"
  end

  @doc """
  Checks a compiled example (`compiled` is what `compile/2` gave), raising an
  `ExUnit.AssertionError` where it is not what the document says.
  """
  def check!(%Example{check: {:invalid, why}} = ex, _), do: flunk("line #{ex.line}: #{why}")

  def check!(%Example{check: {:error, code}} = ex, compiled) do
    assert is_binary(compiled), "line #{ex.line}: compiled, documented as error #{code}"
    codes = Regex.scan(~r/^\(defk ([a-z0-9-]+)[:;] /m, compiled, capture: :all_but_first)

    assert List.flatten(codes) == [code],
           "line #{ex.line}: documented as error #{code}, got:\n#{compiled}"
  end

  def check!(%Example{} = ex, compiled) do
    assert compiled == :ok, "line #{ex.line}: does not compile:\n#{compiled}"
    mod = Module.concat([ex.module])

    assert function_exported?(mod, :__defk_elixir__, 2),
           "line #{ex.line}: no Elixir mode compiled"

    _binding = Enum.reduce(ex.steps, [], fn s, binding -> run_step!(ex, mod, s, binding) end)
    :ok
  end

  defp run_step!(ex, mod, s, binding) do
    src = "alias #{inspect(mod)}, as: #{ex.name}\n#{s.expr}"
    where = "line #{s.line}: iex> #{s.expr}"

    native = eval(:native, src, binding)
    elixir = eval(:elixir, src, binding)
    agree!(where, native, elixir)
    documented!(where, native, s.expected, {inspect(mod), ex.name})

    case native do
      {:ok, _, binding} -> binding
      {:raise, _} -> binding
    end
  end

  defp eval(mode, src, binding) do
    Defk.ElixirMode.with_mode(mode, fn ->
      {value, binding} = Code.eval_string(src, binding)
      {:ok, value, binding}
    end)
  rescue
    e -> {:raise, e}
  end

  defp agree!(where, {:ok, a, _}, {:ok, b, _}),
    do: assert(a === b, "#{where}: native #{inspect(a)}, Elixir mode #{inspect(b)}")

  defp agree!(where, {:raise, a}, {:raise, b}) do
    reasons =
      {{a.__struct__, Defk.Test.agreement_reason(a)},
       {b.__struct__, Defk.Test.agreement_reason(b)}}

    assert elem(reasons, 0) == elem(reasons, 1),
           "#{where}: native raised #{inspect(a)}, Elixir mode raised #{inspect(b)}"
  end

  defp agree!(where, native, elixir),
    do: flunk("#{where}: native #{show(native)}, Elixir mode #{show(elixir)}")

  # `as`: {the module's name, the name the iex lines call it}, which a
  # message naming the module (a FunctionClauseError's) is documented with
  defp documented!(_, _, nil, _as), do: :ok

  defp documented!(where, {:ok, value, _}, {:value, src}, _as) do
    {expected, _} = Code.eval_string(src)
    assert value === expected, "#{where}: documented #{src}, got #{inspect(value)}"
  end

  defp documented!(where, {:raise, e}, {:raise, mod, msg}, {real, name}) do
    got = {inspect(e.__struct__), String.replace(Exception.message(e), real, name)}
    assert got == {mod, msg}, "#{where}: documented ** (#{mod}) #{msg}, got #{show({:raise, e})}"
  end

  defp documented!(where, native, expected, _as),
    do: flunk("#{where}: documented #{inspect(expected)}, got #{show(native)}")

  defp show({:ok, v, _}), do: inspect(v)
  defp show({:raise, e}), do: "** (#{inspect(e.__struct__)}) #{Exception.message(e)}"
end
