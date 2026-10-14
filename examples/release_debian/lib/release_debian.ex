defmodule ReleaseDebian do
  @moduledoc "One defk kernel, called from a mix release (see README.md)."
  use Defk

  defk dot(a :: [f64], b :: [f64]) :: f64 do
    for i <- 0..(length(a) - 1)//1, reduce: 0.0 do
      acc -> acc + a[i] * b[i]
    end
  end

  @doc "Calls the kernel on 1..n and checks it against plain Elixir."
  def check(n \\ 1000) do
    xs = for i <- 1..n, do: i / 1.0
    bin = for x <- xs, into: <<>>, do: <<x::float-64-native>>
    native = dot(bin, bin)
    elixir = Enum.reduce(xs, 0.0, fn x, acc -> acc + x * x end)
    %{kernel: native, elixir: elixir, agree: native == elixir, lib: __defk_lib__()}
  end
end
