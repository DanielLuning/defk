defmodule Defk.Raise do
  @moduledoc false
  # `raise` in a kernel, a statement: `raise Module, "literal message"`,
  # `raise Module` (the module's default message) or `raise "literal"`
  # (RuntimeError), Module one of @modules. The message may interpolate
  # integer expressions (`"bad offset #{ip}"`; the compiler checks the type).
  # Shared by the compiler (which rejects other forms) and Elixir mode (which
  # raises the same exception).

  @modules [ArgumentError, ArithmeticError, RuntimeError]
  @kinds %{
    ArgumentError => "DEFK_E_ARG",
    ArithmeticError => "DEFK_E_ARITH",
    RuntimeError => "DEFK_E_RUNTIME"
  }
  @names "ArgumentError, ArithmeticError or RuntimeError"
  @message_hint "a kernel raises with a literal message that may interpolate integer values (\"bad offset \#{i}\"): put any other value in Elixir, before or after the call"

  @doc false
  def modules, do: @modules

  @doc false
  # {module, message} of a raise statement, or err.(node, code, what, opts).
  # The message is a binary, nil (the module's default) or {:ints, strings,
  # exprs}: the literal parts around the interpolated expressions, one more
  # string than expressions.
  def parse!({:raise, _, args} = node, err) do
    case args do
      [msg] when is_binary(msg) ->
        {RuntimeError, msg}

      [{:<<>>, _, _} = msg] ->
        {RuntimeError, interpolated!(msg, node, err)}

      [mod] ->
        {module!(mod, node, err), nil}

      [mod, msg] when is_binary(msg) ->
        {module!(mod, node, err), msg}

      [mod, [message: msg]] when is_binary(msg) ->
        {module!(mod, node, err), msg}

      [mod, {:<<>>, _, _} = msg] ->
        {module!(mod, node, err), interpolated!(msg, node, err)}

      [mod, [message: {:<<>>, _, _} = msg]] ->
        {module!(mod, node, err), interpolated!(msg, node, err)}

      [mod, msg] ->
        module!(mod, node, err)
        message!(msg, node, err)

      _ ->
        message!(nil, node, err)
    end
  end

  # "text #{expr} text" as {:ints, strings, exprs}; any other bitstring is
  # not a message
  defp interpolated!({:<<>>, _, parts} = msg, node, err) do
    {strings, exprs} =
      Enum.reduce(parts, {[""], []}, fn
        s, {[prev | ss], es} when is_binary(s) ->
          {[prev <> s | ss], es}

        {:"::", _, [{{:., _, [Kernel, :to_string]}, _, [e]}, {:binary, _, _}]}, {ss, es} ->
          {["" | ss], [e | es]}

        _, _ ->
          message!(msg, node, err)
      end)

    {:ints, Enum.reverse(strings), Enum.reverse(exprs)}
  end

  # the bare-module form: a module alias, or a message that is not a literal
  defp module!({:__aliases__, _, parts} = mod, node, err) when is_list(parts) do
    m = Module.concat(parts)

    if m in @modules do
      m
    else
      args = with {:raise, _, [_ | rest]} <- node, do: rest

      err.(mod, "raise-module", "raise #{Macro.to_string(mod)} is not in the kernel subset",
        hint: "use #{@names}",
        rewrite: Macro.to_string({:raise, [], [{:__aliases__, [], [:ArgumentError]} | args]})
      )
    end
  end

  defp module!(other, node, err), do: message!(other, node, err)

  defp message!(msg, node, err) do
    {at, what} =
      case msg do
        {:<<>>, _, _} -> {msg, "raise with the interpolated message #{Macro.to_string(msg)}"}
        nil -> {node, Macro.to_string(node)}
        _ -> {msg, "raise with the message #{Macro.to_string(msg)}"}
      end

    err.(
      if(match?({_, m, _} when is_list(m), at), do: at, else: node),
      "raise-message",
      "#{what} is not in the kernel subset: the message is a string literal, which may interpolate integers",
      hint: @message_hint
    )
  end

  @doc false
  # an interpolated value that is not an integer (the compiler knows its type)
  def not_integer!(expr, type, err) do
    err.(
      expr,
      "raise-message",
      "interpolating #{Macro.to_string(expr)}, a #{type}, into a raise message is not in the kernel subset: only integers can be interpolated",
      hint: @message_hint
    )
  end

  @doc false
  # a raise where a value is needed
  def value!(node, err) do
    err.(node, "raise-value", "#{Macro.to_string(node)} is used as a value",
      hint:
        "raise is a statement; put it before the value: `if not ok, do: raise(...)` on its own line, then the value"
    )
  end

  @doc false
  # The message Elixir gives the exception.
  def message(mod, nil), do: Exception.message(mod.exception([]))
  def message(_mod, msg), do: msg

  @doc false
  # The runtime's error kind for the module (priv/defk_runtime.h).
  def kind(mod), do: Map.fetch!(@kinds, mod)

  @doc false
  # `msg` as a C string literal: printable ASCII as is, every other byte (and
  # `"`, `\`, `?`) as a three-digit octal escape, so no byte is reinterpreted.
  def c_string(msg) do
    body =
      for <<b <- msg>>, into: "" do
        if b in 0x20..0x7E and b not in [?", ?\\, ??],
          do: <<b>>,
          else: "\\" <> String.pad_leading(Integer.to_string(b, 8), 3, "0")
      end

    ~s("#{body}")
  end
end
