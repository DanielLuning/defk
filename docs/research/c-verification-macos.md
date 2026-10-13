# Checking the C that defk generates, on this Mac

Research for the question "what can we practically do on this Mac to verify
and check the C that defk produces, and improve the compiler from that
feedback?". Unlike [nx-boundary.md](nx-boundary.md), most of this note is
**measured**: every tool below was run here against defk's generated C. A
claim that comes from a document cites it; a claim that comes from an
experiment gives the command; *inference* marks my reading of either.

Run 2026-10-13 on one machine: macOS 26.7.1 (25G241), arm64 (Apple Silicon),
SIP enabled, repo at `7b9687f` (`mix dump_c` taken there; `main` moved to
`7e12538` during the session, which changes no conclusion here). Timings were
taken while other jobs ran on the machine: treat them as provisional, good to
a factor of two.

| Tool | Version |
|---|---|
| Apple clang (`cc`) | 21.0.0 (clang-2100.3.34.2), Xcode 27.0 (27A266a) |
| Homebrew LLVM | `llvm` 23.1.3, `llvm@22` 22.1.8 (clang, clang-tidy, scan-build, ASan/UBSan/LSan/libFuzzer runtimes) |
| Erlang/OTP | 29.0.3, ERTS 17.0.3 (asdf, kerl 4.4.0); Elixir 1.20.2 |
| cppcheck | 2.22.0 (brew) |
| CBMC | 6.11.0 (brew) |
| ESBMC | 8.5.0 (brew) |
| KLEE | 3.2, LLVM 16 (brew) |
| Infer | 1.3.0 (`infer-osx-arm64` release tarball) |
| leaks, lldb, xctrace | system (lldb-2103.0.34.103, xctrace 27.0) |

Section 6 (Valgrind) is the exception: it was run in a podman arm64 Linux VM
on the same machine, because Valgrind does not build on this macOS; its own
header gives the conditions.

The material that was checked: `DEFK_DUMP_C=… mix dump_c` (93 files, 11 MB of
C: every test kernel module and every top-level example; `dev/dump_c.exs`),
and three small scratch kernels written for planting bugs (`scale/2` over
`[f64]`, `flip/2` over `[u8]`, a masked reduce). Nothing in the repo was
edited; all experiments ran in a scratch directory, below `$S`.

## Bottom line

**Decision (maintainer, 2026-10-13):** none of these checks join `mix ci`.
They run as part of a release build, and each can be run on demand as its
own task. Tracked in the epic defk-96f; the two header fixes in defk-o52;
the agreement-test allocation abort in defk-bh3.

defk's memory-safety risk sits where the compiler *removes* a check because it
proved it unneeded (elided bounds checks, flagged strips, unzeroed allocs,
owned-buffer cleanup on raise and yield). Tools that see run-time sizes find
those bugs; tools that only see the C text do not, because every array length
in defk's C comes from `enif_inspect_binary` at run time.

**Adopt now (all work on this Mac today; item 2 in a podman Linux VM on it):**

1. **A sanitizer build of the kernels under the test suite.** The whole suite
   (`mix test`: 1,625 tests, 698 properties) ran clean under ASan and under
   UBSan; the only failures were four tests that check build artefacts, not
   behaviour (below). Two ways to load ASan into the BEAM both work:
   - **OTP's own `asan` emulator** (best): building it from the OTP source
     tarball took **1 min 4 s configure + 33 s `make -C erts/emulator asan`**
     here. It needs no `DYLD_*` variables and no `+Mea`, and it removes ERTS's
     7-byte binary slack, so it catches 1-byte overruns of `alloc/2` outputs
     that the other way misses.
   - **The stock asdf `beam.smp` with `DYLD_INSERT_LIBRARIES`**, passed with
     `erl -env` (SIP strips `DYLD_*` from the shell scripts in between) and
     **`+Mea min`** (without it, ERTS's allocators hide every heap bug from
     ASan). Misses overruns of up to 7 bytes past an `enif_alloc_binary`
     buffer unless the runtime header poisons that slack itself (tested: one
     `ASAN_POISON_MEMORY_REGION` call in `defk_own_raw` closes it).
   UBSan needs neither: its runtime loads fine from the NIF itself.
2. **Valgrind memcheck on OTP's `valgrind` emulator, in a Linux container**
   (section 6; podman arm64 VM, since Valgrind does not build on this macOS).
   It is the only tool here that reports an **uninitialised read** with no
   oracle: an `alloc/2` element left unwritten was reported where Elixir
   first used it, with the `alloc/2` call and its line in the generated C as
   the origin, and one read inside the kernel at the kernel's line. It also
   caught the planted 1-byte overread, the 1-byte write past an unzeroed
   `alloc/2` output and the owned-buffer leak on a raise path (exact bytes and
   stack), each with no `+Mea`, `DYLD_*` or re-signing. Cost: the emulator
   builds in 15 s from the OTP tarball; runs are ~35-80x slower than native on
   one core. The suite ran file by file at 47x (~46 minutes on two cores):
   1,615 of 1,618 passed (the rest artefacts), zero Memcheck errors in defk
   code, and `agreement_test.exs` did not finish (its multi-GiB Elixir-mode
   allocations). Sub-binary over-reads stay invisible, as with ASan.
3. **Assertions for every elided check, in a check build.** ASan watches
   allocations, not arrays: a kernel reading past the end of a **sub-binary**
   reads its parent's bytes and ASan stays silent (measured). A
   `DEFK_ELIDED(i, len)` macro around each index the compiler proved, that
   traps in a check build and is the plain index otherwise, caught that case
   (SIGTRAP) and is the hook a model checker needs too.
4. **CBMC on simple kernels, through the elided checks.** With a ~40-line
   `erl_nif` stub harness, two `goto-instrument` options and
   `--slice-formula`, CBMC proved `flip/2` memory-safe for inputs up to 8 bytes
   in 1.5 s, `ws_mask/2` (from `examples/ws_masking.exs`) up to 16 bytes in
   2 min and `valid_utf8?/1` up to 16 bytes in 16 min, and found each planted
   out-of-bounds access. It did **not** finish on `lz4_block_decode/2` (even
   at 4 bytes, 10 min) or on the float kernel `scale/2`; without
   `--slice-formula` even `flip/2` did not finish in 5 minutes. It is bounded:
   a proof holds only up to the input size given. For the decoders, the fuzzer
   (next item) is the tool that works today.
5. **libFuzzer outside the VM for the decoders.** The same stubs, grown into a
   ~50-line `erl_nif` shim, run `lz4_block_decode/2` at **~87,000 inputs/s
   under ASan+UBSan** (10.5 M inputs in 121 s, clean); a planted unguarded
   read was found in under a second. Needs Homebrew LLVM (Apple's clang ships
   no libFuzzer runtime).
6. **`leaks` for owned-buffer cleanup**, with `+Mea min`,
   `MallocStackLogging=1` and a copy of `beam.smp` re-signed with
   `get-task-allow`: it reported exactly one planted leak (192 bytes, with the
   stack into `defk_own_raw`) and zero on the unmodified kernel. **MallocScribble
   with `+Mea min`** turns an unwritten element of an unzeroed `alloc/2` into a
   deterministic `0xAA` that agreement tests catch (defk-i5r's soundness
   question).
7. **Three concrete fixes found on the way:** `priv/defk_runtime.h:1713` passes
   an `int64_t *` where `enif_get_int64` takes `long *` on macOS: a warning
   with Apple clang (printed on every build and swallowed), a **hard error with
   Homebrew LLVM 22 and 23**, so `CC=$(brew --prefix llvm)/bin/clang` cannot
   build any kernel today. And the build cache keys on `CC` but not on the
   flags a `CC` wrapper adds: in this session an ASan build was silently reused
   by a later non-ASan run twice (it aborted the VM, and once it replaced the
   library in `_build/test/lib/defk/ebin`). A sanitizer mode must be part of
   the cache key (it overlaps defk-srh). And on Linux, **clang builds of
   defk crash the node on every raise** (section 6): glibc's `__sigsetjmp`
   carries no `returns_twice`, defk's `-fno-builtin` stops clang from adding
   it, and `guard_k*`'s `return run_k*(…)` becomes a tail call that the
   `siglongjmp` returns into. `mix test` with `CC=clang` died at the first
   raise (Bus error); with a `returns_twice` redeclaration, or with gcc, the
   suite passed.

