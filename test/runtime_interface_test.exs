# The interface list at the top of priv/defk_runtime.h against the names
# the compiler writes into a kernel's C, both ways. The names are read from
# the strings of the modules that write C (an interpolation in a name is a
# wildcard, `defk_get_#{e}` is defk_get_*), not from atoms, sigils or
# comments. A list entry's <x> is a wildcard too. A name the compiler builds
# from variables only (`defk_#{f}_#{s}`) has no fixed part to check; an
# entry no other name covers passes when each of its pieces is an atom or
# a string piece of the sources (defk_clz_i by :clz and "i"), which is
# weaker.
defmodule Defk.RuntimeInterfaceTest do
  use ExUnit.Case, async: true

  @sources Enum.map(~w(compiler.ex raise.ex strip.ex), &Path.expand("../lib/defk/#{&1}", __DIR__))

  # where the builtins' names are, for the pieces
  @words_sources [Path.expand("../lib/defk/builtins.ex", __DIR__) | @sources]

  @name ~r/(?<![A-Za-z0-9_])(?:defk|DEFK)_[A-Za-z0-9_*]*+(?!\.h\b)/

  # the entries between "<marker>:start" and "<marker>:end", a label before
  # ": " dropped, <x> as *
  defp entries(marker) do
    [_, block] = String.split(File.read!(header()), "#{marker}:start\n")
    [block, _] = String.split(block, " * #{marker}:end")

    for line <- String.split(block, "\n"),
        names = line |> String.trim_leading(" * ") |> String.split(": ") |> List.last(),
        name <- String.split(names),
        do: String.replace(name, ~r/<[A-Za-z]+>/, "*")
  end

  # the names in the strings of the sources, an interpolation as *
  defp forms do
    for path <- @sources,
        string <- strings(Code.string_to_quoted!(File.read!(path))),
        [name] <- Regex.scan(@name, string),
        uniq: true,
        do: String.replace(name, ~r/\*+/, "*")
  end

  defp strings(ast) do
    {_, acc} =
      Macro.prewalk(ast, [], fn
        {sigil, _, _}, acc when sigil in [:sigil_r, :sigil_S, :sigil_s, :sigil_w] ->
          {:skip, acc}

        {:<<>>, _, parts}, acc when is_list(parts) ->
          {:skip, [Enum.map_join(parts, &if(is_binary(&1), do: &1, else: "*")) | acc]}

        string, acc when is_binary(string) ->
          {string, [string | acc]}

        node, acc ->
          {node, acc}
      end)

    acc
  end

  # the names the header defines or uses outside its comments, a pasted
  # part (`defk_get_##T`) as *
  defp header, do: Application.app_dir(:defk, "priv/defk_runtime.h")

  defp header_code, do: Regex.replace(~r{/\*.*?\*/|//[^\n]*}s, File.read!(header()), "")

  defp header_names(code) do
    for [name] <-
          Regex.scan(~r/(?<![A-Za-z0-9_])(?:defk|DEFK)_(?:[A-Za-z0-9_]|##\w+?(?:##|\b))*/, code),
        uniq: true,
        do: Regex.replace(~r/##\w+?(?:##|\b)/, name, "*")
  end

  # two names with wildcards agree when either one matches the other with
  # its wildcards filled in
  defp agree?(a, b),
    do: a == b or Regex.match?(re(a), sample(b)) or Regex.match?(re(b), sample(a))

  defp re(name) do
    body = name |> String.split("*") |> Enum.map_join("[A-Za-z0-9_]*", &Regex.escape/1)
    Regex.compile!("^#{body}$")
  end

  defp sample(name), do: String.replace(name, "*", "x")

  # a form with no fixed part past the prefix (`defk_#{f}`, `defk_#{f}_#{s}`)
  # matches any name
  defp checkable?(form), do: Regex.match?(~r/^(?:defk|DEFK)_.*[A-Za-z0-9]/, form)

  # the pieces of the atoms and strings of the sources, word lists included
  defp pieces do
    for path <- @words_sources,
        term <- terms(Code.string_to_quoted!(File.read!(path))),
        [piece] <- Regex.scan(~r/[a-z0-9]+/, term),
        into: MapSet.new(),
        do: piece
  end

  defp terms(ast) do
    {_, acc} =
      Macro.prewalk(ast, [], fn
        t, acc when is_binary(t) -> {t, [t | acc]}
        t, acc when is_atom(t) -> {t, [Atom.to_string(t) | acc]}
        node, acc -> {node, acc}
      end)

    acc
  end

  defp pieces?(entry, pieces) do
    entry
    |> String.replace(~r/^(?:defk|DEFK)_/, "")
    |> String.split(["_", "*"], trim: true)
    |> Enum.all?(&MapSet.member?(pieces, &1))
  end

  test "every name the compiler writes is in a list" do
    listed = entries("interface") ++ entries("kernel")

    missing =
      for form <- forms(), checkable?(form), not Enum.any?(listed, &agree?(form, &1)), do: form

    assert missing == [], "add to the header's interface or kernel list: #{inspect(missing)}"
  end

  test "every listed name is one the compiler writes" do
    forms = Enum.filter(forms(), &checkable?/1)
    pieces = pieces()

    unused =
      for entry <- entries("interface") ++ entries("kernel"),
          not Enum.any?(forms, &agree?(&1, entry)),
          not pieces?(entry, pieces),
          do: entry

    assert unused == [],
           "the compiler writes no such name, drop it from the list: #{inspect(unused)}"
  end

  # a pasted name with no fixed part (`defk_##NAME`) is found by its pieces,
  # the macro's arguments
  test "the interface names are the header's, the kernel's own names are not" do
    code = header_code()
    names = header_names(code)
    forms = Enum.filter(names, &checkable?/1)
    pieces = for [piece] <- Regex.scan(~r/[a-z0-9]+/, code), into: MapSet.new(), do: piece

    undefined =
      for e <- entries("interface"),
          not Enum.any?(forms, &agree?(&1, e)),
          not pieces?(e, pieces),
          do: e

    assert undefined == [], "not a name of the header: #{inspect(undefined)}"

    clashing = for e <- entries("kernel"), not String.contains?(e, "*"), e in names, do: e
    assert clashing == [], "a header name in the kernel's list: #{inspect(clashing)}"
  end
end
