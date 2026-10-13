# libFuzzer targets for the decoder kernels

Fuzzes the generated C of defk's untrusted-input decoders outside the VM:
the kernel library, unchanged, linked against a small `erl_nif`
implementation (`shim/`) and driven by libFuzzer under AddressSanitizer and
UndefinedBehaviorSanitizer. The decoders' claim is "malformed input raises,
never crashes the VM"; this checks it on millions of inputs per minute, where
the example's own fuzz section (`examples/lz4_snappy_decode.exs`) runs 3,000
inside the VM. Background and the spike this grew from:
`docs/research/c-verification-macos.md` section 5 ("libFuzzer outside the VM").

Not part of `mix ci`. It runs on demand and in the release set (the
`mix defk.verify` task and release alias are defk-96f.2). Sibling tools:
`verify/valgrind/` (memcheck inside the VM, Linux container) and the
sanitizer build mode (`DEFK_SANITIZE`, `lib/defk/build.ex`).

## Run it

Needs Homebrew LLVM (`brew install llvm`; Apple's clang ships no libFuzzer
runtime), Erlang/OTP (for `erl_nif.h`) and the project's deps (the C is
generated with `mix run`).

```sh
verify/fuzz/run.sh                                   # the release set: every target, both strip settings, 60 s each
verify/fuzz/run.sh lz4_block_decode                  # chosen targets
FUZZ_TIME=600 STRIPS=small verify/fuzz/run.sh snappy_decode
verify/fuzz/planted.sh                               # self-test: must FIND the planted bug
REPRO=<crash file> STRIPS=small verify/fuzz/run.sh lz4_block_decode    # rerun one input, verbose
```

