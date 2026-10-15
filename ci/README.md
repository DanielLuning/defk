# CI

`mix ci` on four machines, through three paths that run the same script
(`ci/run.sh`), so a release never waits for GitHub or for act. A pull
request uses one machine; a release uses all four.

| Label | Machine | Compiler |
|---|---|---|
| `linux-x86_64-clang` | Linux x86-64 | clang |
| `linux-x86_64-gcc` | Linux x86-64 | gcc |
| `linux-aarch64-clang` | Linux arm64 | clang |
| `macos-arm64-clang` | macOS arm64 | Apple clang |

The Linux jobs run in one pinned multi-arch image,
`hexpm/elixir:<elixir>-erlang-<otp>-debian-trixie-<date>`, plus
`ci/setup-debian.sh` (both compilers, git, Hex). The `container:` line in
`.github/workflows/ci.yml` is the only place that names it.

Each run writes `tmp/ci-result/<label>.txt`: the result, the task (`mix ci`
or `mix ci.test`), the commit, whether the checkout had uncommitted changes,
the path, the toolchain.

`ci/run.sh <label> ci.test` runs `mix ci.test`: the compile and the tests,
without the lint steps (format, docs, Credo, Dialyzer, ex_dna, reach, the
usage rules check, the Hex build). The lint steps give the same answer on
every machine, so one machine runs them.

## The three paths

**GitHub Actions** (`.github/workflows/ci.yml`) runs two sizes of run:

| Event | Machines |
|---|---|
| a pull request; Mondays 03:00 UTC on `main` | `linux-x86_64-clang`, `mix ci` |
| a release tag (`v*`); a run by hand (`gh workflow run CI --ref <ref>`) | all four: `linux-x86_64-clang` runs `mix ci`, the others `mix ci.test` |

Nothing runs on a push to `main`: the pull request already tested the
merge (AGENTS.md has the branch merge `origin/main` when it is behind).
Pull requests use one machine because the owner runs `mix ci` on an
M-series Mac before each one, and the other machines rarely disagree; they
come back at the release. A newer push to the same ref cancels the older
run. Each job stops after 30 minutes. The result files are artifacts for 30
days.

The cache (`deps` and `_build`) is saved after every run and restored from
the newest run of the same branch, else of `main`. It holds the compiled
kernels (`_build/test/defk`, by the hash of their C), which most of the test
time goes to: a warm cache cut a local `mix test` from 81 s to 23 s. A pull
request can restore only its own caches and `main`'s, so the Monday run is
what gives each new pull request a warm start. That run deletes the kernel
cache first, so the libraries of kernels that no longer exist do not pile
up. The cache key changes with `mix.lock`. The cached compiler remarks hold
absolute paths, which is safe because a runner's workspace path is the same
on every run; a `_build` copied from another checkout fails the report tests.

On a public repo the standard runners cost nothing; on a private repo the
minutes count against the plan's quota, and macOS minutes count ten times,
which is why macOS runs only for a release. The Free plan allows 20
concurrent jobs, 5 of them macOS.

**act** (the workflow on this Mac): use it to run the Linux jobs locally and
to test a change to the workflow before a push. act needs a Docker API;
podman's works:

```sh
brew install act
export DOCKER_HOST=unix://$(podman machine inspect --format '{{.ConnectionInfo.PodmanSocket.Path}}')
act -j linux --matrix label:linux-aarch64-clang --container-architecture linux/arm64
act -j linux --matrix label:linux-x86_64-gcc --container-architecture linux/amd64 \
  --env ERL_FLAGS="+JMsingle true"
```

Run act from a normal clone, not from a git worktree: act copies the
directory into the job container, and a worktree's `.git` is a file that
points to a path outside it, so the tests that read `git ls-files` fail.

`.actrc` maps the runner labels to act's images and stops act from mounting
the Docker socket into the job (podman's socket on macOS cannot be mounted;
no job needs it). Under act the cache and
artifact steps are skipped (they need node in the job container), so each
act run fetches deps and builds the PLT again. act does not run the macOS
job; on the Mac, `ci/run.sh macos-arm64-clang` is that job.

**podman fallback** (`ci/local.sh`): the Linux matrix with neither GitHub nor
act. It reads the image and the labels from the workflow, builds
`ci/Containerfile` per architecture, and runs `ci/run.sh` in a copy of the
checkout (uncommitted changes included). deps and `_build` persist in podman
volumes per label.

```sh
ci/local.sh                        # every Linux label
ci/local.sh linux-x86_64-clang     # one label
```

On Apple silicon arm64 runs natively and x86-64 runs under emulation,
which must be Rosetta, not qemu:

- Turn on Rosetta once: put `[machine]` / `rosetta = true` in
  `~/.config/containers/containers.conf`, then `podman machine stop` and
  `podman machine start`. `podman machine ssh -- ls /proc/sys/fs/binfmt_misc/`
  then lists `rosetta` and no `qemu-x86_64`.
- Under qemu the BEAM crashes in the test run (`qemu: uncaught target
  signal 11`), and the failures do not match real hardware.
- Under Rosetta the BEAM needs `+JMsingle true` (the JIT maps its code
  memory once); without it, it dies at boot in `prim_tty`. `ci/local.sh`
  sets it for the x86-64 labels; for act, pass it with `--env`.

On 2026-10-14 the Rosetta runs gave the same failures as native x86-64 on
GitHub, test for test. Later the same day one Rosetta run of the full suite
gave `0.0` where native code gives `-0.0` (a branch clang compiles to
`maxsd`, whose signed-zero rule Rosetta did not keep that once); it did not
reproduce, and native runners pass. Emulated runs are still slow, so never
use one for timing.

## Release evidence

A release commit needs one passing run of every label, from any path. The
result files are the evidence: each must say `result: pass`, name the
release commit, and say `uncommitted changes: no`; at least one must say
`task: mix ci` (the lint steps), and the others may say `mix ci.test`. On
GitHub, run the workflow by hand on the release commit before you tag it
(`gh workflow run CI --ref main`), or push the tag and use the tag's run;
a tag whose run fails is not released. An x86-64 label run under
Rosetta counts only when it passes; a failure there is checked on native
x86-64 (the GitHub workflow) before it is called a bug.

Valgrind (`verify/valgrind`) and the measurement run (`ci/measure.sh`, or
`.github/workflows/measure.yml` on a native runner) are not part of CI.
They run by hand at release time.
