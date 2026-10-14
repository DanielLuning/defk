# release_debian: a mix release in a stock Debian Elixir image

Evidence for the C-compiler stance. This is a
one-module app (`ReleaseDebian.dot/2`, a defk kernel) that depends on defk as
a path dep. It is built with `mix release` in a stock hexpm/elixir Debian
image, and the kernel is called from the release.

```bash
# from the defk repo root (podman or docker)
podman build -f examples/release_debian/Dockerfile -t defk-release-debian .
podman run --rm defk-release-debian
# %{kernel: 333833500.0, elixir: 333833500.0, lib: "/app/lib/release_debian-0.1.0/ebin/Elixir.ReleaseDebian-7e87eb8f86.so", agree: true}
```

The kernel's library ships inside the release, in the app's `ebin/` (see
finding 1), so the runtime stage copies the release and nothing else.

Recorded 2026-10-07 on an Apple-silicon Mac, podman 5 (applehv VM, linux/arm64).
Builder: `hexpm/elixir:1.20.2-erlang-29.0.3-debian-trixie-20260713-slim`
(the same Elixir and OTP as local dev). Runner: `debian:trixie-20260713-slim`.

## Packages that had to be added (build stage only)

| `BUILD_PKGS` | Result |
|---|---|
| none | Fails. `System.cmd("cc", ...)` raises `ErlangError :enoent` while compiling defk's own `lib/examples.ex`. The error doesn't mention a C compiler. Neither the slim nor the full hexpm Debian image ships `cc`, `gcc` or `make`. |
| `gcc` | Fails. `erl_drv_nif.h:161: fatal error: sys/types.h: No such file or directory`. With `--no-install-recommends`, gcc comes without libc headers. |
| `gcc libc6-dev` | Works. This is the minimum. |
| `build-essential` | Works. This is the conventional choice (Phoenix's generated Dockerfile uses it) and the Dockerfile's default. It adds g++, make and dpkg-dev, which defk doesn't need. |

The runtime stage needs **no C compiler**. The final image has no `cc`, `gcc`,
`ld` or `as`, and the kernel runs. The `.so` links only against `libc.so.6`.
The runtime packages (`libstdc++6 libncurses6 libsctp1 openssl locales
ca-certificates`) are what any Elixir release needs. None is there for defk.

## Size and time

| Image | Size |
|---|---|
| hexpm/elixir …-slim (builder base) | 191 MB |
| + `build-essential` apt layer | +335 MB |
| + `gcc libc6-dev` apt layer (minimum) | +214 MB |
| builder stage after `mix release` (build-essential) | 543 MB |
| builder stage after `mix release` (gcc + libc6-dev) | 422 MB |
| debian:trixie-slim (runner base) | 103 MB |
| **final runtime image** | **178 MB** (release 17 MB, kernel `.so` files 212 KB incl. `.c`) |

| Step | Time |
|---|---|
| `apt-get install build-essential` (update + install, 61 packages) | 7.8 s |
| `mix release` from a clean `_build` (defk + app, both kernel modules) | 1.4 s |
| of which `cc` for `Examples.Kernels` (defk's own, 57 KB of C) | 0.36 s |
| of which `cc` for `ReleaseDebian` (one kernel) | 0.08 s |
| whole multi-stage `podman build --no-cache`, base images already pulled | 33 s |

The compiler costs image size in the builder only, not build time: it adds
about 0.45 s to `mix release` and about 8 s of apt (cached as a layer after the
first build).

## Findings for the verdict

1. **The kernel `.so` was not part of the release (since fixed).**
   `Defk.Build` wrote it to `_build/<env>/defk/` and the generated
   `__defk_load__` loaded that absolute build path, which `mix release` does
   not copy. In a multi-stage image without it, `bin/release_debian start`
   crashed at boot (`on_load_function_failed ... cannot open shared object
   file`), and the Dockerfile copied `_build/prod/defk` to the same absolute
   path in the runtime image as a workaround.
   - Now a module of a Mix app gets a copy of its library in the app's
     `ebin/`, beside its `.beam`, and loads it from
     `:code.lib_dir(app)/ebin` when it loads. `mix release` copies `ebin/`,
     so the library is in the release (`lib/release_debian-0.1.0/ebin/`),
     and a release copied to another path still loads it.
   - Verified 2026-10-11 with podman 5 (linux/arm64): the image built without
     the copy runs `eval` and `start` (`daemon` + `rpc`), also from a copy of
     the release at another path, with no `_build` or `/src` in the image.
2. **Every app depending on defk compiles defk's example kernels.**
   `lib/examples.ex` (`Examples.Kernels`) is in the library's `lib/`, so the
   app builds and ships it too: 0.36 s of `cc` and about 75 KB of `.so`.
   (No longer so: the example kernels now compile only in `:dev` and
   `:test`, from `test/support/`; the 2026-10-11 build ships one `.so`.)
3. **gcc warnings are hidden.** gcc 14 warns about unused variables and helpers
   in the generated C. defk discards compiler output on success, so the build
   log stays clean. This isn't a problem, but `-Wall` output on Linux differs
   from clang on macOS.
4. Cross-compiling (for example, building on macOS for a Linux runner) wasn't
   tried. The `.so` is built for the builder's architecture (here
   linux/arm64), so builder and runner must match, as with any NIF.
5. **The builder needs Hex.** defk's `mix.exs` lists Hex dev/test deps, and
   Mix needs Hex to read it even when they are skipped, so the build stage
   runs `mix local.hex --force` (without it: `Could not find an SCM for
   dependency :ex_slop`).