`run.sh` generates the C, builds one binary per target and strip setting,
fuzzes each for `FUZZ_TIME` seconds with one worker, and prints a table
(also in `tmp/fuzz/results.tsv`): runs, seconds, inputs/s, coverage
(libFuzzer's `cov:`), and the artefact of a finding. Exit status 0 when every
run was clean, 1 on any finding, 2 on a usage or build error. Other knobs
(`OUT`, `MAX_LEN`, `FUZZ_ARGS`, `LLVM`, `PLANT`) are documented at the top of
`run.sh`.

Everything it writes goes to `tmp/fuzz/` (git-ignored; `OUT=` to move it):

- `gen/<Module>.c`: the generated C that was fuzzed
- `bin/<target>.<strips>`: the fuzz binaries (with `.dSYM`)
- `corpus/<target>/`: inputs libFuzzer found interesting, grown across runs
  and shared by the two strip settings
- `artifacts/<target>.<strips>/`: `crash-*`, `leak-*`, `timeout-*`, `oom-*`
  inputs of findings
- `logs/<target>.<strips>.log`: libFuzzer's output, sanitizer reports included

## What is fuzzed

| Target | Kernel | Input format | Oracle on a returned value |
|---|---|---|---|
| `lz4_block_decode` | `LzSnappy.Kernels.lz4_block_decode/2` | 2 bytes LE u16, `max_out` = that - 16 (so -16..65519), then the block | `{buffer, len}`, `byte_size(buffer) == max_out`, `0 <= len <= max_out` |
| `snappy_decode` | `LzSnappy.Kernels.snappy_decode/1` | the block | a binary exactly as long as the varint preamble says |

Both allow only `ArgumentError` (the kernels' own checks); an
`Enum.OutOfBoundsError` or `ArithmeticError` means a check the kernel relies
on is missing, and is a finding.

Every input runs **twice** through the NIF the generated Elixir function
calls (`__defk_native_<kernel>__`, found through the library's own
`nif_init()` table after its load callback ran):

1. **straight**: the shim's clock stands still, so the kernel never yields;
2. **yielding**: the clock jumps 1 ms per read and the timeslice is always
   used up, so the kernel yields at every clock read. Each yield promotes the
   frame to a resource and returns `enif_schedule_nif`; the harness then
   moves the input binaries to new addresses (as a GC between two calls may)
   and calls the step function, until the kernel returns or raises.

Findings, besides any ASan or UBSan report (UBSan does not recover):

- the two runs disagree (value, or exception and message);
- an exception the target does not allow, or a raised term that is not an
  exception struct with a binary message;
- the target's check rejects a returned value;
- a frame resource, or a frame `__defk_stats__` counts as live, outlives the
  call (the destructor or the bookkeeping is wrong);
- more than 10 million yields for one input (no progress), or 10 s on one
  input (libFuzzer `-timeout`);
- a leak, e.g. an owned buffer not released on the raise or yield path
  (libFuzzer's per-input LeakSanitizer check, which `run.sh` turns on with
  `ASAN_OPTIONS=detect_leaks=1`, off by default on macOS; the check at exit
  stays off, because libFuzzer leaks its own RSS thread there);
- more than 4 GiB RSS (a 60 s run peaks at
  0.75-1.15 GiB: ASan's quarantine and libFuzzer's corpus, levelling off
  within the minute).

### Two strip settings

`STRIPS=release` builds the kernel with the runtime's own constants, as it
ships. With those, an input of at most `MAX_LEN` (4 KiB) bytes rarely
reaches a safepoint: a loop passes one only every `DEFK_STRIP` (2048)
iterations, and the clock is read only after `DEFK_BUDGET0` (256) back-edges.
`STRIPS=small` sets `DEFK_STRIP=8`, `DEFK_ZERO_STRIP=DEFK_COPY_STRIP=64` and
`DEFK_BUDGET0=1` (all `#ifndef`-guarded in `priv/defk_runtime.h`), so the
yielding run yields at every safepoint it passes: inside the element loop,
between the strips of a long copy or copy_back (the overlapping-match
pattern fill resumed mid-way), and during alloc's zeroing. On the seeds that
is 0-41 yields per input with small strips against 0-3 with release strips.
The release set runs both.

## How the C is generated

`gen_c.exs` evaluates the `defmodule` forms of the example that `use Defk`
(as `dev/dump_c.exs` does: no `Mix.install`, no bench) with the current
compiler and writes the module's `__defk_c_source__/0`. Nothing is
hand-copied, so a change to the compiler or to `priv/defk_runtime.h` is what
gets fuzzed. `MIX_ENV` defaults to `dev` (no test-only fault hooks, as a
user's build). The kernel is compiled with the flags of `Defk.Build` that
change meaning (`-std=gnu11 -ffp-contract=off -fno-strict-overflow
-fno-builtin`) at `-O1 -g`, instrumented for coverage
(`-fsanitize=fuzzer-no-link`); the shim, harness and target are compiled with
the sanitizers but without coverage, so their own string compares do not
steer the fuzzer.

## The shim (`shim/nif_shim.c`)

About 540 lines over `malloc`, implementing the `enif_*` functions the
generated C and the runtime header call (`nm -u` on a kernel library):
binaries (`alloc`/`realloc`/`release`/`inspect`/`make_binary`/
`make_new_binary`), integers, floats, atoms, tuples, maps
(`make_map_from_arrays`, duplicate keys refused), `raise_exception`,
`schedule_nif` (recorded, not run), resource types and reference-counted
resources whose destructor runs when the last term holding one is dropped,
`monotonic_time`/`consume_timeslice` (the clock above), `getenv`, `alloc`/
`free`. Terms are real (each its own malloc block, freed after each input),
so the oracle compares values and messages, and ASan sees a term or binary
used after its input finished. Every binary is exactly as large as asked
(no ERTS `CHICKEN_PAD` slack), so a one-byte overrun of an input or an
`alloc/2` result is reported. A binary above 256 MiB is refused like an
allocator failure (the runtime's out-of-memory raise). `enif_make_double` of
a non-finite value is a finding (ERTS would raise `badarg`; the runtime
promises never to pass one).

Not modelled: processes and messages, GC beyond moving input binaries
between calls, dirty schedulers, bignums (an integer is i64 or u64), iolists,
sub-binaries at odd offsets (the misaligned-input copy path), more than one
library per binary.

## Seed corpora (`corpus/`)

Small valid inputs in each target's format, compressed by the reference
encoders (snappyer, lz4_erl fast and HC) from payloads chosen to cover the
format's cases: empty and one-byte inputs, literals only, short and long
matches (LZ4 length continuation bytes, Snappy copy-2), overlapping matches
(offset below the length), incompressible bytes. 10 Snappy seeds (790
bytes) and 12 LZ4 seeds (957 bytes). `elixir verify/fuzz/seeds.exs`
regenerates them (it `Mix.install`s the encoders). libFuzzer reads them and
writes what it finds to `tmp/fuzz/corpus/`, never here.

## The self-test (planted bug)

`planted.sh` runs `run.sh lz4_block_decode` with a `PLANT` sed expression
applied to a copy of the generated C: the kernel's "lz4: block ends after a
match, not literals" raise is deleted and the token read `src[ip]` becomes
an unchecked `p_src.data[ip]`, so a block ending right after a match reads
one byte past the input binary. It starts from the seeds alone and must
report `heap-buffer-overflow` in `run_k*_lz4_block_decode`; it exits 0 when
it does.

## Results

Apple M4 Pro (14 cores), macOS 26, Homebrew LLVM 23.1.3, OTP 29.0.3, one
worker per run, 2026-10-13. The machine was shared with another agent's
work (load average 6-9 on 14 cores), so the rates are provisional.

`verify/fuzz/run.sh` (the release set, 60 s per run, seeds plus an empty
working corpus), all clean:

| Run | Inputs | Inputs/s | Coverage |
|---|---|---|---|
| `lz4_block_decode.release` | 2,010,828 | ~33,000 | 146 |
| `lz4_block_decode.small` | 344,696 | ~5,700 | 222 |
| `snappy_decode.release` | 1,989,420 | ~32,600 | 164 |
| `snappy_decode.small` | 682,419 | ~11,200 | 189 |

An input is two kernel calls (straight and yielding), so the kernel runs at
about twice these rates; the spike's single straight call per input ran
~87,000 inputs/s on an idle machine. The small-strips builds are slower
because the yielding run promotes a frame, moves the input and reschedules
at every safepoint. Coverage counts edges in the kernel library only (the
runtime header included); the small strips reach the strip and resume code
the release constants do not.

Self-tests, from the seeds alone:

- `planted.sh` (out-of-bounds token read): `heap-buffer-overflow ... READ of
  size 1 ... in run_k1_lz4_block_decode` after 2,963-4,544 inputs, 3-4 s
  wall including generating and building.
- A planted leak (`PLANT='/^defk_finish(&local.ctx);$/d'`, no cleanup after
  a raise or return): `LeakSanitizer: detected memory leaks` on the first
  seeds. Without `detect_leaks=1` the same run ended as an out-of-memory
  after 114,511 inputs instead.

## Adding a target

1. A file `targets/<name>.c` defining `defk_fuzz_target` (`shim/harness.h`):
   the NIF name and arity (a yielding kernel takes the run-queue hint last),
   an `args` function from bytes to terms, the allowed exceptions, and a
   `check` of a returned value.
2. Its source in `source_of` in `run.sh` (example file and kernel module)
   and its name in `ALL_TARGETS`.
3. Seeds in `corpus/<name>/` (extend `seeds.exs`).

## Missing decoders

The ticket (defk-96f.4) names the defk-52v decoders. Only LZ4 and Snappy
exist so far; inflate/PNG (defk-52v.7), zstd (defk-52v.8) and baseline JPEG
(defk-52v.12) are not built yet. Each gets a target when it lands.

## Known limits

- No Elixir-mode oracle (Elixir mode runs only in the VM): a wrong but
  self-consistent value that passes the target's check is not found. The
  example's in-VM fuzz section and the agreement tests cover that side.
- `-O1`, not the `-O3` of a real build: undefined behaviour the optimiser
  exploits only at `-O3` may slip through (UBSan still reports the UB
  itself).
- Inputs of at most 4 KiB by default (`MAX_LEN`): the release strip
  constants are reached only by the small-strips build.
- macOS only as written (Homebrew paths); the C is portable and a Linux
  clang with libFuzzer would do, with `LLVM=`.
