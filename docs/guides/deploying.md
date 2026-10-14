# Deploying

A kernel is compiled to a native library when its module compiles, so
deploying an app with kernels is deploying an app with a NIF built from
source, as with packages that use `elixir_make`. This page says what the
build and the runtime need, how the kernels travel in a release, and where
defk falls short today.

## The build machine needs a C compiler

`mix compile` (and so `mix release`) runs `cc`, or the compiler named in
`CC`, for every module with kernels. Install one in the build stage:

| System | Packages |
|---|---|
| Debian, Ubuntu | `build-essential`, or at least `gcc libc6-dev` (gcc alone lacks the C library headers) |
| Alpine | `build-base` |
| macOS | `xcode-select --install` |

Without one, the build stops with the
[`no-c-compiler`](../compile-errors.md#no-c-compiler) error, which names the
compiler it looked for and these packages. Set `ERTS_INCLUDE_DIR` to build
against another ERTS's `erl_nif.h` instead of the running one's, as with
`elixir_make`.

Compiling the kernels costs little: in a recorded Debian build, `cc` added
about 0.45 s to `mix release`, and the compiler packages added 214 to 335 MB
to the builder image only.

The build is cached in `_build/<env>/defk/` under a hash of the generated C,
the runtime header, the compiler flags, the ERTS version and the compiler, so
a CI cache of `_build` skips unchanged kernels. A module of your app also
gets a copy of its library in the app's `ebin/` (next section).

defk compiles C at build time, rather than shipping precompiled code or
compiling at run time, for the same reason `elixir_make` packages do: the
kernel is specialised to your code and optimised by your C compiler, and the
running system needs nothing extra.

## Where defk is tested

The whole test suite runs on every change, with OTP 29 and Elixir 1.20, on
these four targets:

| OS and CPU | C library | Compiler |
|---|---|---|
| Linux x86-64 (Debian) | glibc | clang |
| Linux x86-64 (Debian) | glibc | gcc |
| Linux arm64 (Debian) | glibc | clang |
| macOS arm64 | | Apple clang |

Linux arm64 with gcc passed the suite too, but is not run on every change.

Not tested: Alpine and other musl systems (the table above lists their
compiler packages, but no kernel has been run there), macOS on x86-64,
Windows, the BSDs, 32-bit systems, and cross-compiling. Each may work; none
has been checked.

Two features depend on the compiler:

- The fast-path report's vectorisation facts (`report: :full`) come from
  clang. With gcc they say "unknown".
- Which loops vectorise differs by CPU: a float sum kept in Elixir's order
  vectorises on arm64 but not on x86-64. Results stay the same; only the
  speed differs.

## The runtime needs no compiler

The kernel libraries link only against the C library (`libc.so.6` on
Debian), so the runtime image needs what any Elixir release needs and
nothing more: no `cc`, `ld` or headers.

Build on the same CPU architecture and C library as you run on. A library
built on `linux/arm64` with glibc will not load on `x86_64`, or on Alpine
(musl). Cross-compiling (macOS to Linux, Nerves) has not been tried.

## Releases

A module of a Mix app (compiled from the project's `elixirc_paths`) gets a
copy of its kernel library in the app's `ebin/` directory, beside its
`.beam`: `_build/<env>/lib/<app>/ebin/<Module>-<key>.so`. When the module
loads, it finds the library from where the app is then, through
`:code.lib_dir(app)`, not from a path fixed at build time. `mix release`
copies each application's `ebin/`, so the libraries are in the release
(`lib/<app>-<vsn>/ebin/`), and a release copied to another machine or path
loads them. Nothing beyond the release needs copying. Applications that
depend on a library with kernels get its libraries in that library's
`ebin/` the same way.

The source `priv/` is not used: in development `_build/<env>/lib/<app>/priv`
is a link to it, and generated files do not belong in the source tree.

A multi-stage Dockerfile is the usual one for an Elixir release, with a C
compiler in the build stage only:

```dockerfile
FROM hexpm/elixir:1.20.2-erlang-29.0.3-debian-trixie-20260713-slim AS build
RUN apt-get update && apt-get install -y --no-install-recommends build-essential \
    && rm -rf /var/lib/apt/lists/*
ENV MIX_ENV=prod
WORKDIR /app
RUN mix local.hex --force
COPY . .
RUN mix deps.get --only prod && mix release

FROM debian:trixie-20260713-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
      libstdc++6 libncurses6 openssl locales ca-certificates \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY --from=build /app/_build/prod/rel/my_app ./
CMD ["bin/my_app", "start"]
```

This Dockerfile is a sketch, not built by the tests. The version the project
built and ran, a multi-stage Debian build of a small app with a kernel, is
[`examples/release_debian`](https://github.com/DanielLuning/defk/blob/main/examples/release_debian/README.md)
in the repository; it records what the build needed and cost (a 178 MB
final image, of which the kernel libraries are 212 KB).

`Mod.__defk_lib__/0` returns the path a module loads its library from,
which helps when checking an image:
`bin/my_app eval 'IO.puts(MyApp.Kernels.__defk_lib__())'`.

A module that belongs to no Mix app (a script, `Mix.install`,
`Code.compile_string/2`, a test file) loads its library from the absolute
build path, as before (see [Scripts and Livebook](#scripts-and-livebook)).

Release upgrades (relups) with kernels have not been tried. Reloading a
module while a kernel is suspended is covered by
[the runtime contract](runtime-contract.md#4-hot-code-upgrade-a-suspended-kernel-finishes-in-its-own-code).

## Elixir mode is not a fallback

There is no plain-Elixir fallback in production: if a kernel's library does
not load, the module does not load. `config :defk, mode: :elixir` is refused
outside `:dev` and `:test`, and `use Defk, elixir_mode: true` only adds
`__defk_elixir__/2` for checks; the kernel's own function stays native.

## Scripts and Livebook

`Mix.install([{:defk, ...}])` compiles kernels on the machine that runs the
script or notebook, so that machine needs the C compiler. The builds are
cached with the rest of `Mix.install`'s cache. A kernel module defined in
the script itself loads its library from its absolute build path.

## Defining kernels at run time

A kernel module can be defined in a running node, with no restart:
`Code.compile_string/2` (or IEx) on source that does `use Defk` builds the
library, loads it and the module is ready to call, with the same compiler,
compile errors, yielding and [runtime contract](runtime-contract.md) as a
module in `lib/`:

<!-- defk-example skip: the kernel is inside a string; test/runtime_define_test.exs runs the same steps -->
```elixir
Code.compile_string("""
defmodule MyApp.Live do
  use Defk
  defk add(a :: i64, b :: i64) :: i64, do: a + b
end
""")

MyApp.Live.add(2, 3)
#=> 5
```

- **The node that compiles is a build machine.** It needs the C compiler
  and `erl_nif.h` (the running ERTS's, or `ERTS_INCLUDE_DIR`), which a
  runtime image built as above does not have. Each new kernel costs a C
  compile (about 0.7 s for a small one on an M-series Mac); an unchanged
  one is a cache hit (about 20 ms).
- **The library stays where it was built**: under `_build/<env>/defk/` in a
  Mix project, else in the system temp directory, loaded from that absolute
  path. It is not copied into `ebin/` and is not part of a release, so the
  module is gone after a restart until it is defined again.
- **Defining the module again** builds and loads the new version; a kernel
  still running the old one finishes in it, as in a
  [hot code upgrade](runtime-contract.md#4-hot-code-upgrade-a-suspended-kernel-finishes-in-its-own-code).
- **The source is native code.** The kernel subset leaves out the unsafe
  parts of C, but compiling source you did not write still runs it in your
  node; compile only source you trust.

## Shipping kernels in a Hex package

A library of your own that uses kernels would today make every app that
depends on it compile
them, so every build machine would need a C compiler. Precompiled libraries,
built per target in CI and downloaded by hash as `rustler_precompiled` and
`cc_precompiler` do, are the way out the project has named, but nothing is
built for it yet. The [scope page](../scope.md) tracks what
is planned.
