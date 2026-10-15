#!/usr/bin/env bash
# The CI work for one matrix entry: `mix ci` (or `mix ci.test`, the compile
# and the tests without the lint steps), then a result file. Every CI path
# calls this script: the GitHub Actions workflow, act and the podman
# fallback (ci/local.sh). It installs nothing: the caller provides
# Erlang/OTP, Elixir with Hex, git and a C compiler (CC, default cc).
#
#   ci/run.sh <label> [ci | ci.test]    e.g. ci/run.sh linux-x86_64-gcc ci.test
#
# Writes tmp/ci-result/<label>.txt (the commit, the task, the toolchain, the
# outcome), which the release-readiness check cites. Exits with mix's status.
set -u
label=${1:?usage: ci/run.sh <label> [ci | ci.test]}
task=${2:-ci}
case $task in
  ci | ci.test) ;;
  *) echo "unknown task: $task (ci or ci.test)" >&2; exit 2 ;;
esac
cd "$(dirname "$0")/.."
export MIX_ENV=test

mix deps.get && mix "$task"
rc=$?

if [ -n "${ACT:-}" ]; then path=act; else path=${CI_PATH:-local}; fi
# ci/local.sh runs in a git snapshot of the checkout and passes the real
# commit and its state in CI_COMMIT and CI_DIRTY
commit=${CI_COMMIT:-$(git rev-parse HEAD 2>/dev/null || echo "${GITHUB_SHA:-unknown}")}
if ! status=$(git status --porcelain 2>/dev/null); then dirty=unknown
elif [ -z "$status" ]; then dirty=no; else dirty=yes; fi
dirty=${CI_DIRTY:-$dirty}
if [ $rc -eq 0 ]; then result=pass; else result="fail (exit $rc)"; fi

mkdir -p tmp/ci-result
cat >"tmp/ci-result/$label.txt" <<EOF
label: $label
result: $result
task: mix $task
commit: $commit
uncommitted changes: $dirty
path: $path
date: $(date -u +%Y-%m-%dT%H:%M:%SZ)
os: $(uname -sm)
beam: $(elixir --version | tail -1)
cc: ${CC:-cc}, $(${CC:-cc} --version | head -1)
EOF
cat "tmp/ci-result/$label.txt"
exit $rc
