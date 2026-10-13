#!/bin/bash
# Proves the runner fails on a real error: runs uninit_read_test.exs through
# scripts/valgrind/run.sh with a C bug planted (the odd output bytes of
# encode16 are never written). Expected: MEMCHECK-ERRORS, exit status 1.
# With PLANT unset the same file passes ("clean" control): run it as
# PLANT= scripts/valgrind/planted/run.sh
here=$(cd "$(dirname "$0")" && pwd)
if [ "${PLANT+set}" != set ]; then
  PLANT='s/data\[((INT64_C(2) \* v_i_3) + INT64_C(1))\]/data[(INT64_C(2) * v_i_3)]/'
fi
export PLANT
exec "$here/../run.sh" scripts/valgrind/planted/uninit_read_test.exs
