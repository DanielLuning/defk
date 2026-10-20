defmodule Defk.Docs do
  @moduledoc false
  # Every generated region of the repository's docs, behind one task,
  # `mix defk.docs [--check]`: what each region is, where it lives and the
  # text it must hold. A region is a whole file, or the lines between
  # `<!-- NAME:start -->` and `<!-- NAME:end -->` in a Markdown file; the
  # comments render as nothing, in HexDocs and in a dependent's AGENTS.md.
  # Nothing outside a region is generated.

  alias Defk.Examples
  alias Defk.Examples.{Snapshot, Tables}

  @doc """
  The regions, as `{file, marker | :file, text}`:

    * `docs/compile-errors.md`, the error catalogue from the "Codes"
      heading to the end of the page (`Defk.Errors.reference/0`)
    * `docs/scope.md`, the lists of planned codes and of codes outside the
      subset for good (`Defk.Errors.scope/1`)
    * `usage-rules.md` and `usage-rules/language.md`, the same two lists
      with the error footer's HexDocs links, as the rules are read inside
      another project (`Defk.Errors.scope/2`)
    * `priv/defk_messages.h`, the runtime's message defines, a whole file
      (`Defk.Messages.header/0`)
    * `examples/README.md` and `README.md`, the catalog's result tables
      from the stored scoreboard (`Defk.Examples.Tables`)

  Raises when the tables cannot be rendered: no stored scoreboard, or a
  problem `Tables.render/2` names.
  """
  def regions do
    [
      {"docs/compile-errors.md", "codes", Defk.Errors.reference()},
      {"docs/scope.md", "planned", Defk.Errors.scope(:planned)},
      {"docs/scope.md", "subset", Defk.Errors.scope(:subset)},
      {"usage-rules.md", "planned-hexdocs", Defk.Errors.scope(:planned, :hexdocs)},
      {"usage-rules/language.md", "subset-hexdocs", Defk.Errors.scope(:subset, :hexdocs)},
      {"priv/defk_messages.h", :file, Defk.Messages.header()}
    ] ++ tables()
  end

  defp tables do
    snapshot =
      case Snapshot.read() do
        {:ok, s} ->
          s

        {:error, why} ->
          raise "no stored scoreboard (#{why}); run mix defk.examples --bench --all --snapshot"
      end

    blocks =
      case Tables.render(snapshot, Tables.text()) do
        {:ok, blocks} ->
          blocks

        {:error, problems} ->
          raise "the tables cannot be rendered:\n" <>
                  Enum.map_join(problems, "\n", &("  * " <> &1))
      end

    for {file, marker} <- Tables.targets(),
        do: {Path.join(Examples.root(), file), marker, blocks[marker]}
  end

  @doc "`{:ok, content with the region's text replaced}`, or `{:error, why}` when the markers are missing."
  def put(_content, :file, text), do: {:ok, text}

  def put(content, marker, text) do
    case split(content, marker) do
      {:ok, before, _old, after_} -> {:ok, before <> text <> after_}
      :error -> {:error, "no #{start_tag(marker)} ... #{end_tag(marker)} pair"}
    end
  end

  @doc "`{:ok, the region's text in content}`, or `:error` when the markers are missing."
  def get(content, :file), do: {:ok, content}

  def get(content, marker) do
    case split(content, marker) do
      {:ok, _, old, _} -> {:ok, old}
      :error -> :error
    end
  end

  defp split(content, marker) do
    with [before, rest] <- String.split(content, start_tag(marker) <> "\n", parts: 2),
         [old, after_] <- String.split(rest, end_tag(marker), parts: 2) do
      {:ok, before <> start_tag(marker) <> "\n", old, end_tag(marker) <> after_}
    else
      _ -> :error
    end
  end

  defp start_tag(marker), do: "<!-- #{marker}:start -->"
  defp end_tag(marker), do: "<!-- #{marker}:end -->"
end
