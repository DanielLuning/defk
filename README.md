# defk

> defk explores one question: **can a typed subset of Elixir compile
> to native code that runs at C speed, with a cheap boundary, while keeping the
> BEAM's promises (preemption, isolation, cleanup)?**

defk is a research project, not a released library (it is not on Hex). You
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
on the BEAM is in the [performance guide](docs/performance.md).

- **Where defk looks like it helps.** These are provisional: the Elixir baselines are optimised, but the numbers were measured under load and wait for a quiet-machine run. Measure your own job.
  - rolling sensor statistics
  - nearest of 500k locations
  - 1080p image blur
  - FFT and convolution over audio-sized f64 signals (63–91× an optimised Elixir baseline)
  - a fuzzy-search web service, where `/health` latency stays at Elixir levels while a blocking NIF pushes it to ~80 ms p99
  - 1080p image resize, YUV420 conversion and Floyd-Steinberg dithering on raw frames (12–26× an optimised Elixir baseline, bit-exact; libvips not compared)
  - Monte Carlo slot RTP simulation, the kernel running `:rand`'s exsss generator bit for bit (3.2–3.3× an optimised Elixir baseline at 100M spins on all schedulers; totals equal exactly)
- **Where Elixir is the right choice:**
  - data that arrives as lists (defk ≈3× slower)
  - one kernel call per element (defk ≈2.5× slower)
  - maps and string building (not expressible; a string literal is a read-only `[u8]`)

## A first kernel

```elixir
defmodule Stats do
  use Defk

  defk dot(a :: [f64], b :: [f64]) :: f64 do
    for i <- 0..(len(a) - 1)//1, reduce: 0.0 do
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
(`{:defk, path: "../defk"}` in a Mix project's `deps`, or
`Mix.install([{:defk, path: "../defk"}])` in a script; it is not on Hex) and
write kernels in any module with `use Defk`.

- [Getting started](docs/guides/getting-started.md): a first kernel, step by step.
- [Testing kernels](docs/guides/testing.md): check a kernel against Elixir.
- [Measuring](docs/guides/measuring.md): compare with an optimised Elixir version honestly.
- [Runtime contract](docs/guides/runtime-contract.md): preemption, errors and cleanup.
- [Deploying](docs/guides/deploying.md): releases and the C compiler.
- [Cheatsheet](docs/guides/cheatsheet.cheatmd) and the full [language reference](docs/language.md).
- [Compile errors](docs/compile-errors.md): every code, why and what to write instead.
- [Scope](docs/scope.md) and the [performance guide](docs/performance.md).

Working on defk itself (demo and benchmarks, which file does what, design
decisions, results snapshot, roadmap): [docs/project.md](https://github.com/DanielLuning/defk/blob/main/docs/project.md).
