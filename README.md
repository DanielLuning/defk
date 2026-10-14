# defk

> defk explores one question: **can a typed subset of Elixir compile
> to native code that runs at C speed, with a cheap boundary, while keeping the
> BEAM's promises (preemption, isolation, cleanup)?**

The project's [verdict](https://github.com/DanielLuning/defk/blob/main/docs/verdict.md)
answered yes for loops over numbers and bytes, and defk is now a library on
Hex, from `0.1.0` with a [stability promise](docs/guides/stability.md). You
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
what is planned and what stays out by design; what we have learned about speed
on the BEAM is in the
[performance guide](https://github.com/DanielLuning/defk/blob/main/docs/performance.md).

Speedups over an optimised Elixir baseline, measured end to end on an
otherwise idle M4 Pro on 2026-10-13 (the frozen snapshot in
[the verdict](https://github.com/DanielLuning/defk/blob/main/docs/verdict.md);
every number is one machine, so measure your own job). ✅ defk helps;
🟡 and ❌ use Elixir.

| | The job | defk vs best Elixir |
|---|---|---|
| ✅ | non-cryptographic hashes that must match other systems (xxHash64; Murmur3, SipHash and CRC32C beside it) | 209× |
| ✅ | FFT and convolution over audio-sized f64 signals | 73× |
| ✅ | BLAKE2b and BLAKE3 from scratch, level with the reference C NIF | 32× |
| ✅ | cosine top-k over 100k resident f32 embeddings (Nx with EXLA is faster still for a plain dot product) | 13× |
| ✅ | a bounded CDCL SAT solver on an authorisation job, 4× faster than picosat behind Crux | 13× |
| ✅ | 1080p image resize, blur, YUV420 conversion and dithering on raw frames, bit-exact | 7–14× |
| ✅ | rolling sensor statistics, HyperLogLog updates, PCM mixing with clip prevention, a byte histogram | 8–11× |
| ✅ | base64, hex and base58 codecs (4× the fast64 NIF); Snappy and LZ4 block decode on untrusted input | 5–7× |
| ✅ | sorting packed keys, nearest of 500k locations, Monte Carlo slot simulation with `:rand` bit for bit, Gorilla encoding | 2.4–6× |
| ✅ | a fuzzy-search web service: `/health` p99 stays at 10–12 ms where a blocking NIF pushes it to ~80 ms | 4.4× per query |
| 🟡 | a dictionary-wide Levenshtein batch over all schedulers: Myers bit-parallel in Elixir is close | 1.7× |
| 🟡 | small WebSocket frames, UTF-8 validation, substring search: the BIFs are native already | 1.0–1.1× |
| ❌ | anything `:crypto` does (a SHA-256 chain) and memory-hard password hashing (Argon2: the C runs its lanes on threads) | 0.25–0.55× |
| ❌ | one kernel call per element | 0.28× |
| ❌ | data that arrives as lists: packing costs more than the whole `Enum.sum` | 0.08× |
| ⛔ | maps and string building | not expressible (a string literal is a read-only `[u8]`) |

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
- [Scope](docs/scope.md) and the
  [performance guide](https://github.com/DanielLuning/defk/blob/main/docs/performance.md).

Working on defk itself (demo and benchmarks, which file does what, design
decisions, results snapshot, roadmap): [docs/project.md](https://github.com/DanielLuning/defk/blob/main/docs/project.md).
