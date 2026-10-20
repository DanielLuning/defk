# defk

> defk explores one question: **can a typed subset of Elixir compile
> to native code that runs at C speed, with a cheap boundary, while keeping the
> BEAM's promises (preemption, isolation, cleanup)?**

For loops over numbers and bytes the answer was yes. You
write a **kernel** with `defk` in an ordinary module. It reads like Elixir,
takes typed numbers and packed binaries, and compiles to a checked native
function (a NIF) when the module compiles.

## Purpose: help Elixir, not compete with it

The goal of defk is not to beat Elixir. It is to find the jobs where Elixir
today pushes people towards a hand-written NIF, and to offer something
better there.

Elixir stays the default. When an Elixir solution is as good or as fast, it
is the right choice. So before claiming defk should be used anywhere, we
optimise the Elixir solution as far as we can, and we keep the cases where
Elixir wins as part of the record.

## When it helps, and when Elixir is the right choice

[`examples/`](https://github.com/DanielLuning/defk/blob/main/examples) is a growing catalog of real use cases, each written in
Elixir and in defk, checked for agreement and measured end to end. The
measurement rules are in [`examples/README.md`](https://github.com/DanielLuning/defk/blob/main/examples/README.md); the
[scope page](docs/scope.md) says when to use defk, when to use something else,
what is planned and what stays out by design.

<!-- summary:start -->
Speedups over an optimised Elixir baseline, measured end to end on Apple M4 Pro from 2026-10-19 to 2026-10-20 (one machine, so measure your own job). ✅ defk helps; 🟡 and ❌ use Elixir.

| | The job | defk vs best Elixir |
|---|---|---|
| ✅ | non-cryptographic hashes that must match other systems (xxHash64; Murmur3, SipHash and CRC32C beside it) | 203× |
| ✅ | FFT and convolution over audio-sized f64 signals | 82× |
| ✅ | BLAKE2b and BLAKE3 from scratch, level with the reference C NIF | 32× |
| ✅ | cosine top-k over 100k resident f32 embeddings (Nx with EXLA is faster still for a plain dot product) | 13× |
| ✅ | a bounded CDCL SAT solver on an authorisation job, 3.6× faster than picosat behind Crux | 11× |
| ✅ | 1080p image resize, blur, YUV420 conversion and dithering on raw frames, bit-exact | 7.4–14× |
| ✅ | rolling sensor statistics, HyperLogLog updates, PCM mixing with clip prevention, a byte histogram | 8.4–10× |
| ✅ | base64, hex and base58 codecs (4.2× the fast64 NIF); Snappy and LZ4 block decode on untrusted input | 5.1–6.1× |
| ✅ | sorting packed keys, nearest of 500k locations, Monte Carlo slot simulation with `:rand` bit for bit, Gorilla encoding | 2.4–6.0× |
| ✅ | a numeric CSV or a JSON array of numbers straight into packed f64s (NimbleCSV and Jason stay for anything else) | 2.7× |
| ✅ | CSV to NimbleCSV's rows through a kernel that cleans the separators for `:binary.split` (rusty_csv's NIF is faster still) | 2.1× |
| ✅ | a fuzzy-search web service, Myers bit-parallel on both sides: `/health` latency stays at Elixir's while a blocking NIF raises it | [its own measurement](https://github.com/DanielLuning/defk/blob/main/examples/fuzzy_search/README.md) |
| 🟡 | a dictionary-wide Levenshtein batch over all schedulers: Myers bit-parallel in Elixir is close | 1.5× |
| 🟡 | small WebSocket frames, UTF-8 validation, substring search: the BIFs are native already | 1.0–1.5× |
| ❌ | anything `:crypto` does (a SHA-256 chain) and memory-hard password hashing (Argon2: the C runs its lanes on threads) | 0.27–0.57× |
| ❌ | one kernel call per element | 0.28× |
| ❌ | data that arrives as lists: packing costs more than the whole `Enum.sum` | 0.07× |
| ⛔ | maps and string building | not expressible (a string literal is a read-only `[u8]`) |
<!-- summary:end -->

## A first kernel

```elixir
defmodule Stats do
  use Defk

  defk dot(a :: [f64], b :: [f64]) :: f64 do
    for i <- 0..(length(a) - 1)//1, reduce: 0.0 do
      acc -> acc + a[i] * b[i]
    end
  end
end
```

```elixir
iex> bin_a = for x <- [1.0, 2.0], into: <<>>, do: <<x::float-64-native>>
iex> bin_b = for x <- [3.0, 4.0], into: <<>>, do: <<x::float-64-native>>
iex> Stats.dot(bin_a, bin_b)
11.0
```

A `[f64]` argument is a binary of packed native-endian floats. At `mix
compile`, `defk` type-checks the body, emits C, builds a NIF with `cc -O3`,
and generates the Elixir stubs plus `@spec`s. A construct outside the kernel
subset is a compile error in Elixir's diagnostic format, with why it's
rejected, a rewrite where one exists, and a stable code. Every kernel also
compiles to plain Elixir (Elixir mode), so tests can check the two agree.

## Start here

Needs Elixir ≥ 1.20 (OTP 29 tested) and a C compiler (`cc`, or set `CC`) on
the machine that compiles your code. To use it, add it as a dependency
(`{:defk, "~> 0.1"}` in a Mix project's `deps`, or
`Mix.install([{:defk, "~> 0.1"}])` in a script) and
write kernels in any module with `use Defk`.

- [Getting started](docs/guides/getting-started.md): a first kernel, step by step.
- [Testing kernels](docs/guides/testing.md): check a kernel against Elixir.
- [Measuring](docs/guides/measuring.md): compare with an optimised Elixir version honestly.
- [Runtime contract](docs/guides/runtime-contract.md): preemption, errors and cleanup.
- [Deploying](docs/guides/deploying.md): releases and the C compiler.
- [Stability](docs/guides/stability.md): what stays the same from release to release.
- [Cheatsheet](docs/guides/cheatsheet.cheatmd) and the full [language reference](docs/language.md).
- [Compile errors](docs/compile-errors.md): every code, why and what to write instead.
- [Scope](docs/scope.md): what defk is for, what is planned and what stays out.
