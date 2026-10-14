#!/usr/bin/env bash
# The podman fallback (defk-wfi.2): the Linux matrix of
# .github/workflows/ci.yml without GitHub and without act. It reads the job
# image and the labels from the workflow, so the two cannot drift.
#
#   ci/local.sh                         every Linux label
#   ci/local.sh linux-aarch64-clang     one label
#
# Each label runs ci/run.sh in a copy of this checkout (uncommitted changes
# included) inside ci/Containerfile built for its architecture: arm64
# natively on Apple silicon, x86_64 under emulation (correct, slow, never
# for timing). deps and _build persist in podman volumes per label. Results
# land in tmp/ci-result/<label>.txt; the exit status is non-zero when any
# label fails.
set -u
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/.." && pwd)
workflow=$repo/.github/workflows/ci.yml
beam_image=$(sed -n 's/^ *container: *//p' "$workflow" | head -1)
all_labels=$(sed -n 's/.*label: *\(linux-[a-z0-9_]*-[a-z]*\).*/\1/p' "$workflow")
[ -n "$beam_image" ] && [ -n "$all_labels" ] || { echo "cannot read the matrix from $workflow" >&2; exit 2; }

if [ $# -gt 0 ]; then labels=("$@"); else read -r -d '' -a labels <<<"$all_labels"; fi
mkdir -p "$repo/tmp/ci-result"

# The container gets the files git would commit (tracked and untracked, not
# ignored) as a fresh one-commit repo: a worktree's .git points outside the
# mount, and some tests read `git ls-files`. The real commit travels in env.
commit=$(git -C "$repo" rev-parse HEAD)
if [ -z "$(git -C "$repo" status --porcelain)" ]; then dirty=no; else dirty=yes; fi
git -C "$repo" ls-files -z --cached --others --exclude-standard >"$repo/tmp/ci-result/.files"

rc=0
for label in "${labels[@]}"; do
  grep -qx "$label" <<<"$all_labels" || { echo "unknown label: $label (known: $(echo $all_labels))" >&2; exit 2; }
  arch=${label#linux-}; arch=${arch%-*}; cc=${label##*-}
  # Rosetta cannot run the JIT's double-mapped code memory: the BEAM dies at
  # boot (prim_tty: erlang:nif_error/1 undef) unless it maps it once
  erl_flags=
  case $arch in
    x86_64) platform=linux/amd64 erl_flags="+JMsingle true" ;;
    aarch64) platform=linux/arm64 ;;
    *) echo "unknown arch: $arch" >&2; exit 2 ;;
  esac
  image=defk-ci:$arch

  echo "== $label ($platform, CC=$cc)"
  podman build -q --platform "$platform" --build-arg BEAM_IMAGE="$beam_image" \
    -t "$image" -f "$here/Containerfile" "$here" >/dev/null || exit 1
  podman run --rm --platform "$platform" \
    -v "$repo":/src:ro \
    -v "defk-ci-$label-deps":/work/deps -v "defk-ci-$label-build":/work/_build \
    -v "$repo/tmp/ci-result":/out \
    -e CC="$cc" -e CI_PATH=podman -e ERL_FLAGS="$erl_flags" -e CI_COMMIT="$commit" -e CI_DIRTY="$dirty" \
    "$image" bash -c '
      tar -C /src --null --ignore-failed-read -T /out/.files -cf - 2>/dev/null | tar -C /work -xf -
      cd /work && git init -q && git add -A &&
        git -c user.name=ci -c user.email=ci@localhost commit -qm snapshot || exit 1
      ci/run.sh "$0"; rc=$?
      cp tmp/ci-result/"$0".txt /out/
      exit $rc' "$label" || rc=1
done
exit $rc
