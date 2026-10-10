Code.require_file("count_min_lib.exs", __DIR__)

defmodule CountMinTest do
  use ExUnit.Case
  import Bitwise

  test "agrees with reference and Elixir mode; input not mutated" do
    for {d, w} <- [{1, 1}, {1, 5}, {4, 37}, {7, 64}, {3, 1000}], _ <- 1..20 do
      sk = for(_ <- 1..(d * w), into: <<>>, do: <<:rand.uniform(1000)::unsigned-64-native>>)
      n = :rand.uniform(300) - 1
      hashes = for _ <- 1..n//1, do: :rand.uniform(1 <<< 64) - 1
      hb = for h <- hashes, into: <<>>, do: <<h::unsigned-64-native>>
      orig = sk
      assert CountMin.update_many(sk, d, w, hb) == Ref.update_many(sk, d, w, hashes)
      assert sk == orig
      Defk.Test.assert_agrees(CountMin, :update_many, [sk, d, w, hb])
    end
  end
end
