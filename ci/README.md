# CI

`mix ci` on four machines, through three paths that run the same script
(`ci/run.sh`), so a release never waits for GitHub or for act.

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

Each run writes `tmp/ci-result/<label>.txt`: the result, the commit,
whether the checkout had uncommitted changes, the path, the toolchain.

## The three paths

**GitHub Actions** (`.github/workflows/ci.yml`): every push and pull
request, and on demand (`workflow_dispatch`). A newer push to the same ref
cancels the older run. The result files are artifacts for 30 days. On a
public repo the standard runners cost nothing; the Free plan allows 20
concurrent jobs, 5 of them macOS.

**act** (the workflow on this Mac): use it to run the Linux jobs locally and
to test a change to the workflow before a push. act needs a Docker API;
podman's works:

```sh
brew install act
export DOCKER_HOST=unix://$(podman machine inspect --format '{{.ConnectionInfo.PodmanSocket.Path}}')
act -j linux --matrix label:linux-aarch64-clang --container-architecture linux/arm64
act -j linux --matrix label:linux-x86_64-gcc --container-architecture linux/amd64
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

On Apple silicon arm64 runs natively and x86-64 runs under emulation:
correct but slow, so never use an emulated run for timing.

## Release evidence

A release commit needs one passing run of every label, from any path. The
result files are the evidence: each must say `result: pass`, name the
release commit, and say `uncommitted changes: no` (a GitHub run says
`unknown`, as its checkout has no `.git`; the commit is `GITHUB_SHA`).

Valgrind (`verify/valgrind`) and the measurement run (`examples/run_all.exs`)
are not part of CI. They run by hand at release time.
