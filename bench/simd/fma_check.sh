#!/usr/bin/env bash
# Static check (defk-ulk.1): does any target level make clang fuse a*b+c into
# an FMA in defk's generated C? Compiles each given .c file to assembly with
# defk's flags (lib/defk/build.ex) plus each level's, counts FMA instructions,
# and, as a control, does the same with -ffp-contract=on.
#   bench/simd/fma_check.sh path/to/Mod.c ...
# The C files: `mix run bench/simd/remarks.exs` leaves one per module in
# $TMPDIR/defk-simd-remarks/ (or write Mod.__defk_c_source__() to a file).
set -euo pipefail
here="$(cd "$(dirname "$0")/../.." && pwd)"
erts="$(elixir -e 'IO.puts Path.join([to_string(:code.root_dir()), "erts-#{:erlang.system_info(:version)}", "include"])')"
cflags=(-O3 -ffp-contract=off -std=gnu11 -fPIC -Wall -Wno-unused-label -Wno-unused-variable
        -fstack-protector-strong -D_FORTIFY_SOURCE=2 -fno-strict-overflow -fno-builtin
        -I "$erts" -I "$here/priv" -S -w)
levels=("" "-mcpu=generic" "-march=armv8.2-a" "-mcpu=native"
        "-target x86_64-apple-macos13 -march=x86-64" "-target x86_64-apple-macos13 -march=x86-64-v2"
        "-target x86_64-apple-macos13 -march=x86-64-v3" "-target x86_64-apple-macos13 -march=x86-64-v4")
fma='vfn?m(add|sub)[0-9]|\bfn?m(add|sub)\b|\bfml[as]\b'
tmp="$(mktemp -d)"
for c in "$@"; do
  for lv in "${levels[@]}"; do
    # shellcheck disable=SC2086
    "${CC:-cc}" "${cflags[@]}" $lv -o "$tmp/off.s" "$c"
    # shellcheck disable=SC2086
    "${CC:-cc}" "${cflags[@]/-ffp-contract=off/-ffp-contract=on}" $lv -o "$tmp/on.s" "$c"
    printf '%s\t[%s]\tfma off: %s\tfma with contract=on: %s\n' "$(basename "$c")" "${lv:-default}" \
      "$(grep -cE "$fma" "$tmp/off.s" || true)" "$(grep -cE "$fma" "$tmp/on.s" || true)"
  done
done
rm -rf "$tmp"