**Needs Linux CI (defk-a1p):** Valgrind as a routine job (measured in a
local container, section 6; Homebrew's formula is `depends_on :linux`),
MemorySanitizer for uninitialised reads (Linux, NetBSD, FreeBSD only;
assessed in section 6 and not worth building while Valgrind covers the same
bugs), `rr` record-and-replay (not in Homebrew), GCC's `-fanalyzer` (GCC only), and
LeakSanitizer as a routine check (it works here only with Homebrew's runtime,
and ERTS's exit noise needs OTP's suppressions).

**Skip (measured, no signal on defk's C):** the clang static analyzer and
scan-build (668 reports, all dead stores; a planted out-of-bounds read was not
reported), clang-tidy (2,600+ style reports on 8 files, none real), cppcheck
(16 reports, all false positives, and 20-30+ minutes over the dump), Infer 1.3.0 (missed the planted bug, with and without a harness),
Guard Malloc (works, but only with `+Mea min`, 16-byte granularity, and a bare
SIGSEGV), `MallocGuardEdges` (missed a 4,800-byte overrun), and ESBMC (runs
after workarounds, but reported a violation in the unmodified kernel that CBMC
proves safe). Compiler warnings beyond `-Wall` found the `int64_t *` bug and
nothing else. KLEE runs here and found the planted bug, but CBMC plus libFuzzer
cover what it would add. Frama-C was assessed, not installed.

## What the risk looks like in the C

Read before the experiments, so the tools are judged against the right bugs.

- **Elided bounds checks.** A checked read is `defk_get_u8(ctx, p_src, i)`; an
  elided one is `(p_a).data[v_i_2]` (`scale/2` in `Examples.Kernels`, dump
  line 730ff). The proof behind the elision is in the compiler (`Facts.prove_in_bounds`,
  [ADR-0007](../adr/0007-symbolic-bounds.md)), not in the C.
- **Array lengths are run-time values.** `defk_bind` sets `data`/`len` from
  `enif_inspect_binary` (`priv/defk_runtime.h` L571-L598); outputs come from
  `enif_alloc_binary` via `defk_own_raw` (L246-L263). A tool that cannot see
  inside `erl_nif` sees an unknown pointer with no size.
- **Unzeroed allocs** (`defk_alloc_raw_*`, defk-ktw/defk-i5r): safe only if
  every element is written before Elixir sees it.
- **Inputs are often sub-binaries** (`ws_masking.exs` times "each its own
  sub-binary of one receive buffer"): the bytes past `len` belong to the
  parent binary and are mapped and readable.
- **Owned buffers and raise/yield** (`defk_finish`, `defk_frame_dtor`, L174-L191;
  defk-c1e): a missed release is a leak, not a crash.

## 1. Dynamic checking inside the BEAM

### The sanitizer `CC` wrapper

All runs below used one wrapper as `CC` (defk passes `CC` through,
`lib/defk/build.ex`). Its flags come after defk's `@cflags`, so `-O1` wins over
`-O3`; `PLANT` applies a `sed` to a copy of the generated `.c` (how the bugs
below were planted; the repo's C is never touched):

```bash
#!/opt/homebrew/bin/bash
# $S/bin/cc-san
set -e
REAL=${SAN_CC:-cc}
if [ "$1" = "--version" ]; then exec $REAL --version; fi
out=(); for a in "$@"; do
  if [[ -n "$PLANT" && "$a" == *.c ]]; then
    p="${a%.c}.planted.c"; sed -e "$PLANT" "$a" > "$p"; out+=("$p")
  else out+=("$a"); fi
done
exec $REAL "${out[@]}" ${SAN_FLAGS:--fsanitize=address -fno-omit-frame-pointer -fno-common -g -O1}
```

Kernel modules for experiments were compiled by `mix run --no-start spike.exs`
with `MIX_ENV=test`, and full-suite runs used their own `MIX_BUILD_PATH`, so
the sanitized libraries stay out of `_build` (see the cache-key finding).

### Getting the ASan runtime into `beam.smp`

The asdf `beam.smp` is ad-hoc signed without the hardened runtime
(`codesign -dvv`: `flags=0x20002(adhoc,linker-signed)`), so dyld honours
`DYLD_INSERT_LIBRARIES` for it. Apple: a hardened-runtime binary ignores
`DYLD_*` unless it has the *Allow DYLD Environment Variables* entitlement, and
library validation needs *Disable Library Validation* for libraries signed by
another team
([allow-dyld-environment-variables](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.cs.allow-dyld-environment-variables),
[disable-library-validation](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.cs.disable-library-validation)).
Neither applies to a locally built OTP.

What does block it is the launch chain. `mix`/`elixir` are asdf shims
(`#!/usr/bin/env bash`) and `erl` is a `/bin/sh` script, and "any dynamic
linker (dyld) environment variables, such as DYLD_LIBRARY_PATH, are purged when
launching protected processes" ([SIP, Runtime Protections](https://developer.apple.com/library/archive/documentation/Security/Conceptual/System_Integrity_Protection_Guide/RuntimeProtections/RuntimeProtections.html)).
Measured:

```console
$ DYLD_INSERT_LIBRARIES=/nonexistent DYLD_FOO=1 /bin/sh -c 'env | grep DYLD; echo shdone'
shdone
```

The way through is `erl -env Var Value`, which "sets the host OS environment
variable Variable to the value Value for the Erlang runtime system"
([erl](https://www.erlang.org/doc/apps/erts/erl_cmd.html)): `erlexec` (not
protected) sets it just before it `exec`s `beam.smp`. `ERL_AFLAGS` carries it
through the scripts:

```bash
ASAN=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/clang/21/lib/darwin/libclang_rt.asan_osx_dynamic.dylib
ERL_AFLAGS="-env DYLD_INSERT_LIBRARIES $ASAN +Mea min" CC=$S/bin/cc-san MIX_ENV=test mix run --no-start spike.exs
```

`vmmap` on that node showed the ASan dylib mapped. Without the insert, the
first ASan kernel aborts the node at load:

```text
==47820==ERROR: Interceptors are not working. This may be because AddressSanitizer is loaded too late (e.g. via dlopen). Please launch the executable with:
DYLD_INSERT_LIBRARIES=…/libclang_rt.asan_osx_dynamic.dylib
"interceptors not installed" && 0
```

The ASan runtime must be the one from the compiler that built the kernel
(Apple's here); Homebrew's is a different runtime.

### `+Mea min` is required

ASan instruments `malloc`; ERTS serves binaries from its own allocators.
`+Mea min` "disables all allocators that can be disabled", and a disabled
allocator falls back to `sys_alloc`, "normally the default malloc
implementation" ([erts_alloc](https://www.erlang.org/doc/apps/erts/erts_alloc.html)).
The planted bug: `scale/2` reading `a[i + 1]` (`PLANT='s/(p_a).data\[v_i_2\] \* p_k/(p_a).data[v_i_2 + 1] * p_k/'`),
100 floats:

| Run | Result |
|---|---|
| ASan inserted, default allocators | **not detected**; returns a wrong sum (10098.0 for 10100.0) |
| ASan inserted, `+Mea min` | `heap-buffer-overflow … READ of size 8 … in run_k0_scale Elixir.Spike.K-….planted.c:70`, allocated by `erts_new_bitstring_refc` via `erts_sys_alloc`; node exits 134 |
| same, planted **write** `out[i + 1]` | `heap-buffer-overflow … WRITE of size 8`, allocated by `enif_alloc_binary` ← `defk_own_raw defk_runtime.h:259` |
| 5 floats (40 B, a heap binary) | not detected: heap binaries live inside the process heap block |

### The 7-byte slack ERTS adds to every `enif_alloc_binary`

A `[u8]` kernel writing `out[i + 1]` (one byte past the end) was **not**
detected under `+Mea min`; `out[i + 8]` was, and ASan reported a "139-byte
region" for a 100-byte binary. The reason is in ERTS:
`erts_bin_drv_alloc_fnf` (which `enif_alloc_binary` calls) allocates
`ERTS_SIZEOF_Binary(size) + CHICKEN_PAD`, with `CHICKEN_PAD` `sizeof(void*) - 1`
"to counter buggy drivers", and 0 only in `DEBUG`, `VALGRIND` and
`ADDRESS_SANITIZER` builds
([erl_binary.h L239-L261 at OTP-29.0.3](https://github.com/erlang/otp/blob/OTP-29.0.3/erts/emulator/beam/erl_binary.h#L239-L261),
[erl_nif.c L1409-L1422](https://github.com/erlang/otp/blob/OTP-29.0.3/erts/emulator/beam/erl_nif.c#L1409-L1422)).
Inputs built by `:binary.copy` had no slack (an 832-byte region for 800 bytes).

Defk can close the gap itself in a sanitizer build. With this added to a copy
of the runtime header (after `enif_alloc_binary` in `defk_own_raw`):

```c
#if defined(__has_feature)
#if __has_feature(address_sanitizer)
#include <sanitizer/asan_interface.h>
#define DEFK_POISON_TAIL(p, n) ASAN_POISON_MEMORY_REGION((p), (n))
#endif
#endif
#ifndef DEFK_POISON_TAIL
#define DEFK_POISON_TAIL(p, n) ((void)0)
#endif
/* in defk_own_raw, after enif_alloc_binary: */
  DEFK_POISON_TAIL(b->data + bytes, sizeof(void *) - 1); /* ERTS CHICKEN_PAD */
```

the 1-byte overrun was reported for lengths 100, 101 and 104
(`use-after-poison … located 132 bytes inside of 139-byte region`), the
unplanted kernel ran clean, and the whole suite ran clean with it (next
section), so nothing in ERTS reads that slack.

### The whole suite under ASan and under UBSan

```bash
# ASan, stock beam, poisoned tail: header copy swapped in by PLANT
MIX_BUILD_PATH=$S/build_asan MIX_ENV=test CC=$S/bin/cc-san \
PLANT="s|#include \"defk_runtime.h\"|#include \"$S/hdr/defk_runtime.h\"|" \
ASAN_OPTIONS="log_path=$S/asanlogs/asan" \
ERL_AFLAGS="-env DYLD_INSERT_LIBRARIES $ASAN +Mea min" mix test

# UBSan: no insert, no +Mea; keeps -O3 (no -O in SAN_FLAGS)
MIX_BUILD_PATH=$S/build_ubsan MIX_ENV=test CC=$S/bin/cc-san \
SAN_FLAGS="-fsanitize=undefined -fno-sanitize-recover=undefined -fno-omit-frame-pointer -g" mix test
```

"Time" is ExUnit's "Finished in", with the machine loaded (load average
11-13 on 12 cores) during all four runs; the plain run is at the later commit,
with 26 more tests. *Inference:* the sanitizer runs cost about 2x, in line
with the ASan docs' "typical slowdown … 2x"
([ASan](https://clang.llvm.org/docs/AddressSanitizer.html)).

| Run | Result | Time |
|---|---|---|
| plain (`mix test`, at `7e12538`) | 1651/1651 | 61.9 s |
| ASan, stock beam + `+Mea min` + poisoned tail | 1621/1625, **0 ASan reports** | 128.6 s |
| ASan, OTP `asan` emulator (below) | 1627/1631, **0 ASan reports** | 143.9 s |
| UBSan (`-fno-sanitize-recover=undefined`) | 1622/1625, **0 UBSan reports** | 125.6 s |

All failures are artefacts of the build mode, read one by one:
`:erlang.memory(:binary)` raises `notsup` once the binary allocator is
disabled (`bitstring_test.exs:479`, `raise_cleanup_test.exs:54`); `report:
:full` expects `dot` to vectorise, and it does not at `-O1`, nor under UBSan at
`-O3` ("Cannot vectorize early exit loop", the UBSan checks are the early
exits); `-g` makes the linker write a `.so.dSYM` directory that
`report_test.exs:289` tries to `File.cp!`; and UBSan's one other failure was a
`Mix.install` script test that picked up an ASan library from the shared
`System.tmp_dir` cache (the cache-key problem again).

UBSan keeps checking signed overflow even with defk's `-fno-strict-overflow`
(the docs say "checks are still added even when -fwrapv is enabled",
[UBSan](https://clang.llvm.org/docs/UndefinedBehaviorSanitizer.html); verified
with a 3-line program under `-fno-strict-overflow` and `-fwrapv`). So the clean
run is evidence that no generated C relies on signed wraparound, misaligned
loads, oversized shifts or out-of-range float-to-int casts, on the suite's
inputs. A planted shift by 64 in a kernel was reported as
`runtime error: shift exponent 64 is too large for 64-bit type 'unsigned long long'`.
Without `-fno-sanitize-recover` UBSan prints and continues (the node exited 0),
so a test run must use it or scan the log. `-fsanitize-trap=undefined` needs no
runtime and killed the node with SIGTRAP (exit 133) and no message: a release
hardening option, not a test tool.

### OTP's `asan` emulator

OTP's guide: build with the `asan` target, run with `erl -emu_type asan`,
compile the NIF with `-fsanitize=address -fno-common -fno-omit-frame-pointer`,
and use `LSAN_OPTIONS=suppressions=$ERL_TOP/erts/emulator/asan/suppress`
([Debugging NIFs and Port Drivers](https://www.erlang.org/doc/system/debugging.html);
"make TYPE=$TYPE" in [Building and installing](https://www.erlang.org/doc/system/install.html)).
`-emu_type` starts "an emulator of a different type … The emulator of this type
must already be built" ([erl](https://www.erlang.org/doc/apps/erts/erl_cmd.html));
the asdf install has only `beam.smp`:

```console
$ erl -emu_type asan
erlexec: Invalid emulator type or flavor. Available combinations are:
  -emu_flavor smp
```

Building just the emulator from the release tarball worked first try:

```bash
curl -LO https://github.com/erlang/otp/releases/download/OTP-29.0.3/otp_src_29.0.3.tar.gz
tar xzf otp_src_29.0.3.tar.gz && cd otp_src_29.0.3 && export ERL_TOP=$PWD
./configure --without-wx --without-javac --without-odbc --without-ssl --without-termcap   # 1:04
make -C erts/emulator asan -j10                                                          # 0:33
# -> bin/aarch64-apple-darwin25.6.0/{beam.asan.smp,erl_child_setup.asan}
```

I copied the asdf OTP install (120 MB) to `$S/otp29asan`, dropped both files
into its `erts-17.0.3/bin/`, and pointed `ROOTDIR` in its `bin/erl` and
`bin/start` at the copy; `erl -emu_type asan` then reports
`erlang:system_info(build_type) =:= asan`. kerl (which asdf-erlang uses) builds
it as part of an install with `KERL_RELEASE_TARGET="opt asan"`: it runs
`make asan` in `erts/emulator` and copies `beam.asan.smp` and
`erl_child_setup.asan` into the release (kerl 4.4.0, `_do_build` and the
install loop). That path is a full OTP build, not timed here.

Why it is better: an `ADDRESS_SANITIZER` build turns the allocators off by
default (`AU_ALLOC_DEFAULT_ENABLE` is 0, and `literal_alloc` too,
[erl_alloc.c L70-L74, L287-L293](https://github.com/erlang/otp/blob/OTP-29.0.3/erts/emulator/beam/erl_alloc.c#L70-L74)),
`CHICKEN_PAD` is 0, and the emulator is linked against the ASan runtime
([Makefile.in L168-L175](https://github.com/erlang/otp/blob/OTP-29.0.3/erts/emulator/Makefile.in#L168-L175)),
so no `DYLD_*`, no `+Mea`. Measured: the 1-byte `[u8]` overrun the stock beam
missed was reported (`0 bytes after 132-byte region`) with **no flags beyond
`-emu_type asan`**, the unplanted kernel ran clean, and the whole suite ran
clean (table above).

### What ASan cannot see

- **Reads past a sub-binary.** `flip/2` reading `a[i + 1]` on
  `binary_part(<<7 × 100, 9 × 100>>, 0, 100)` returned `last=8` (it read the
  parent's 9) under the `asan` emulator with no report; the same read on a
  whole binary was reported. The bytes belong to a live allocation.
- **Uninitialised reads** (an unzeroed `alloc/2` element never written):
  ASan does not track them, and MemorySanitizer is "supported on … Linux,
  NetBSD, FreeBSD" and "requires that all program code is instrumented … even
  libc" ([MSan](https://clang.llvm.org/docs/MemorySanitizer.html)), so not here
  and not without an instrumented ERTS.
- **Leaks**: Apple's runtime says `detect_leaks is not supported on this
  platform`; Homebrew LLVM 23's runtime does support it on arm64 macOS (a
  3-line leak was reported), but a kernel run reported 97,827 bytes in 624
  allocations from ERTS itself at halt. Use `leaks` instead (section 2).

## 2. macOS-native tools

All of the allocator-based ones need `+Mea min` to see binary memory at all,
for the same reason as ASan. Every environment variable below was passed with
`erl -env` like `DYLD_*` (whether SIP also strips `Malloc*` variables was not
tested).

| Tool | Against beam.smp + kernel | Verdict |
|---|---|---|
| `leaks` | stock asdf beam: "Process … is not debuggable. Due to security restrictions, leaks can only show or save contents of readonly memory", 0 leaks reported regardless | useless on the stock binary |
| `leaks` + `MallocStackLogging=1` + `+Mea min` + beam re-signed with `get-task-allow` | planted leak (no `defk_finish` on the return path): `1 leak for 192 total leaked bytes`, stack `defk_own_raw defk_runtime.h:254` ← `run_k0_scale` ← `nif_k0_scale`; unplanted: `0 leaks`; without `+Mea min`: `0 leaks` (the table lives in an ERTS allocator) | **adopt** for cleanup paths |
| `MallocScribble=1` (+ `+Mea min`) | planted "first element never written" in an unzeroed `[u8]` alloc: element is `170` (0xAA) every run; without `+Mea min` it was 1, 3 or 0 | **adopt** with agreement tests: makes an unwritten element a deterministic divergence |
| Guard Malloc (`DYLD_INSERT_LIBRARIES=/usr/lib/libgmalloc.dylib`) | with `+Mea min`: planted read past an 800-byte input → SIGSEGV (exit 139), crash report names `run_k0_scale` line 70; default allocators: not detected | works, but ASan gives more for the same setup |
| `MallocGuardEdges=1` | a read 600 elements (4,800 B) past an 800,000-byte input: not detected, with or without `+Mea min` | skip |
| `xctrace record --template Leaks --attach` | stock beam: "Unable to acquire required task port"; `get-task-allow` copy: records | same as `leaks`, GUI-oriented |
| `lldb -p <beam pid>` | attaches to the stock asdf beam (`stop reason = signal SIGSTOP`) | works for watchpoints and backtraces |

Guard Malloc places "the end of the allocated buffer … at the end of the last
page" but aligns to 16 bytes, so "up to 15 bytes at the end of an allocated
block may be excess … libgmalloc will not detect buffer overruns into that
area" (`man libgmalloc`); `MallocGuardEdges` guards only "each large block"
(`man malloc`), and a large block is rounded to pages, so the slack swallowed
the overrun. *Inference:* the page granularity is why both lose to ASan.

The `get-task-allow` step re-signs a **copy** of `beam.smp` (no system setting
is touched):

```bash
cat > gta.plist <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>com.apple.security.get-task-allow</key><true/></dict></plist>
EOF
codesign -s - -f --entitlements gta.plist $S/otp29asan/erts-17.0.3/bin/beam.smp
PATH=$S/otp29asan/bin:$PATH ERL_AFLAGS="+Mea min -env MallocStackLogging 1" \
  SLEEP=20000 mix run --no-start spike.exs &   # the script prints its OS pid, then sleeps
leaks <pid>
```

`leaks` scans a live process conservatively, so ERTS's never-freed state is
still referenced and does not show; that is why it was exact here where
LeakSanitizer at exit was noise.

## 3. Static analysis of the generated C

Over all 93 dumped files. The flags were defk's `@cflags` minus `-shared`.

| Tool | Command (per file) | Wall | Reports | Real |
|---|---|---|---|---|
| clang static analyzer (Apple) | `cc --analyze -Xanalyzer -analyzer-output=text …` | 2 min 33 s at `-P8` (962 s summed; slowest file 126 s, `Defk.AllocUnzeroedTest.K`) | 668, all `deadcode.DeadStores` | 0 |
| same + `security.ArrayBound`, `optin.taint` (Apple and LLVM 23) on the planted `scale/2` | | <1 s | 1 dead store; **planted read not reported** | — |
| warnings: `-Wextra -Wconversion -Wsign-compare -Wsign-conversion -Wshadow -Warray-bounds -Warray-bounds-pointer-arithmetic -Wcast-align -Wcast-qual -Wfloat-equal -Wimplicit-fallthrough -Wunreachable-code -Wnull-dereference -Wformat=2 -Wdouble-promotion -Wcomma -Wshorten-64-to-32` | | 6 min (serial) | 2,764 (1,882 from 25 sites in the header) | 1 (below) |
| clang-tidy 23 (`bugprone-*,cert-*,misc-*`), 8 files | | 2 s | 2,645 (1,616 `signed-bitwise`, 290 `assignment-in-if-condition`, 269 `switch-missing-default-case`, …) | 0 |
| cppcheck 2.22 `--enable=warning,portability,performance --inconclusive` | | killed at 30 min, 90/93 files (it checks every `#ifdef` configuration of `erl_nif.h`); with `--max-configs=1` still running at 19 min, same 16 reports | 16 | 0 |
| Infer 1.3.0 `--pulse --bufferoverrun`, planted `flip/2` with and without the CBMC harness | | 2 s | 2 dead stores | missed the planted bug |

The real one: `priv/defk_runtime.h:1713`, in `defk_slice_init`, declares
`int64_t waiting` and passes `&waiting` to `enif_get_int64`, which on 64-bit
macOS is `enif_get_long(…, long *)` (`erl_nif_api_funcs.h` L670); `int64_t` is
`long long` there. Every other call site uses `ErlNifSInt64` (L604, L614). It
is harmless at run time (same size), but:

```text
cc (Apple 21):          defk_runtime.h:1713:42: warning: incompatible pointer types passing 'int64_t *' (aka 'long long *') to parameter of type 'long *' [-Wincompatible-pointer-types]
clang (LLVM 22, 23):    defk_runtime.h:1713:42: error: incompatible pointer types …
```

so no kernel builds with Homebrew's clang, which is also the only clang here
with libFuzzer and a leak-checking ASan runtime. The fix is `ErlNifSInt64
waiting;`. The rest of the warnings, read at their sites: `-Wcast-align` on the
`unsigned char *` → `double *` casts of `defk_alloc_raw_*` (alignment is what
`defk_bind` checks for inputs and ERTS guarantees for `orig_bytes`; UBSan's
alignment check ran clean over the suite), self-comparisons and
distinct-pointer-type comparisons in the "is this the caller's own binary"
result code, `-Wself-assign` (`v_z_18 = v_z_18`) and `-Wunused-but-set-variable`
from straight-line emission, `-Wfloat-equal` on argmax ties. cppcheck's three
`shiftTooManyBitsSigned` on `defk_bsl_core`/`defk_bsr_core` (L701-L717) are
right shifts by at most 63, which C defines (implementation-defined for
negative values, which the comment there addresses).

Why the analyzers miss the planted bug (*inference*, consistent with every
run): the length of `p_a.data` is whatever `enif_inspect_binary` returned, an
unknown external, so a path-sensitive analyzer has no extent to compare the
index with. The checks defk elides are exactly the ones that need that extent.
GCC's `-fanalyzer` is a GCC option
([GCC Static Analyzer Options](https://gcc.gnu.org/onlinedocs/gcc/Static-Analyzer-Options.html))
and would have the same blind spot; try it on Linux only if the harness below
is reused.

## 4. Bounded and formal verification

### CBMC works, with a harness and three options

The harness replaces the `erl_nif` calls the `run_` path makes with stubs whose
sizes are explicit, and calls the kernel's `run_k*` function directly
(`$S/cbmc/harness.c`, abridged):

```c
int enif_inspect_binary(ErlNifEnv *env, ERL_NIF_TERM t, ErlNifBinary *bin) {
  size_t n = nondet_size();
  __CPROVER_assume(n <= MAXN * 8);
  bin->size = n;
  bin->data = malloc(n ? n : 1);
  __CPROVER_assume(bin->data != 0); /* ERTS never hands out NULL data */
  return 1;
}
int enif_alloc_binary(size_t size, ErlNifBinary *bin) {
  bin->size = size; bin->data = malloc(size ? size : 1); return bin->data != 0;
}
int enif_get_long(ErlNifEnv *env, ERL_NIF_TERM t, long *v) {
  long x; __CPROVER_assume(x >= -MAXINT && x <= MAXINT); *v = x; return 1;
}
/* + enif_get_double, enif_realloc, enif_monotonic_time, enif_make_binary,
   enif_make_new_binary */

#include "flip.c"   /* the generated kernel, so its static functions are visible */
int main(void) {
  frame_k0_flip F; memset(&F, 0, sizeof F);
  ERL_NIF_TERM argv[2] = {0, 0}, res;
  if (sigsetjmp(F.ctx.jb, 0)) return 0;
  run_k0_flip(NULL, &F, argv, &res);
  return 0;
}
```

```bash
goto-cc main_flip.c -DMAXN=1 -I$ERTS_INCLUDE -I priv -o flip.gb
goto-instrument flip.gb flip2.gb --remove-function-body defk_fail --remove-function-body siglongjmp \
  --generate-function-body 'defk_fail|siglongjmp' --generate-function-body-options assume-false
cbmc flip2.gb --bounds-check --pointer-check --unwind 10 --unwinding-assertions --slice-formula --object-bits 12
```

`assume-false` makes a raise end the path, which is its meaning (a raise is
allowed behaviour; only a memory error is a bug); CBMC otherwise reports
"siglongjmp requires instrumentation". Without `--slice-formula`, `flip/2`
(≤ 8 bytes) ran 5 minutes at 2.7 GB without an answer and `scale/2` 10 minutes
at 4 GB; with it, `flip/2` takes 1.5 s. Two harness bugs showed up as CBMC
failures before the real results (CBMC's `malloc` may return NULL; an
unstubbed `defk_slice_init` would leave `slice_us` 0): a harness is code and
needs the same review.

| Kernel (input bound) | Unwind | Result | Time |
|---|---|---|---|
| `flip/2` (`[u8]`, ≤ 8 B) | 10 | **SUCCESSFUL**, 0 of 1,077 properties failed | 1.5 s |
| `flip/2`, planted `out[i + 1]` | 10 | FAILED: `pointer outside object bounds in v_out_1.data[v_i_2 + 1]`, line 60 | 1.0 s |
| `ws_mask/2` (`examples/ws_masking.exs`, ≤ 8 B) | 12 | **SUCCESSFUL**, 0 of 1,780 | 53 s |
| `ws_mask/2` (≤ 16 B) | 20 | **SUCCESSFUL**, 0 of 1,780 | 119 s |
| `ws_mask/2`, planted `payload[j + 4]` (≤ 8 B) | 12 | FAILED: `pointer outside object bounds in p_payload.data[v_j_11 + 4ll]`, line 149 | 60 s |
| `valid_utf8?/1` (`examples/utf8_valid.exs`, ≤ 16 B) | 20, two 256-trip table loops 257 | no memory-safety failure; 1 of 1,634 failed, `no body for callee enif_make_atom` (a missing stub, not a defect) | 16 min |
| `lz4_block_decode/2` (≤ 8 B, `max_out` in ±64) | 12 | no answer: still in symbolic execution at the 20 min timeout | — |
| `lz4_block_decode/2` (≤ 4 B) | 6 | no answer: symbolic execution done, SAT solving at the 10 min timeout | — |
| `scale/2` (`[f64]`, ≤ 4 elements) | 8 | no answer: SAT solving at the 15 min timeout | — |

So it scales to small inputs of one simple kernel at a time, and not yet to
the decoders that need it most. *Inference:* the cost grows with unrolled loop
trips, with nested data-dependent loops (LZ4's literal-length and
match-length loops inside the sequence loop multiply paths), and with float
arithmetic (bit-blasted IEEE multiplication; the `scale/2` row). It fits
straight loops over bytes and index arithmetic; for `lz4_block_decode/2` it
would need per-loop `--unwindset` bounds, a check of one elided assertion at a
time (`--property`, item 6 below), or a decomposition the compiler can emit
(the inner loops as their own functions with contracts). Not attempted here. Constant loops (a 256-entry class
table in `valid_utf8?`) need `--unwindset` per loop or the unwinding assertion
fails.

### Translation validation: assert what the compiler proved

The idea from the brief: emit, for every bounds check the compiler elides, an
assertion of the fact it relied on, so a checker verifies the compiler's proof
rather than the whole kernel. Tested by hand on `flip/2` with one macro:

```c
#define DEFK_ELIDED(i, n) ((uint64_t)(i) < (uint64_t)(n) ? (i) : (__builtin_trap(), (i)))
/* emitted as: (p_a).data[DEFK_ELIDED(v_i_2, (p_a).len)] */
```

- **At run time** (stock beam, `-g`, no sanitizer): with the planted
  `a[i + 1]` on a sub-binary the node died with SIGTRAP (exit 133), the case
  ASan missed above; unplanted, the kernel returned the right result.
- **Under CBMC** the same macro becomes `__CPROVER_assert(i < n, "elided: <kernel>:<line>")`,
  and CBMC can then be run with only those assertions as properties
  (`--property`), not every pointer dereference. *Inference:* that turns each
  run into "is this compiler proof true for inputs up to N bytes", with a
  counterexample when not, and needs no ERTS model beyond the stubs above.

Frama-C/WP could prove the same facts unbounded from ACSL contracts, but
that means generating loop invariants, which the compiler's range facts
(ADR-0007) have but do not export. Frama-C 33.0 installs on macOS from a
binary package or `brew install opam gmp … && opam install frama-c`
([Get Frama-C](https://frama-c.com/html/get-frama-c.html)); not installed
here. *Inference:* worth it only after the bounded CBMC check exists and a
proof needs to hold for all sizes.

### The other tools

- **ESBMC 8.5.0** (brew bottle for arm64): the macOS SDK headers break its
  parser (`typedef redefinition … 'struct fd_set'`, then `Conversion of
  unsupported clang type: "BlockPointer"`); preprocessing with
  `cc -E -P -fno-blocks` and stubbing `siglongjmp` gets it running (1 s), but
  it reported `array bounds violated: heap object` on the **unmodified**
  `flip/2`, through its model of `realloc` on the owned table, where CBMC and
  the ASan suite are clean. Not pursued.
- **KLEE 3.2** (brew bottle, LLVM 16): runs on arm64 macOS. With the
  libFuzzer shim and `klee_make_symbolic` on an 8-byte input it reported the
  planted `flip/2` write (`memory error: out of bound pointer`, line 60) and
  nothing on the unplanted one, in under a second, with two caveats it printed
  itself: `sigsetjmp` is called as an external (a raise path would not
  resume), and the symbolic `malloc` size is concretised.
- **Infer 1.3.0**: see section 3; missed the planted bug.

## 5. Differential and fuzz testing

### Sanitizers under the agreement properties

The suite's 698 properties (`Defk.Test.assert_agrees`, native against Elixir
mode, forced yields by default per `0b9798e`) all ran under ASan and UBSan in
the runs above, so the two combine with no extra work: a property input that
makes a kernel touch memory it should not now kills the run with a report,
where before it could pass if the wrong value happened to agree. *Inference:*
StreamData's default sizes are small, so this exercises edge lengths more than
large buffers; the catalog's own agreement corpora (`examples/*.exs`, e.g. the
2,187 payloads in `ws_masking.exs`) under the `asan` emulator would add size.
`MallocScribble` with `+Mea min` adds the third oracle: an unzeroed element
that is never written becomes `0xAA`, which an agreement property reports as a
divergence.

### libFuzzer outside the VM

Worth it for the from-scratch decoders (defk-52v), whose claim is "raises,
never crashes the VM" on attacker bytes. The shim (`$S/fuzz/nif_shim.c`, 40
lines) implements the 26 `enif_*` functions the generated C references
(`nm -u` on a kernel `.so`) over `malloc`; the harness calls the kernel's
`guard_k*` entry the way `nif_k*` does (including `defk_slice_init`, or
`defk_tick` divides by a zero slice), loops on `DEFK_YIELD`, then
`defk_finish`:

```bash
$(brew --prefix llvm)/bin/clang -g -O1 -fsanitize=fuzzer,address,undefined -fno-sanitize-recover=undefined \
  -ffp-contract=off -std=gnu11 -fno-strict-overflow -fno-builtin -Wno-incompatible-pointer-types \
  -I$ERTS_INCLUDE -I priv fuzz_lz4.c -o fuzz_lz4
./fuzz_lz4 -max_total_time=120 -max_len=4096 corpus
```

| Run | Result |
|---|---|
| `lz4_block_decode/2`, unmodified, 120 s | `Done 10506478 runs in 121 second(s)`, ~87k/s, 108 edges, no report |
| planted: guard `ip >= n` weakened to `ip > n` and the token read unchecked | `heap-buffer-overflow … LzPlanted.c:1218 in run_k1_lz4_block_decode` after 0.5 s |
| Apple clang `-fsanitize=fuzzer` | `ld: library '…/libclang_rt.fuzzer_osx.a' not found` |

The fuzzer has no Elixir-mode oracle (only crashes and UB), so it complements
the agreement properties rather than replacing them. Byproduct (*inference*,
from the C, not a bug): each of the checked `src` reads I read in
`lz4_block_decode/2` (`defk_get_u8(ctx, p_src, …)` at three indices; the other
two occurrences are copies in the other strip variant) sits right after the
kernel's own `if i >= n, raise …` guard, so the check is
redundant; planting its removal alone found nothing. That is a range fact from
an in-loop raising guard that ADR-0007 lists as a source.

## 6. Valgrind (Linux container: run in a podman arm64 Linux VM)

**Run in a podman arm64 Linux VM, not on macOS:** podman 5 `applehv`
machine on this Mac (8 vCPUs, 8 GiB, Fedora kernel 7.1.10 aarch64), container
Debian 13 (trixie) arm64. Same day, repo at `7e12538`, copied into the
container (read-only mount, then `tar` into `/work/defk`; the host repo was not
touched). The host was loaded as before, so every time below is provisional.

| Tool | Version |
|---|---|
| Valgrind | 3.24.0 (Debian package) |
| Erlang/OTP | 29.0.3 built from `otp_src_29.0.3.tar.gz` (the tarball above), plus `make -C erts/emulator valgrind` |
| Elixir | 1.20.2 (copied from `hexpm/elixir:1.20.2-erlang-29.0.3-debian-trixie-20260713-slim`) |
| C compilers | Debian clang 19.1.7, gcc 14.2.0; glibc 2.41 |

### Why not on the Mac

Homebrew's `valgrind` formula is Linux-only (above). The macOS fork
[LouisBrunner/valgrind-macos](https://github.com/LouisBrunner/valgrind-macos)
at `7877928` was tried here and did not build: its configure rejects the
default SDK (`checking for the Xcode SDK version... unsupported (27.0)`); with
an `xcrun` shim pinning the 26.5 SDK configure passes, but linking
`memcheck-arm64-darwin` fails with Apple `ld-27037.1`. The fork's issue #123
reports arm64 Valgrind taking down the whole system on macOS 15 (the
maintainer says macOS 26 works, about 3x slower than Linux). Not retried.
Upstream Valgrind supports arm64 Linux, which is what a podman machine on
Apple Silicon runs, so the container is the cheap way in.

### The container

`$V` below is the scratch directory (`scratchpad/valgrind`). The image
(`$V/ctx/Containerfile`, abridged):

```dockerfile
FROM docker.io/hexpm/elixir:1.20.2-erlang-29.0.3-debian-trixie-20260713-slim AS elixir
FROM docker.io/library/debian:trixie-20260713-slim
RUN apt-get install -y build-essential autoconf m4 libncurses-dev libssl-dev valgrind clang git curl procps bc time util-linux
COPY otp_src.tar.gz /tmp/
RUN tar xzf /tmp/otp_src.tar.gz -C /otp --strip-components=1
WORKDIR /otp
RUN ./configure --prefix=/usr/local --without-wx --without-javac --without-odbc --without-debugger --without-observer --without-et
RUN make -j8 && make install                  # 30 s: the tarball ships prebuilt .beam files (prebuilt.files)
RUN make -C erts/emulator valgrind -j8        # 15 s -> bin/aarch64-unknown-linux-gnu/beam.valgrind.smp, erl_child_setup.valgrind
COPY --from=elixir /usr/local/lib/elixir /usr/local/lib/elixir
RUN mix local.hex --force && mix local.rebar --force
```

Valgrind must be installed before the `valgrind` build, which includes
`<valgrind/memcheck.h>` ([Debugging NIFs and Port Drivers, Valgrind](https://www.erlang.org/doc/system/debugging.html#valgrind);
types are `opt debug lcnt valgrind asan gcov`,
[make/otp.mk.in L51](https://github.com/erlang/otp/blob/OTP-29.0.3/make/otp.mk.in#L51),
built with `make TYPE=$TYPE`, [HOWTO/INSTALL.md](https://github.com/erlang/otp/blob/OTP-29.0.3/HOWTO/INSTALL.md)).

**Running `mix` on it.** OTP's documented way is `$ERL_TOP/bin/cerl -valgrind`
(debugging guide; [HOWTO/DEVELOPMENT.md, cerl](https://github.com/erlang/otp/blob/OTP-29.0.3/HOWTO/DEVELOPMENT.md#cerl)),
but `cerl` starts `beam.valgrind.smp` itself, skipping `erlexec`
(`skip_erlexec=yes`, [cerl.src L267-L273](https://github.com/erlang/otp/blob/OTP-29.0.3/erts/etc/unix/cerl.src#L267-L273)),
so `mix`/`elixir` cannot go through it. `erl -emu_type valgrind` runs
`$BINDIR/beam.valgrind.smp` directly, not under Valgrind. What worked: copy the
two files into the installed `erts-17.0.3/bin` with the beam renamed
`beam.valgrind.smp.real`, and put a script under the old name
(`$V/spike/setup.sh`):

```sh
#!/bin/sh
exec taskset --cpu-list ${VG_CPU:-0} valgrind --tool=memcheck \
  --suppressions=/otp/erts/emulator/valgrind/suppress.standard \
  --show-possibly-lost=no --child-silent-after-fork=yes --trace-children=no \
  ${VG_LOG:+--log-file=$VG_LOG} $VALGRIND_MISC_FLAGS \
  /usr/local/lib/erlang/erts-17.0.3/bin/beam.valgrind.smp.real "$@"
```

Then `ERL_AFLAGS="-emu_type valgrind" mix test` runs the whole VM under
memcheck (`erlang:system_info(build_type)` is `valgrind`). `--trace-children=no`
keeps the C compiler (a port child) out of Valgrind; the flags and the
suppression file are the ones `cerl` passes
([cerl.src L396-L410](https://github.com/erlang/otp/blob/OTP-29.0.3/erts/etc/unix/cerl.src#L396-L410)).
The analysis flags used throughout: `--track-origins=yes --leak-check=full
--show-leak-kinds=definite --errors-for-leak-kinds=definite`.

**Pin it to one CPU.** Without `taskset`, `erl -emu_type valgrind -eval
'halt().'` did not finish in 10 minutes (8 schedulers), nor in 5 with
`+sbwt none +sbwtdcpu none +sbwtdio none`; with `+S 1:1` it took 5.6 s, and
with `taskset --cpu-list 3` and the default 8 schedulers 5.8 s. `cerl` does the
same: "We only let valgrind utilize one core with "taskset 1" as it can be very
slow on multiple cores" ([cerl.src L411-L426](https://github.com/erlang/otp/blob/OTP-29.0.3/erts/etc/unix/cerl.src#L411-L426)).
A side effect: ERTS then sees one CPU, so ExUnit ran with `max_cases: 2`
(natively 16).

### What the `valgrind` build changes

`TYPE=valgrind` compiles ERTS with `-DVALGRIND -DNO_JUMP_TABLE` and the debug
`CFLAGS` ([Makefile.in L161-L165](https://github.com/erlang/otp/blob/OTP-29.0.3/erts/emulator/Makefile.in#L161-L165)). Under `VALGRIND`:

- **ERTS's allocators are off by default** (`AU_ALLOC_DEFAULT_ENABLE` is 0,
  [erl_alloc.c L70-L74](https://github.com/erlang/otp/blob/OTP-29.0.3/erts/emulator/beam/erl_alloc.c#L70-L74)),
  so every binary is a `malloc` block Memcheck tracks, with no `+Mea min`;
  scheduler-specific pre-allocators are short-circuited too
  ([erl_alloc.h L614-L676](https://github.com/erlang/otp/blob/OTP-29.0.3/erts/emulator/beam/erl_alloc.h#L614-L676)).
- **`CHICKEN_PAD` is 0** ([erl_binary.h L246](https://github.com/erlang/otp/blob/OTP-29.0.3/erts/emulator/beam/erl_binary.h#L246)),
  so a 1-byte overrun of an `enif_alloc_binary` buffer lands in Valgrind's
  redzone, as with the `asan` emulator.
- **The JIT uses single-mapped executable memory** (`erts_jit_single_map = 1`,
  [beam_jit_main.cpp L186-L187](https://github.com/erlang/otp/blob/OTP-29.0.3/erts/emulator/beam/jit/beam_jit_main.cpp#L186-L187))
  and **native Erlang stacks and frame pointers are off**, because "`valgrind`
  can't handle stack switching" ([erl_vm.h L32-L37](https://github.com/erlang/otp/blob/OTP-29.0.3/erts/emulator/beam/erl_vm.h#L32-L37)).
  The JIT stays on (`emu_flavor` is `jit`). On arm64 no `--smc-check` flag is
  needed: "a correct program must take explicit action to reestablish D-I
  cache coherence following code modification. Valgrind observes and honours
  such actions" ([Valgrind manual, --smc-check](https://valgrind.org/docs/manual/manual-core.html#opt.smc-check));
  on x86-64 the default `all-non-file` covers JIT code in anonymous mappings.
- Smaller things: heap fragments sized exactly
  ([erl_vm.h L217-L221](https://github.com/erlang/otp/blob/OTP-29.0.3/erts/emulator/beam/erl_vm.h#L217-L221)),
  `ERTS_UNDEF` leaves variables undefined so Memcheck still sees them
  ([sys.h L272-L282](https://github.com/erlang/otp/blob/OTP-29.0.3/erts/emulator/beam/sys.h#L272-L282)),
  mutexes instead of spinlocks ([ethread.h L464-L465](https://github.com/erlang/otp/blob/OTP-29.0.3/erts/include/internal/ethread.h#L464-L465)),
  and `erlang:system_info(build_type)` returns `valgrind`.

**JIT frames in reports** show as `???`. `cerl` runs the beam with `-JPperf
true` and `ERL_SYM_MAP_FILE`, then rewrites the log with
[scripts/valgrind_beamasm_update.escript](https://github.com/erlang/otp/blob/OTP-29.0.3/scripts/valgrind_beamasm_update.escript)
([cerl.src L427-L436](https://github.com/erlang/otp/blob/OTP-29.0.3/erts/etc/unix/cerl.src#L427-L436)).
Done by hand (`ERL_SYM_MAP_FILE=… ERL_AFLAGS="-emu_type valgrind +JPperf true"`,
then the escript on the log) it replaced all 35 `???` frames, but only with
JIT shared fragments (`$global::call_nif_shared+37`,
`$global::i_bif_guard_shared+1F`): the unwinder stops at the first JIT frame,
so the Elixir function that used a bad value is not named. The C frames
(kernel, runtime header, ERTS) carry the information that matters for defk.

### A defk bug the container found first: clang + `-fno-builtin` + glibc `sigsetjmp`

Before any Valgrind run, the unmodified `decode16/1` (below) **crashed the
node natively on its raise path** (`Bus error (core dumped)`), and so did
`mix test` with `CC=clang` (rc 135 after 45 tests, at the first raise). With
`CC=gcc` the whole suite passed (1,646 tests, 33.2 s). Cause: glibc declares
`extern int __sigsetjmp (...) __THROWNL;` without `returns_twice`
(`/usr/include/setjmp.h` L41; `sigsetjmp` is a macro for it, L74). Clang
gives a call `returns_twice` through its library builtins, and defk's
`-fno-builtin` turns those off. Measured on a 4-line `guard()` shaped like
`guard_k*` (`if (sigsetjmp(jb, 0)) return -1; return work();`), clang `-O3`
LLVM IR:

```text
Linux clang 19:              %1 = call i32 @__sigsetjmp(...)       ; Function Attrs: nounwind returns_twice
Linux clang 19 -fno-builtin: %1 = tail call i32 @__sigsetjmp(...)  ; no returns_twice
macOS Apple clang 21, with and without -fno-builtin: call i32 @sigsetjmp(...) ; returns_twice
```

Without the attribute, `return work();` becomes a tail call. The `-O3`
arm64 code of `guard` with `-fno-builtin` ends `ldp x29, x30, [sp], #16; b work`
(it pops its own frame, saved return address included, and jumps), where the
default build has `bl work; ldp x29, x30, [sp], #16; ret`. The kernel's frame
then overwrites the slot `guard` saved its return address in, and when
`defk_fail`'s `siglongjmp` resumes `guard` its `ret` goes to garbage: under
Valgrind the clang build's raise was `Jump to the invalid address stated on
the next line at 0x2: ???`. macOS's header has no attribute either (`int sigsetjmp(sigjmp_buf, int);`,
SDK `setjmp.h` L90), but Apple clang keeps `returns_twice` on `sigsetjmp`
under `-fno-builtin` (*inference*: it recognises that name, not glibc's
`__sigsetjmp`), which is why the Mac never showed it. GCC was fine (*inference*:
GCC recognises setjmp-like functions by name). Confirmed by build flags:

| `CC=clang` plus | `decode16` raise path |
|---|---|
| defk's flags as-is | Bus error |
| `-fbuiltin` (after `-fno-builtin`) | raises `ArgumentError`, correct |
| `-O1` | Bus error |
| `-include rt2.h`, which redeclares `extern int __sigsetjmp(struct __jmp_buf_tag [1], int) __attribute__((returns_twice));` | raises `ArgumentError`, correct |

The fix belongs in
`priv/defk_runtime.h`: the redeclaration under `#if defined(__GLIBC__)` (or
`-fno-builtin` narrowed to the functions it is for). Everything below used
clang with that `-include` (the closest match to the Mac's clang).

### Planted bugs

`encode16/1` and `decode16/1` copied verbatim from `examples/codecs.exs` into
a script (`$V/spike/hex.exs`): encode 100 bytes (a refc binary from
`:binary.copy`), compare with `Base.encode16`, decode it back, then call
`decode16` three times on input with a bad last pair (it raises "alloc/2:
negative length -1" after its `out` is allocated). `encode16`'s `out` is an
**unzeroed** alloc (`defk_alloc_raw_u8` with no zero strip: the loop writes
`out[2 * i]` and `out[2 * i + 1]` for every `i`); `decode16`'s is zeroed. A `CC`
wrapper (`$V/spike/cc-plant`) applies `$PLANT` to a copy of the generated C, as
on the Mac, and puts a hash of the plant into the first line of `cc --version`
so the build cache cannot reuse a library across plants. Each run:

```bash
PLANT='…' MIX_ENV=test CC=$V/spike/cc-plant REAL_CC=clang EXTRA_CFLAGS="-g -include rt2.h" \
VALGRIND_MISC_FLAGS="--track-origins=yes --leak-check=full --show-leak-kinds=definite --errors-for-leak-kinds=definite" \
ERL_AFLAGS="-emu_type valgrind" mix run --no-start hex.exs
```

| Plant (`sed` on the C) | `valgrind` emulator | stock `beam.smp` under Valgrind | stock + `+Mea min` | Mac (section 1-2) |
|---|---|---|---|---|
| none | **0 errors**, 0 bytes definitely lost | 0 | 0 | — |
| (a) read past input: `(p_s).data[v_i_3]` → `[v_i_3 + 1]` | **`Invalid read of size 1` at `run_k0_encode16 (….planted.c:70)`, "0 bytes after a block of size 132 alloc'd" by `erts_bin_nrml_alloc` ← `binary_copy_2`** | not detected | detected (same report) | ASan: detected with `+Mea min` or the `asan` emulator |
| (a′) same, input a sub-binary | not detected | — | — | ASan: not detected; `DEFK_ELIDED` trap: detected |
| (b) write past an unzeroed alloc: `out[2 * i + 1]` → `out[2 * i + 2]` | **`Invalid write of size 1` at `….planted.c:72`, "0 bytes after a block of size 232 alloc'd" by `enif_alloc_binary` ← `defk_own_raw (defk_runtime.h:259)` ← `run_k0_encode16 (….planted.c:63)`**; then the unwritten odd bytes, as in (c) | **not detected** as a write (ERTS's 7-byte `CHICKEN_PAD`); the uninitialised bytes still reported | ASan stock: missed 1 byte unless the tail is poisoned; `asan` emulator: detected |
| (c) element never written (odd bytes of `out` left unwritten; Elixir compares the result) | **`Conditional jump or move depends on uninitialised value(s)` at `bcmp` ← `erts_cmp_bits` ← `seqeq_2`, "Uninitialised value was created by a heap allocation" at `enif_alloc_binary` ← `defk_own_raw` ← `defk_alloc_raw_u8` ← `run_k0_encode16 (….planted.c:63)`**; printing the result adds `Syscall param writev(vector[0]) points to uninitialised byte(s)` | not detected | detected | ASan: no; MallocScribble + `+Mea min`: unwritten bytes become `0xAA`, which only an agreement test turns into a failure |
| (c′) element read in the kernel before it is written (`out[2 * i + 1]` used as a table index before its write) | **`Use of uninitialised value of size 8` at `run_k0_encode16 (….planted.c:71)`**, origin the same `defk_alloc_raw_u8` call; 100 errors (one per iteration) | — | — | ASan: no |
| (d) leak on the raise path: `defk_finish(&local.ctx)` → `if (r != DEFK_ERR) defk_finish(…)` in `nif_k1_decode16` | **`972 (480 direct, 492 indirect) bytes in 3 blocks are definitely lost`**, allocated by `enif_realloc` ← `defk_own_raw (defk_runtime.h:253)` ← `run_k1_decode16` (the owned table, 160 bytes per raise, holding the binaries) | not detected | detected (1,014 bytes) | `leaks` with `+Mea min`, `MallocStackLogging` and a re-signed beam: detected |

Each line number was checked against the planted copy (`….planted.c:70` is
`v_b_5 = ((int64_t)(p_s).data[v_i_3 + 1]);`). Three things to read from the
table:

- **The uninitialised read is the case only Valgrind turns into a report
  with no oracle.** In (c) the agreement check failed too (`ok=false`) and the
  bytes that came back were old ERTS heap contents (fragments of paths and
  atom names in the `decode16` error message: memory disclosure, not just a
  wrong answer). But Memcheck "does not complain" about copying junk around,
  only when a use "might affect your program's externally-visible behaviour"
  ([Memcheck manual §4.2.2](https://valgrind.org/docs/manual/mc-manual.html#mc-manual.uninitvals)):
  if no Erlang code compares, hashes or prints the result, nothing is reported.
  The test suite's `assert_agrees` compares every result, so under the suite
  that use always happens. With `--track-origins=yes` the report names the
  `alloc/2` call and its line in the generated C, which is what defk-i5r's
  soundness question needs.
- **The `valgrind` emulator is worth the 15-second build.** Stock `beam.smp`
  under Valgrind sees nothing (binaries live in ERTS carriers); with
  `+Mea min` it sees most things but misses the 1-byte write past an
  `alloc/2` output, as ASan did, because of `CHICKEN_PAD`. The stock JIT ran
  under Valgrind without trouble (the dual-mapped code memory did not matter
  here).
- **Sub-binary over-reads stay invisible**, to Valgrind as to ASan: the bytes
  belong to the parent's live block. Only `DEFK_ELIDED` (section 4) sees them.

### Cost

| Run (in the container) | Native | Under Valgrind | Ratio |
|---|---|---|---|
| `erl -noshell -eval 'halt().'` | 0.08 s | 4.0 s | 50x |
| `mix run hex.exs` (spike, unplanted, no logging flags) | 0.36-0.42 s | 13.3-13.9 s | ~35x |
| `mix test` on `alloc_unzeroed_test.exs`, `raise_cleanup_test.exs`, `raise_test.exs` (107 tests, 87 properties), ExUnit "Finished in" | 3.9 s (8 CPUs), 4.4 s (one CPU) | 252.7 s | 57x against one CPU |
| `mix test`, all 75 files one `mix test` each, ExUnit "Finished in" summed over the 74 that finished (native: each file pinned to one CPU) | 63.1 s | 2,939.5 s | 47x (34-81x per file) |
| same, wall time including `mix` start and compiling each test file under Valgrind (~33 s a file) | — | 91 min of one-core runs (two shards on two cores: ~46 min) | — |
| whole suite natively, for reference | 33.1 s on 8 CPUs, 66.8 s pinned to one | — | — |

Memory: the Valgrind VM of the partial `agreement_test` rerun below sat at 0.64 GB RSS after 20 minutes; the `make -j8` peak was 409 MB. The slowest files under Valgrind were `language_doc_examples_test` (663 s), `elixir_mode_test` (332 s) and `alloc_unzeroed_test` (259 s).

### The test suite under Valgrind

A single `mix test` under Valgrind was OOM-killed after 12 minutes (below), so
each file ran in its own `mix test` (`$V/spike/perfile.sh`, two shards on
CPUs 0 and 1, `--timeout 3600000`).

**Result: 74 of 75 files completed; 1,615 of 1,618 tests and properties
passed; zero Memcheck errors in defk code.** Over 90 VM logs (some tests
start child VMs) there was no invalid read or write, no uninitialised use and
no `Jump`; only OTP's `suppress.standard` was used, and it matched leak
records at exit only (about 150-170 KB reported "suppressed"), no errors.
`--show-possibly-lost=no` (as `cerl`) hides ERTS's ~300-400 KB of "possibly
lost" blocks at exit. In particular `alloc_unzeroed_test.exs` (96 tests, 87
properties: every unzeroed-alloc shape and its brute-force shape test, each
result compared with Elixir mode) ran clean, which is evidence that no
unzeroed element reaches Elixir unwritten on those inputs.

The three failures are artefacts, read one by one: `:erlang.memory(:binary)`
raises `notsup` with the allocators off (`raise_cleanup_test.exs:54`,
`bitstring_test.exs:479`, the same two as under ASan), and
`resume_test.exs:292` has `@tag timeout: 10_000`, too short at 50x.

**One "definitely lost" report, expected:** `frame_tag_test.exs`,
`151,232 (3,200 direct, 148,032 indirect) bytes in 20 blocks are definitely
lost`, allocated by `enif_realloc` ← `defk_own_raw (defk_runtime.h:253)` ←
`defk_alloc_raw_i64` ← `run_k0_sum`. The test "a frame with a foreign tag
fails cleanly…" stamps 20 promoted frames with a wrong layout tag
(`__defk_corrupt_tags__`), and `defk_frame_dtor` deliberately frees nothing
for a foreign frame: "The leak (the binaries it owned) is accepted; a crash
is not" (`priv/defk_runtime.h` L184-L187, defk-ls8). 20 owned tables of 160
bytes are the 3,200 direct bytes, the 8 KiB `alloc(i64, 1024)` buffers the
indirect ones. So it is the designed behaviour, and the report shows
Valgrind sees exactly what the destructor abandons; a CI job needs a
suppression for `defk_frame_dtor`'s foreign path (or this test excluded).

**`agreement_test.exs` did not complete under Valgrind.** Whole, it was
OOM-killed twice (memcheck at 7.5 GB RSS in the 8 GiB VM, after Valgrind
reported `set address range perms: large range [0x59c8b040, 0x159c8b060)
(undefined)`, a 4 GiB block). The cause is the test, not Valgrind: its
hostile-size properties make Elixir mode build `<<0::size(n * esz)-unit(8)>>`
for any size under `@no_alloc_bytes` (`lib/defk/elixir_mode/ops.ex` L136-L139),
and natively in the same container `mix test test/agreement_test.exs --seed 5`
aborted the VM with `binary_alloc: Cannot allocate 8589934592 bytes of memory
(of type "binary")` at `Blur.Kernels.gray_blur_band agrees with Elixir mode`
(other seeds were OOM-killed; most seeds pass, as did the full native runs).
So the suite is seed-dependently fatal on an 8 GiB Linux host, which is a
defk-a1p finding. Rerun without the Blur block (`test/agreement_test.exs:27:194:205:221`)
it had 0 Memcheck errors after 21 minutes but did not complete: line filters
also select the `:deep` properties the default run excludes, two of which
hit their 600 s timeouts. Stopped there.

### MemorySanitizer: assessed, not built

MSan finds the same uninitialised reads at roughly the cost of a sanitizer
rather than an emulator, but it "requires that all program code is
instrumented", libraries included ([MSan](https://clang.llvm.org/docs/MemorySanitizer.html)).
For defk inside the BEAM that means, *inference* from the OTP source: OTP has
no `msan` type ([make/otp.mk.in L51](https://github.com/erlang/otp/blob/OTP-29.0.3/make/otp.mk.in#L51)),
so ERTS would be configured by hand with `CC=clang CFLAGS=-fsanitize=memory`
and its C++ JIT linked against an MSan-built libc++; the JIT's own machine code
is not instrumented, so every byte it writes (process heaps, binaries built in
Erlang) would carry no shadow and look uninitialised to instrumented C, which
leaves the `emu` flavor (the interpreter, plain C) as the only workable one;
and OpenSSL (`crypto`, which `mix` needs) would need an instrumented build or
interceptors. Valgrind already reports this class end to end in the real JIT
VM, so MSan would only buy speed; not worth building until a Valgrind run is
too slow to be routine.

## What this means for defk

Each proposal names the experiment it rests on.

1. **Fix `defk_slice_init`'s `int64_t waiting` → `ErlNifSInt64`**
   (`priv/defk_runtime.h:1713`). Section 3: it blocks every build with
   upstream clang 22/23 and is the only real finding of the warning sweep.
   Consider `-Werror=incompatible-pointer-types` in `@cflags` so the next one
   fails here, not on someone's newer compiler.
2. **A sanitizer build mode in `Defk.Build`**, e.g. `DEFK_SANITIZE=address|undefined|check`
   or a `config :defk, sanitize: …`, that appends the flags, **goes into the
   cache key** and the library file name, and is refused (or loudly reported)
   by `Defk.Bench.report/1`. Sections 1 and 3: sanitizer flags change code
   generation (vectorisation lost under UBSan), and this session reused an
   ASan library for a non-ASan run twice because a `CC` wrapper's flags are not
   in the key; once it replaced `_build/test/lib/defk/ebin`'s library. The
   version probe (`cc --version` with stderr merged) also put Guard Malloc's
   banner and PID into the key under `DYLD_INSERT_LIBRARIES`; read stdout only.
3. **In that mode, poison the `CHICKEN_PAD` tail** in `defk_own_raw` (the
   `DEFK_POISON_TAIL` snippet in section 1) so the stock beam with `+Mea min`
   catches 1-byte overruns of `alloc/2` outputs. Section 1: verified for
   lengths 100, 101 and 104 and over the whole suite.
4. **A `mix test` recipe for the `asan` emulator**, documented in
   `docs/beam-nifs.md` §5 (which already cites the OTP debugging page):
   `KERL_RELEASE_TARGET="opt asan"` for asdf users, or the 1.5-minute
   `make -C erts/emulator asan`. Tag the four artefact tests
   (`:erlang.memory(:binary)`, vectorisation, `.dSYM`) so the run is green.
   Section 1: whole suite clean in 144 s.
5. **Emit `DEFK_ELIDED(i, len)` around every index whose check was elided**,
   the plain index in normal builds (byte-identical object code; the
   `mix dump_c` gate would see the macro, so add it in one step), a trap in the
   `check` mode, `__CPROVER_assert` under CBMC. It is the only tool here that
   sees a sub-binary over-read, and it checks the compiler's proof at the
   granularity the proof was made. The same pattern fits the other elisions:
   an assertion at strip end that a flagged strip's deferred test covers what
   it suppressed (defk-zj8, defk-5qk) and, for unzeroed allocs, a
   "every element written" counter in the check mode (defk-i5r).
6. **A CI job over `mix dump_c`** that, for the decoders and any kernel with
   a `# verify:` tag, builds the CBMC harness from the kernel's frame type and
   `run_` name (both appear in the C) and checks the `DEFK_ELIDED` assertions
   up to a small N. Section 4: seconds to minutes per simple kernel at
   N = 8-16 bytes with `--slice-formula`; the nested-loop decoders did not
   finish, so start with one `--property` per elided assertion and measure
   before promising coverage of them. Generating the harness is mechanical: one
   `enif_inspect_binary` stub per array parameter, `enif_get_long` per scalar.
7. **A libFuzzer target per decoder** next to its catalog entry, reusing one
   shared `erl_nif` shim. Section 5: ~87k inputs/s under ASan+UBSan, planted
   bug found in 0.5 s. It needs item 1 (Homebrew clang).
8. **Leak checks with `leaks`** for the raise/yield cleanup tests
   (defk-c1e's territory), where `:erlang.memory(:binary)` is unavailable
   under `+Mea min`. Section 2: exact on the planted leak, silent on clean code.
9. **Declare `__sigsetjmp` `returns_twice` in `priv/defk_runtime.h` on
   glibc** (`#if defined(__GLIBC__)`, the one-line redeclaration from
   section 6), or narrow `-fno-builtin`, and add `CC=clang` on Linux to
   defk-a1p's matrix. Section 6: without it every clang-built kernel that
   raises crashes the node on Linux; gcc and Apple clang are unaffected.
10. **A Valgrind job for defk-a1p, from a `Containerfile` in the repo**
   (section 6's, about 15 lines: Debian, distro `valgrind`, OTP from source
   plus `make -C erts/emulator valgrind`, the `beam.valgrind.smp` wrapper
   pinned with `taskset`). Run it over the kernel-heavy files (the
   `alloc_*`, `array_*`, `raise_*`, `resume`, `value_semantics` and
   `word_loads` tests) on every change to the alloc analysis, strips or
   cleanup paths, and over the whole suite nightly; fail on any
   `ERROR SUMMARY` above 0 and on definite leaks. Tag the
   `:erlang.memory(:binary)` tests (as for ASan) and keep agreement_test's
   gigabyte-size property cases out of it (Elixir mode builds multi-GiB binaries for them; natively one seed in eight aborted an 8 GiB Linux VM, section 6). It is the
   uninitialised-read oracle defk-i5r's extensions need: run their brute-force
   shape test under it. The same container is a start on defk-a1p's Linux run
   (the native suite passed there, item 9 aside).
11. **Elsewhere on Linux (defk-a1p):** MSan only if Valgrind becomes too slow
   to be routine (section 6: it needs an instrumented ERTS, probably the `emu`
   flavor); keep `rr` for the first real kernel fault; GCC's `-fanalyzer` only
   if the harness from item 6 is reused, since the bare C has no array
   extents.
