#!/bin/bash
# Runs inside the container: one `mix test <file>` per test file, each under
# the valgrind emulator (memcheck), then reads the memcheck logs of that file.
#
#   run-suite.sh [test/foo_test.exs ...]     (default: every test/*_test.exs)
#
# Exit status: 0 when every file ran, passed and every VM log says
# "ERROR SUMMARY: 0 errors"; 1 otherwise (a memcheck error, a definite leak
# not suppressed in defk.supp, a failing test, a missing log, a timeout).
#
# Environment:
#   SRC=/src            the defk checkout, mounted read-only
#   LOGDIR=/vg-logs     per-file mix output, memcheck logs, results.tsv
#   VG_CPU=0            CPU the VM is pinned to (taskset)
#   MIX_TEST_ARGS       extra `mix test` arguments
#   FILE_TIMEOUT=7200   seconds per file
#   MIX_EXS_DIR         where to copy SRC to (default /work/defk)
set -u
SRC=${SRC:-/src}
LOGDIR=${LOGDIR:-/vg-logs}
WORK=${MIX_EXS_DIR:-/work/defk}
FILE_TIMEOUT=${FILE_TIMEOUT:-7200}
export VG_CPU=${VG_CPU:-0}

mkdir -p "$LOGDIR" "$WORK"
# A fresh copy, without the host's _build (it holds absolute paths and macOS
# objects) and without anything a previous run left in the container.
rm -rf "$WORK"/* "$WORK"/.[!.]* 2>/dev/null
(cd "$SRC" && tar cf - --exclude=./_build --exclude=./erl_crash.dump --exclude=./tmp--exclude=./.git .) | tar xf - -C "$WORK"
cd "$WORK" || exit 1

export MIX_ENV=test CC=/opt/defk-vg/cc-vg REAL_CC=${REAL_CC:-clang}
# resume_test.exs has a 10 s backstop that is a native-speed guard
export DEFK_TIMEOUT_SCALE=100

# Compile the library and deps once, natively: under memcheck the Elixir
# compiler alone is ~50x slower, and the library is not what is being tested.
# (The kernels in each test file are still built, and run, under memcheck.)
echo "== native compile of the library and deps"
(unset ERL_AFLAGS; mix deps.get --only test && mix compile) >"$LOGDIR/compile.out" 2>&1 \
  || { echo "native compile failed, see $LOGDIR/compile.out"; tail -20 "$LOGDIR/compile.out"; exit 1; }

# Preflight: the VM really is the valgrind emulator, under memcheck.
bt=$(ERL_AFLAGS="-emu_type valgrind" erl -noshell -eval 'io:format("~s",[erlang:system_info(build_type)]),halt().' 2>/dev/null)
[ "$bt" = valgrind ] || { echo "preflight: build_type is '$bt', not valgrind"; exit 1; }

# The default list skips what has no C or kernel in it and needs the git
# metadata the container copy does not have: no_conflict_markers_test runs
# `git ls-files` (it checks the repo's text, not defk's code).
if [ $# -gt 0 ]; then
  files=("$@")
else
  files=()
  for f in test/*_test.exs; do
    [ "$f" = test/no_conflict_markers_test.exs ] || files+=("$f")
  done
fi

# Tests that cannot hold under the valgrind emulator are tagged and excluded
# here: :erlang_memory asserts on :erlang.memory(:binary), which raises
# `notsup` because the valgrind build runs ERTS with its allocators off.
EXCLUDES=(--exclude erlang_memory)

printf 'file\tstatus\tmix_rc\ttests\tmemcheck_errors\twall_s\n' >"$LOGDIR/results.tsv"
bad=0
for f in "${files[@]}"; do
  n=$(basename "$f" .exs)
  rm -f "$LOGDIR/$n".vg.*.log
  export VG_LOG="$LOGDIR/$n.vg.%p.log"
  export ERL_AFLAGS="-emu_type valgrind"
  start=$(date +%s)
  # shellcheck disable=SC2086
  timeout "$FILE_TIMEOUT" mix test "$f" "${EXCLUDES[@]}" --timeout 3600000 ${MIX_TEST_ARGS:-} \
    >"$LOGDIR/$n.out" 2>&1
  rc=$?
  wall=$(( $(date +%s) - start ))
  unset VG_LOG ERL_AFLAGS

  tests=$(grep -h "^Result:" "$LOGDIR/$n.out" | tail -1 | sed "s/^Result: //")
  logs=("$LOGDIR/$n".vg.*.log)
  errors=0; missing=0
  if [ ! -e "${logs[0]}" ]; then
    missing=1
  else
    for l in "${logs[@]}"; do
      s=$(grep -o 'ERROR SUMMARY: [0-9]* errors' "$l" | tail -1 | grep -o '[0-9]*')
      if [ -z "$s" ]; then missing=1; else errors=$((errors + s)); fi
    done
  fi

  status=ok
  if   [ $rc -eq 124 ];     then status=TIMEOUT
  elif [ $missing -eq 1 ];  then status=NO-MEMCHECK-LOG
  elif [ $errors -gt 0 ];   then status=MEMCHECK-ERRORS
  elif [ $rc -ne 0 ];       then status=TEST-FAILURE
  fi
  [ $status = ok ] || bad=1

  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$n" "$status" "$rc" "$tests" "$errors" "$wall" >>"$LOGDIR/results.tsv"
  printf '%-34s %-16s mix=%s errors=%s %ss  %s\n' "$n" "$status" "$rc" "$errors" "$wall" "$tests"
  if [ "$status" = MEMCHECK-ERRORS ]; then
    # first error of each VM log, for the console; the full logs are in LOGDIR
    for l in "${logs[@]}"; do
      grep -q 'ERROR SUMMARY: [1-9]' "$l" && { echo "  --- $l"; grep -m1 -A18 '^==[0-9]*== [A-Z]' "$l" | sed 's/^/  /'; }
    done
  fi
done

if [ $bad -eq 0 ]; then echo "VALGRIND: PASS (${#files[@]} file(s))"; else echo "VALGRIND: FAIL (see $LOGDIR/results.tsv)"; fi
exit $bad
