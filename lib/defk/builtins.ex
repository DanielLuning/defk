defmodule Defk.Builtins do
  @moduledoc false
  # The functions a kernel calls without defining them: one list for the
  # compiler, Elixir mode and the compile errors.

  # f64 -> f64 math, also callable as :math.sqrt/1 and so on
  @math1 [:sqrt, :exp, :log, :sin, :cos]
  # i64 -> i64 bitwise, as Elixir's Bitwise; each also has an operator form
  @bitwise [:band, :bor, :bxor, :bnot, :bsl, :bsr]
  @bitwise_ops %{&&&: :band, |||: :bor, "^^^": :bxor, "~~~": :bnot, <<<: :bsl, >>>: :bsr}
  @all [:len, :min, :max, :abs, :float, :trunc, :round, :div, :rem] ++
         @math1 ++ [:pow] ++ @bitwise ++ [:alloc]

  @doc "Every builtin name."
  def all, do: @all

  @doc "The one-argument math builtins."
  def math1, do: @math1

  @doc "The bitwise builtins (band/2, bor/2, bxor/2, bnot/1, bsl/2, bsr/2)."
  def bitwise, do: @bitwise

  @doc "The bitwise operators (&&&, |||, ^^^, ~~~, <<<, >>>)."
  def bitwise_ops, do: Map.keys(@bitwise_ops)

  @doc "The bitwise builtin an operator or bitwise function name stands for."
  def bitwise_fun(name), do: Map.get(@bitwise_ops, name, name)

  @doc "The arity of bitwise builtin `f`."
  def bitwise_arity(:bnot), do: 1
  def bitwise_arity(_f), do: 2

  @doc "Whether `name` is a builtin."
  def builtin?(name), do: name in @all

  # Enum.all?/any? with a predicate are the same fold with a different bool
  # accumulator: {init, if kw} for `reduce_while` over the predicate.
  @doc "The {init, if kw} that lowers Enum.all?/any? to a bool-accumulator reduce."
  def bool_reduce(f) when f in [:all?, :any?] do
    if f == :all?,
      do: {true, [do: {:cont, true}, else: {:halt, false}]},
      else: {false, [do: {:halt, true}, else: {:cont, false}]}
  end
end
