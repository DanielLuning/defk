defmodule Defk.Bitstring do
  @moduledoc false
  # The bitstring accumulator (defk-cmr): a kernel local that starts as `<<>>`
  # and is only appended to, `acc = <<acc::bitstring, v::size(n), ...>>`, with
  # unsigned big-endian integer segments, and is returned as a bitstring. The
  # compiler, Elixir mode and the generated wrappers share the forms here, so
  # they cannot disagree about which appends are accepted.
  #
  # `<<>>` is also the empty binary literal, a [u8]. It is a bitstring where
  # it is bound to a name the kernel appends to (accumulator_names/1), returned
  # as a bitstring, or an arm of a branch whose other arms give one.

  @segment_hint "write unsigned big-endian integer segments: v::size(n), v::k or v (8 bits)"

  @doc false
  # {:append, head, [{value, size}]} for `<<head::bitstring, seg, ...>>`,
  # {:error, node, what, opts} for an append with a segment outside the
  # subset, :error for any other node (a binary literal, say). A segment `v`
  # has size 8, `v::k` size k.
  def parse({:<<>>, _, [{:"::", _, [head, spec]} | segs]} = node) do
    case spec do
      {t, _, ctx} when t in [:bitstring, :bits] and is_atom(ctx) ->
        segs
        |> Enum.reduce_while([], fn seg, acc ->
          case segment(seg) do
            {:ok, s} -> {:cont, [s | acc]}
            {:error, what, opts} -> {:halt, {:error, seg, what, opts}}
          end
        end)
        |> case do
          {:error, _, _, _} = e -> e
          parts -> {:append, head, Enum.reverse(parts)}
        end

      {t, _, ctx} when t in [:binary, :bytes] and is_atom(ctx) ->
        {:error, node,
         "#{Macro.to_string(node)} appends to #{Macro.to_string(head)}::#{t}; the bitstring accumulator is appended to as #{Macro.to_string(head)}::bitstring",
         rewrite:
           Macro.to_string({:<<>>, [], [{:"::", [], [head, {:bitstring, [], nil}]} | segs]})}

      _ ->
        :error
    end
  end

  def parse(_), do: :error

  defp segment({:"::", _, [v, spec]} = seg) do
    with :ok <- value(v, seg) do
      spec
      |> flatten()
      |> Enum.reduce_while({:ok, nil}, fn s, {:ok, size} ->
        case spec_item(s, seg) do
          {:size, n} when size == nil -> {:cont, {:ok, n}}
          {:size, _} -> {:halt, error(seg, "it has two sizes")}
          :ok -> {:cont, {:ok, size}}
          {:error, _, _} = e -> {:halt, e}
        end
      end)
      |> case do
        {:ok, size} -> {:ok, {v, size || 8}}
        e -> e
      end
    end
  end

  defp segment(v) do
    with :ok <- value(v, v), do: {:ok, {v, 8}}
  end

  defp value(v, seg) do
    cond do
      is_float(v) -> error(seg, "segments are integers")
      is_binary(v) -> error(seg, "segments are integers")
      match?({:<<>>, _, _}, v) -> error(seg, "segments are integers")
      true -> :ok
    end
  end

  defp flatten({:-, _, [a, b]}), do: flatten(a) ++ flatten(b)
  defp flatten(s), do: [s]

  defp spec_item(n, _seg) when is_integer(n), do: {:size, n}
  defp spec_item({:size, _, [n]}, _seg), do: {:size, n}

  defp spec_item({t, _, ctx}, _seg) when t in [:integer, :unsigned, :big] and is_atom(ctx),
    do: :ok

  defp spec_item({t, _, ctx}, seg) when is_atom(t) and is_atom(ctx) do
    case t do
      :signed ->
        error(seg, "segments are unsigned",
          hint: "append band(v, 2^n - 1)::size(n): the same bits"
        )

      t when t in [:little, :native] ->
        error(seg, "segments are big-endian")

      t when t in [:float, :binary, :bytes, :bitstring, :bits, :utf8, :utf16, :utf32] ->
        error(seg, "segments are integers, and #{t} is not")

      _ ->
        error(seg, "#{t} is not a segment type")
    end
  end

  defp spec_item(other, seg),
    do: error(seg, "#{Macro.to_string(other)} is not a segment size or type")

  defp error(seg, why, opts \\ []),
    do:
      {:error, "the bitstring segment #{seg_string(seg)} is not supported yet: #{why}",
       Keyword.put_new(opts, :hint, @segment_hint)}

  # a segment as written in a binary (`x::float-64`, not `x :: float - 64`)
  defp seg_string(seg) do
    case Macro.to_string({:<<>>, [], [seg]}) do
      "<<" <> rest -> String.trim_trailing(rest, ">>")
      _string -> Macro.to_string(seg)
    end
  end

  @doc false
  # The names `body` appends to: `<<name::bitstring, ...>>` anywhere in it.
  def accumulator_names(body) do
    {_, names} =
      Macro.prewalk(body, MapSet.new(), fn
        {:<<>>, _, [{:"::", _, [{name, _, ctx}, {t, _, tctx}]} | _]} = node, acc
        when is_atom(name) and is_atom(ctx) and t in [:bitstring, :bits] and is_atom(tctx) ->
          {node, MapSet.put(acc, name)}

        node, acc ->
          {node, acc}
      end)

    names
  end

  @doc false
  # Whether a kernel head's return type has a bitstring in it: its NIF then
  # returns {bytes, bit_length} there, and an Elixir wrapper (decode/2) makes
  # the bitstring.
  def returns_bits?({:"::", _, [_call, ret]}), do: bits_type?(ret)
  def returns_bits?(_head), do: false

  @doc false
  # The kernel name of a head, or nil (the compiler rejects such a head).
  def name({:"::", _, [{name, _, _}, _]}) when is_atom(name), do: name
  def name(_head), do: nil

  defp bits_type?({:bitstring, _, ctx}) when is_atom(ctx), do: true
  defp bits_type?({a, b}), do: bits_type?(a) or bits_type?(b)
  defp bits_type?({:{}, _, ts}) when is_list(ts), do: Enum.any?(ts, &bits_type?/1)
  defp bits_type?(_), do: false

  @doc false
  # Quoted: the result of NIF call `q` for return type `ret`, with each
  # {bytes, bit_length} made the bitstring it stands for. The match takes a
  # sub-binary of the first bit_length bits, without copying.
  def decode(:bitstring, q) do
    {stmts, b} = decode_one(q, 0)
    {:__block__, [generated: true], stmts ++ [b]}
  end

  def decode({:tuple, ts}, q) do
    if :bitstring in ts do
      vs = for {_, i} <- Enum.with_index(ts), do: Macro.var(:"r#{i}", __MODULE__)

      {stmts, out} =
        Enum.zip(ts, vs)
        |> Enum.with_index()
        |> Enum.map(fn
          {{:bitstring, v}, i} -> decode_one(v, i)
          {{_, v}, _} -> {[], v}
        end)
        |> Enum.unzip()

      match = quote(generated: true, do: {unquote_splicing(vs)} = unquote(q))
      tuple = quote(generated: true, do: {unquote_splicing(out)})
      {:__block__, [generated: true], [match | Enum.concat(stmts)] ++ [tuple]}
    else
      q
    end
  end

  def decode(_ret, q), do: q

  defp decode_one(q, i) do
    bin = Macro.var(:"bin#{i}", __MODULE__)
    len = Macro.var(:"len#{i}", __MODULE__)
    b = Macro.var(:"b#{i}", __MODULE__)

    stmts =
      quote generated: true do
        {unquote(bin), unquote(len)} = unquote(q)
        <<unquote(b)::bitstring-size(^unquote(len)), _::bitstring>> = unquote(bin)
      end

    {elem(stmts, 2), b}
  end
end
