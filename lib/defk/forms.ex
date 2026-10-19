defmodule Defk.Forms do
  @moduledoc false
  # The shape of a body form, parsed once for both modes. The compiler and
  # Elixir mode each give a form its own meaning (ADR-0008: shape is shared,
  # meaning is written twice); what they share is what a `for` holds, what
  # a case clause holds, and the parts of an Enum.reduce_while/all?/any?
  # call, so a new option or clause shape is matched in one place.
  # Enum.reduce/3 and Enum.find/3 are rewritten into those forms before
  # either mode sees the body (desugar/1, as Defk.Attributes.inline/1 does
  # for attributes).
  #
  # A shape outside the kernel subset is rejected through `err`, called as
  # err.(node, code, what, opts) and expected not to return (the compiler
  # throws its rejection; Defk.Raise.parse!/2 works the same way). Elixir
  # mode translates a kernel the compiler accepted, so its `err` never
  # runs. The Enum forms answer :error instead: their rejection
  # (fn-argument, with the rewrite of a capture) is the compiler's own.

  # the codes used here, checked against the registry while this module
  # compiles (as the compiler's err!/4 checks its own)
  Enum.each(~w(for-form for-option generator-pattern case-pattern), &Defk.Errors.validate_code!/1)

  # ------------------------------------------------------------------ for --

  @doc false
  # `args` of `{:for, _, args}` as {quals, {:reduce, init} | nil, body}, or
  # {:into, quals, body, into} for a `for ..., into:` (the compiler lowers
  # what it holds before rejecting it). `node` is the whole for, for err.
  def for(args, node, err) do
    {kws, quals} = Enum.split_with(args, &(is_list(&1) and Keyword.keyword?(&1)))
    opts = Enum.concat(kws)

    case Enum.find(Keyword.keys(opts), &(&1 not in [:do, :reduce])) do
      :into ->
        {:into, quals, opts[:do], opts[:into]}

      nil ->
        generator!(quals, node, err)

        body =
          Keyword.get(opts, :do) ||
            err.(node, "for-form", "this for has no do block",
              hint: "write the loop body in a do block"
            )

        case Keyword.fetch(opts, :reduce) do
          {:ok, init} -> {quals, {:reduce, init}, body}
          :error -> {quals, nil, body}
        end

      k ->
        err.(node, "for-option", "for ..., #{k}: is not in the kernel subset", [])
    end
  end

  # the first qualifier is a generator; a bitstring generator is rejected
  # with the array walk as its rewrite
  defp generator!(quals, node, err) do
    case quals do
      [{:<-, _, _} | _] ->
        :ok

      [{:<<>>, _, [{:<-, _, [x, bin]}]} = gen | _] ->
        err.(
          gen,
          "generator-pattern",
          "the bitstring generator #{Macro.to_string(gen)} is not in the kernel subset",
          hint: "walk the bytes as a [u8] array",
          rewrite: "#{Macro.to_string(x)} <- #{Macro.to_string(bin)}"
        )

      _ ->
        err.(node, "for-form", "this for has no generator", [])
    end
  end

  # ----------------------------------------------------------------- case --

  @doc false
  # A case clause as {pattern, guard | nil, body, meta}; a clause with
  # several patterns is rejected (the compiler commits to the subject once).
  def case_clause(clause, err) do
    case clause do
      {:->, cm, [[{:when, _, [pat, guard]}], body]} ->
        {pat, guard, body, cm}

      {:->, cm, [[pat], body]} ->
        {pat, nil, body, cm}

      {:->, _, [pats, _]} = cl ->
        err.(
          cl,
          "case-pattern",
          "a case clause with #{length(pats)} patterns is not in the kernel subset",
          []
        )
    end
  end

  # ----------------------------------------------------------- Enum forms --

  @doc false
  # Enum.reduce_while(src, init, fn x, acc -> body end) as
  # {:ok, src, init, x, acc, body}; :error for any other arguments
  def reduce_while([src, init, {:fn, _, [{:->, _, [[x, acc], body]}]}]),
    do: {:ok, src, init, x, acc, body}

  def reduce_while(_args), do: :error

  @doc false
  # Enum.all?/any?(src, fn x -> pred end) as {:ok, src, x, pred, metas}, the
  # metas those of the fn and its clause, for a mode that emits the fn as
  # written; :error for any other arguments
  def predicate([src, {:fn, fm, [{:->, am, [[x], pred]}]}]), do: {:ok, src, x, pred, {fm, am}}
  def predicate(_args), do: :error

  # ----------------------------------------------- Enum.reduce, Enum.find --
  # Enum.reduce/3 and Enum.find/3 in kernel bodies, written as the forms
  # above before either mode sees the body, so both modes give them the
  # same meaning:
  #
  #   Enum.reduce(src, init, fn x, acc -> body end)
  #     for x <- src, reduce: init do acc -> body end
  #
  #   Enum.find(src, default, fn x -> pred end)
  #     Enum.reduce_while(src, default, fn x, d -> if pred, do: {:halt, x}, else: {:cont, d} end)
  #
  # Only a literal one-clause fn with no guard, and for find a plain variable
  # x, is rewritten; any other form stays as written and the compiler rejects
  # it (fn-argument). Enum.find/2 and Enum.find_index/2 return nil when
  # nothing matches, and a kernel has no nil, so they stay rejected
  # (enum-find).

  # the accumulator and element of a find: names no kernel writes (a name
  # that starts with _ would not be bound)
  @default :defk__find_default
  @elem :defk__find_elem

  @doc false
  # the accumulator's name: the compiler reports a type mismatch on it as
  # one between Enum.find/3's default and the elements
  def find_default, do: @default

  @doc false
  def desugar(%{body: body} = kernel), do: %{kernel | body: Macro.prewalk(body, &form/1)}

  # the same on a bare expression (the compiler checks the inside of a
  # rejected pipe this way, since a pipe hides the arity before unpiping)
  def desugar(ast), do: Macro.prewalk(ast, &form/1)

  defp form({{:., _, [{:__aliases__, _, [:Enum]}, :reduce]}, m, [src, init, f]} = node) do
    case f do
      {:fn, _, [{:->, am, [[x, acc], body]}]} ->
        {:for, m, [{:<-, m, [x, src]}, [reduce: init, do: [{:->, am, [[acc], body]}]]]}

      _ ->
        node
    end
  end

  defp form({{:., dm, [{:__aliases__, _, [:Enum]} = enum, :find]}, m, [src, default, f]} = node) do
    case f do
      {:fn, fm, [{:->, am, [[{name, _, ctx} = x], pred]}]} when is_atom(name) and is_atom(ctx) ->
        d = {@default, m, nil}
        # `fn _ -> ... end`: the element still needs a name to be returned
        x = if String.starts_with?(Atom.to_string(name), "_"), do: {@elem, m, nil}, else: x
        body = {:if, m, [pred, [do: {:halt, x}, else: {:cont, d}]]}
        fun = {:fn, fm, [{:->, am, [[x, d], body]}]}
        {{:., dm, [enum, :reduce_while]}, m, [src, default, fun]}

      _ ->
        node
    end
  end

  defp form(node), do: node
end
