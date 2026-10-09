defmodule Defk.BinaryLiteral do
  @moduledoc false
  # Binary literals in kernel bodies (defk-n4r.5): `"abc"` and `<<1, 2, 3>>`
  # with integer segments are a read-only [u8], the same value a binary module
  # attribute is. The compiler lowers it to a static const view and Elixir mode
  # is the binary itself; both take the bytes from here, so they cannot
  # disagree about which literals are accepted.

  @hint "build it in Elixir and pass it as a [u8] parameter, or use a module attribute"

  @doc false
  # The error text for a `<<...>>` that is not a literal, with `reason` why.
  def message(node, reason),
    do: "the binary literal #{Macro.to_string(node)} is not in the kernel subset: #{reason}"

  @doc false
  # {:ok, bytes} for a binary literal node, {:error, reason, opts} for a `<<...>>`
  # that is not one, :error for any other node.
  def bytes(b) when is_binary(b), do: {:ok, b}

  def bytes({:<<>>, _, segs}) do
    segs
    |> Enum.reduce_while([], fn seg, acc ->
      case segment(seg) do
        {:ok, byte} -> {:cont, [byte | acc]}
        {:error, reason} -> {:halt, {:error, reason, [hint: @hint]}}
      end
    end)
    |> case do
      {:error, _, _} = e -> e
      acc -> {:ok, acc |> Enum.reverse() |> :erlang.list_to_binary()}
    end
  end

  def bytes(_), do: :error

  defp segment(n) when is_integer(n) and n in 0..255, do: {:ok, n}

  defp segment(n) when is_integer(n),
    do: {:error, "the segment #{n} is not a byte (0..255)"}

  defp segment({:"::", _, [{{:., _, [Kernel, :to_string]}, _, _} = interp, _]}),
    do: segment(interp)

  defp segment({:"::", _, [n, spec]} = seg) do
    if byte_spec?(spec),
      do: segment(n),
      else: {:error, "the segment #{Macro.to_string(seg)} is not an 8-bit integer"}
  end

  defp segment({{:., _, [Kernel, :to_string]}, _, _} = seg),
    do: {:error, "interpolation (#{Macro.to_string(seg)}) is not allowed"}

  defp segment(seg) when is_binary(seg),
    do: {:error, "the string segment #{inspect(seg)} is not an integer segment"}

  defp segment(seg),
    do: {:error, "the segment #{Macro.to_string(seg)} is not an integer literal"}

  defp byte_spec?({:size, _, [8]}), do: true
  defp byte_spec?(8), do: true
  defp byte_spec?({:integer, _, ctx}) when is_atom(ctx), do: true
  defp byte_spec?({:-, _, [a, b]}), do: byte_spec?(a) and byte_spec?(b)

  defp byte_spec?({u, _, ctx}) when u in [:unsigned, :big, :little, :native] and is_atom(ctx),
    do: true

  defp byte_spec?(_), do: false
end
