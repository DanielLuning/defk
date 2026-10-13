#!/bin/bash
# libFuzzer runs of the decoder kernels outside the VM (scripts/fuzz/README.md).
#
#   scripts/fuzz/run.sh                         # the release set: every target, both strip settings
#   scripts/fuzz/run.sh lz4_block_decode        # chosen targets
#   FUZZ_TIME=600 STRIPS=small scripts/fuzz/run.sh snappy_decode
#   REPRO=tmp/fuzz/artifacts/lz4_block_decode.small/crash-... STRIPS=small scripts/fuzz/run.sh lz4_block_decode
#
# Environment:
#   FUZZ_TIME   seconds of fuzzing per target and strip setting (default 60)
#   STRIPS      which builds to fuzz (default "release small"):
#                 release  the runtime's own strip constants, as shipped
#                 small    DEFK_STRIP=8, DEFK_ZERO_STRIP=DEFK_COPY_STRIP=64 and
#                          DEFK_BUDGET0=1, so a fuzz-sized input crosses many
#                          strip boundaries and the yielding run yields at
#                          every safepoint it passes
#   OUT         build, corpus, artefact and log directory (default tmp/fuzz,
#               git-ignored); not inside scripts/fuzz
#   PLANT       a sed expression applied to a copy of the generated C before
#               it is compiled (the self-test, planted.sh); the repo is not
#               touched
#   REPRO       run one target and one strip setting once on this file,
#               printing both outcomes, instead of fuzzing
#   FUZZ_ARGS   extra libFuzzer flags (e.g. "-seed=1")
#   MAX_LEN     the longest input libFuzzer makes (default 4096)
#   LLVM        the LLVM prefix with libFuzzer (default: brew --prefix llvm)
#
# Exit status: 0 when every run was clean, 1 when any reported a finding
# (crash, sanitizer report, oracle failure, timeout, leak, out of memory),
# 2 on a usage or build error.
set -u -o pipefail

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
cd "$root" || exit 2

FUZZ_TIME=${FUZZ_TIME:-60}
STRIPS=${STRIPS:-release small}
OUT=${OUT:-tmp/fuzz}
MAX_LEN=${MAX_LEN:-4096}
PLANT=${PLANT:-}
REPRO=${REPRO:-}
FUZZ_ARGS=${FUZZ_ARGS:-}
export MIX_ENV=${MIX_ENV:-dev}
# LeakSanitizer is off by default on macOS; libFuzzer checks each input with it.
# Not at exit: libFuzzer leaks its own RSS thread there (std::thread in
# StartRssThread, LLVM 23 on macOS), which would turn every clean run red.
export ASAN_OPTIONS="detect_leaks=1:leak_check_at_exit=0${ASAN_OPTIONS:+:$ASAN_OPTIONS}"
export UBSAN_OPTIONS="print_stacktrace=1${UBSAN_OPTIONS:+:$UBSAN_OPTIONS}"

ALL_TARGETS="lz4_block_decode snappy_decode"

# target -> "<example file> <kernel module>"; the C is generated from the
# module in that file with the current compiler (gen_c.exs)
source_of() {
  case "$1" in
    lz4_block_decode | snappy_decode) echo "examples/lz4_snappy_decode.exs LzSnappy.Kernels" ;;
    *) return 1 ;;
  esac
}

strip_flags() {
  case "$1" in
    release) echo "" ;;
    small) echo "-DDEFK_STRIP=8 -DDEFK_ZERO_STRIP=64 -DDEFK_COPY_STRIP=64 -DDEFK_BUDGET0=1" ;;
    *) return 1 ;;
  esac
}

die() {
  echo "fuzz: $*" >&2
  exit 2
}

LLVM=${LLVM:-$(brew --prefix llvm 2>/dev/null)}
CC="$LLVM/bin/clang"
[ -x "$CC" ] || die "no clang at $CC: install Homebrew LLVM (brew install llvm) or set LLVM= (Apple's clang has no libFuzzer runtime)"
ERTS=$(erl -noshell -eval 'io:format("~s/erts-~s/include", [code:root_dir(), erlang:system_info(version)]), halt().') ||
  die "erl not found"
[ -f "$ERTS/erl_nif.h" ] || die "no erl_nif.h in $ERTS"

