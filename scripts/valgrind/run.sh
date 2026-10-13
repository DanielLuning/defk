#!/bin/bash
# Host side: build the image (cached), then run the per-file memcheck
# runner in a container with this checkout mounted read-only.
#
#   scripts/valgrind/run.sh [test/foo_test.exs ...]
#
# Environment: IMAGE (default defk-valgrind), LOGDIR (default
# tmp/valgrind-logs under the repo, which is git-ignored), REBUILD=1 to force
# an image rebuild, JOBS=N to run N shards of the file list at once (one CPU
# each; each shard gets its own copy of the checkout), and anything
# run-suite.sh reads (MIX_TEST_ARGS, FILE_TIMEOUT).
set -u
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
image=${IMAGE:-defk-valgrind}
logdir=${LOGDIR:-$repo/tmp/valgrind-logs}
jobs=${JOBS:-1}
mkdir -p "$logdir"

# Always build: the layers are cached, so this is a second when nothing
# changed, and an edit to defk.supp or run-suite.sh is picked up.
podman build ${REBUILD:+--no-cache} -t "$image" -f "$here/Containerfile" "$here" >/dev/null || exit 1

if [ $# -gt 0 ]; then files=("$@"); else files=("$repo"/test/*_test.exs); files=("${files[@]#"$repo"/}"); fi

pids=()
for ((j = 0; j < jobs; j++)); do
  shard=(); i=0
  for f in "${files[@]}"; do
    [ $((i % jobs)) -eq $j ] && shard+=("$f"); i=$((i + 1))
  done
  [ ${#shard[@]} -eq 0 ] && continue
  sub=$logdir; [ "$jobs" -gt 1 ] && sub=$logdir/shard$j
  mkdir -p "$sub"
  podman run --rm \
    -v "$repo":/src:ro -v "$sub":/vg-logs \
    -e PLANT="${PLANT:-}" -e VG_CPU=$j -e MIX_EXS_DIR=/work/shard$j \
    -e MIX_TEST_ARGS="${MIX_TEST_ARGS:-}" -e FILE_TIMEOUT="${FILE_TIMEOUT:-7200}" \
    "$image" /opt/defk-vg/run-suite.sh "${shard[@]}" &
  pids+=($!)
done
rc=0
for p in "${pids[@]}"; do wait "$p" || rc=1; done
exit $rc
