#!/usr/bin/env bash
# SIMD study: run the agreement and float tests (native === Elixir mode,
# bit-exact floats) with every kernel built at each target level of this
# machine's architecture. Each level gets its own build path, so _build is
# untouched. `bench/simd/agree_levels.sh [level ...]`
set -euo pipefail
cd "$(dirname "$0")/../.."
cc="${SIMD_CC:-cc}"
case "$(uname -m)" in
  x86_64) default_levels="x86-64-v2:-march=x86-64-v2 x86-64-v3:-march=x86-64-v3 native:-march=native" ;;
  *) default_levels="generic:-mcpu=generic armv8.2-a:-march=armv8.2-a native:-mcpu=native" ;;
esac
levels="${*:-$default_levels}"
tmp="${TMPDIR:-/tmp}/defk-simd-agree"
mkdir -p "$tmp"
MIX_ENV=test mix compile >/dev/null
for lv in $levels; do
  name="${lv%%:*}"; flags="${lv#*:}"
  wrapper="$tmp/cc-$name"
  printf '#!/bin/sh\nexec %s %s "$@"\n' "$cc" "$flags" > "$wrapper"
  chmod +x "$wrapper"
  rm -rf "$tmp/build-$name"; cp -R _build/test "$tmp/build-$name"
  echo "== $name ($flags)"
  MIX_ENV=test MIX_BUILD_PATH="$tmp/build-$name" CC="$wrapper" mix compile --force >/dev/null
  MIX_ENV=test MIX_BUILD_PATH="$tmp/build-$name" CC="$wrapper" mix test \
    test/agreement_test.exs test/fp_contract_test.exs test/sincos_test.exs \
    test/non_finite_test.exs test/elixir_mode_test.exs test/element_types_test.exs \
    test/masked_arith_test.exs test/u64_test.exs test/bit_builtins_test.exs \
    test/comparison_test.exs
done
