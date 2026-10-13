#!/bin/bash
# Self-test of the fuzz runner: plant an out-of-bounds read in a copy of the
# generated C of lz4_block_decode and check the fuzzer finds it. Exits 0 when
# it does (an AddressSanitizer heap-buffer-overflow in the kernel), 1 when the
# run stays clean or fails some other way.
#
#   verify/fuzz/planted.sh                  # FUZZ_TIME (default 60) is the deadline
#
# The plant drops the kernel's `if ip >= n, do: raise ...` guard before the
# token read ("lz4: block ends after a match, not literals") and turns the
# checked read src[ip] into an unchecked one, so a block that ends right
# after a match reads one byte past the input binary. Sed on a copy under
# OUT (run.sh's PLANT); the repo's C and the normal build are untouched. It
# runs from the seeds alone (a fresh corpus), with the release strips.
set -u -o pipefail
here=$(cd "$(dirname "$0")" && pwd)

OUT=${OUT:-tmp/fuzz-planted}
export OUT
export FUZZ_TIME=${FUZZ_TIME:-60}
export STRIPS=release
export PLANT='/lz4: block ends after a match/d; s/\(v_token_[0-9]* = ((int64_t)\)defk_get_u8(ctx, p_src, \(v_ip_[0-9]*\))/\1p_src.data[\2]/'

rm -rf "$OUT/corpus/lz4_block_decode" "$OUT/artifacts"
start=$(date +%s)
"$here/run.sh" lz4_block_decode
rc=$?
end=$(date +%s)
log="$OUT/logs/lz4_block_decode.release-planted.log"
case "$OUT" in /*) ;; *) log="$here/../../$log" ;; esac

if [ $rc -eq 1 ] && grep -q 'ERROR: AddressSanitizer: heap-buffer-overflow' "$log" &&
  grep -A8 'heap-buffer-overflow' "$log" | grep -q 'run_k[0-9]*_lz4_block_decode'; then
  execs=$(grep -o '^#[0-9]*' "$log" | tail -1 | tr -d '#')
  echo "planted: FOUND after $((end - start)) s wall (including generating and building), ${execs:-?} inputs:"
  grep -m1 -A6 'ERROR: AddressSanitizer' "$log"
  exit 0
fi
echo "planted: NOT FOUND (run.sh exit $rc) in ${FUZZ_TIME}s; log $log" >&2
exit 1
