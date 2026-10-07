# release_debian: a mix release in a stock Debian Elixir image

Evidence for the C-compiler stance (defk-dtw.11, ticket defk-ds0). This is a
one-module app (`ReleaseDebian.dot/2`, a defk kernel) that depends on defk as
a path dep. It is built with `mix release` in a stock hexpm/elixir Debian
image, and the kernel is called from the release.

```bash
# from the defk repo root (podman or docker)
podman build -f examples/release_debian/Dockerfile -t defk-release-debian .
podman run --rm defk-release-debian
# %{kernel: 333833500.0, elixir: 333833500.0, agree: true, lib: "/src/defk/.../Elixir.ReleaseDebian-3f0d203f78.so"}
```

Recorded 2026-10-07 on an Apple-silicon Mac, podman 5 (applehv VM, linux/arm64).
Builder: `hexpm/elixir:1.20.2-erlang-29.0.3-debian-trixie-20260713-slim`
(the same Elixir and OTP as local dev). Runner: `debian:trixie-20260713-slim`.

## Packages that had to be added (build stage only)

| `BUILD_PKGS` | Result |
|---|---|
| none | Fails. `System.cmd("cc", ...)` raises `ErlangError :enoent` while compiling defk's own `lib/examples.ex`. The error doesn't mention a C compiler (defk-lb8 covers that). Neither the slim nor the full hexpm Debian image ships `cc`, `gcc` or `make`. |
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

1. **The kernel `.so` is not part of the release.** `Defk.Build` writes it to
   `_build/<env>/defk/` and the generated `__defk_load__` loads that absolute
   build path. `mix release` copies `ebin/` and `priv/`, not `_build/<env>/defk`.
   - A same-stage release works only because the build path still exists.
   - In a multi-stage image without it (`--build-arg COPY_SO=0`),
     `bin/release_debian start` crashes at boot: `Kernel pid terminated
     (application_controller) ... on_load_function_failed,'Elixir.ReleaseDebian',
     ... Failed to load NIF library: '/src/defk/examples/release_debian/_build/prod/defk/Elixir.ReleaseDebian-3f0d203f78.so: cannot open shared object file'`.
     `eval` logs the same error and then `ReleaseDebian.check/0 is undefined`.
   - The Dockerfile works around this by copying `_build/prod/defk` to the same
     absolute path in the runtime image. This is a workaround, not a contract.
     A release is not relocatable until defk puts the `.so` under the app's
     `priv/` and loads it via `:code.priv_dir/1`, as elixir_make packages do.
     This belongs under Limitations, or as a fix before the verdict.
2. **Every app depending on defk compiles defk's example kernels.**
   `lib/examples.ex` (`Examples.Kernels`) is in the library's `lib/`, so the
   app builds and ships it too: 0.36 s of `cc` and about 75 KB of `.so`.
3. **gcc warnings are hidden.** gcc 14 warns about unused variables and helpers
   in the generated C. defk discards compiler output on success, so the build
   log stays clean. This isn't a problem, but `-Wall` output on Linux differs
   from clang on macOS.
4. Cross-compiling (for example, building on macOS for a Linux runner) wasn't
   tried. The `.so` is built for the builder's architecture (here
   linux/arm64), so builder and runner must match, as with any NIF.
