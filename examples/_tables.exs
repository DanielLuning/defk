# The hand-written text of the catalog's result tables. The numbers are not
# here: `mix defk.docs` fills them in from examples/scoreboard.json
# (written by `mix defk.examples --bench --all --snapshot`) and rewrites the
# tables in examples/README.md and README.md. A test fails when a table and
# the stored scoreboard disagree.
#
# A placeholder in a text takes a value from a DEFK_RESULT line:
#
#   {speedup}  {native}  {crossover}            this example's first report
#   {speedup:NAME}  {native:NAME}  {crossover:NAME}
#                                               the report NAME, or the first
#                                               report of the example NAME
#
# `speedup` is defk against the best Elixir, `native` defk against the
# package's NIF, `crossover` the first size where defk is 2x.
#
# Numbers that no report measures (sizes, figures from a script's header)
# are plain text; their source is the script.

%{
  # examples/README.md, the scoreboard: one row per example. `native` and
  # `line` may hold placeholders; `job` is the size the verdict is measured at.
  examples: %{
    "argon2" => %{
      job: "Argon2id at argon2_elixir's defaults",
      # argon2_one_lane's Elixir side is argon2_elixir, the reference C: its
      # speedup is the native comparison
      native: "lane for lane {speedup:argon2_one_lane} of the reference C",
      line: "the C runs its four lanes on threads; the kernel runs them in sequence"
    },
    "batched_levenshtein" => %{
      job: "one query against 234k words, 12 chunks each side",
      native: "{native} ex_strsim per pair",
      line: "Myers bit-parallel in plain Elixir is close; use it"
    },
    "blake" => %{
      job: "BLAKE2b-512 of 64 KB",
      native: "{native} blake2_elixir (reference C)",
      line:
        "BLAKE3 {speedup:blake3} Elixir and {native:blake3} the NEON NIF; against `:crypto`'s BLAKE2b only {speedup:blake_crypto}"
    },
    "byte_histogram" => %{
      job: "histogram of 16 MB, 12 chunks each side",
      line: "windowed entropy {speedup:windowed_entropy}; one process vs one call 11–18×"
    },
    "cdcl_sat" => %{
      job: "Crux's whole scenario enumeration, 109 vars",
      native: "{native} Crux on picosat",
      line: "picosat's search is stronger on hard random 3-SAT, and blocks a scheduler for the whole solve there"
    },
    "cdcl_sat_per_call" => %{
      job: "one SAT solve per call, 26–28 vars",
      native: "{native} picosat",
      line: "≈1× on tiny formulas; batch the solves when one question makes several"
    },
    "codecs" => %{
      job: "base64 round trip of 1 MB",
      native: "{native} fast64",
      line: "hex {speedup:codecs_hex}, base58 {speedup:codecs_base58} per batch; one key per call is about as fast as Elixir"
    },
    "cosine_topk" => %{
      job: "top-10 of 100k × 384 f32 embeddings",
      native: "{native} vettore",
      line: "Nx + EXLA is faster than defk: use it for a plain dot-product top-k"
    },
    "fft" => %{
      job: "FFT of 4096 points; a 64-tap FIR over 2 s of audio",
      line: "bit-exact with Elixir; Nx's binary backend is slower than plain Elixir here"
    },
    "geo_nearest" => %{
      job: "10 nearest of 500k locations",
      line: "14× in one process; a grid prefilter helps both sides"
    },
    "geohash_crc" => %{
      job: "geohash encode of 100k points",
      line:
        "decode {speedup:geohash_decode}; CRC-16 {speedup:crc16} and CRC-64 {speedup:crc64}; one point per call {speedup:geohash_encode_single}"
    },
    "gorilla_encode" => %{
      job: "Gorilla encoding of 100-point blocks",
      native: "{native} gorilla_stream's NIF",
      line: "close to the bar at this size; {speedup:gorilla_encode_1m} at 1M points"
    },
    "hash_chain" => %{
      job: "a 10M-step SHA-256 chain",
      line: "`:crypto` runs on the SHA instructions; HMAC rounds {speedup:hmac_rounds}"
    },
    "hashes" => %{
      job: "xxHash64 of a 4 MB message",
      native: "SipHash {native:hashes_siphash24} of its NIF; CRC32C {native:hashes_crc32c} of crc32cer",
      line: "Elixir is bignum-bound at 64-bit hashes; Murmur3 and SipHash are the same story"
    },
    "hll_update_many" => %{
      job: "100k hashes into a p = 14 sketch",
      native: "{native} the Rust NIF",
      line: "the NIF's time is its own packing; fed packed input it is level"
    },
    "image_blur" => %{
      job: "grayscale + 3×3 box blur, 1080p, 12 bands each side",
      line: "one process against one call 26–29×"
    },
    "image_ops" => %{
      job: "bilinear resize 1080p → 480×270",
      line: "YUV420 {speedup:image_yuv420} and Floyd-Steinberg dither {speedup:image_dither}; libvips not compared"
    },
    "keccak" => %{
      job: "Keccak-256 of 10k × 32 B per call",
      native: "{native} ex_keccak",
      line: "the NIF blocks its scheduler on a 16 MB message; SHA3-256 against `:crypto` is {speedup:keccak_sha3_256}"
    },
    "lz4_snappy_decode" => %{
      job: "Snappy block decode of 64 KB",
      native: "{native} snappyer as installed (-O0)",
      line: "slower than the same libraries built -O2; LZ4 the same picture"
    },
    "matmul" => %{
      job: "256×256 f64",
      native: "{native} Nx + EXLA (CPU, from binaries)",
      line:
        "Nx with EXLA is 6× faster at 256×256 and 108× at 1024×1024; defk wins only at 64×64, where EXLA's dispatch and copies cost more than the product"
    },
    "monte_carlo_rtp" => %{
      job: "100M slot spins on all schedulers",
      line: "≈1× at 1M spins: short kernel chunks stay on few schedulers"
    },
    "out_of_scope_word_count" => %{
      job: "strings in, a map out",
      line: "not expressible: the compiler refuses, as it should"
    },
    "pcm_mix" => %{
      job: "4 PCM streams with clip prevention, 10 ms chunks",
      native: "{native} Membrane's NativeAdder",
      line: "back-to-back NativeAdder calls are never preempted"
    },
    "per_pair_distance" => %{
      job: "Levenshtein on 50k short pairs, one call each",
      line: "stay in Elixir for very short strings"
    },
    "poor_list_data" => %{
      job: "the data arrives as a list",
      line: "packing the list costs more than the whole `Enum.sum`"
    },
    "poor_substring_search" => %{
      job: "a 64-byte needle in 16 MB",
      line: "`:binary.match` is Boyer-Moore in C already"
    },
    "poor_tiny_calls" => %{
      job: "one kernel call per element",
      line: "13 ns per call against 2 ns for an Elixir call"
    },
    "rolling_stats" => %{
      job: "moving mean/stddev over 1M readings, 12 chunks each side",
      line: "one process against one call ~34×"
    },
    "sort_u64_keys" => %{
      job: "sort 1M packed keys",
      line: "{speedup:sort_to_list} when the caller needs a list back"
    },
    "utf8_valid" => %{
      job: "validate 16 MB of UTF-8",
      line: "`String.valid?` is C already"
    },
    "ws_masking" => %{
      job: "mask 125-byte WebSocket frames",
      native: "{native} bandit_native",
      line: "the call is the cost; {speedup:ws_masking_1mib} at 1 MiB, crossover {crossover}"
    }
  },

  # Rows for the apps, which measure themselves and are not in the
  # scoreboard: placed after the rows of their verdict.
  apps: [
    %{
      name: "fuzzy_search",
      verdict: "good",
      job: "a search service over 234k words behind Bandit",
      value: "its own measurement, see its README",
      line: "Myers on both sides; `/health` latency stays at Elixir's while a blocking NIF raises it"
    }
  ],

  # README.md, the summary: one row per group, in this order. A group's
  # examples must share a verdict; the value is the range of their first
  # reports' speedups, unless `value` is given. `app` names an app row.
  summary: [
    %{
      text:
        "non-cryptographic hashes that must match other systems (xxHash64; Murmur3, SipHash and CRC32C beside it)",
      examples: ["hashes"]
    },
    %{text: "FFT and convolution over audio-sized f64 signals", examples: ["fft"]},
    %{text: "BLAKE2b and BLAKE3 from scratch, level with the reference C NIF", examples: ["blake"]},
    %{
      text:
        "cosine top-k over 100k resident f32 embeddings (Nx with EXLA is faster still for a plain dot product)",
      examples: ["cosine_topk"]
    },
    %{
      text: "a bounded CDCL SAT solver on an authorisation job, {native:cdcl_sat} faster than picosat behind Crux",
      examples: ["cdcl_sat"]
    },
    %{
      text: "1080p image resize, blur, YUV420 conversion and dithering on raw frames, bit-exact",
      examples: ["image_blur", "image_ops"]
    },
    %{
      text:
        "rolling sensor statistics, HyperLogLog updates, PCM mixing with clip prevention, a byte histogram",
      examples: ["rolling_stats", "hll_update_many", "pcm_mix", "byte_histogram"]
    },
    %{
      text:
        "base64, hex and base58 codecs ({native:codecs} the fast64 NIF); Snappy and LZ4 block decode on untrusted input",
      examples: ["codecs", "lz4_snappy_decode"]
    },
    %{
      text:
        "sorting packed keys, nearest of 500k locations, Monte Carlo slot simulation with `:rand` bit for bit, Gorilla encoding",
      examples: ["sort_u64_keys", "geo_nearest", "monte_carlo_rtp", "gorilla_encode"]
    },
    %{
      text:
        "a fuzzy-search web service, Myers bit-parallel on both sides: `/health` latency stays at Elixir's while a blocking NIF raises it",
      app: "fuzzy_search",
      value:
        "[its own measurement](https://github.com/DanielLuning/defk/blob/main/examples/fuzzy_search/README.md)"
    },
    %{
      text: "a dictionary-wide Levenshtein batch over all schedulers: Myers bit-parallel in Elixir is close",
      examples: ["batched_levenshtein"]
    },
    %{
      text: "small WebSocket frames, UTF-8 validation, substring search: the BIFs are native already",
      examples: ["ws_masking", "utf8_valid", "poor_substring_search"]
    },
    %{
      text:
        "anything `:crypto` does (a SHA-256 chain) and memory-hard password hashing (Argon2: the C runs its lanes on threads)",
      examples: ["hash_chain", "argon2"]
    },
    %{text: "one kernel call per element", examples: ["poor_tiny_calls"]},
    %{
      text: "data that arrives as lists: packing costs more than the whole `Enum.sum`",
      examples: ["poor_list_data"]
    },
    %{
      text: "maps and string building",
      examples: ["out_of_scope_word_count"],
      value: "not expressible (a string literal is a read-only `[u8]`)"
    }
  ]
}
