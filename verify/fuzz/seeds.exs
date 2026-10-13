# Regenerate the seed corpora in verify/fuzz/corpus/ from the reference
# encoders (snappyer: the snappy C++ library; lz4_erl: liblz4, fast and HC).
# The seeds are committed; run this only to change them:
#
#   elixir verify/fuzz/seeds.exs
#
# Each seed is a small valid input in the target's input format
# (verify/fuzz/targets/*.c): snappy_decode takes the block as is,
# lz4_block_decode a 2-byte little-endian max_out + 16 and then the block.
# The payloads cover the format's cases: an empty and a one-byte input,
# literals only, short and long matches (lengths past 15 and 255, so LZ4's
# continuation bytes and Snappy's copy-2 elements appear), overlapping
# matches (offset below the length), and incompressible bytes.

Mix.install([
  {:snappyer, "~> 1.2"},
  {:lz4, "~> 0.2.4", hex: :lz4_erl}
])

root = Path.expand("corpus", __DIR__)

text = "the quick brown fox jumps over the lazy dog; "

json =
  for i <- 1..6, into: "" do
    ~s({"ts":#{1_700_000_000 + i * 37},"level":"info","msg":"request served","path":"/api/v1/items/#{i}","ms":#{rem(i * 13, 97)}}\n)
  end

payloads = [
  {"empty", ""},
  {"one_byte", "a"},
  {"short_literal", "hello"},
  {"text", String.duplicate(text, 4)},
  {"json", json},
  {"run_zeros_1000", :binary.copy(<<0>>, 1000)},
  {"run_ab_600", :binary.copy("ab", 300)},
  {"period3_70", :binary.copy("xyz", 23) <> "x"},
  {"all_bytes", :binary.list_to_bin(Enum.to_list(0..255))},
  {"mixed",
   "header:" <>
     :binary.copy(<<1, 2, 3, 4>>, 40) <>
     Enum.into(0..99, "", &<<&1 * 7>>) <> String.duplicate(text, 2)}
]

write = fn dir, name, bin ->
  File.mkdir_p!(Path.join(root, dir))
  File.write!(Path.join([root, dir, name]), bin)
end

for {name, data} <- payloads do
  {:ok, s} = :snappyer.compress(data)
  write.("snappy_decode", name, s)

  max = <<byte_size(data) + 16::little-16>>

  if data != "" do
    {:ok, l} = :lz4.compress(data, [])
    {:ok, lhc} = :lz4.compress(data, [:high])
    write.("lz4_block_decode", name, max <> l)
    if lhc != l, do: write.("lz4_block_decode", name <> "_hc", max <> lhc)
  end
end

# an empty LZ4 block is one token with no literals; liblz4 refuses to
# compress "" through lz4_erl, so it is written by hand
write.("lz4_block_decode", "empty", <<16::little-16, 0>>)

for dir <- ~w(snappy_decode lz4_block_decode) do
  files = Path.wildcard(Path.join([root, dir, "*"]))
  bytes = files |> Enum.map(&File.stat!(&1).size) |> Enum.sum()
  IO.puts("#{dir}: #{length(files)} seeds, #{bytes} bytes")
end
