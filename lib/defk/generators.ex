defmodule Defk.Generators do
  @moduledoc false

  def i64 do
    StreamData.integer(-9_223_372_036_854_775_808..9_223_372_036_854_775_807)
  end

  def f64 do
    StreamData.float(min: -1.0e300, max: 1.0e300)
  end

  def bool do
    StreamData.boolean()
  end

  def array_f64 do
    StreamData.list_of(f64(), min_length: 0, max_length: 10_000)
    |> StreamData.map(fn list -> :erlang.list_to_binary(for(x <- list, do: <<x::float-64-native>>)) end)
  end

  def array_i64 do
    StreamData.list_of(i64(), min_length: 0, max_length: 10_000)
    |> StreamData.map(fn list -> :erlang.list_to_binary(for(x <- list, do: <<x::signed-64-native>>)) end)
  end

  def array_u8 do
    StreamData.binary(min_length: 0, max_length: 10_000)
  end
end
