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
  #   - `<!-- defk-example skip: <reason> -->`: not checked (a fragment)
  #   - `<!-- defk-example known-failure: <ticket> -->`, above a runnable or
  #     compile-only block: checked as usual, and the check must fail; the
  #     ticket is the compiler bug, and the marker comes off when it is fixed
  #
  # Anything else is a failure: a kernel block with no iex block and no
  # annotation, an iex block that follows no kernel, an annotation on a block
  # with no kernel, or one that doesn't parse. Kernels without a `defmodule`
  # are wrapped in one with `use Defk`, and the iex lines call it as `M`; a
  # block's own `defmodule Name` is renamed and the iex lines call it as
  # `Name`. The generated error reference (section 11, "Compile errors") is
  # the registry's text (test/language_doc_test.exs) and its examples are
  # checked from the registry (test/compile_errors_test.exs), so it is left
  # out here.

  import ExUnit.Assertions

  @kernel ~r/^\s*defk\s+[a-z_]/m
  @annotation ~r/^\s*<!--\s*defk-example\s+(.*?)\s*-->\s*$/

  defmodule Example do
    @moduledoc false
    # check: :run | {:compiles, reason} | {:error, code} | {:skip, reason} | {:invalid, why}
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
  # "Compile errors" section to the next ## heading
  defp registry_span(lines) do
    numbered = Enum.with_index(lines, 1)

    with {_, h} <- Enum.find(numbered, fn {l, _} -> l =~ ~r/^## \d+\. Compile errors$/ end),
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
        open = %{line: n, indent: String.length(indent), marker: marker, prev: prev}
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
    case Regex.run(~r/^([a-z-]+)(?::\s*(.*))?$/, spec) do
      [_, "compiles", reason] when reason != "" ->
        {:compiles, reason}

      [_, "error", code] ->
        if code =~ ~r/^[a-z0-9-]+$/, do: {:error, code}, else: {:bad, spec}

      [_, "skip", reason] when reason != "" ->
        {:skip, reason}

      [_, "known-failure", t] ->
        if t =~ ~r/^defk-\w+/, do: {:known_failure, t}, else: {:bad, spec}

      _ ->
        {:bad, spec}
    end
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
        nil -> "-"
      end

    check =
      case ex.check do
        {kind, arg} -> "#{kind} #{arg}"
        kind -> to_string(kind)
      end

    known = if ex.known_failure, do: " (known failure #{ex.known_failure})", else: ""
    "#{check}: #{kernel}#{known}"
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
