defmodule Defk.Errors.Diagnostics do
  # Rejections as the developer sees them: the CompileError for a
  # module, each diagnostic rendered with a source frame, and the location
  # machinery that turns an AST node into line, column and span against the
  # source text. Pure given its arguments; the code registry stays in
  # Defk.Errors (footer/1, indent_block/1).
  @moduledoc false

  # at most this many rejections shown per module (as in Defk.Errors)
  @cap 10

  # ------------------------------------------------------------ rendering --

  @doc false
  # The CompileError for a module's rejections, at most @cap of them shown.
  def compile_error(module, file, diags) do
    diags = Enum.sort_by(diags, &{&1.line, &1.col})
    {shown, rest} = Enum.split(diags, @cap)
    n = length(diags)

    head =
      "cannot compile #{inspect(module)}: #{n} kernel compile error#{if n == 1, do: "", else: "s"}"

    more = if rest == [], do: [], else: ["#{length(rest)} more not shown; fix these first"]

    %CompileError{
      file: file,
      line: 0,
      description: Enum.join([head | Enum.map(shown, &render/1)] ++ more, "\n\n")
    }
  end

  @doc false
  # The CompileError for a C compiler that cannot be run (enoent).
  def no_compiler(module, file, cc) do
    entry = Defk.Errors.fetch!("no-c-compiler")

    description =
      Enum.join(
        [
          "error: cannot compile #{inspect(module)}: C compiler `#{cc}` not found",
          "",
          "why: #{entry.why}",
          "hint: #{entry.hint}",
          Defk.Errors.footer(entry.code)
        ],
        "\n"
      )

    %CompileError{file: file, line: 0, description: description}
  end

  @doc false
  # Style D: Elixir's diagnostic frame, then why, hint (with a rewrite) and the code.
  def render(d) do
    entry = Defk.Errors.fetch!(d.code)
    why = d[:why] || entry.why
    hint = d[:hint] || entry.hint

    hint =
      case d[:rewrite] do
        nil -> hint
        rw -> "#{hint}:\n\n" <> Defk.Errors.indent_block(rw)
      end

    Enum.join(
      [frame(d), "", "why: #{why}", "hint: #{hint}", Defk.Errors.footer(d.code)],
      "\n"
    )
  end

  defp frame(d) do
    loc =
      "#{relative(d.file)}#{if d.line > 0, do: ":#{d.line}"}#{if d.line > 0 and d.col, do: ":#{d.col}"}"

    fun = with {name, arity} <- d.fun, do: ": #{inspect(d.module)}.#{name}/#{arity}"

    case d.text do
      text when is_nil(text) or is_nil(d.col) ->
        "error: #{d.what}\n└─ #{loc}#{fun}"

      text ->
        pad = String.duplicate(" ", String.length("#{d.line}"))
        caret = String.duplicate(" ", d.col - 1) <> String.duplicate("^", max(d.width, 1))

        Enum.join(
          [
            "error: #{d.what}",
            "#{pad} │",
            "#{d.line} │#{text}",
            "#{pad} │#{caret}",
            "#{pad} │",
            "#{pad} └─ #{loc}#{fun}"
          ],
          "\n"
        )
    end
  end

  defp relative(nil), do: "nofile"
  defp relative(file), do: Path.relative_to_cwd(file)

  # -------------------------------------------------------------- parsing --
  # The rendering read back (Defk.Errors.diagnostics/1): each rejection is the
  # lines from an `error: ` line to its footer, with at most one location
  # line (`└─ file[:line[:col]][: Module.name/arity]`) in its frame. A change
  # to frame/1 or Defk.Errors.footer/1 changes this too.

  @footer ~r/^\(defk ([a-z0-9-]+): \S+\)$/
  @where ~r/^\s*└─ (.+?)(?::(\d+))?(?::(\d+))?(?:: (\S+)\.([^.\s]+)\/(\d+))?$/

  @doc false
  def parse(message) do
    [first | rest] = String.split(message, "\n")

    # a CompileError's message puts "file: " before its first line
    first =
      case String.split(first, ": error: ", parts: 2) do
        [_file, what] -> "error: " <> what
        _ -> first
      end

    {diags, _open} =
      Enum.reduce([first | rest], {[], nil}, fn line, {done, open} ->
        cond do
          String.starts_with?(line, "error: ") ->
            {done, %{message: String.replace_prefix(line, "error: ", "")}}

          open == nil ->
            {done, nil}

          match = Regex.run(@footer, line, capture: :all_but_first) ->
            {[finish(open, hd(match)) | done], nil}

          not Map.has_key?(open, :where) and Regex.match?(@where, line) ->
            {done, Map.put(open, :where, Regex.run(@where, line, capture: :all_but_first))}

          true ->
            {done, open}
        end
      end)

    Enum.reverse(diags)
  end

  defp finish(open, code) do
    {file, line, col, module, kernel} =
      case open[:where] do
        nil ->
          {nil, nil, nil, nil, nil}

        [file | rest] ->
          {file, int(Enum.at(rest, 0)), int(Enum.at(rest, 1)), module(rest), kernel(rest)}
      end

    %{
      code: code,
      message: open.message,
      file: file,
      line: line,
      column: col,
      module: module,
      kernel: kernel
    }
  end

  defp int(nil), do: nil
  defp int(""), do: nil
  defp int(digits), do: String.to_integer(digits)

  defp module([_, _, mod, _, _]) when mod != "", do: existing_atom("Elixir." <> mod)
  defp module(_), do: nil

  defp kernel([_, _, _, name, arity]) when name != "",
    do: with(atom when atom != nil <- existing_atom(name), do: {atom, int(arity)})

  defp kernel(_), do: nil

  # the module and kernel names exist as atoms once their module was compiled;
  # a message from elsewhere must not create atoms
  defp existing_atom(name) do
    String.to_existing_atom(name)
  rescue
    ArgumentError -> nil
  end

  # ------------------------------------------------------------- location --

  @doc false
  # {line, col, width, line_text} of `node` in the source. A node without
  # metadata (a literal) is searched for inside `ctx`, the enclosing statement.
  def locate(node, ctx, lines) do
    case start(node) do
      {line, col} ->
        place(lines, line, col, node)

      nil ->
        case start(ctx) do
          nil -> {0, nil, 1, nil}
          {line, nil} -> {line, nil, 1, nil}
          {line, col} -> find_literal(lines, line, col, node) || place(lines, line, col, ctx)
        end
    end
  end

  # earliest {line, column} in the node's metadata
  defp start(nil), do: nil

  defp start(node) do
    {_, acc} =
      Macro.prewalk(node, [], fn
        {_, m, _} = n, acc when is_list(m) ->
          if m[:line] && m[:column], do: {n, [{m[:line], m[:column]} | acc]}, else: {n, acc}

        n, acc ->
          {n, acc}
      end)

    if acc == [], do: line_only(node), else: Enum.min(acc)
  end

  defp line_only({_, m, _}) when is_list(m), do: if(m[:line], do: {m[:line], nil})
  defp line_only(_), do: nil

  defp source_line(nil, _), do: nil

  defp source_line(lines, line) when line >= 1 and line <= tuple_size(lines),
    do: elem(lines, line - 1)

  defp source_line(_, _), do: nil

  # a node from a macro has a line but no column: no caret, no text, no width
  defp place(_lines, line, nil, _node), do: {line, nil, 1, nil}

  defp place(lines, line, col, node) do
    case source_line(lines, line) do
      nil ->
        {line, col, 1, nil}

      text ->
        {col, width} = span(text, col, node)
        {line, col, width, text}
    end
  end

  # The columns of `node` on its first line: the longest slice from its start
  # (or an opening bracket just before it) that parses back to the node. A node
  # that doesn't fit on one line is underlined to the end of its first line.
  defp span(text, col, node) do
    norm = strip(node)
    len = String.length(text)

    starts = [col | opening_brackets(text, col)]

    exact =
      Enum.find_value(starts, fn s ->
        Enum.find_value((len - s + 1)..1//-1, fn w ->
          if parses_to?(String.slice(text, s - 1, w), norm), do: {s, w}
        end)
      end)

    exact || {col, max(String.length(String.trim_trailing(text)) - col + 1, 1)}
  end

  # columns of `(`, `{` or `[` directly before `col` (whitespace between)
  defp opening_brackets(text, col) do
    text
    |> String.slice(0, col - 1)
    |> String.graphemes()
    |> Enum.with_index(1)
    |> Enum.reverse()
    |> Enum.reduce_while([], fn
      {c, i}, acc when c in ["(", "{", "["] -> {:cont, acc ++ [i]}
      {c, _}, acc when c in [" ", "\t"] -> {:cont, acc}
      _, acc -> {:halt, acc}
    end)
  end

  defp parses_to?(snippet, norm) do
    case Code.string_to_quoted(snippet, emit_warnings: false) do
      {:ok, ast} -> strip(ast) == norm
      _ -> false
    end
  rescue
    _ -> false
  end

  defp strip(ast) do
    Macro.prewalk(ast, fn
      {a, m, b} when is_list(m) -> {a, [], b}
      other -> other
    end)
  end

  # a literal (no metadata) is found by its text after the statement's start
  defp find_literal(nil, _line, _col, _node), do: nil

  defp find_literal(lines, line, col, node) do
    needle = Macro.to_string(node)

    Enum.find_value(line..min(line + 30, tuple_size(lines)), fn l ->
      text = elem(lines, l - 1)
      from = if l == line, do: col - 1, else: 0
      {pre, rest} = String.split_at(text, from)

      case :binary.match(rest, needle) do
        {pos, _} ->
          {l, String.length(pre) + String.length(binary_part(rest, 0, pos)) + 1,
           String.length(needle), text}

        :nomatch ->
          nil
      end
    end)
  end
end
