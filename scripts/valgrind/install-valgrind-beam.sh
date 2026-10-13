#!/bin/sh
# Build-time step: put the valgrind emulator where erlexec looks for it, with
# the real beam renamed and a wrapper under the old name that runs it under
# memcheck, pinned to one CPU.
set -e
ERTS=$(echo /usr/local/lib/erlang/erts-*)
BIN=$(echo /otp/bin/*-linux-gnu)
cp "$BIN/beam.valgrind.smp" "$ERTS/bin/beam.valgrind.smp.real"
cp "$BIN/erl_child_setup.valgrind" "$ERTS/bin/erl_child_setup.valgrind"
cat > "$ERTS/bin/beam.valgrind.smp" <<W
#!/bin/sh
# Pin to one CPU: unpinned, erl -emu_type valgrind did not boot in 10 minutes
# (cerl does the same: "We only let valgrind utilize one core with taskset 1").
# --trace-children=no keeps the C compiler (a port child) out of Valgrind.
# The leak flags make a definite leak count as an error in ERROR SUMMARY;
# possibly-lost is hidden as in cerl (ERTS leaves ~300-400 KB at exit).
exec taskset --cpu-list \${VG_CPU:-0} valgrind --tool=memcheck \\
  --suppressions=/otp/erts/emulator/valgrind/suppress.standard \\
  --suppressions=/opt/defk-vg/defk.supp \\
  --track-origins=yes --num-callers=30 \\
  --leak-check=full --show-leak-kinds=definite --errors-for-leak-kinds=definite \\
  --show-possibly-lost=no --child-silent-after-fork=yes --trace-children=no \\
  \${VG_LOG:+--log-file=\$VG_LOG} \$VALGRIND_MISC_FLAGS \\
  $ERTS/bin/beam.valgrind.smp.real "\$@"
W
chmod +x "$ERTS/bin/beam.valgrind.smp"
