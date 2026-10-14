# The timed kernels of the SIMD study: one or more per catalogue
# example, at a size the example measures (or a smaller one where the full
# size takes seconds), with inputs built the way the example builds them.
# Each case: {label, module, kernel, args}. `small/0` gives the same kernels
# on inputs small enough for Elixir mode, for the agreement check.
defmodule Simd.Cases do
  import Bitwise

  defp seed(s), do: :rand.seed(:exsss, {s, 2, 3})
  defp bytes(n), do: :crypto.strong_rand_bytes(n)

  defp f64s(n, f \\ fn -> :rand.uniform() * 2 - 1 end),
    do: for(_ <- 1..n, into: <<>>, do: <<f.()::float-64-native>>)

  defp f32s(n), do: for(_ <- 1..n, into: <<>>, do: <<:rand.uniform() * 2 - 1::float-32-native>>)
  defp i64s(l), do: for(x <- l, into: <<>>, do: <<x::signed-64-native>>)

  defp u64s(n),
    do: for(_ <- 1..n, into: <<>>, do: <<:rand.uniform(1 <<< 64) - 1::unsigned-64-native>>)

  defp i16s(n, amp),
    do: for(_ <- 1..n, into: <<>>, do: <<:rand.uniform(2 * amp + 1) - amp - 1::signed-16-native>>)

  defp words(n) do
    for _ <- 1..n do
      len = 3 + :rand.uniform(10)
      for _ <- 1..len, into: <<>>, do: <<?a + :rand.uniform(26) - 1>>
    end
  end

  defp index(words) do
    {offs, total} = Enum.map_reduce(words, 0, fn w, at -> {at, at + byte_size(w)} end)
    {IO.iodata_to_binary(words), i64s(offs ++ [total])}
  end

  # mixed UTF-8 text: ASCII with 2-, 3- and 4-byte sequences
  defp utf8(n) do
    alphabet = ~c"abcdefghij klmnopqrstuvwxyz" ++ [?é, ?ß, ?€, ?中, 0x1F600]
    t = List.to_tuple(alphabet)
    s = for _ <- 1..n, into: <<>>, do: <<elem(t, :rand.uniform(tuple_size(t)) - 1)::utf8>>
    s
  end

  # size: :big for timing, :small for agreement with Elixir mode
  def all(size) do
    seed(1)
    big? = size == :big
    n = if big?, do: 1_000_000, else: 1000
    mb = if big?, do: 1_048_576, else: 1000
    a = f64s(n)
    b = f64s(n)
    ek = Examples.Kernels
    fc = FloatChecks.On
    text = utf8(if big?, do: 1_000_000, else: 500)

    hay =
      for _ <- 1..if(big?, do: 4 * mb, else: 4000), into: <<>>, do: <<?a + :rand.uniform(26) - 1>>

    needle = for _ <- 1..64, into: <<>>, do: <<?A + :rand.uniform(26) - 1>>
    {wblob, woffs} = index(words(if big?, do: 50_000, else: 200))
    {pblob, poffs} = index(words(if big?, do: 20_000, else: 100))
    side = if big?, do: 256, else: 16
    {fw, fh} = if big?, do: {1920, 1080}, else: {32, 18}
    rgb = bytes(fw * fh * 3)
    gray = bytes(fw * fh)
    model = RTP.model()
    {reels_b, lines_b, pays_b} = RTP.packed(model)
    {h, t} = RTP.Elixir.words(:rand.seed_s(:exsss, {7, 8, 9}))
    pts = if big?, do: 100_000, else: 100
    lat = f64s(pts, fn -> :rand.uniform() * 180 - 90 end)
    lon = f64s(pts, fn -> :rand.uniform() * 360 - 180 end)

    coslat =
      for <<x::float-64-native <- lat>>,
        into: <<>>,
        do: <<:math.cos(x * :math.pi() / 180)::float-64-native>>

    rows = if big?, do: 10_000, else: 20

    series =
      for i <- 1..if(big?, do: 100_000, else: 200),
          do: {1_700_000_000 + 60 * i + :rand.uniform(3), 20.0 + :rand.uniform() * 0.5}

    pcm_n = if big?, do: 96_000, else: 960
    hll_state = <<0::size(8 * (4 + 16384))>>
    sort_keys = i64s(for _ <- 1..n, do: :rand.uniform(1 <<< 62) - (1 <<< 61))
    keys58 = bytes(32 * if(big?, do: 10_000, else: 20))
    b64 = Base.encode64(bytes(mb))
    hex = Base.encode16(bytes(mb), case: :lower)
    fftn = if big?, do: 65_536, else: 64
    audio = f64s(if(big?, do: 96_000, else: 500))
    taps = f64s(64)

    [
      {"sum 1M f64", ek, :sum, [a]},
      {"dot 1M f64", ek, :dot, [a, b]},
      {"mean_var 1M f64", ek, :mean_var, [a]},
      {"scale 1M f64", ek, :scale, [a, 1.5]},
      {"histogram 1 MB", ek, :histogram, [bytes(mb)]},
      {"count_primes", ek, :count_primes, [if(big?, do: 200_000, else: 500)]},
      {"cosine 1M f64", fc, :cosine, [a, b]},
      {"mean_std w=100", fc, :mean_std, [a, if(big?, do: 100, else: 10)]},
      {"encode64 1 MB", Codecs.Kernels, :encode64, [bytes(mb)]},
      {"decode64 1 MB", Codecs.Kernels, :decode64, [b64]},
      {"encode16 1 MB", Codecs.Kernels, :encode16, [bytes(mb)]},
      {"decode16 1 MB", Codecs.Kernels, :decode16, [hex]},
      {"encode58 32 B keys", Codecs.Kernels, :encode58, [keys58, 32]},
      {"topk 384-dim f32", Cosine.Kernels, :topk, [f32s(rows * 384), f64s(384), 10, 0]},
      {"fft", FFT.Kernels, :fft, [f64s(fftn), f64s(fftn)]},
      {"convolve 64 taps", FFT.Kernels, :convolve, [audio, taps]},
      {"nearest k=10", Geo.Kernels, :nearest, [lat, lon, coslat, 51.5, -0.12, 10]},
      {"geohash_encode p=12", GeoCrc.Kernels, :geohash_encode, [lat, lon, 12]},
      {"crc16 1 MB", GeoCrc.Kernels, :crc16, [bytes(mb)]},
      {"crc64 1 MB", GeoCrc.Kernels, :crc64, [bytes(mb)]},
      {"gorilla streams", Gorilla.Kernels, :streams, [Gorilla.Defk.pack(series, <<>>)]},
      {"sha256_chain", HashChain.Kernels, :sha256_chain_unrolled,
       [bytes(32), if(big?, do: 20_000, else: 10)]},
      {"xxh64 1 MB", Hashes.Kernels, :xxh64, [bytes(mb), 0]},
      {"murmur3_128 1 MB", Hashes.Kernels, :murmur3_128, [bytes(mb), 0]},
      {"siphash24 1 MB", Hashes.Kernels, :siphash24, [bytes(mb), 1, 2]},
      {"crc32c 1 MB", Hashes.Kernels, :crc32c, [bytes(mb)]},
      {"hll update_many", Hll.Kernels, :update_many,
       [hll_state, u64s(if(big?, do: 100_000, else: 100)), 14]},
      {"gray_blur frame", Blur.Kernels, :gray_blur, [rgb, fw, fh]},
      {"resize_bilinear", ImageOps.Kernels, :resize_bilinear,
       [rgb, fw, fh, 3, div(fw, 4), div(fh, 4)]},
      {"rgb_to_yuv420", ImageOps.Kernels, :rgb_to_yuv420, [rgb, fw, fh]},
      {"dither_fs", ImageOps.Kernels, :dither_fs, [gray, fw, fh]},
      {"keccak256 1 MB", Keccak.Kernels, :keccak256, [bytes(mb)]},
      {"matmul", Matmul.Kernels, :matmul,
       [f64s(side * side), f64s(side * side), side, side, side]},
      {"rtp simulate", RTP.Kernels, :simulate,
       [reels_b, lines_b, pays_b, h, t, if(big?, do: 100_000, else: 50)]},
      {"mix_s16 4 streams", PCM.Kernels, :mix_s16, [i16s(4 * pcm_n, 12_000), 4, <<>>, true]},
      {"lev_batch pairs", Pairs.Kernels, :lev_batch, [pblob, poffs, 13]},
      {"lev_myers", Lev.Kernels, :lev_myers,
       [~c"levenshtein" |> to_string(), wblob, woffs, 0, div(byte_size(woffs), 8) - 1]},
      {"fuzzy search", FuzzySearch.Kernels, :search_blocking, ["levenshtein", wblob, woffs, 10]},
      {"horspool find", Search.Kernels, :find, [hay, needle]},
      {"sort_i64 1M", Keys.Kernels, :sort_i64, [sort_keys]},
      {"valid_utf8?", Utf8.Kernels, :valid_utf8?, [text]},
      {"ws_mask 1 MB", Ws.Defk, :ws_mask, [bytes(mb), 0x12345678]}
    ]
  end
end
