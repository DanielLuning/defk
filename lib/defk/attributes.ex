defmodule Defk.Attributes do
  @moduledoc false
  # Module attributes in kernel bodies.
  #
  # `@name` in a kernel body means what it means in a def: the attribute's
  # value where the kernel is defined. `defk` reads every attribute its body
  # names at that point (capture/1), and `Defk.__before_compile__/1` inlines
  # them (inline/1) before the compiler and Elixir mode see the body, so both
  # modes get the same value even if the attribute is redefined later.
  #
  # An i64 or u64 integer, a float or a boolean becomes its literal, so it works
  # wherever a literal does (case patterns, guards, range steps, band masks
  # with their range facts). Any other value stays an `@name` node carrying
  # `defk_attr: {:ok, value} | :undefined` in the name's meta: the compiler
  # lowers a binary to a read-only [u8] and rejects the rest; Elixir mode
  # reads the binary from the same place.

  # i64 and u64: -2^63..2^64 - 1
  @ints -0x8000000000000000..0xFFFFFFFFFFFFFFFF

  @doc false
  # Quoted `%{name => {:ok, value} | :undefined}` for the attributes `body`
  # reads, evaluated in the module body where the kernel is defined.
  def capture(body) do
    {_, names} =
      Macro.prewalk(body, [], fn
        {:@, _, [{name, _, ctx}]} = node, acc when is_atom(name) and is_atom(ctx) ->
          {node, [name | acc]}

        node, acc ->
          {node, acc}
      end)

    pairs =
      for name <- Enum.uniq(names),
          do: {name, quote(do: Defk.Attributes.value(__MODULE__, unquote(name)))}

    {:%{}, [], pairs}
  end

  @doc false
  # Module.get_attribute/2 marks the attribute as read, so it is not reported
  # as unused.
  def value(module, name) do
    if Module.has_attribute?(module, name),
      do: {:ok, Module.get_attribute(module, name)},
      else: :undefined
  end

  @doc false
  # The kernel with its attribute reads inlined (see the module comment).
  def inline(%{body: body} = kernel) do
    attrs = Map.get(kernel, :attrs, %{})

    body =
      Macro.prewalk(body, fn
        {:@, m, [{name, nm, ctx}]} when is_atom(name) and is_atom(ctx) ->
          case Map.get(attrs, name, :undefined) do
            {:ok, v} when is_boolean(v) or is_float(v) -> v
            {:ok, v} when is_integer(v) and v in @ints -> v
            other -> {:@, m, [{name, [{:defk_attr, other} | nm], ctx}]}
          end

        node ->
          node
      end)

    %{kernel | body: body}
  end

  @doc false
  # {:ok, value} | :undefined of an attribute node left by inline/1.
  def of({:@, _, [{_, nm, _}]}), do: Keyword.get(nm, :defk_attr, :undefined)

  @doc false
  # The value's type in words, for an error.
  def describe(v) when is_list(v), do: "a list"
  def describe(v) when is_tuple(v), do: "a tuple"
  def describe(v) when is_map(v), do: "a map"
  def describe(nil), do: "nil"
  def describe(v) when is_atom(v), do: "the atom #{inspect(v)}"
  def describe(v) when is_integer(v), do: "the integer #{v}"
  def describe(v) when is_bitstring(v), do: "a bitstring of #{bit_size(v)} bits"
  def describe(v) when is_function(v), do: "a function"
  def describe(_), do: "a BEAM term"
end
