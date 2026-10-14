# Valgrind memcheck for defk kernels

Runs the defk test suite inside the BEAM under Valgrind memcheck, in a Linux
container. It finds what the compiler's elisions and the C runtime can get
wrong and nothing else sees: invalid reads and writes of `alloc/2` outputs
and input binaries, uses of uninitialised bytes (an unzeroed `alloc/2` that
is not fully written), and owned buffers leaked on a raise path.
Background, measurements and the failures seen:
`docs/research/c-verification-macos.md` section 6.

Valgrind does not build on macOS, so on a Mac this goes through a podman
machine (arm64 Linux). Linux CI hosting and an on-demand
`mix defk.verify` are separate work. This directory is only the container, the
runner and the suppressions.

## Run it

Needs `podman` (on macOS: `podman machine start`, at least 4 CPUs and 8 GiB).

```sh
verify/valgrind/run.sh                           # every test/*_test.exs, one at a time
verify/valgrind/run.sh test/alloc_test.exs       # chosen files (paths relative to the repo root)
JOBS=2 verify/valgrind/run.sh                    # two shards on two CPUs
verify/valgrind/planted/run.sh                   # self-test: must FAIL (see below)
```

The first call builds the image `defk-valgrind` (about 2 minutes on 8 CPUs:
Debian trixie, distro Valgrind 3.24, OTP 29.0.3 from source plus
`make -C erts/emulator valgrind`, Elixir from the hexpm image). Later calls
reuse the cached layers. `REBUILD=1` rebuilds from scratch.

The repo is mounted read-only; the runner copies it (without `_build`) inside
the container, so nothing in your checkout is touched. Output goes to
`tmp/valgrind-logs/` (git-ignored; `LOGDIR=` to change it, one `shardN/`
subdirectory per job with `JOBS>1`):

- `results.tsv`: one row per file (status, mix exit code, test counts,
  memcheck error count, wall seconds)
- `<file>.out`: the `mix test` output
- `<file>.vg.<pid>.log`: the memcheck log of each VM that file started (some
  tests start child VMs)

**Exit status** is 0 only if every file ran, passed and every VM log says
`ERROR SUMMARY: 0 errors`. Statuses: `MEMCHECK-ERRORS` (an invalid access, an
uninitialised use, or a definite leak not in `defk.supp`; the first report of
each log is printed), `TEST-FAILURE`, `TIMEOUT`, `NO-MEMCHECK-LOG` (the VM did
not run under Valgrind). `MIX_TEST_ARGS="--seed 1"` passes arguments to
`mix test`; `FILE_TIMEOUT` (seconds per file, default 7200) bounds each file.

## What it does and why

- **One `mix test <file>` per test file.** The whole suite in one VM was
  OOM-killed after 12 minutes in an 8 GiB machine: memcheck holds shadow
  memory for everything the VM touches.
- **One CPU per VM (`taskset`).** Unpinned, `erl -emu_type valgrind` did not
  boot in 10 minutes; pinned it takes seconds. OTP's own `cerl` does the same.
  ERTS then sees one CPU, so ExUnit runs with `max_cases: 2`.
- **The `valgrind` emulator flavor, not the stock beam.** It compiles ERTS with
  `-DVALGRIND` and turns the allocators off, so a binary is a plain `malloc`
  block and a 1-byte overrun of an `alloc/2` output lands in a redzone. The
  stock beam under Valgrind sees none of this. `install-valgrind-beam.sh` puts a
  wrapper under the name `erlexec` runs for `-emu_type valgrind`, so
  `mix` works with `ERL_AFLAGS="-emu_type valgrind"`.
- **The library and deps are compiled natively first**; only each file's
  kernels (built by the C compiler, which is outside Valgrind) and the tests
  run under memcheck. `CC` is `cc-vg`, a thin wrapper over clang that adds
  `-g` so reports carry file and line in the generated C (also what planted
  bugs hook into).
- **Flags**: `--track-origins=yes` (an uninitialised report names the
  `alloc/2` that made the value), `--leak-check=full`,
  `--errors-for-leak-kinds=definite` (a definite leak is an error),
  `--show-possibly-lost=no` (ERTS leaves ~300-400 KB at exit), plus OTP's
  `suppress.standard`.
- **Cost**: about 47x slower than native, plus ~40 s per file to compile it
  under Valgrind. See "Full suite" below for the measured wall time.

## Suppressions and excluded tests

`defk.supp` holds one entry: the leak of `frame_tag_test.exs`'s "a frame with
a foreign tag fails cleanly". `defk_frame_dtor` deliberately frees nothing for
a frame with a foreign layout tag, so the owned table and its
buffers are by design lost. The entry is scoped to the kernel library that
test builds (`Elixir.Defk.FrameTagTest.K-*.so`), so the same leak in any other
kernel still fails.

Tests tagged `:erlang_memory` are excluded (`--exclude erlang_memory` in
`run-suite.sh`): they assert on `:erlang.memory(:binary)`, which raises
`notsup` under the valgrind emulator because its allocators are off. They run
normally everywhere else (`mix test --only erlang_memory` runs just them):
`raise_cleanup_test.exs` "a raise after alloc frees every owned buffer" and
`bitstring_test.exs` "a process killed mid-build frees the buffer". The leak
class they check is covered here by Valgrind itself, which reports the leak
directly.

`agreement_test.exs` runs: its sides are bounded (Elixir mode
enforces the owned-buffer budget on `alloc/2`), so no case asks for GiBs.

## The self-test (planted bug)

`planted/run.sh` runs `planted/uninit_read_test.exs` through the same runner
with a C bug planted in the generated code (`PLANT` is a `sed` expression that
`cc-vg` applies to a copy of the `.c`, never to the repo): the kernel's odd
output bytes are never written, and Elixir compares the result. The runner must
report `MEMCHECK-ERRORS` (`Conditional jump or move depends on uninitialised
value(s)`, origin `defk_alloc_raw_u8` in the kernel's C) and exit 1.
`PLANT= planted/run.sh` runs the same file unplanted and must pass. The file
lives outside `test/`, so `mix test` never sees it.

## Known limits

- JIT frames show as `???`, and the unwinder stops at the first one, so a
  report names the C frames (kernel, runtime header, ERTS) but not the Elixir
  function. OTP's `valgrind_beamasm_update.escript` can name the JIT shared
  fragments only; not wired in.
- A sub-binary over-read of the input stays invisible (the bytes belong to the
  parent binary); only an elided-index trap would see it.
- Memcheck reports an uninitialised value only where it is used (compared,
  hashed, printed, branched on). The suite's agreement checks compare every
  result, which is what makes an unwritten element visible.
- Possibly-lost blocks are not an error.

## Full suite

`JOBS=2 verify/valgrind/run.sh` on an 8 CPU / 8 GiB podman machine (Apple
Silicon, host not idle, so provisional): **52 minutes wall** for 76 files,
about 97 minutes of one-CPU time. Zero memcheck errors and zero definite
leaks over the 76 files (frame_tag_test's by-design leak suppressed). The
slowest files: `language_doc_examples_test` 12 min, `elixir_mode_test` 6 min,
`alloc_unzeroed_test` 5 min, `release_layout_test` 4 min; most take 35-90 s,
about 33 s of which is `mix` start and compiling the file under Valgrind.
The two non-memory failures of that run were fixed afterwards:
`resume_test` has a 10 s timeout (now stretched by `DEFK_TIMEOUT_SCALE`, set
to 100 by the runner) and `no_conflict_markers_test` needs `git` metadata (now
skipped from the default list; it checks repo text, not kernels).