case "$OUT" in /*) ;; *) OUT="$root/$OUT" ;; esac
case "$OUT/" in "$here"/*) die "OUT must not be inside scripts/fuzz" ;; esac

targets=${*:-$ALL_TARGETS}
for t in $targets; do source_of "$t" >/dev/null || die "unknown target $t (known: $ALL_TARGETS)"; done
for s in $STRIPS; do strip_flags "$s" >/dev/null || die "unknown STRIPS setting $s (known: release small)"; done
if [ -n "$REPRO" ]; then
  [ "$(echo $targets | wc -w)" -eq 1 ] && [ "$(echo $STRIPS | wc -w)" -eq 1 ] ||
    die "REPRO takes one target and one STRIPS setting"
  [ -f "$REPRO" ] || die "REPRO: no file $REPRO"
fi

# The flags Defk.Build compiles kernels with that change meaning (lib/defk/build.ex
# @cflags), at -O1 for fast builds and readable reports. The kernel's object is
# instrumented for coverage; the shim, harness and target only for the
# sanitizers (their own comparisons would otherwise steer the fuzzer).
SEM="-std=gnu11 -ffp-contract=off -fno-strict-overflow -fno-builtin"
SAN="-g -O1 -fno-omit-frame-pointer -fsanitize=address,undefined -fno-sanitize-recover=undefined"
KWARN="-Wall -Wno-unused-label -Wno-unused-variable -Wno-unused-function -Wno-parentheses-equality"
SWARN="-Wall -Wextra -Wno-unused-parameter"

plant_tag=""
[ -n "$PLANT" ] && plant_tag="-planted"
mkdir -p "$OUT/gen" "$OUT/bin" "$OUT/logs" || exit 2

# the C of every module the targets need, generated once per run
generated=""
for t in $targets; do
  set -- $(source_of "$t")
  file=$1 module=$2 c="$OUT/gen/$2.c"
  case " $generated " in *" $module "*) continue ;; esac
  echo "fuzz: generating the C of $module from $file" >&2
  mix run --no-start "$here/gen_c.exs" "$file" "$module" "$c" >"$OUT/logs/gen-$module.log" 2>&1 ||
    { cat "$OUT/logs/gen-$module.log" >&2; die "generating the C of $module failed"; }
  if [ -n "$PLANT" ]; then
    sed -e "$PLANT" "$c" >"$OUT/gen/$module$plant_tag.c"
    cmp -s "$c" "$OUT/gen/$module$plant_tag.c" && die "PLANT changed nothing in $c"
  fi
  generated="$generated $module"
done

build() { # target, strip setting -> binary path on stdout
  local t=$1 strips=$2 c bin objs
  set -- $(source_of "$t")
  c="$OUT/gen/$2$plant_tag.c"
  bin="$OUT/bin/$t.$strips$plant_tag"
  objs="$bin.o"
  mkdir -p "$objs"
  echo "fuzz: building $t ($strips strips) from $c" >&2
  {
    "$CC" $SAN -fsanitize=fuzzer-no-link $SEM $KWARN $(strip_flags "$strips") -I"$ERTS" -Ipriv \
      -c "$c" -o "$objs/kernel.o" &&
      "$CC" $SAN $SEM $SWARN -I"$ERTS" -c "$here/shim/nif_shim.c" -o "$objs/shim.o" &&
      "$CC" $SAN $SEM $SWARN -I"$ERTS" -c "$here/shim/harness.c" -o "$objs/harness.o" &&
      "$CC" $SAN $SEM $SWARN -I"$ERTS" -c "$here/targets/$t.c" -o "$objs/target.o" &&
      "$CC" $SAN -fsanitize=fuzzer "$objs"/*.o -o "$bin"
  } >&2 || die "building $t failed"
  echo "$bin"
}

if [ -n "$REPRO" ]; then
  bin=$(build $targets $STRIPS) || exit 2
  echo "fuzz: $bin $REPRO" >&2
  DEFK_FUZZ_VERBOSE=1 "$bin" "$REPRO"
  exit $?
fi

results="$OUT/results$plant_tag.tsv"
printf 'run\tstatus\truns\tseconds\texecs_per_s\tcoverage\tartefact\n' >"$results"
echo "fuzz: load before: $(uptime)" >&2
status=0
for t in $targets; do
  for strips in $STRIPS; do
    run="$t.$strips"
    bin=$(build "$t" "$strips") || exit 2
    corpus="$OUT/corpus/$t" # shared by the strip settings: same input format
    arts="$OUT/artifacts/$run$plant_tag"
    log="$OUT/logs/$run$plant_tag.log"
    mkdir -p "$corpus" "$arts"
    echo "fuzz: $run for ${FUZZ_TIME}s (log $log)" >&2
    # the first corpus directory collects new inputs; the repo's seeds are read only
    "$bin" -max_total_time="$FUZZ_TIME" -max_len="$MAX_LEN" -timeout=10 -rss_limit_mb=4096 \
      -print_final_stats=1 -artifact_prefix="$arts/" $FUZZ_ARGS "$corpus" "$here/corpus/$t" >"$log" 2>&1
    rc=$?
    runs=$(sed -n 's/^Done \([0-9]*\) runs in \([0-9]*\) second.*/\1/p' "$log" | tail -1)
    secs=$(sed -n 's/^Done \([0-9]*\) runs in \([0-9]*\) second.*/\2/p' "$log" | tail -1)
    cov=$(grep -o 'cov: [0-9]*' "$log" | tail -1 | cut -d' ' -f2)
    art=$(sed -n 's/.*Test unit written to \(.*\)$/\1/p' "$log" | tail -1)
    if [ $rc -eq 0 ] && [ -n "$runs" ]; then
      st=clean
    else
      st=FINDING
      status=1
      runs=$(sed -n 's/^stat::number_of_executed_units: *//p' "$log" | tail -1)
    fi
    eps=""
    [ -n "$secs" ] && [ "$secs" -gt 0 ] && eps=$((runs / secs))
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$run" "$st" "${runs:-?}" "${secs:-?}" "${eps:-?}" "${cov:-?}" \
      "${art:--}" >>"$results"
    if [ "$st" = FINDING ]; then
      echo "fuzz: $run: FINDING (exit $rc); first report:" >&2
      grep -m1 -A14 -E 'ERROR: (AddressSanitizer|LeakSanitizer|libFuzzer)|runtime error:|defk-fuzz:' "$log" >&2
      echo "fuzz: reproduce: REPRO=$art STRIPS=$strips scripts/fuzz/run.sh $t" >&2
    fi
  done
done
echo "fuzz: load after: $(uptime)" >&2
column -t -s $'\t' "$results"
exit $status
