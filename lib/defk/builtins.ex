defmodule Defk.Builtins do
  @moduledoc false
  # The functions a kernel calls without defining them: one list for the
  # compiler, Elixir mode and the compile errors.

  # f64 -> f64 math, also callable as :math.sqrt/1 and so on
  @math1 [:sqrt, :exp, :log, :sin, :cos]
  @all [:len, :min, :max, :abs, :float, :trunc, :round, :div, :rem] ++ @math1 ++ [:pow, :alloc]

  @doc "Every builtin name."
  def all, do: @all

  @doc "The one-argument math builtins."
  def math1, do: @math1

  @doc "Whether `name` is a builtin."
  def builtin?(name), do: name in @all
end
