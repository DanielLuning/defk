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

