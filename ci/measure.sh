#!/usr/bin/env bash
# The Linux measurement run (defk-a1p): every example timed, with its
# verdict checked, and the snapshot table (mix defk.examples --bench --all
# --snapshot --fresh), plus the conditions it ran under. Writes
# tmp/measure/conditions.txt and tmp/measure/bench.log; the exit status is
# the bench's. Run it on native hardware only: an emulated run's times mean
# nothing. .github/workflows/measure.yml runs it on demand.
set -u
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/.." && pwd)
out=$repo/tmp/measure
mkdir -p "$out"
cd "$repo" || exit 2

conditions() {
  echo "commit: $(git rev-parse HEAD 2>/dev/null || echo "${GITHUB_SHA:-unknown}")"
  echo "date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "os: $(uname -sm)"
  echo "cpu: $(sed -n 's/^model name[[:space:]]*: //p' /proc/cpuinfo 2>/dev/null | head -1)"
  echo "cores: $(nproc)"
  echo "load: $(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null)"
  echo "beam: $(elixir --version 2>/dev/null | tail -1)"
  echo "cc: ${CC:-cc}, $(${CC:-cc} --version | head -1)"
}

conditions >"$out/conditions.txt"
mix deps.get
mix defk.examples --bench --all --snapshot --fresh 2>&1 | tee "$out/bench.log"
rc=${PIPESTATUS[0]}
echo "load after: $(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null)" >>"$out/conditions.txt"
echo "exit: $rc" >>"$out/conditions.txt"
cat "$out/conditions.txt"
exit "$rc"
