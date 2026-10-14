#!/usr/bin/env bash
# Turns the hexpm/elixir Debian image into a CI machine: both C
# compilers, git, Hex and rebar. The GitHub Actions Linux jobs run it in
# their job container; ci/Containerfile runs it for ci/local.sh.
# libclang-rt-dev: clang's <sanitizer/*.h>, which the runtime header includes
# in the sanitizer build mode (gcc ships its own). llvm: llvm-symbolizer on
# the PATH, without which clang's ASan reports carry no function names.
# procps: `uptime`, which Defk.Bench.Cache reads to decide whether a
# machine was quiet.
set -eu
apt-get update
apt-get install -y --no-install-recommends \
  build-essential clang libclang-rt-dev llvm git ca-certificates procps
rm -rf /var/lib/apt/lists/*
mix local.hex --force
mix local.rebar --force
