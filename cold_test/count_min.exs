import Bitwise
defmodule CountMin do
  use Defk, elixir_mode: true

  defk update_many(sk :: [u64], d :: i64, w :: i64, hashes :: [u64]) :: [u64] do
    for h <- hashes do
      h1 = band(h, 0xFFFFFFFF)
      h2 = bsr(h, 32)

      for r <- 0..(d - 1)//1 do
        col = rem(band(h1 + r * h2, 0xFFFFFFFF), w)
        idx = r * w + col
        sk[idx] = sk[idx] + 1
      end
    end

    sk
  end
end

defmodule Ref do
  import Bitwise

  def update_many(sk, d, w, hashes) do
    counters = for <<x::unsigned-64-native <- sk>>, do: x
    t = List.to_tuple(counters)

    t =
      Enum.reduce(hashes, t, fn h, t ->
        h1 = h &&& 0xFFFFFFFF
        h2 = h >>> 32

        Enum.reduce(0..(d - 1)//1, t, fn r, t ->
          col = rem((h1 + r * h2) &&& 0xFFFFFFFF, w)
          idx = r * w + col
          put_elem(t, idx, elem(t, idx) + 1)
        end)
      end)

    for x <- Tuple.to_list(t), into: <<>>, do: <<x::unsigned-64-native>>
  end
end

d = 4
w = 37
sk = for(_ <- 1..(d * w), into: <<>>, do: <<:rand.uniform(1000)::unsigned-64-native>>)
hashes = for _ <- 1..2000, do: :rand.uniform(1 <<< 64) - 1
hb = for h <- hashes, into: <<>>, do: <<h::unsigned-64-native>>
native = CountMin.update_many(sk, d, w, hb)
ref = Ref.update_many(sk, d, w, hashes)
el = CountMin.__defk_elixir__(:update_many, [sk, d, w, hb])
IO.inspect({native == ref, el == ref, native == el})
