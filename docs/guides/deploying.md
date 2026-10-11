# Deploying

A kernel is compiled to a native library when its module compiles, so
deploying an app with kernels is deploying an app with a NIF built from
source, as with packages that use `elixir_make`. This page says what the
build and the runtime need, and where defk falls short today.

> #### Kernels are not in a `mix release` yet {: .warning}
>
> `mix release` does not copy the kernels' native libraries, so a release
> moved to another machine or path fails to start. Until ticket `defk-n8f`
> is fixed, use one of the workarounds [below](#releases).

## The build machine needs a C compiler

`mix compile` (and so `mix release`) runs `cc`, or the compiler named in
`CC`, for every module with kernels. Install one in the build stage:

| System | Packages |
|---|---|
| Debian, Ubuntu | `build-essential`, or at least `gcc libc6-dev` (gcc alone lacks the C library headers) |
| Alpine | `build-base` |
| macOS | `xcode-select --install` |

Without one, the build stops with the
[`no-c-compiler`](../language.md#no-c-compiler) error, which names the
compiler it looked for and these packages. Set `ERTS_INCLUDE_DIR` to build
against another ERTS's `erl_nif.h` instead of the running one's, as with
`elixir_make`.

Compiling the kernels costs little: in a recorded Debian build, `cc` added
about 0.45 s to `mix release`, and the compiler packages added 214 to 335 MB
to the builder image only.

The build is cached in `_build/<env>/defk/` under a hash of the generated C,
the runtime header, the compiler flags, the ERTS version and the compiler, so
a CI cache of `_build` skips unchanged kernels.

Why defk compiles C at build time, rather than shipping precompiled code or
compiling at run time, is recorded in
[ADR 0002](https://github.com/DanielLuning/defk/blob/main/docs/adr/0002-c-compiler-at-build-time.md).

## The runtime needs no compiler

The kernel libraries link only against the C library (`libc.so.6` on
Debian), so the runtime image needs what any Elixir release needs and
nothing more: no `cc`, `ld` or headers.

Build on the same CPU architecture and C library as you run on. A library
built on `linux/arm64` with glibc will not load on `x86_64`, or on Alpine
(musl). Cross-compiling (macOS to Linux, Nerves) has not been tried.

## Releases

The kernel libraries are written to `_build/<env>/defk/`, and each module
loads its library from that absolute path when it loads. `mix release`
copies each application's `ebin/` and `priv/`, not that directory. So:

- a release run where it was built, with `_build` still in place, works;
- a release copied anywhere else fails at boot with
  `on_load_function_failed` and `Failed to load NIF library: ... cannot
  open shared object file`, and the kernel module is undefined.

Until the libraries ship in the release (ticket `defk-n8f`: write them under
the app's `priv/` and load them from there), the workaround for a container
is to copy `_build/<env>/defk` from the build stage to **the same absolute
path** in the runtime image. The multi-stage Debian example in
[`examples/release_debian`](https://github.com/DanielLuning/defk/blob/main/examples/release_debian/README.md)
does this, and records what it needed and cost (a 178 MB final image, of
which the kernel libraries are 212 KB). This is a workaround, not a
contract: the release is not relocatable.

`Mod.__defk_lib__/0` returns the path a module loads its library from,
which helps when checking an image.

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
cached with the rest of `Mix.install`'s cache.

## Shipping kernels in a Hex package

defk itself is not on Hex; a release waits for the project's verdict. A
library with kernels would today make every app that depends on it compile
them, so every build machine would need a C compiler. Precompiled libraries,
built per target in CI and downloaded by hash as `rustler_precompiled` and
`cc_precompiler` do, are the way out the project has named
([ADR 0002](https://github.com/DanielLuning/defk/blob/main/docs/adr/0002-c-compiler-at-build-time.md)),
but nothing is built for it yet. The [scope page](../scope.md) tracks what
is planned.
