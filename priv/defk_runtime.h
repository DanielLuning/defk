/*
 * defk runtime. Included once by every generated kernel NIF.
 *
 * Responsibilities:
 *   - packed array views over BEAM binaries (zero-copy in, owned binaries out)
 *   - checked arithmetic / bounds checks that raise Elixir exceptions
 *   - timeslice accounting so long kernels yield back to the scheduler
 *   - the frame resource that holds a suspended kernel between yields
 */
#ifndef DEFK_RUNTIME_H
#define DEFK_RUNTIME_H

/* before any system header: dl_iterate_phdr and REG_RIP (fault containment) */
#if defined(__linux__) && !defined(_GNU_SOURCE)
#define _GNU_SOURCE 1
#endif

#include <erl_nif.h>
#include <dlfcn.h>
#include <signal.h>
#include <inttypes.h>
#include <limits.h>
#include <math.h>
#include <setjmp.h>
#include <stdarg.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

/* glibc's <setjmp.h> declares __sigsetjmp without returns_twice, and clang with
 * -fno-builtin does not recognise it either: guard_k*'s `return run_k*()` after
 * sigsetjmp then becomes a tail call, and a raise's siglongjmp lands in a dead
 * frame (Bus error on the first raise). Redeclaring it restores the attribute.
 * gcc and Apple clang are unaffected. */
#if defined(__GLIBC__)
extern int __sigsetjmp(struct __jmp_buf_tag __env[1], int __savemask) __attribute__((returns_twice));
#endif

#define DEFK_DONE 0
#define DEFK_YIELD 1
#define DEFK_ERR 2

#define DEFK_E_ARG 1
#define DEFK_E_ARITH 2
#define DEFK_E_OOB 3
#define DEFK_E_CASE_I64 4  /* CaseClauseError; the term is err_index */
#define DEFK_E_CASE_BOOL 5
#define DEFK_E_RESUME 6    /* a resume missed its safepoint (a defk bug); RuntimeError */
#define DEFK_E_RUNTIME 7   /* RuntimeError: a kernel's raise "msg" */
#define DEFK_E_FUN_CLAUSE 8 /* FunctionClauseError: module\0function in umsg (module ulen bytes), arity in err_index */
#define DEFK_E_FAULT 9     /* RuntimeError: a hardware fault inside kernel native code (a defk bug), contained */
#define DEFK_E_USER 16     /* flag on a kind: a kernel's own raise, message in umsg/ulen */

#define DEFK_LIKELY(x) __builtin_expect(!!(x), 1)
#define DEFK_UNLIKELY(x) __builtin_expect(!!(x), 0)

/* ---- packed arrays ------------------------------------------------------ */

typedef struct { double *data; int64_t len; } defk_arr_f64;
typedef struct { int64_t *data; int64_t len; } defk_arr_i64;
typedef struct { uint8_t *data; int64_t len; } defk_arr_u8;
typedef struct { uint64_t *data; int64_t len; } defk_arr_u64;
/* narrow element types: only inside arrays; a read widens to
   int64_t / double, a write is range-checked (defk_to_i16 ... defk_to_f32) */
typedef struct { int16_t *data; int64_t len; } defk_arr_i16;
typedef struct { int32_t *data; int64_t len; } defk_arr_i32;
typedef struct { float *data; int64_t len; } defk_arr_f32;

/* ---- per-call context (first member of every frame) --------------------- */

/*
 * Frame layout tag, defence in depth. Frames of one library image only ever
 * meet that image's own code (a resource type per image: "Hot code upgrade"),
 * so a mismatch should be impossible. If that invariant ever breaks (a shared
 * type name, a separate runtime NIF), the destructor and the step functions
 * must not read a foreign layout. defk_promote stamps every resource frame
 * with DEFK_LAYOUT_TAG (a hash of this header, emitted by the compiler as
 * DEFK_HEADER_HASH, mixed with sizeof(defk_ctx)) and its own struct size.
 * The tag and the size are the first two members of defk_ctx, at fixed
 * offsets 0 and 8, so even a foreign layout can be asked for them.
 */
#ifndef DEFK_HEADER_HASH
#define DEFK_HEADER_HASH 0
#endif
#define DEFK_LAYOUT_TAG ((uint64_t)(DEFK_HEADER_HASH) ^ ((uint64_t)sizeof(defk_ctx) * 0x9E3779B97F4A7C15ULL))

typedef struct {
  uint64_t layout_tag; /* DEFK_LAYOUT_TAG, set when the frame becomes a resource; keep first */
  uint64_t frame_size; /* sizeof the kernel's frame struct, likewise; keep second */
  sigjmp_buf jb; /* sigsetjmp(jb, 0): plain setjmp saves the signal mask on macOS = a syscall per call */
  int err;
  int64_t err_index; /* for out-of-bounds */
  char msg[200];
  const char *umsg; /* a kernel's raise: its literal message (static), ulen bytes */
  size_t ulen;
  ErlNifBinary *owned; /* binaries we allocated (outputs, aligned copies) */
  int nowned, cap;
  uint64_t owned_bytes; /* bytes of the live binaries in owned, at most defk_max_owned */
  int finished;
  int is_resource;
  /* this call's slice: slice_us until short_left us of kernel
     time have run (0: no limit), then DEFK_SLICE_US; see defk_slice_init */
  int64_t slice_us;
  int64_t short_left;
} defk_ctx;

static ErlNifResourceType *defk_frame_rt;
static _Atomic long defk_stat_frames_live = 0;
static _Atomic long defk_stat_promotions = 0;
static _Atomic long defk_stat_yields = 0;
/* testing: yield at every clock read, so every safepoint's resume path runs */
static _Atomic int defk_force_yields = 0;
/* testing: stamp promoted frames with a wrong tag, to exercise the mismatch path */
static _Atomic int defk_corrupt_tags = 0;

__attribute__((noreturn, cold, format(printf, 3, 4))) static void
defk_fail(defk_ctx *ctx, int kind, const char *fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  vsnprintf(ctx->msg, sizeof ctx->msg, fmt, ap);
  va_end(ap);
  ctx->err = kind;
  siglongjmp(ctx->jb, 1);
}

/* raise Module, "msg" in a kernel: the literal is static, so it is raised
 * whole (no length limit, NUL bytes kept) rather than copied into msg */
__attribute__((noreturn, cold, unused)) static void
defk_user_raise(defk_ctx *ctx, int kind, const char *msg, size_t len) {
  ctx->umsg = msg;
  ctx->ulen = len;
  ctx->err = kind | DEFK_E_USER;
  siglongjmp(ctx->jb, 1);
}

__attribute__((noreturn, cold)) static void defk_oob(defk_ctx *ctx, int64_t i, int64_t len) {
  ctx->err_index = i;
  defk_fail(ctx, DEFK_E_OOB, "index %lld out of bounds for array of length %lld",
            (long long)i, (long long)len);
}

/*
 * A range loop first..stop//step whose stop is within one step of the i64
 * limit (step != 0). Raise if its last element is too: stepping past it would
 * overflow the loop counter (a limit, see range_limit in the compiler).
 */
__attribute__((cold, unused)) static void defk_range_limit(defk_ctx *ctx, int64_t first,
                                                           int64_t stop, int64_t step) {
  if (step > 0 ? first > stop : first < stop) return; /* empty */
  uint64_t mag = step > 0 ? (uint64_t)step : -(uint64_t)step;
  uint64_t span = step > 0 ? (uint64_t)stop - (uint64_t)first : (uint64_t)first - (uint64_t)stop;
  uint64_t back = span / mag * mag; /* <= span: no wrap */
  int64_t last = (int64_t)(step > 0 ? (uint64_t)first + back : (uint64_t)first - back);
  if (step > 0 ? last > INT64_MAX - step : last < INT64_MIN - step)
    defk_fail(ctx, DEFK_E_ARITH,
              "range element %lld is within one step of the i64 limit (stepping past it overflows)",
              (long long)last);
}

/* a `case` with no matching clause: CaseClauseError, like Elixir */
__attribute__((noreturn, cold)) static void defk_no_clause(defk_ctx *ctx, int is_bool, int64_t v) {
  ctx->err_index = v;
  ctx->msg[0] = 0;
  ctx->err = is_bool ? DEFK_E_CASE_BOOL : DEFK_E_CASE_I64;
  siglongjmp(ctx->jb, 1);
}

/* a multi-clause kernel with no matching clause: FunctionClauseError, like
 * Elixir. `mod_fun` is the static "Elixir.Mod\0name", `mod_len` the length
 * of the module part. */
__attribute__((noreturn, cold, unused)) static void
defk_no_fun_clause(defk_ctx *ctx, const char *mod_fun, size_t mod_len, int64_t arity) {
  ctx->umsg = mod_fun;
  ctx->ulen = mod_len;
  ctx->err_index = arity;
  ctx->msg[0] = 0;
  ctx->err = DEFK_E_FUN_CLAUSE;
  siglongjmp(ctx->jb, 1);
}

static void defk_release_owned(defk_ctx *ctx) {
  for (int i = 0; i < ctx->nowned; i++)
    if (ctx->owned[i].data) enif_release_binary(&ctx->owned[i]);
  if (ctx->owned) enif_free(ctx->owned);
  ctx->owned = NULL;
  ctx->nowned = ctx->cap = 0;
}

static void defk_finish(defk_ctx *ctx) {
  if (!ctx->finished) {
    defk_release_owned(ctx);
    ctx->finished = 1;
  }
}

static void defk_frame_dtor(ErlNifEnv *env, void *obj) {
  (void)env;
  defk_ctx *ctx = (defk_ctx *)obj;
  /* A foreign layout: ctx->owned and ctx->finished are not where
     this code expects them, so neither is safe to touch. Free nothing and do
     not touch the frames_live counter, which a foreign frame was never counted
     in. The leak (the binaries it owned) is accepted; a crash is not. */
  if (DEFK_UNLIKELY(ctx->layout_tag != DEFK_LAYOUT_TAG)) return;
  defk_finish(ctx); /* process died mid-kernel: free what it allocated */
  atomic_fetch_sub(&defk_stat_frames_live, 1);
}

/*
 * The budget for a call's owned binaries. Every alloc/2, every
 * value-semantics copy, every bitstring accumulator buffer and every aligned
 * copy of an input is a slot in ctx->owned and lives until the kernel returns,
 * so an alloc or a copy in a loop body keeps one buffer per iteration. On an
 * OS that overcommits, the node is OOM-killed long before enif_alloc_binary
 * fails (seen: SIGKILL at ~1.6 GB of 4 MB copies), which breaks the
 * runtime contract. So a call raises ArgumentError "out of memory" once its
 * live owned bytes would pass defk_max_owned.
 *
 * `use Defk, max_owned_bytes: n` compiles DEFK_MAX_OWNED in. The default is half of
 * physical memory, read once when the library loads: a single call may then
 * build any result that fits comfortably in RAM, while a runaway loop raises
 * before it takes the machine's memory (the BEAM and the OS keep the other
 * half). A fixed default would be too small on large servers or too large on
 * small machines. sysconf cannot see a container's cgroup limit; such a
 * deployment sets max_owned_bytes. Without a physical memory size the default is
 * DEFK_OWNED_FALLBACK (4 GiB).
 *
 * The check is one compare and one add per allocation, never per element.
 * Elixir mode applies the same budget, with the same message, to the bytes
 * of the call's alloc/2 calls (Defk.ElixirMode.Ops.alloc/2), so a
 * size no host could hold raises there too instead of aborting the VM.
 */
#define DEFK_OWNED_FALLBACK ((uint64_t)1 << 32)
static uint64_t defk_max_owned = DEFK_OWNED_FALLBACK;

static void defk_max_owned_init(void) {
#ifdef DEFK_MAX_OWNED
  defk_max_owned = (uint64_t)(DEFK_MAX_OWNED);
#else
  long pages = sysconf(_SC_PHYS_PAGES), page = sysconf(_SC_PAGESIZE);
  defk_max_owned = pages > 0 && page > 0 ? (uint64_t)pages * (uint64_t)page / 2 : DEFK_OWNED_FALLBACK;
#endif
}

/* A request this large no platform's allocator serves; Elixir mode raises
   the allocator's "out of memory (allocating N bytes)" for it without trying
   (Defk.ElixirMode.Ops.alloc/2), so the budget leaves that message alone. */
#define DEFK_NO_ALLOC_BYTES ((uint64_t)1 << 47)

__attribute__((noreturn, cold)) static void defk_over_budget(defk_ctx *ctx, size_t bytes) {
  if ((uint64_t)bytes >= DEFK_NO_ALLOC_BYTES)
    defk_fail(ctx, DEFK_E_ARG, "out of memory (allocating %zu bytes)", bytes);
  defk_fail(ctx, DEFK_E_ARG,
            "out of memory (allocating %zu bytes would take this call's buffers past max_owned_bytes, %llu bytes)",
            bytes, (unsigned long long)defk_max_owned);
}

/* raise unless `bytes` more fit in the budget (owned_bytes <= defk_max_owned) */
static inline void defk_owned_check(defk_ctx *ctx, size_t bytes) {
  if (DEFK_UNLIKELY((uint64_t)bytes > defk_max_owned - ctx->owned_bytes))
    defk_over_budget(ctx, bytes);
}

/*
 * The sanitizer build mode's `address` (DEFK_SANITIZE=address):
 * ERTS allocates every enif_alloc_binary buffer with CHICKEN_PAD
 * (sizeof(void *) - 1) bytes of slack after it "to counter buggy drivers"
 * (erl_binary.h), so under ASan with the stock emulator and +Mea min a write
 * or read up to 7 bytes past an alloc/2 result is not reported. Poison that
 * slack: from the end of the binary's data to the end of the malloc chunk
 * that holds it (ref_bin, the Binary, is that chunk's start). Only when ASan's
 * allocator owns the chunk: with ERTS's own allocators (no +Mea min) the
 * memory is reused without ASan unpoisoning it, and OTP's asan emulator has
 * no slack (the region is then empty). docs/research/c-verification-macos.md
 * §1. A normal build compiles DEFK_POISON_SLACK to nothing.
 */
#ifdef DEFK_SANITIZE_ADDRESS
/* gcc ships no allocator_interface.h, but its libasan exports the two
 * functions; the declarations are compiler-rt's */
#if __has_include(<sanitizer/allocator_interface.h>)
#include <sanitizer/allocator_interface.h>
#else
int __sanitizer_get_ownership(const volatile void *p);
size_t __sanitizer_get_allocated_size(const volatile void *p);
#endif
#include <sanitizer/asan_interface.h>
static void defk_poison_slack(const ErlNifBinary *b) {
  const char *chunk = (const char *)b->ref_bin;
  if (!chunk || !__sanitizer_get_ownership(chunk)) return;
  const char *end = chunk + __sanitizer_get_allocated_size(chunk);
  const char *tail = (const char *)b->data + b->size;
  if (tail > chunk && tail < end) ASAN_POISON_MEMORY_REGION(tail, (size_t)(end - tail));
}
#define DEFK_POISON_SLACK(b) defk_poison_slack(b)
#else
#define DEFK_POISON_SLACK(b) ((void)0)
#endif

/* Owned binary: off-heap, stable address across yields and GC; uninitialised. */
static int defk_own_raw(defk_ctx *ctx, size_t bytes) {
  defk_owned_check(ctx, bytes);
  if (ctx->nowned == ctx->cap) {
    /* one slot per alloc/2 call, so a loop can grow the table without bound:
       a failed grow raises and keeps the old table, whose binaries are freed */
    if (ctx->cap > INT_MAX / 2) defk_fail(ctx, DEFK_E_ARG, "out of memory");
    int ncap = ctx->cap ? ctx->cap * 2 : 4;
    ErlNifBinary *grown = enif_realloc(ctx->owned, sizeof(ErlNifBinary) * (size_t)ncap);
    if (!grown) defk_fail(ctx, DEFK_E_ARG, "out of memory");
    ctx->owned = grown;
    ctx->cap = ncap;
  }
  ErlNifBinary *b = &ctx->owned[ctx->nowned];
  if (!enif_alloc_binary(bytes, b))
    defk_fail(ctx, DEFK_E_ARG, "out of memory (allocating %zu bytes)", bytes);
  DEFK_POISON_SLACK(b);
  ctx->owned_bytes += bytes;
  return ctx->nowned++;
}

/* Owned binary of zeros. */
static int defk_own(defk_ctx *ctx, size_t bytes) {
  int slot = defk_own_raw(ctx, bytes);
  memset(ctx->owned[slot].data, 0, bytes);
  return slot;
}

/*
 * Largest array alloc/2 makes, in bytes: 2^48 (256 TiB), the user address
 * space of 64-bit platforms, so no allocator can serve more. Elixir mode
 * applies the same limit (Defk.ElixirMode.Ops.alloc/2), where asking the VM
 * for a binary that large aborts it; the two modes agree on it. The check also keeps n * sizeof(T) from wrapping: unchecked, alloc(f64, 2^61)
 * was a 0-byte buffer of length 2^61, and an in-bounds write crashed the VM.
 * A size under the limit that the allocator cannot provide raises
 * "out of memory" (defk_own). It also bounds every array length below 2^61,
 * which the compiler relies on (range_limit: a range ending at length/1 cannot
 * step past the i64 limit).
 */
#if UINTPTR_MAX > 0xFFFFFFFFu
#define DEFK_ALLOC_MAX_BYTES ((uint64_t)1 << 48)
#else
#define DEFK_ALLOC_MAX_BYTES ((uint64_t)1 << 29)
#endif

/*
 * alloc/2: defk_alloc_raw_T leaves the buffer uninitialised, and
 * the compiler zeroes it after (defk_zero_strip, a loop with a safepoint per
 * strip) unless it proves every element is written before anything reads it.
 * defk_alloc_T zeroes at once, for a length known to be small.
 */
#define DEFK_ALLOC_FN(T, CT)                                                     \
  static inline defk_arr_##T defk_alloc_raw_##T(defk_ctx *ctx, int64_t n) {      \
    if (n < 0) defk_fail(ctx, DEFK_E_ARG, "alloc/2: negative length %lld", (long long)n); \
    uint64_t bytes;                                                              \
    if (DEFK_UNLIKELY(__builtin_mul_overflow((uint64_t)n, (uint64_t)sizeof(CT), &bytes) || \
                      bytes > DEFK_ALLOC_MAX_BYTES))                             \
      defk_fail(ctx, DEFK_E_ARG, "alloc/2: length too large");                   \
    int slot = defk_own_raw(ctx, (size_t)bytes);                                 \
    defk_arr_##T a = {(CT *)ctx->owned[slot].data, n};                           \
    return a;                                                                    \
  }                                                                              \
  static inline __attribute__((unused)) defk_arr_##T defk_alloc_##T(defk_ctx *ctx, int64_t n) { \
    defk_arr_##T a = defk_alloc_raw_##T(ctx, n);                                 \
    memset(a.data, 0, (size_t)n * sizeof(CT));                                   \
    return a;                                                                    \
  }
DEFK_ALLOC_FN(f64, double)
DEFK_ALLOC_FN(i64, int64_t)
DEFK_ALLOC_FN(u8, uint8_t)
DEFK_ALLOC_FN(u64, uint64_t)
DEFK_ALLOC_FN(i16, int16_t)
DEFK_ALLOC_FN(i32, int32_t)
DEFK_ALLOC_FN(f32, float)

/*
 * Zeroing an alloc/2 buffer in strips: one memset of 85 MB held
 * the scheduler ~5 ms (cold pages) before the kernel's first loop ran. The
 * generated loop zeroes DEFK_ZERO_STRIP bytes at a time from byte `done` and
 * passes a safepoint after each strip, charged one back-edge per 16 bytes
 * (DEFK_ZERO_TICKS), about what a cheap loop iteration costs, so the clock
 * is read at the usual rate. A yield spills the array and `done`. A strip
 * of 1 MiB takes ~60 us on cold pages; 64 KiB strips made a warm 85 MB alloc
 * ~30% slower than one memset, 1 MiB strips cost nothing measurable.
 */
#ifndef DEFK_ZERO_STRIP
#define DEFK_ZERO_STRIP (1024 * 1024)
#endif
#define DEFK_ZERO_TICKS(BYTES) ((int64_t)((BYTES) >> 4) + 1)

static inline __attribute__((unused)) uint64_t defk_zero_strip(void *data, uint64_t bytes,
                                                               uint64_t done) {
  uint64_t n = bytes - done < DEFK_ZERO_STRIP ? bytes - done : DEFK_ZERO_STRIP;
  memset((char *)data + done, 0, (size_t)n);
  return done + n;
}

/*
 * Array value semantics: a copy of `src` in a new owned binary,
 * made before a write when another binding may still see src's buffer, or
 * src is the caller's binary (never written). The compiler decides where
 * statically; see "array values" in lib/defk/compiler.ex.
 */
#define DEFK_COPY_FN(T, CT)                                                       \
  static inline defk_arr_##T defk_copy_##T(defk_ctx *ctx, defk_arr_##T src) {    \
    size_t bytes = (size_t)src.len * sizeof(CT);                                  \
    int slot = defk_own_raw(ctx, bytes);                                          \
    if (bytes) memcpy(ctx->owned[slot].data, src.data, bytes);                    \
    defk_arr_##T a = {(CT *)ctx->owned[slot].data, src.len};                      \
    return a;                                                                     \
  }
DEFK_COPY_FN(f64, double)
DEFK_COPY_FN(i64, int64_t)
DEFK_COPY_FN(u8, uint8_t)
DEFK_COPY_FN(u64, uint64_t)
DEFK_COPY_FN(i16, int16_t)
DEFK_COPY_FN(i32, int32_t)
DEFK_COPY_FN(f32, float)

/*
 * Range copies (defk_rcopy_T and defk_rcopy_back_T):
 * copy(out, at, src, from, n) and
 * copy_back(out, at, off, n), checked once for the whole range. The
 * compiler has made `out` the kernel's own buffer (copied first where value
 * semantics need it, as for out[i] = v), so these write it in place.
 *
 *   copy      out[at..at+n) = src[from..from+n) as src was before the call:
 *             memmove, so src may be out itself or share its buffer.
 *   copy_back out[at+j] = out[at+j-off] for j = 0, 1, ..., n-1 in order:
 *             an LZ match. When off < n this repeats the off elements before
 *             `at` (a run), which memmove does not do.
 *
 * Up to DEFK_COPY_STRIP bytes are copied at once and their bytes charged to
 * the safepoint budget (DEFK_ZERO_TICKS); the caller then reads the clock at
 * its next safepoint at the usual rate. A longer copy returns -1 and the
 * compiler's loop copies it in strips (defk_move_strip, defk_back_strip) with
 * a safepoint after each, like alloc/2's zeroing. A yielding kernel passes
 * once = 0; a yield: false kernel or a length known to be short, once = 1.
 */
#ifndef DEFK_COPY_STRIP
#define DEFK_COPY_STRIP DEFK_ZERO_STRIP
#endif

__attribute__((noreturn, cold, unused)) static void defk_copy_negative(defk_ctx *ctx,
                                                                     const char *f, int64_t n) {
  defk_fail(ctx, DEFK_E_ARG, "%s: negative length %lld", f, (long long)n);
}
__attribute__((noreturn, cold, unused)) static void defk_copy_oob(defk_ctx *ctx, const char *f,
                                                                int64_t n, const char *where,
                                                                int64_t i, const char *what,
                                                                int64_t len) {
  ctx->err_index = i;
  defk_fail(ctx, DEFK_E_OOB, "%s: %lld elements %s index %lld out of bounds for %s of length %lld",
            f, (long long)n, where, (long long)i, what, (long long)len);
}
__attribute__((noreturn, cold, unused)) static void defk_copy_back_off(defk_ctx *ctx, int64_t off,
                                                                     int64_t at) {
  if (off < 1)
    defk_fail(ctx, DEFK_E_ARG, "copy_back/4: offset %lld is not positive", (long long)off);
  ctx->err_index = at - off;
  defk_fail(ctx, DEFK_E_OOB, "copy_back/4: offset %lld from index %lld is before the start of the array",
            (long long)off, (long long)at);
}

/* n <= 32 bytes, every load before any store: memmove-safe */
static inline __attribute__((unused)) void defk_move_small(uint8_t *d, const uint8_t *s, size_t n) {
  if (n >= 16) {
    uint64_t a, b, c, e;
    __builtin_memcpy(&a, s, 8);
    __builtin_memcpy(&b, s + 8, 8);
    __builtin_memcpy(&c, s + n - 16, 8);
    __builtin_memcpy(&e, s + n - 8, 8);
    __builtin_memcpy(d, &a, 8);
    __builtin_memcpy(d + 8, &b, 8);
    __builtin_memcpy(d + n - 16, &c, 8);
    __builtin_memcpy(d + n - 8, &e, 8);
  } else if (n >= 8) {
    uint64_t a, b;
    __builtin_memcpy(&a, s, 8);
    __builtin_memcpy(&b, s + n - 8, 8);
    __builtin_memcpy(d, &a, 8);
    __builtin_memcpy(d + n - 8, &b, 8);
  } else if (n >= 4) {
    uint32_t a, b;
    __builtin_memcpy(&a, s, 4);
    __builtin_memcpy(&b, s + n - 4, 4);
    __builtin_memcpy(d, &a, 4);
    __builtin_memcpy(d + n - 4, &b, 4);
  } else if (n >= 2) {
    uint16_t a, b;
    __builtin_memcpy(&a, s, 2);
    __builtin_memcpy(&b, s + n - 2, 2);
    __builtin_memcpy(d, &a, 2);
    __builtin_memcpy(d + n - 2, &b, 2);
  } else if (n) {
    d[0] = s[0];
  }
}
static inline __attribute__((unused)) void defk_move_bytes(uint8_t *d, const uint8_t *s, size_t n) {
  if (DEFK_LIKELY(n <= 32)) defk_move_small(d, s, n);
  else memmove(d, s, n);
}

/* d[j] = d[j - off] for j in 0..n-1 in order, in bytes; off >= 1 */
static inline __attribute__((unused)) void defk_back_bytes(uint8_t *d, size_t off, size_t n) {
  const uint8_t *s = d - off;
  if (DEFK_LIKELY(off >= n)) { /* no overlap: a plain copy */
    defk_move_bytes(d, s, n);
    return;
  }
  if (n < 16) {
    for (size_t j = 0; j < n; j++) d[j] = s[j];
    return;
  }
  /* d[j] = d[j - m] for any multiple m of off; take m >= 8 so a word reads
   * only bytes already final, after the first m - off (< 8) bytes one by
   * one (a pattern fill when off < 8) */
  size_t m = off >= 8 ? off : off * ((8 + off - 1) / off), j = 0;
  for (; j < m - off; j++) d[j] = s[j];
  const uint8_t *t = d - m;
  for (; j + 8 <= n; j += 8) {
    uint64_t w;
    __builtin_memcpy(&w, t + j, 8);
    __builtin_memcpy(d + j, &w, 8);
  }
  if (j < n) { /* the last word ends at n; its first bytes are final already */
    uint64_t w;
    __builtin_memcpy(&w, t + n - 8, 8);
    __builtin_memcpy(d + n - 8, &w, 8);
  }
}

/* one strip of a long copy: `done` bytes moved so far, returns the new
 * count; from the end when the destination overlaps the source from above */
static inline __attribute__((unused)) uint64_t defk_move_strip(uint8_t *d, const uint8_t *s,
                                                               uint64_t bytes, uint64_t done) {
  uint64_t c = bytes - done < DEFK_COPY_STRIP ? bytes - done : DEFK_COPY_STRIP;
  if (d > s && d < s + bytes) memmove(d + bytes - done - c, s + bytes - done - c, (size_t)c);
  else memmove(d + done, s + done, (size_t)c);
  return done + c;
}
/* one strip of a long copy_back: the bytes before d + done are final, so
 * d[done..done+c) is the copy of d[done-m..done-m+c) for the multiple m of
 * off with done - m >= -off, which does not overlap it for c <= m */
static inline __attribute__((unused)) uint64_t defk_back_strip(uint8_t *d, uint64_t off,
                                                               uint64_t n, uint64_t done) {
  uint64_t m = off * (done / off + 1), c = n - done;
  if (c > m) c = m;
  if (c > DEFK_COPY_STRIP) c = DEFK_COPY_STRIP;
  memcpy(d + done, d + done - m, (size_t)c);
  return done + c;
}

#define DEFK_RANGE_COPY_FN(T, CT)                                                          \
  static inline __attribute__((unused)) int64_t defk_rcopy_##T(                             \
      defk_ctx *ctx, defk_arr_##T a, int64_t at, defk_arr_##T s, int64_t from, int64_t n,  \
      int once) {                                                                          \
    if (DEFK_UNLIKELY(n < 0)) defk_copy_negative(ctx, "copy/5", n);                        \
    if (DEFK_UNLIKELY(at < 0 || at > a.len - n))                                          \
      defk_copy_oob(ctx, "copy/5", n, "at", at, "array", a.len);                           \
    if (DEFK_UNLIKELY(from < 0 || from > s.len - n))                                      \
      defk_copy_oob(ctx, "copy/5", n, "from", from, "source array", s.len);               \
    uint64_t bytes = (uint64_t)n * sizeof(CT);                                             \
    if (!once && DEFK_UNLIKELY(bytes > DEFK_COPY_STRIP)) return -1;                        \
    defk_move_bytes((uint8_t *)(a.data + at), (const uint8_t *)(s.data + from), bytes);   \
    return (int64_t)bytes;                                                                 \
  }                                                                                        \
  static inline __attribute__((unused)) int64_t defk_rcopy_back_##T(                        \
      defk_ctx *ctx, defk_arr_##T a, int64_t at, int64_t off, int64_t n, int once) {       \
    if (DEFK_UNLIKELY(n < 0)) defk_copy_negative(ctx, "copy_back/4", n);                   \
    if (DEFK_UNLIKELY(at < 0 || at > a.len - n))                                          \
      defk_copy_oob(ctx, "copy_back/4", n, "at", at, "array", a.len);                      \
    if (n == 0) return 0;                                                                  \
    if (DEFK_UNLIKELY(off < 1 || at < off)) defk_copy_back_off(ctx, off, at);              \
    uint64_t bytes = (uint64_t)n * sizeof(CT);                                             \
    if (!once && DEFK_UNLIKELY(bytes > DEFK_COPY_STRIP)) return -1;                        \
    defk_back_bytes((uint8_t *)(a.data + at), (size_t)off * sizeof(CT), (size_t)bytes);    \
    return (int64_t)bytes;                                                                 \
  }
DEFK_RANGE_COPY_FN(f64, double)
DEFK_RANGE_COPY_FN(i64, int64_t)
DEFK_RANGE_COPY_FN(u8, uint8_t)
DEFK_RANGE_COPY_FN(u64, uint64_t)
DEFK_RANGE_COPY_FN(i16, int16_t)
DEFK_RANGE_COPY_FN(i32, int32_t)
DEFK_RANGE_COPY_FN(f32, float)

/* Hand an owned array back to the BEAM as a binary (ownership transfers). */
static ERL_NIF_TERM defk_make_arr(ErlNifEnv *env, defk_ctx *ctx, void *data) {
  for (int i = 0; i < ctx->nowned; i++) {
    if (ctx->owned[i].data == data) {
      ctx->owned_bytes -= ctx->owned[i].size;
      ERL_NIF_TERM t = enif_make_binary(env, &ctx->owned[i]);
      ctx->owned[i].data = NULL; /* no longer ours to release */
      return t;
    }
  }
  /* zero-length arrays may share no slot; return an empty binary */
  ERL_NIF_TERM t;
  enif_make_new_binary(env, 0, &t);
  return t;
}

/*
 * Hand back an array the kernel may not own: an owned buffer is
 * handed over as defk_make_arr does; any other (a binary literal's or
 * attribute's static bytes) is copied into a new binary. The generated code
 * matches an input array first and returns the caller's own binary.
 */
__attribute__((unused)) static ERL_NIF_TERM defk_make_arr_view(ErlNifEnv *env, defk_ctx *ctx,
                                                               const void *data, size_t bytes) {
  ERL_NIF_TERM t;
  if (bytes) {
    for (int i = 0; i < ctx->nowned; i++)
      if (ctx->owned[i].data == data) return defk_make_arr(env, ctx, ctx->owned[i].data);
    memcpy(enif_make_new_binary(env, bytes, &t), data, bytes);
    return t;
  }
  enif_make_new_binary(env, 0, &t);
  return t;
}

/*
 * Bind a binary argument as a packed array. Called on EVERY entry (first call
 * and each resume) because heap binaries can move during GC between yields.
 * Misaligned data (e.g. a sub-binary at an odd offset) is copied once into an
 * owned binary; *copy_slot remembers that copy across resumes.
 */
static void defk_bind(ErlNifEnv *env, defk_ctx *ctx, ERL_NIF_TERM t, size_t esz,
                      void **data, int64_t *len, int *copy_slot, int argn,
                      const char *pname, const char *tname) {
  if (*copy_slot > 0) {
    ErlNifBinary *b = &ctx->owned[*copy_slot - 1];
    *data = b->data;
    *len = (int64_t)(b->size / esz);
    return;
  }
  ErlNifBinary bin;
  if (!enif_inspect_binary(env, t, &bin))
    defk_fail(ctx, DEFK_E_ARG, "argument %d (%s) must be a binary of packed %s", argn,
              pname, tname);
  if (bin.size % esz)
    defk_fail(ctx, DEFK_E_ARG,
              "argument %d (%s): byte size %zu is not a multiple of %zu (%s)", argn, pname,
              bin.size, esz, tname);
  if (((uintptr_t)bin.data) % esz) {
    int slot = defk_own_raw(ctx, bin.size);
    memcpy(ctx->owned[slot].data, bin.data, bin.size);
    *copy_slot = slot + 1;
    *data = ctx->owned[slot].data;
  } else {
    *data = bin.data;
  }
  *len = (int64_t)(bin.size / esz);
}

/* ---- scalar decoding ----------------------------------------------------- */

static int64_t defk_get_i64_arg(ErlNifEnv *env, defk_ctx *ctx, ERL_NIF_TERM t, int argn,
                                const char *pname) {
  ErlNifSInt64 v;
  if (!enif_get_int64(env, t, &v))
    defk_fail(ctx, DEFK_E_ARG, "argument %d (%s) must be an integer fitting in i64", argn,
              pname);
  return (int64_t)v;
}

static double defk_get_f64_arg(ErlNifEnv *env, defk_ctx *ctx, ERL_NIF_TERM t, int argn,
                               const char *pname) {
  double d;
  ErlNifSInt64 v;
  if (enif_get_double(env, t, &d)) return d;
  if (enif_get_int64(env, t, &v)) return (double)v;
  defk_fail(ctx, DEFK_E_ARG, "argument %d (%s) must be a number", argn, pname);
}

__attribute__((unused)) static uint64_t defk_get_u64_arg(ErlNifEnv *env, defk_ctx *ctx, ERL_NIF_TERM t,
                                                        int argn, const char *pname) {
  ErlNifUInt64 v;
  if (!enif_get_uint64(env, t, &v))
    defk_fail(ctx, DEFK_E_ARG, "argument %d (%s) must be an integer fitting in u64", argn,
              pname);
  return (uint64_t)v;
}

__attribute__((unused)) static int defk_get_bool_arg(ErlNifEnv *env, defk_ctx *ctx, ERL_NIF_TERM t, int argn,
                             const char *pname) {
  char buf[6];
  if (enif_get_atom(env, t, buf, sizeof buf, ERL_NIF_UTF8)) {
    if (!strcmp(buf, "true")) return 1;
    if (!strcmp(buf, "false")) return 0;
  }
  defk_fail(ctx, DEFK_E_ARG, "argument %d (%s) must be a boolean", argn, pname);
}

/* ---- result encoding ----------------------------------------------------- */

static ERL_NIF_TERM defk_make_f64(defk_ctx *ctx, ErlNifEnv *env, double d) {
  /* BEAM floats cannot be inf/nan. Every operation that could make one
     already raised; this stays as defence in depth. */
  if (DEFK_UNLIKELY(!isfinite(d)))
    defk_fail(ctx, DEFK_E_ARITH, "kernel produced a non-finite float");
  return enif_make_double(env, d);
}

static ERL_NIF_TERM defk_make_bool(ErlNifEnv *env, int b) {
  return enif_make_atom(env, b ? "true" : "false");
}

/* ---- checked arithmetic (Elixir semantics, i64 domain) ------------------- */

static inline int64_t defk_add_i64(defk_ctx *ctx, int64_t a, int64_t b) {
  int64_t r;
  if (DEFK_UNLIKELY(__builtin_add_overflow(a, b, &r)))
    defk_fail(ctx, DEFK_E_ARITH, "i64 overflow in %lld + %lld", (long long)a, (long long)b);
  return r;
}
static inline int64_t defk_sub_i64(defk_ctx *ctx, int64_t a, int64_t b) {
  int64_t r;
  if (DEFK_UNLIKELY(__builtin_sub_overflow(a, b, &r)))
    defk_fail(ctx, DEFK_E_ARITH, "i64 overflow in %lld - %lld", (long long)a, (long long)b);
  return r;
}
static inline int64_t defk_mul_i64(defk_ctx *ctx, int64_t a, int64_t b) {
  int64_t r;
  if (DEFK_UNLIKELY(__builtin_mul_overflow(a, b, &r)))
    defk_fail(ctx, DEFK_E_ARITH, "i64 overflow in %lld * %lld", (long long)a, (long long)b);
  return r;
}
static inline int64_t defk_neg_i64(defk_ctx *ctx, int64_t a) {
  return defk_sub_i64(ctx, 0, a);
}
/* the same, flagging overflow instead of raising (arms of a speculated `if`/`cond`) */
static inline int64_t defk_add_i64_s(int *ovf, int64_t a, int64_t b) {
  int64_t r;
  *ovf |= __builtin_add_overflow(a, b, &r);
  return r;
}
static inline int64_t defk_sub_i64_s(int *ovf, int64_t a, int64_t b) {
  int64_t r;
  *ovf |= __builtin_sub_overflow(a, b, &r);
  return r;
}
static inline int64_t defk_mul_i64_s(int *ovf, int64_t a, int64_t b) {
  int64_t r;
  *ovf |= __builtin_mul_overflow(a, b, &r);
  return r;
}
static inline int64_t defk_neg_i64_s(int *ovf, int64_t a) { return defk_sub_i64_s(ovf, 0, a); }
/* ---- bitwise shifts (Elixir's Bitwise.bsl/bsr, i64 domain) ---------------
 * bsl(a, n) is a * 2^n exactly and bsr(a, n) is floor(a / 2^n), as Elixir
 * computes them over bignums: a negative n shifts the other way, bsr fills
 * with the sign (n >= 64 gives 0 or -1), and *ovf is set when the exact
 * result does not fit in i64 (any bit shifted out of bsl, or its sign
 * changing). Shift counts outside 0..63 are UB in C, so they branch first.
 * `>>` on a negative int64_t is arithmetic on every compiler defk builds
 * with (clang, gcc). band/bor/bxor/bnot are the C operators. */
static inline int64_t defk_bsl_core(int *ovf, int64_t a, int64_t n) {
  if (n >= 64) {
    *ovf |= a != 0;
    return 0;
  }
  if (n >= 0) {
    int64_t r = (int64_t)((uint64_t)a << n);
    *ovf |= (r >> n) != a;
    return r;
  }
  if (n > -64) return a >> -n;
  return a < 0 ? -1 : 0;
}
static inline int64_t defk_bsr_core(int *ovf, int64_t a, int64_t n) {
  if (n >= 64) return a < 0 ? -1 : 0;
  if (n >= 0) return a >> n;
  if (n > -64) return defk_bsl_core(ovf, a, -n);
  *ovf |= a != 0;
  return 0;
}
static inline int64_t defk_bsl_i64(defk_ctx *ctx, int64_t a, int64_t n) {
  int ovf = 0;
  int64_t r = defk_bsl_core(&ovf, a, n);
  if (DEFK_UNLIKELY(ovf))
    defk_fail(ctx, DEFK_E_ARITH, "i64 overflow in bsl(%lld, %lld)", (long long)a, (long long)n);
  return r;
}
static inline int64_t defk_bsr_i64(defk_ctx *ctx, int64_t a, int64_t n) {
  int ovf = 0;
  int64_t r = defk_bsr_core(&ovf, a, n);
  if (DEFK_UNLIKELY(ovf))
    defk_fail(ctx, DEFK_E_ARITH, "i64 overflow in bsr(%lld, %lld)", (long long)a, (long long)n);
  return r;
}
static inline int64_t defk_bsl_i64_s(int *ovf, int64_t a, int64_t n) { return defk_bsl_core(ovf, a, n); }
static inline int64_t defk_bsr_i64_s(int *ovf, int64_t a, int64_t n) { return defk_bsr_core(ovf, a, n); }
/* bsr by a shift known to be non-negative: it cannot overflow */
static inline int64_t defk_bsr_nn(int64_t a, int64_t n) {
  /* n >= 0 is proved; the unsigned test keeps a wrong n from a failed flagged
     operation from shifting by a negative count */
  return (uint64_t)n >= 64 ? (a < 0 ? -1 : 0) : a >> n;
}
static inline int64_t defk_div_i64(defk_ctx *ctx, int64_t a, int64_t b) {
  if (DEFK_UNLIKELY(b == 0)) defk_fail(ctx, DEFK_E_ARITH, "div/2 by zero");
  if (DEFK_UNLIKELY(a == INT64_MIN && b == -1)) defk_fail(ctx, DEFK_E_ARITH, "i64 overflow in div/2");
  return a / b; /* C truncates toward zero, like Elixir div/2 */
}
static inline int64_t defk_rem_i64(defk_ctx *ctx, int64_t a, int64_t b) {
  if (DEFK_UNLIKELY(b == 0)) defk_fail(ctx, DEFK_E_ARITH, "rem/2 by zero");
  if (DEFK_UNLIKELY(b == -1)) return 0;
  return a % b; /* sign follows dividend, like Elixir rem/2 */
}
static inline int64_t defk_abs_i64(defk_ctx *ctx, int64_t a) {
  return a < 0 ? defk_neg_i64(ctx, a) : a;
}

/* case guards: an Elixir guard that errors fails its clause. A zero
 * divisor sets *bad (an Elixir error: the clause fails); a result outside i64
 * sets *ovf (not an error in Elixir, which has bignums: the guard raises, as
 * the unguarded operation does). Neither form divides by zero or by -1 when
 * flagging, so a flagged guard is safe to evaluate whether or not it is reached. */
static inline int64_t defk_div_i64_g(int *bad, int *ovf, int64_t a, int64_t b) {
  if (b == 0) { *bad = 1; return 0; }
  if (b == -1) { *ovf |= a == INT64_MIN; return (int64_t)(0 - (uint64_t)a); }
  return a / b;
}
static inline int64_t defk_rem_i64_g(int *bad, int64_t a, int64_t b) {
  if (b == 0) { *bad = 1; return 0; }
  if (b == -1) return 0;
  return a % b;
}
static inline int64_t defk_abs_i64_s(int *ovf, int64_t a) {
  return a < 0 ? defk_neg_i64_s(ovf, a) : a;
}

/* ---- u64 -----------------------------------------------------------------
 * Checked arithmetic in the u64 domain, 0..2^64 - 1: the exact result, or
 * ArithmeticError where it leaves u64 (a - b below 0 included). Masked
 * arithmetic (band(expr, 2^k - 1)) never comes here: it wraps in uint64_t. */
#define DEFK_U64_OP(NAME, OP, BUILTIN)                                              \
  static inline uint64_t defk_##NAME##_u64(defk_ctx *ctx, uint64_t a, uint64_t b) { \
    uint64_t r;                                                                     \
    if (DEFK_UNLIKELY(BUILTIN(a, b, &r)))                                           \
      defk_fail(ctx, DEFK_E_ARITH, "u64 overflow in %llu " OP " %llu",              \
                (unsigned long long)a, (unsigned long long)b);                      \
    return r;                                                                       \
  }                                                                                 \
  static inline uint64_t defk_##NAME##_u64_s(int *ovf, uint64_t a, uint64_t b) {    \
    uint64_t r;                                                                     \
    *ovf |= BUILTIN(a, b, &r);                                                      \
    return r;                                                                       \
  }
DEFK_U64_OP(add, "+", __builtin_add_overflow)
DEFK_U64_OP(sub, "-", __builtin_sub_overflow)
DEFK_U64_OP(mul, "*", __builtin_mul_overflow)
/* bsl/bsr on a u64, exact: a negative count shifts the other way, bsr is
 * logical (a u64 is never negative), and bsl sets *ovf when a bit is shifted
 * out of the 64 */
static inline uint64_t defk_bsl_u64_core(int *ovf, uint64_t a, int64_t n) {
  if (n >= 64) {
    *ovf |= a != 0;
    return 0;
  }
  if (n >= 0) {
    *ovf |= n > 0 && (a >> (64 - n)) != 0;
    return a << n;
  }
  return n > -64 ? a >> -n : 0;
}
static inline uint64_t defk_bsr_u64_core(int *ovf, uint64_t a, int64_t n) {
  if (n >= 64) return 0;
  if (n >= 0) return a >> n;
  if (n > -64) return defk_bsl_u64_core(ovf, a, -n);
  *ovf |= a != 0;
  return 0;
}
static inline uint64_t defk_bsl_u64(defk_ctx *ctx, uint64_t a, int64_t n) {
  int ovf = 0;
  uint64_t r = defk_bsl_u64_core(&ovf, a, n);
  if (DEFK_UNLIKELY(ovf))
    defk_fail(ctx, DEFK_E_ARITH, "u64 overflow in bsl(%llu, %lld)", (unsigned long long)a,
              (long long)n);
  return r;
}
static inline uint64_t defk_bsr_u64(defk_ctx *ctx, uint64_t a, int64_t n) {
  int ovf = 0;
  uint64_t r = defk_bsr_u64_core(&ovf, a, n);
  if (DEFK_UNLIKELY(ovf))
    defk_fail(ctx, DEFK_E_ARITH, "u64 overflow in bsr(%llu, %lld)", (unsigned long long)a,
              (long long)n);
  return r;
}
static inline uint64_t defk_bsl_u64_s(int *ovf, uint64_t a, int64_t n) { return defk_bsl_u64_core(ovf, a, n); }
static inline uint64_t defk_bsr_u64_s(int *ovf, uint64_t a, int64_t n) { return defk_bsr_u64_core(ovf, a, n); }
static inline uint64_t defk_div_u64(defk_ctx *ctx, uint64_t a, uint64_t b) {
  if (DEFK_UNLIKELY(b == 0)) defk_fail(ctx, DEFK_E_ARITH, "div/2 by zero");
  return a / b;
}
static inline uint64_t defk_rem_u64(defk_ctx *ctx, uint64_t a, uint64_t b) {
  if (DEFK_UNLIKELY(b == 0)) defk_fail(ctx, DEFK_E_ARITH, "rem/2 by zero");
  return a % b;
}
static inline uint64_t defk_div_u64_g(int *bad, uint64_t a, uint64_t b) {
  if (b == 0) { *bad = 1; return 0; }
  return a / b;
}
static inline uint64_t defk_rem_u64_g(int *bad, uint64_t a, uint64_t b) {
  if (b == 0) { *bad = 1; return 0; }
  return a % b;
}
/* a u64 where an i64 is expected, and an i64 where a u64 is expected: the
 * same integer, or ArithmeticError when the other type cannot hold it */
static inline int64_t defk_u64_to_i64(defk_ctx *ctx, uint64_t a) {
  if (DEFK_UNLIKELY(a > (uint64_t)INT64_MAX))
    defk_fail(ctx, DEFK_E_ARITH, "%llu does not fit in i64", (unsigned long long)a);
  return (int64_t)a;
}
static inline uint64_t defk_i64_to_u64(defk_ctx *ctx, int64_t a) {
  if (DEFK_UNLIKELY(a < 0)) defk_fail(ctx, DEFK_E_ARITH, "%lld does not fit in u64", (long long)a);
  return (uint64_t)a;
}
/* bsl inside a mask by a count that is not a literal: the low 64 bits of
 * a * 2^n. A negative count would shift high bits of the exact value down,
 * which the wrapped 64 bits no longer hold: it raises (a limit). */
static inline uint64_t defk_wbsl(defk_ctx *ctx, uint64_t a, int64_t n) {
  if (DEFK_UNLIKELY(n < 0))
    defk_fail(ctx, DEFK_E_ARITH, "bsl/2 by the negative count %lld inside a mask", (long long)n);
  return n >= 64 ? 0 : a << n;
}
static inline uint64_t defk_wbsl_s(int *ovf, uint64_t a, int64_t n) {
  *ovf |= n < 0;
  return n >= 64 || n < 0 ? 0 : a << n;
}
/* a value written to a [u64] or [i64] that its element type cannot hold:
 * ArgumentError, as for a [u8] */
static inline uint64_t defk_to_u64(defk_ctx *ctx, int64_t v) {
  if (DEFK_UNLIKELY(v < 0)) defk_fail(ctx, DEFK_E_ARG, "value %lld does not fit in u64", (long long)v);
  return (uint64_t)v;
}
static inline int64_t defk_to_i64_elem(defk_ctx *ctx, uint64_t v) {
  if (DEFK_UNLIKELY(v > (uint64_t)INT64_MAX))
    defk_fail(ctx, DEFK_E_ARG, "value %llu does not fit in i64", (unsigned long long)v);
  return (int64_t)v;
}

/* ---- float arithmetic Elixir's way ---------------------------------------
 *
 * Elixir raises ArithmeticError at any float operation whose result would be
 * inf or NaN (BEAM floats are always finite), so each operation that can make
 * one checks its result: one predictable branch, raising at the operation as
 * Elixir does. Underflow to 0.0 or a subnormal is finite and does not raise.
 * Operations that keep a finite value finite (unary -, abs, min, max, sin,
 * cos, float/1) need no check, and since every value a kernel computes is
 * finite, neither does a write to an array. The _s twins flag the result
 * instead of raising, for the arms of a speculated `if`/`cond` (as the i64
 * _s forms do): only the taken arm's flag replays the raising form.
 *
 * DEFK_NO_FLOAT_CHECKS compiles the checks out; it exists only to measure
 * their cost (docs/performance.md 6.5) and is not a user option.
 */
#ifdef DEFK_NO_FLOAT_CHECKS
#define DEFK_FINITE(x) 1
#define DEFK_NONFIN(x) 0
#else
#define DEFK_FINITE(x) DEFK_LIKELY(isfinite(x))
/* !isfinite(x) as one unordered compare, which clang vectorises as a mask */
#define DEFK_NONFIN(x) (!(__builtin_fabs(x) <= 0x1.fffffffffffffp+1023))
#endif

__attribute__((noreturn, cold)) static void defk_nonfinite(defk_ctx *ctx, double a, char op,
                                                           double b) {
  if (op == '/' && b == 0.0)
    defk_fail(ctx, DEFK_E_ARITH, "bad argument in arithmetic expression: division by zero");
  defk_fail(ctx, DEFK_E_ARITH, "float result of %.17g %c %.17g is inf or NaN", a, op, b);
}

#define DEFK_FLOAT_OP(NAME, OP)                                                   \
  static inline double defk_##NAME(defk_ctx *ctx, double a, double b) {           \
    double r = a OP b;                                                            \
    if (!DEFK_FINITE(r)) defk_nonfinite(ctx, a, (#OP)[0], b);                     \
    return r;                                                                     \
  }                                                                               \
  static inline double defk_##NAME##_s(int *nf, double a, double b) {             \
    double r = a OP b;                                                            \
    *nf |= !DEFK_FINITE(r);                                                       \
    return r;                                                                     \
  }
DEFK_FLOAT_OP(fadd, +)
DEFK_FLOAT_OP(fsub, -)
DEFK_FLOAT_OP(fmul, *)
DEFK_FLOAT_OP(fdiv, /)

/* a float expression's check failed but its replay did not raise (a defk bug;
   raising is still Elixir's outcome, see float_tree in the compiler) */
__attribute__((noreturn, cold, unused)) static void defk_nonfinite_lost(defk_ctx *ctx) {
  defk_fail(ctx, DEFK_E_ARITH, "float result is inf or NaN");
}

/* libm calls: Erlang's :math raises when the result is not finite */
__attribute__((noreturn, cold)) static void defk_nonfinite_call(defk_ctx *ctx, const char *f,
                                                                double a, double b, int arity) {
  if (arity == 1)
    defk_fail(ctx, DEFK_E_ARITH, "float result of %s(%.17g) is inf or NaN", f, a);
  defk_fail(ctx, DEFK_E_ARITH, "float result of %s(%.17g, %.17g) is inf or NaN", f, a, b);
}
static inline double defk_exp(defk_ctx *ctx, double a) {
  double r = exp(a);
  if (!DEFK_FINITE(r)) defk_nonfinite_call(ctx, "exp", a, 0.0, 1);
  return r;
}
static inline double defk_pow(defk_ctx *ctx, double a, double b) {
  double r = pow(a, b);
  if (!DEFK_FINITE(r)) defk_nonfinite_call(ctx, "pow", a, b, 2);
  return r;
}
/* __builtin_sqrt: one instruction where -fno-builtin would make it a libm
   call. IEEE 754 square root is correctly rounded, in hardware and in libm
   (which :math.sqrt calls), so the result is the same bits. */
static inline double defk_sqrt(defk_ctx *ctx, double a) {
  if (DEFK_UNLIKELY(a < 0.0)) defk_fail(ctx, DEFK_E_ARITH, "sqrt of negative number %g", a);
  return __builtin_sqrt(a);
}
static inline double defk_log(defk_ctx *ctx, double a) {
  if (DEFK_UNLIKELY(a <= 0.0)) defk_fail(ctx, DEFK_E_ARITH, "log of non-positive number %g", a);
  return log(a);
}
static inline double defk_log2(defk_ctx *ctx, double a) {
  if (DEFK_UNLIKELY(a <= 0.0)) defk_fail(ctx, DEFK_E_ARITH, "log2 of non-positive number %g", a);
  return log2(a);
}
static inline double defk_log10(defk_ctx *ctx, double a) {
  if (DEFK_UNLIKELY(a <= 0.0)) defk_fail(ctx, DEFK_E_ARITH, "log10 of non-positive number %g", a);
  return log10(a);
}
static inline int64_t defk_trunc(defk_ctx *ctx, double a) {
  if (DEFK_UNLIKELY(!(a >= -0x1p63 && a < 0x1p63)))
    defk_fail(ctx, DEFK_E_ARITH, "trunc/1: %g does not fit in i64", a);
  return (int64_t)a;
}
static inline int64_t defk_round(defk_ctx *ctx, double a) { return defk_trunc(ctx, round(a)); }
static inline int64_t defk_trunc_s(int *ovf, double a) {
  int ok = a >= -0x1p63 && a < 0x1p63;
  *ovf |= !ok;
  return ok ? (int64_t)a : 0;
}
static inline int64_t defk_round_s(int *ovf, double a) { return defk_trunc_s(ovf, round(a)); }
/* Bit builtins (Defk.Bits): on the u64 bit patterns. __builtin_clzll and
 * ctzll are undefined at 0, so 0 is guarded (the compiler folds the test into
 * the instruction where the target defines it); rotates mask the count to 0..63
 * and use the two-shift idiom, which compiles to one rotate instruction. */
static inline int64_t defk_mulhi(int64_t a, int64_t b) {
  return (int64_t)(((unsigned __int128)(uint64_t)a * (uint64_t)b) >> 64);
}
static inline int64_t defk_clz(int64_t x) { return x == 0 ? 64 : __builtin_clzll((uint64_t)x); }
static inline int64_t defk_ctz(int64_t x) { return x == 0 ? 64 : __builtin_ctzll((uint64_t)x); }
static inline int64_t defk_popcount(int64_t x) { return __builtin_popcountll((uint64_t)x); }
static inline int64_t defk_rotl64(int64_t x, int64_t n) {
  uint64_t u = (uint64_t)x;
  unsigned k = (unsigned)n & 63u;
  return (int64_t)((u << k) | (u >> ((64u - k) & 63u)));
}
static inline int64_t defk_rotr64(int64_t x, int64_t n) {
  uint64_t u = (uint64_t)x;
  unsigned k = (unsigned)n & 63u;
  return (int64_t)((u >> k) | (u << ((64u - k) & 63u)));
}
/* Defk.Bits.clz/2, ctz/2, rotl/3, rotr/3: x is a w-bit value, 1 <= w <= 64;
 * a width outside 1..64 or an x outside 0..2^w - 1 raises ArgumentError, as
 * the Elixir functions do. An i64 x arrives as its bit pattern with `neg`
 * set when it was negative. rotl/rotr rotate by n mod w. */
__attribute__((noreturn, cold, unused)) static void defk_field_fail(defk_ctx *ctx, const char *f,
                                                           uint64_t x, int neg, int64_t w) {
  if (w < 1 || w > 64)
    defk_fail(ctx, DEFK_E_ARG, "Defk.Bits.%s: width %lld is not in 1..64", f, (long long)w);
  if (neg)
    defk_fail(ctx, DEFK_E_ARG, "Defk.Bits.%s: %lld does not fit in a %lld-bit field", f,
              (long long)x, (long long)w);
  defk_fail(ctx, DEFK_E_ARG, "Defk.Bits.%s: %llu does not fit in a %lld-bit field", f,
            (unsigned long long)x, (long long)w);
}
static inline uint64_t defk_field_arg(defk_ctx *ctx, const char *f, uint64_t x, int neg, int64_t w) {
  if (DEFK_UNLIKELY(w < 1 || w > 64 || neg || (w < 64 && (x >> w) != 0)))
    defk_field_fail(ctx, f, x, neg, w);
  return x;
}
static inline int64_t defk_clz_w(defk_ctx *ctx, uint64_t x, int neg, int64_t w) {
  x = defk_field_arg(ctx, "clz/2", x, neg, w);
  return x == 0 ? w : __builtin_clzll(x) - (64 - w);
}
static inline int64_t defk_ctz_w(defk_ctx *ctx, uint64_t x, int neg, int64_t w) {
  x = defk_field_arg(ctx, "ctz/2", x, neg, w);
  return x == 0 ? w : __builtin_ctzll(x);
}
/* rotate left by n mod w (right: by -n mod w) */
static inline uint64_t defk_rot_w(defk_ctx *ctx, const char *f, uint64_t x, int neg, int64_t n,
                                  int64_t w, int right) {
  x = defk_field_arg(ctx, f, x, neg, w);
  int64_t m = ((n % w) + w) % w;
  uint64_t k = (uint64_t)(right && m ? w - m : m);
  if (k == 0) return x;
  /* a 32-bit field rotates as a uint32_t, so clang emits one ror (the 64-bit
     spelling below compiles to a shift and a bit-field insert) */
  if (w == 32) return (uint32_t)(((uint32_t)x << k) | ((uint32_t)x >> (32 - k)));
  uint64_t mask = w == 64 ? ~UINT64_C(0) : (UINT64_C(1) << w) - 1;
  return ((x << k) | (x >> (w - k))) & mask;
}
/* the forms the compiler calls, for an i64 x (its sign checked) and a u64 x */
static inline int64_t defk_clz_i(defk_ctx *ctx, int64_t x, int64_t w) { return defk_clz_w(ctx, (uint64_t)x, x < 0, w); }
static inline int64_t defk_clz_u(defk_ctx *ctx, uint64_t x, int64_t w) { return defk_clz_w(ctx, x, 0, w); }
static inline int64_t defk_ctz_i(defk_ctx *ctx, int64_t x, int64_t w) { return defk_ctz_w(ctx, (uint64_t)x, x < 0, w); }
static inline int64_t defk_ctz_u(defk_ctx *ctx, uint64_t x, int64_t w) { return defk_ctz_w(ctx, x, 0, w); }
static inline uint64_t defk_rotl_i(defk_ctx *ctx, int64_t x, int64_t n, int64_t w) { return defk_rot_w(ctx, "rotl/3", (uint64_t)x, x < 0, n, w, 0); }
static inline uint64_t defk_rotl_u(defk_ctx *ctx, uint64_t x, int64_t n, int64_t w) { return defk_rot_w(ctx, "rotl/3", x, 0, n, w, 0); }
static inline uint64_t defk_rotr_i(defk_ctx *ctx, int64_t x, int64_t n, int64_t w) { return defk_rot_w(ctx, "rotr/3", (uint64_t)x, x < 0, n, w, 1); }
static inline uint64_t defk_rotr_u(defk_ctx *ctx, uint64_t x, int64_t n, int64_t w) { return defk_rot_w(ctx, "rotr/3", x, 0, n, w, 1); }
/* ---- hardware builtins ---------------------------------------------------
 *
 * Defk.Bits.crc32c/3: one CRC32C (Castagnoli, reflected polynomial
 * 0x82F63B78) update step over the w/8 bytes of x, least significant byte
 * first, with no pre- or post-inversion: what ARMv8 CRC32C{B,H,W,X} and
 * SSE4.2 crc32{b,w,l,q} compute. Two implementations, picked at run time:
 *
 *   - the instruction, where the CPU has it: always on Apple arm64 and every
 *     arm64 with __ARM_FEATURE_CRC32; Linux arm64 when getauxval(AT_HWCAP)
 *     has HWCAP_CRC32; x86-64 when CPUID reports SSE4.2;
 *   - a portable slicing-by-8 table (8 x 256 u32, built on first use)
 *     everywhere else, and when DEFK_PORTABLE_BUILTINS is set to anything
 *     but "" or "0" when a kernel library first calls the builtin (for
 *     testing and measuring the fallback, as OPENSSL_ia32cap does; set in
 *     the shell or with System.put_env/2).
 *
 * The choice is made once per kernel library (a cached state, read with a
 * relaxed load per call: a predicted branch, measured at no cost against
 * the bare instruction). The instruction is inline asm, not the intrinsic,
 * so it inlines into code compiled without the feature (a portable Linux
 * build: GCC will not inline a target("+crc") function into one without
 * it, which cost 1.7x); it only runs after the check said the CPU has it,
 * so no CPU without it ever sees the instruction (never SIGILL). */
#include <pthread.h>
#if defined(__aarch64__) && !defined(DEFK_NO_HW_BUILTINS)
#define DEFK_HW_CRC32C 1
#if defined(__linux__)
#include <sys/auxv.h>
#ifndef HWCAP_CRC32
#define HWCAP_CRC32 (1 << 7)
#endif
#endif
static int defk_cpu_crc32c(void) {
#if defined(__ARM_FEATURE_CRC32) || defined(__APPLE__)
  return 1;
#elif defined(__linux__)
  return (getauxval(AT_HWCAP) & HWCAP_CRC32) != 0;
#else
  return 0;
#endif
}
/* c and the result are 64-bit registers whose top half is 0 (writing a W
   register clears it), so the chain needs no zero-extending mov, which
   cost a cycle per step (536 vs 389 us for 4 MB) */
static inline uint64_t defk_crc32c_hw(uint64_t c, uint64_t x, int w) {
  switch (w) {
  case 8: __asm__(".arch_extension crc\n\tcrc32cb %w0, %w0, %w1" : "+r"(c) : "r"(x)); return c;
  case 16: __asm__(".arch_extension crc\n\tcrc32ch %w0, %w0, %w1" : "+r"(c) : "r"(x)); return c;
  case 32: __asm__(".arch_extension crc\n\tcrc32cw %w0, %w0, %w1" : "+r"(c) : "r"(x)); return c;
  default: __asm__(".arch_extension crc\n\tcrc32cx %w0, %w0, %x1" : "+r"(c) : "r"(x)); return c;
  }
}
#elif defined(__x86_64__) && !defined(DEFK_NO_HW_BUILTINS)
#define DEFK_HW_CRC32C 1
#include <cpuid.h>
static int defk_cpu_crc32c(void) {
  unsigned a, b, c, d;
  return __get_cpuid(1, &a, &b, &c, &d) && (c & bit_SSE4_2) != 0;
}
/* as on arm64: a 32-bit destination clears the top half of the register */
static inline uint64_t defk_crc32c_hw(uint64_t c, uint64_t x, int w) {
  switch (w) {
  case 8: __asm__("crc32b %b1, %k0" : "+r"(c) : "q"(x)); return c;
  case 16: __asm__("crc32w %w1, %k0" : "+r"(c) : "r"(x)); return c;
  case 32: __asm__("crc32l %k1, %k0" : "+r"(c) : "r"(x)); return c;
  default: __asm__("crc32q %1, %0" : "+r"(c) : "r"(x)); return c;
  }
}
#endif

__attribute__((unused)) static uint32_t defk_crc32c_t[8][256];
__attribute__((unused)) static atomic_int defk_crc32c_state; /* 0 unknown, 1 instruction, 2 table */
__attribute__((unused)) static pthread_once_t defk_crc32c_once = PTHREAD_ONCE_INIT;
__attribute__((unused)) static void defk_crc32c_init_once(void) {
  int hw = 0;
#ifdef DEFK_HW_CRC32C
  /* enif_getenv reads the emulator's environment, which System.put_env/2
     changes (getenv does not see it) */
  char e[8];
  size_t n = sizeof e;
  int portable = enif_getenv("DEFK_PORTABLE_BUILTINS", e, &n);
  portable = portable == 1 || (portable == 0 && n > 0 && strcmp(e, "0") != 0);
  hw = !portable && defk_cpu_crc32c();
#endif
  if (!hw) {
    for (uint32_t n = 0; n < 256; n++) {
      uint32_t c = n;
      for (int k = 0; k < 8; k++) c = (c >> 1) ^ (0x82F63B78u & (0u - (c & 1u)));
      defk_crc32c_t[0][n] = c;
    }
    for (int k = 1; k < 8; k++)
      for (uint32_t n = 0; n < 256; n++) {
        uint32_t c = defk_crc32c_t[k - 1][n];
        defk_crc32c_t[k][n] = (c >> 8) ^ defk_crc32c_t[0][c & 255];
      }
  }
  atomic_store_explicit(&defk_crc32c_state, hw ? 1 : 2, memory_order_release);
}
__attribute__((noinline, cold, unused)) static int defk_crc32c_init(void) {
  pthread_once(&defk_crc32c_once, defk_crc32c_init_once);
  return atomic_load_explicit(&defk_crc32c_state, memory_order_acquire);
}
/* table k advances a byte by k + 1 bytes: slicing-by-8 for a 64-bit word */
static inline uint32_t defk_crc32c_sw(uint32_t c, uint64_t x, int w) {
  uint32_t(*t)[256] = defk_crc32c_t;
  switch (w) {
  case 8: return (c >> 8) ^ t[0][(c ^ (uint32_t)x) & 255];
  case 16: c ^= (uint32_t)x; return (c >> 16) ^ t[1][c & 255] ^ t[0][(c >> 8) & 255];
  case 32:
    c ^= (uint32_t)x;
    return t[3][c & 255] ^ t[2][(c >> 8) & 255] ^ t[1][(c >> 16) & 255] ^ t[0][c >> 24];
  default: {
    uint32_t lo = c ^ (uint32_t)x, hi = (uint32_t)(x >> 32);
    return t[7][lo & 255] ^ t[6][(lo >> 8) & 255] ^ t[5][(lo >> 16) & 255] ^ t[4][lo >> 24] ^
           t[3][hi & 255] ^ t[2][(hi >> 8) & 255] ^ t[1][(hi >> 16) & 255] ^ t[0][hi >> 24];
  }
  }
}
/* w is 8, 16, 32 or 64, c < 2^32 and x < 2^w */
static inline uint64_t defk_crc32c(uint64_t c, uint64_t x, int w) {
  int s = atomic_load_explicit(&defk_crc32c_state, memory_order_relaxed);
#ifdef DEFK_HW_CRC32C
  if (DEFK_LIKELY(s == 1)) return defk_crc32c_hw(c, x, w);
#endif
  if (DEFK_UNLIKELY(s != 2)) s = defk_crc32c_init();
#ifdef DEFK_HW_CRC32C
  if (s == 1) return defk_crc32c_hw(c, x, w);
#endif
  atomic_thread_fence(memory_order_acquire);
  return defk_crc32c_sw((uint32_t)c, x, w);
}
/* the checks of Defk.Bits.crc32c/3, in its order: the width, then crc as a
 * 32-bit value, then x as a w-bit value; the forms the compiler calls take
 * an i64 (sign checked) or a u64 crc and x */
__attribute__((noreturn, cold, unused)) static void defk_crc32c_width(defk_ctx *ctx, int64_t w) {
  defk_fail(ctx, DEFK_E_ARG, "Defk.Bits.crc32c/3: width %lld is not 8, 16, 32 or 64", (long long)w);
}
static inline int64_t defk_crc32c_k(defk_ctx *ctx, uint64_t c, int cneg, uint64_t x, int xneg,
                                    int64_t w) {
  if (DEFK_UNLIKELY(w != 8 && w != 16 && w != 32 && w != 64)) defk_crc32c_width(ctx, w);
  c = defk_field_arg(ctx, "crc32c/3", c, cneg, 32);
  x = defk_field_arg(ctx, "crc32c/3", x, xneg, w);
  return (int64_t)defk_crc32c(c, x, (int)w);
}
static inline int64_t defk_crc32c_ii(defk_ctx *ctx, int64_t c, int64_t x, int64_t w) { return defk_crc32c_k(ctx, (uint64_t)c, c < 0, (uint64_t)x, x < 0, w); }
static inline int64_t defk_crc32c_iu(defk_ctx *ctx, int64_t c, uint64_t x, int64_t w) { return defk_crc32c_k(ctx, (uint64_t)c, c < 0, x, 0, w); }
static inline int64_t defk_crc32c_ui(defk_ctx *ctx, uint64_t c, int64_t x, int64_t w) { return defk_crc32c_k(ctx, c, 0, (uint64_t)x, x < 0, w); }
static inline int64_t defk_crc32c_uu(defk_ctx *ctx, uint64_t c, uint64_t x, int64_t w) { return defk_crc32c_k(ctx, c, 0, x, 0, w); }
static inline uint64_t defk_min_u64(uint64_t a, uint64_t b) { return a < b ? a : b; }
static inline uint64_t defk_max_u64(uint64_t a, uint64_t b) { return a > b ? a : b; }
static inline uint64_t defk_f64_to_u64(double x) {
  uint64_t u;
  __builtin_memcpy(&u, &x, 8);
  return u;
}
static inline int64_t defk_min_i64(int64_t a, int64_t b) { return a < b ? a : b; }
static inline int64_t defk_max_i64(int64_t a, int64_t b) { return a > b ? a : b; }
/* Erlang's min/max return the first argument when the two compare equal
 * (erlang:min(A, B) when A > B -> B; min(A, _) -> A), so min(-0.0, 0.0) is
 * -0.0 and min(0.0, -0.0) is 0.0.
 * A plain select, so loops over min/max still vectorise; x86 does each in one
 * minsd/maxsd. On arm64 max(x, 0.0) no longer folds to fmaxnm, which gives
 * 0.0 for -0.0 where Elixir gives -0.0. */
static inline double defk_min_f64(double a, double b) { return a > b ? b : a; }
static inline double defk_max_f64(double a, double b) { return a < b ? b : a; }

/* ---- comparisons Elixir's way -------------------------------------------- */

/* -1, 0 or 1 as the exact value of i is below, equal to or above f, as Erlang
 * compares an integer with a float (erts_cmp_compound in erts utils.c): never
 * by rounding i to a double, which would make 2^53 + 1 == 2^53 + 0.0.
 * Kernel floats are never NaN (every operation that could make one raises);
 * one would compare below every integer. */
static inline int defk_cmp_i64_f64(int64_t i, double f) {
  if (f >= 0x1p63) return -1;           /* above every i64 */
  if (!(f >= -0x1p63)) return 1;        /* below every i64 (or NaN) */
  int64_t t = (int64_t)f;               /* f's integer part, exact here */
  if (i != t) return i < t ? -1 : 1;
  double frac = f - (double)t;          /* exact: t is f truncated */
  return frac > 0.0 ? -1 : frac < 0.0 ? 1 : 0;
}

/* the same for a u64, and a u64 against an i64 (exact, both integers) */
static inline int defk_cmp_u64_f64(uint64_t u, double f) {
  if (u <= (uint64_t)INT64_MAX) return defk_cmp_i64_f64((int64_t)u, f);
  if (f >= 0x1p64) return -1;           /* above every u64 */
  if (!(f >= 0x1p63)) return 1;         /* below 2^63 <= u (or NaN) */
  uint64_t t = (uint64_t)f;             /* f is an integer here (>= 2^53) */
  return u < t ? -1 : u > t ? 1 : 0;
}
static inline int defk_cmp_u64_i64(uint64_t u, int64_t i) {
  if (i < 0) return 1;
  return u < (uint64_t)i ? -1 : u > (uint64_t)i ? 1 : 0;
}

/* === on two floats: Erlang's exact equality tells -0.0 from 0.0 */
static inline int defk_feq_exact(double a, double b) {
  uint64_t x, y;
  __builtin_memcpy(&x, &a, 8);
  __builtin_memcpy(&y, &b, 8);
  return x == y;
}

/* ---- bounds-checked element access --------------------------------------- */

#define DEFK_ACCESS_FN(T, CT)                                                       \
  static inline CT defk_get_##T(defk_ctx *ctx, defk_arr_##T a, int64_t i) {         \
    if (DEFK_UNLIKELY((uint64_t)i >= (uint64_t)a.len)) defk_oob(ctx, i, a.len);     \
    return a.data[i];                                                               \
  }                                                                                 \
  static inline void defk_put_##T(defk_ctx *ctx, defk_arr_##T a, int64_t i, CT v) { \
    if (DEFK_UNLIKELY((uint64_t)i >= (uint64_t)a.len)) defk_oob(ctx, i, a.len);     \
    a.data[i] = v;                                                                  \
  }                                                                                 \
  /* flagged forms (flat strips, below): never touch memory outside a */           \
  static inline CT defk_get_##T##_f(int *nf, defk_arr_##T a, int64_t i) {           \
    static const CT zero = 0;                                                       \
    int bad = (uint64_t)i >= (uint64_t)a.len;                                       \
    *nf |= bad;                                                                     \
    return (bad ? &zero : (const CT *)a.data)[bad ? 0 : i];                         \
  }                                                                                 \
  static inline void defk_put_##T##_f(int *nf, CT *sink, defk_arr_##T a, int64_t i, \
                                      CT v) {                                       \
    int bad = (uint64_t)i >= (uint64_t)a.len;                                       \
    *nf |= bad;                                                                     \
    (bad ? sink : a.data)[bad ? 0 : i] = v;                                         \
  }
DEFK_ACCESS_FN(f64, double)
DEFK_ACCESS_FN(i64, int64_t)
DEFK_ACCESS_FN(u8, uint8_t)
DEFK_ACCESS_FN(u64, uint64_t)
DEFK_ACCESS_FN(i16, int16_t)
DEFK_ACCESS_FN(i32, int32_t)
DEFK_ACCESS_FN(f32, float)

/*
 * Word loads from a [u8] (u64_le(bytes, i) and friends): the unsigned
 * w-byte integer at byte offset i, as Elixir's
 * <<_::binary-size(i), x::little-unsigned-size(w * 8), _::binary>> = bytes.
 * An unaligned load: __builtin_memcpy (not disabled by -fno-builtin) into an
 * integer compiles to one load, plus a bswap for the other byte order. A u64
 * value is returned as its i64 bit pattern (a value with the top bit set is
 * negative). The checked form raises like a[i] when i < 0 or i + w > len;
 * the _at form is for an offset the compiler proved in range.
 */
__attribute__((noreturn, cold, unused)) static void defk_oob_load(defk_ctx *ctx, int64_t i, int w,
                                                          int64_t len) {
  ctx->err_index = i;
  defk_fail(ctx, DEFK_E_OOB, "%d-byte load at index %lld out of bounds for array of length %lld",
            w, (long long)i, (long long)len);
}
#if defined(__BYTE_ORDER__) && __BYTE_ORDER__ == __ORDER_BIG_ENDIAN__
#define DEFK_LE(B, x) __builtin_bswap##B(x)
#define DEFK_BE(B, x) (x)
#else
#define DEFK_LE(B, x) (x)
#define DEFK_BE(B, x) __builtin_bswap##B(x)
#endif
#define DEFK_LOAD_FN(NAME, B, ORDER)                                                \
  static inline int64_t defk_##NAME##_at(const uint8_t *p) {                        \
    uint##B##_t x;                                                                  \
    __builtin_memcpy(&x, p, B / 8);                                                 \
    return (int64_t)ORDER(B, x);                                                    \
  }                                                                                 \
  static inline int64_t defk_##NAME(defk_ctx *ctx, defk_arr_u8 a, int64_t i) {      \
    if (DEFK_UNLIKELY(i < 0 || i > a.len - B / 8)) defk_oob_load(ctx, i, B / 8, a.len); \
    return defk_##NAME##_at(a.data + i);                                            \
  }
DEFK_LOAD_FN(u64_le, 64, DEFK_LE)
DEFK_LOAD_FN(u64_be, 64, DEFK_BE)
DEFK_LOAD_FN(u32_le, 32, DEFK_LE)
DEFK_LOAD_FN(u32_be, 32, DEFK_BE)
DEFK_LOAD_FN(u16_le, 16, DEFK_LE)
DEFK_LOAD_FN(u16_be, 16, DEFK_BE)

/*
 * An f64 element read from an array the kernel did not create (an input) may
 * hold inf or NaN bits, which no BEAM float can: the read raises ArgumentError
 * like Elixir mode's <<x::float-64>> match, and only elements actually read
 * count. Arrays from alloc/2 hold only finite values, so their
 * reads skip the check.
 */
__attribute__((noreturn, cold)) static void defk_nonfinite_input(defk_ctx *ctx, int64_t i) {
  defk_fail(ctx, DEFK_E_ARG,
            "non-finite float (inf or NaN) read from an input array at index %lld", (long long)i);
}
/* an element read whose index is in range (checked or proved) */
static inline double defk_in_f64(defk_ctx *ctx, double x, int64_t i) {
  if (!DEFK_FINITE(x)) defk_nonfinite_input(ctx, i);
  return x;
}
static inline double defk_get_in_f64(defk_ctx *ctx, defk_arr_f64 a, int64_t i) {
  return defk_in_f64(ctx, defk_get_f64(ctx, a, i), i);
}

/*
 * Flat strips. A branch per float operation stops clang from
 * vectorising a flat loop, so the compiler runs a flat strip whose only
 * possible errors are float checks (+ - * /, sqrt, log, exp, pow, [f64] input
 * reads) with a flag instead: it #defines each checked helper below to its
 * DEFK_NF_ form for that copy of the body, which ORs "inf or NaN" into the
 * block-local defk_nf (no branch, no call) and computes the same value. The
 * flag is tested once at the strip's end; if set, the strip is replayed from
 * its snapshot with the raising forms, which raise at the first failing
 * operation in Elixir's order. Every value the flagged form computes is the
 * checked form's value: a NaN or inf it lets through only flows into more
 * flagged operations, plain comparisons and array writes the replay redoes.
 */
static inline double defk_nf_r(int *nf, double r) {
  *nf |= DEFK_NONFIN(r);
  return r;
}
#define DEFK_NF_fadd(C, A, B) defk_nf_r(&defk_nf, (double)(A) + (double)(B))
#define DEFK_NF_fsub(C, A, B) defk_nf_r(&defk_nf, (double)(A) - (double)(B))
#define DEFK_NF_fmul(C, A, B) defk_nf_r(&defk_nf, (double)(A) * (double)(B))
#define DEFK_NF_fdiv(C, A, B) defk_nf_r(&defk_nf, (double)(A) / (double)(B))
#define DEFK_NF_in_f64(C, X, I) defk_nf_r(&defk_nf, (X))
/* a read whose inf or NaN a later check of the strip is sure to see
   (seen_later/1 in the compiler): no check of its own */
#define defk_in_f64_later(C, X, I) (X)
/* sqrt, log, log2 and log10 of a finite argument are inf or NaN exactly where the checked
   forms raise (a < 0.0, a <= 0.0) */
#define DEFK_NF_sqrt(C, A) defk_nf_r(&defk_nf, __builtin_sqrt(A))
#define DEFK_NF_log(C, A) defk_nf_r(&defk_nf, log(A))
#define DEFK_NF_log2(C, A) defk_nf_r(&defk_nf, log2(A))
#define DEFK_NF_log10(C, A) defk_nf_r(&defk_nf, log10(A))
#define DEFK_NF_exp(C, A) defk_nf_r(&defk_nf, exp(A))
#define DEFK_NF_pow(C, A, B) defk_nf_r(&defk_nf, pow((A), (B)))
/* a float expression's single check (float_tree in the compiler): raise
   through its replay, or in a flagged strip, flag and skip the replay */
#define DEFK_FCHECK(B) if (DEFK_UNLIKELY(B))
#define DEFK_NF_FCHECK(B) defk_nf |= (B); if (0)

/*
 * A strip with float checks may also hold i64/u64 overflow checks, bounds
 * checks, narrow-write range checks and float-to-integer conversions.
 * Their DEFK_NF_ forms OR the failure into the same defk_nf and
 * compute on: an overflowing + - * gives the wrapped value (the builtins
 * define it), a conversion out of range gives 0 or the truncated value. Any
 * failure replays the strip with the raising forms, so the first error in
 * program order still wins: up to the first failing check the flagged and
 * the replayed run compute the same values, take the same branches and make
 * the same writes, and the replay raises at that check.
 *
 * Memory safety: what the flagged run computes after its first failure is
 * thrown away, but it still runs, so no flagged form may touch memory it
 * should not. An element access out of bounds reads a static zero or writes
 * the strip's local defk_sink instead: the address is selected from (array,
 * index) or (zero/sink, 0), never formed from an index out of bounds, and
 * there is no branch. Every other access in such a strip is an unchecked
 * a.data[i] whose index the compiler proved in range from values the flagged
 * run computes exactly (flag_strip/3 in the compiler: only the loop counter
 * and values not assigned in the strip), so a wrong value from a failed
 * operation never reaches an address. Writes to in-range elements after the
 * failure are redone by the replay up to the raise, and the array is never
 * returned once the kernel raises.
 */
typedef union {
  double f64;
  float f32;
  int64_t i64;
  uint64_t u64;
  int32_t i32;
  int16_t i16;
  uint8_t u8;
} defk_nf_sink;
#define DEFK_NF_add_i64(C, A, B) defk_add_i64_s(&defk_nf, (A), (B))
#define DEFK_NF_sub_i64(C, A, B) defk_sub_i64_s(&defk_nf, (A), (B))
#define DEFK_NF_mul_i64(C, A, B) defk_mul_i64_s(&defk_nf, (A), (B))
#define DEFK_NF_neg_i64(C, A) defk_neg_i64_s(&defk_nf, (A))
#define DEFK_NF_abs_i64(C, A) defk_abs_i64_s(&defk_nf, (A))
#define DEFK_NF_add_u64(C, A, B) defk_add_u64_s(&defk_nf, (A), (B))
#define DEFK_NF_sub_u64(C, A, B) defk_sub_u64_s(&defk_nf, (A), (B))
#define DEFK_NF_mul_u64(C, A, B) defk_mul_u64_s(&defk_nf, (A), (B))
#define DEFK_NF_trunc(C, A) defk_trunc_s(&defk_nf, (A))
#define DEFK_NF_round(C, A) defk_round_s(&defk_nf, (A))
#define DEFK_NF_get_in_f64(C, A, I) defk_nf_r(&defk_nf, defk_get_f64_f(&defk_nf, (A), (I)))
#define DEFK_NF_get_f64(C, A, I) defk_get_f64_f(&defk_nf, (A), (I))
#define DEFK_NF_get_i64(C, A, I) defk_get_i64_f(&defk_nf, (A), (I))
#define DEFK_NF_get_u8(C, A, I) defk_get_u8_f(&defk_nf, (A), (I))
#define DEFK_NF_get_u64(C, A, I) defk_get_u64_f(&defk_nf, (A), (I))
#define DEFK_NF_get_i16(C, A, I) defk_get_i16_f(&defk_nf, (A), (I))
#define DEFK_NF_get_i32(C, A, I) defk_get_i32_f(&defk_nf, (A), (I))
#define DEFK_NF_get_f32(C, A, I) defk_get_f32_f(&defk_nf, (A), (I))
#define DEFK_NF_put_f64(C, A, I, V) defk_put_f64_f(&defk_nf, &defk_sink.f64, (A), (I), (V))
#define DEFK_NF_put_i64(C, A, I, V) defk_put_i64_f(&defk_nf, &defk_sink.i64, (A), (I), (V))
#define DEFK_NF_put_u8(C, A, I, V) defk_put_u8_f(&defk_nf, &defk_sink.u8, (A), (I), (V))
#define DEFK_NF_put_u64(C, A, I, V) defk_put_u64_f(&defk_nf, &defk_sink.u64, (A), (I), (V))
#define DEFK_NF_put_i16(C, A, I, V) defk_put_i16_f(&defk_nf, &defk_sink.i16, (A), (I), (V))
#define DEFK_NF_put_i32(C, A, I, V) defk_put_i32_f(&defk_nf, &defk_sink.i32, (A), (I), (V))
#define DEFK_NF_put_f32(C, A, I, V) defk_put_f32_f(&defk_nf, &defk_sink.f32, (A), (I), (V))

static inline uint8_t defk_to_u8(defk_ctx *ctx, int64_t v) {
  if (DEFK_UNLIKELY(v < 0 || v > 255)) defk_fail(ctx, DEFK_E_ARG, "value %lld does not fit in u8", (long long)v);
  return (uint8_t)v;
}
/* a u64 as an i64 for a narrow write's range check: one above 2^63 - 1
   saturates, which no narrow type holds */
static inline int64_t defk_u64_sat(uint64_t v) {
  return v > (uint64_t)INT64_MAX ? INT64_MAX : (int64_t)v;
}
static inline int16_t defk_to_i16(defk_ctx *ctx, int64_t v) {
  if (DEFK_UNLIKELY(v < INT16_MIN || v > INT16_MAX))
    defk_fail(ctx, DEFK_E_ARG, "value %lld does not fit in i16", (long long)v);
  return (int16_t)v;
}
static inline int32_t defk_to_i32(defk_ctx *ctx, int64_t v) {
  if (DEFK_UNLIKELY(v < INT32_MIN || v > INT32_MAX))
    defk_fail(ctx, DEFK_E_ARG, "value %lld does not fit in i32", (long long)v);
  return (int32_t)v;
}
/* their flagged forms: the truncated value, the failure flagged */
#define DEFK_NF_to_u8(C, V) defk_to_narrow_f(&defk_nf, (V), 0, 255, uint8_t)
#define DEFK_NF_to_i16(C, V) defk_to_narrow_f(&defk_nf, (V), INT16_MIN, INT16_MAX, int16_t)
#define DEFK_NF_to_i32(C, V) defk_to_narrow_f(&defk_nf, (V), INT32_MIN, INT32_MAX, int32_t)
#define defk_to_narrow_f(NF, V, LO, HI, CT)                                         \
  ({                                                                                \
    int64_t defk_v_ = (V);                                                          \
    *(NF) |= defk_v_ < (LO) || defk_v_ > (HI);                                      \
    (CT) defk_v_;                                                                   \
  })

/*
 * An [f32] write: v rounded to nearest, as Elixir's <<v::float-32-native>>
 * (the C conversion under the default rounding mode). Underflow to 0.0 and
 * subnormals are Elixir's result too. A value that rounds to +-inf, which
 * Elixir would store, raises (a limit). v is finite (every float
 * operation checked it), so the converted value is inf exactly when it
 * overflowed. In a flagged strip the DEFK_NF_ form flags it instead, and the
 * replay raises here (f32 writes feed the strip's flag).
 */
__attribute__((noreturn, cold)) static void defk_f32_range(defk_ctx *ctx, double v) {
  defk_fail(ctx, DEFK_E_ARG, "value %.17g does not fit in f32", v);
}
static inline float defk_to_f32(defk_ctx *ctx, double v) {
  float f = (float)v;
  if (DEFK_UNLIKELY(!(__builtin_fabsf(f) <= 0x1.fffffep+127f))) defk_f32_range(ctx, v);
  return f;
}
#define DEFK_NF_to_f32(C, V) ((float)defk_nf_r(&defk_nf, (double)(float)(V)))

/*
 * The bitstring accumulator: acc = <<acc::bitstring, v::size(n)>>.
 * A value is {nbits, slot + 1} (0: the empty bitstring, no buffer, which is
 * what a zeroed local holds). Its buffer is an owned binary, so it stays put
 * across yields, and is freed on an exception or process death like an array.
 * The buffer's first 8 bytes hold its end, the number of bits written to it;
 * the bits follow MSB-first (Elixir's big-endian default), and everything past
 * the end is zero, so an append ORs its bits in.
 *
 * A value is a prefix of its buffer, so a value is never changed by a later
 * append, as in Elixir. An append to a value that ends at its buffer's end
 * writes in place (the common acc = <<acc::bitstring, ...>>); an append to an
 * older, shorter value (`b = <<a::bitstring, 1::1>>` then `c = <<a::bitstring,
 * 0::1>>`) copies its bits into a new buffer first, as the BEAM's own binary
 * append does.
 */
typedef struct { int64_t nbits; int slot1; } defk_bits;

#define DEFK_BITS_HDR 8

/* the end of b's buffer (b has one) */
static inline uint64_t defk_bits_end(defk_ctx *ctx, defk_bits b) {
  uint64_t end;
  __builtin_memcpy(&end, ctx->owned[b.slot1 - 1].data, sizeof end);
  return end;
}

/* b with a buffer of its own that ends at b and has room for `more` bits,
   plus the 8 bytes of slack an append's word store needs */
__attribute__((noinline, unused)) static defk_bits defk_bits_reserve(defk_ctx *ctx, defk_bits b,
                                                             int64_t more) {
  uint64_t need = ((uint64_t)b.nbits + (uint64_t)more + 7) / 8 + 8 + DEFK_BITS_HDR;
  if (need > DEFK_ALLOC_MAX_BYTES) defk_fail(ctx, DEFK_E_ARG, "bitstring too large");
  if (b.slot1 && defk_bits_end(ctx, b) == (uint64_t)b.nbits) {
    /* ours, at its end: grow in place, doubling */
    ErlNifBinary *bin = &ctx->owned[b.slot1 - 1];
    size_t old = bin->size, cap = old * 2;
    if (cap < need) cap = (size_t)need;
    defk_owned_check(ctx, cap - old);
    if (!enif_realloc_binary(bin, cap))
      defk_fail(ctx, DEFK_E_ARG, "out of memory (allocating %zu bytes)", cap);
    DEFK_POISON_SLACK(bin);
    ctx->owned_bytes += cap - old;
    memset(bin->data + old, 0, cap - old);
    return b;
  }
  /* empty, or an older value of a buffer appended past it: a new buffer
     holding b's bits, the bits after them in its last byte cleared */
  size_t cap = need < 64 ? 64 : (size_t)need;
  int slot = defk_own(ctx, cap);
  size_t bytes = (size_t)(b.nbits + 7) / 8;
  uint8_t *data = ctx->owned[slot].data;
  if (bytes) {
    memcpy(data + DEFK_BITS_HDR, ctx->owned[b.slot1 - 1].data + DEFK_BITS_HDR, bytes);
    if (b.nbits & 7) data[DEFK_BITS_HDR + bytes - 1] &= (uint8_t)(0xFF00u >> (b.nbits & 7));
  }
  uint64_t end = (uint64_t)b.nbits;
  __builtin_memcpy(data, &end, sizeof end);
  defk_bits r = {b.nbits, slot + 1};
  return r;
}

/* the low n bits of v (1 <= n <= 57) at bit `pos` of p, MSB-first; the bits
   from pos on are zero, and p has 8 readable bytes from pos / 8 */
static inline void defk_bits_or(uint8_t *p, uint64_t pos, uint64_t v, int64_t n) {
  uint8_t *q = p + (pos >> 3);
  uint64_t w;
  __builtin_memcpy(&w, q, 8);
  w = DEFK_BE(64, w) | ((v << (64 - n)) >> (pos & 7));
  w = DEFK_BE(64, w);
  __builtin_memcpy(q, &w, 8);
}

__attribute__((noreturn, cold, unused)) static void defk_bits_fail(defk_ctx *ctx, int64_t v, int64_t n,
                                                                    int is_signed) {
  if (n < 0 || n > 64)
    defk_fail(ctx, DEFK_E_ARG, "bitstring segment size %lld is outside 0..64", (long long)n);
  defk_fail(ctx, DEFK_E_ARG, "bitstring segment value %lld does not fit in %lld%s bits",
            (long long)v, (long long)n, is_signed ? " signed" : "");
}

/* <<b::bitstring, v::size(n)>>, unsigned: v must be in 0..2^n - 1 (Elixir
   would keep the low n bits; a limit, like an array write) and n in 0..64 */
static inline defk_bits defk_bits_append(defk_ctx *ctx, defk_bits b, uint64_t v, int64_t n);

static inline defk_bits defk_bits_put(defk_ctx *ctx, defk_bits b, int64_t v, int64_t n) {
  if (DEFK_UNLIKELY((uint64_t)n > 64 || (n < 64 ? ((uint64_t)v >> n) != 0 : v < 0)))
    defk_bits_fail(ctx, v, n, 0);
  return defk_bits_append(ctx, b, (uint64_t)v, n);
}

/* the same for a u64 value: v must be below 2^n (any u64 for n = 64) */
static inline defk_bits defk_bits_put_u64(defk_ctx *ctx, defk_bits b, uint64_t v, int64_t n) {
  if (DEFK_UNLIKELY((uint64_t)n > 64 || (n < 64 && (v >> n) != 0))) {
    if ((uint64_t)n <= 64 && v > (uint64_t)INT64_MAX)
      defk_fail(ctx, DEFK_E_ARG, "bitstring segment value %llu does not fit in %lld bits",
                (unsigned long long)v, (long long)n);
    defk_bits_fail(ctx, (int64_t)v, n, 0);
  }
  return defk_bits_append(ctx, b, v, n);
}

/* <<b::bitstring, v::size(n)-signed>>: v must be in -2^(n-1)..2^(n-1) - 1
   (n = 0 holds only 0; n = 64 takes every i64). The low n bits of v, as an
   unsigned segment, are appended. The bounds are built by shifting 1 left by
   at most 62 and negating, so there is no shift by 64 and no left shift of a
   negative value. */
static inline defk_bits defk_bits_put_signed(defk_ctx *ctx, defk_bits b, int64_t v, int64_t n) {
  if (DEFK_UNLIKELY((uint64_t)n > 64)) defk_bits_fail(ctx, v, n, 1);
  if (n == 0) {
    if (DEFK_UNLIKELY(v != 0)) defk_bits_fail(ctx, v, n, 1);
  } else if (n < 64) {
    int64_t hi = (int64_t)(((uint64_t)1 << (n - 1)) - 1);
    if (DEFK_UNLIKELY(v > hi || v < -hi - 1)) defk_bits_fail(ctx, v, n, 1);
  }
  uint64_t u = (uint64_t)v;
  if (n < 64) u &= ((uint64_t)1 << n) - 1;
  return defk_bits_append(ctx, b, u, n);
}

static inline defk_bits defk_bits_append(defk_ctx *ctx, defk_bits b, uint64_t v, int64_t n) {
  if (n == 0) return b;
  if (DEFK_UNLIKELY(!b.slot1 || defk_bits_end(ctx, b) != (uint64_t)b.nbits ||
                    ((uint64_t)b.nbits + (uint64_t)n + 7) / 8 + 8 + DEFK_BITS_HDR >
                        ctx->owned[b.slot1 - 1].size))
    b = defk_bits_reserve(ctx, b, n);
  uint8_t *p = ctx->owned[b.slot1 - 1].data;
  uint64_t pos = (uint64_t)b.nbits;
  if (n > 56) {
    defk_bits_or(p + DEFK_BITS_HDR, pos, v >> 32, n - 32);
    defk_bits_or(p + DEFK_BITS_HDR, pos + (uint64_t)(n - 32), v & 0xFFFFFFFFu, 32);
  } else {
    defk_bits_or(p + DEFK_BITS_HDR, pos, v, n);
  }
  b.nbits += n;
  uint64_t end = (uint64_t)b.nbits;
  __builtin_memcpy(p, &end, sizeof end);
  return b;
}

/* A bitstring result: {Bytes, BitLength}. The generated Elixir wrapper takes
   the first BitLength bits of Bytes (<<b::bitstring-size(len), _::bitstring>>).
   The bytes are copied out, so the buffer's slack is not returned. */
__attribute__((unused)) static ERL_NIF_TERM defk_make_bits(ErlNifEnv *env, defk_ctx *ctx, defk_bits b) {
  size_t bytes = (size_t)(b.nbits + 7) / 8;
  ERL_NIF_TERM bin;
  uint8_t *d = enif_make_new_binary(env, bytes, &bin);
  if (bytes) memcpy(d, ctx->owned[b.slot1 - 1].data + DEFK_BITS_HDR, bytes);
  return enif_make_tuple2(env, bin, enif_make_int64(env, b.nbits));
}

/* ---- scheduling ---------------------------------------------------------- */

/*
 * Safepoint clock. Loops count back-edges against an adaptive budget so the
 * clock is read every DEFK_SLICE_US/10 .. /4 no matter how expensive one
 * iteration is (an outer loop may call a kernel with its own inner loop).
 * Returns 0 when the kernel should yield, else the next back-edge budget.
 * A yielding kernel saves c->budget so it resumes at the adapted rate: a
 * reset would let it run DEFK_BUDGET0 expensive iterations unchecked.
 */
typedef struct {
  ErlNifTime last;
  ErlNifTime unreported; /* microseconds x 100 not yet charged to the process */
  int64_t budget;        /* adapted back-edge budget, kept across a yield */
  defk_ctx *ctx;         /* the call's slice state */
} defk_clock;

/* overridable like DEFK_STRIP: the fuzz targets' small-strips build sets 1,
   so a short input yields at every safepoint (verify/fuzz) */
#ifndef DEFK_BUDGET0
#define DEFK_BUDGET0 256
#endif

/*
 * Wall-clock time charged as one full timeslice (100% of a process's
 * reductions), so a kernel yields about this often. ERTS allows a NIF ~1ms,
 * but a busy Elixir process yields every few microseconds, so at 1ms a kernel
 * delays the other processes on its scheduler ~1.5ms more than Elixir code
 * would (bench/tick_gap.exs). A yield costs a few microseconds of scheduler
 * work (mostly its I/O poll), so shorter is slower: 250us keeps the delay
 * close to Elixir's for <3% on count_primes and no measurable loss on
 * fuzzy_search (bench/yield_cost.exs).
 */
#ifndef DEFK_SLICE_US
#define DEFK_SLICE_US 250
#endif

/* Flat inner loops (no nested loop, including one in an inlined kernel call)
 * run up to this many iterations without a safepoint, so the check does not
 * stop vectorisation. Even expensive builtins (exp, pow) keep that below the
 * clock period. A loop just over the limit pays for a second, short strip:
 * at 512, count_primes' trial division (up to 1000 trips at 1M) ran 6%
 * slower than yield: false; at 2048 it is within 1%. */
#ifndef DEFK_STRIP
#define DEFK_STRIP 2048
#endif

/*
 * A crowded run queue gets a short slice for the call's first millisecond.
 * ERTS wakes an idle scheduler from a run queue with waiting
 * processes by the reductions run there, and a kernel charges a whole
 * timeslice (4000 reductions) per slice, so at 250 us short kernel calls
 * fanned out from one process (Task.async_stream) stayed on 2-3 of 12
 * schedulers. At 50 us they charge five times faster and spread. A lone call
 * keeps 250 us (a 50 us slice costs it ~7-8% on a busy scheduler), and so
 * does a crowded call after its first millisecond: calls that long spread
 * anyway. The generated Elixir function passes the hint as an extra last
 * argument, :erlang.statistics(:total_run_queue_lengths) (~9 ns); the NIF
 * API has no run-queue length. docs/performance.md 4.9.
 */
#ifndef DEFK_SHORT_SLICE_US
#define DEFK_SHORT_SLICE_US 50
#endif
#ifndef DEFK_SHORT_FOR_US
#define DEFK_SHORT_FOR_US 1000
#endif

/* hint: the run-queue length the caller saw (NULL: none passed) */
__attribute__((unused)) static void defk_slice_init(ErlNifEnv *env, defk_ctx *ctx, const ERL_NIF_TERM *hint) {
  ErlNifSInt64 waiting; /* not int64_t: enif_get_int64 takes long * on macOS */
  if (hint && enif_get_int64(env, *hint, &waiting) && waiting > 0) {
    ctx->slice_us = DEFK_SHORT_SLICE_US;
    ctx->short_left = DEFK_SHORT_FOR_US;
  } else {
    ctx->slice_us = DEFK_SLICE_US;
    ctx->short_left = 0;
  }
}

static void defk_clock_init(defk_clock *c, defk_ctx *ctx) {
  c->last = enif_monotonic_time(ERL_NIF_USEC);
  c->unreported = 0;
  c->ctx = ctx;
}

#ifdef DEFK_FAULT_HOOKS
/* testing: the next clock read faults on purpose; see defk_inject_fault */
static _Atomic int defk_inject_fault = 0;
static void defk_inject_fault_now(int kind);
#endif

__attribute__((noinline)) static int64_t defk_tick(ErlNifEnv *env, defk_clock *c, int64_t budget) {
  c->budget = budget;
#ifdef DEFK_FAULT_HOOKS
  /* kind + 256 * (clock reads to let pass first) */
  int inj = atomic_load_explicit(&defk_inject_fault, memory_order_relaxed);
  if (DEFK_UNLIKELY(inj)) {
    if (inj >= 256) atomic_store(&defk_inject_fault, inj - 256);
    else defk_inject_fault_now(inj);
  }
#endif
  if (atomic_load_explicit(&defk_force_yields, memory_order_relaxed)) return 0;
  ErlNifTime now = enif_monotonic_time(ERL_NIF_USEC);
  ErlNifTime dt = now - c->last;
  defk_ctx *ctx = c->ctx;
  int64_t slice = ctx->slice_us;
  c->last = now;
  if (dt < slice / 10 && budget < (1 << 24)) budget *= 2;
  else if (dt > slice / 4 && budget > 16) budget /= 2;
  c->budget = budget;
  c->unreported += dt * 100;
  long pct = (long)(c->unreported / slice);
  if (DEFK_UNLIKELY(ctx->short_left > 0) && (ctx->short_left -= dt) <= 0) ctx->slice_us = DEFK_SLICE_US;
  if (pct >= 1) {
    c->unreported -= pct * slice;
    if (enif_consume_timeslice(env, pct > 100 ? 100 : (int)pct)) return 0;
  }
  return budget;
}

/* ---- exceptions ---------------------------------------------------------- */

/*
 * A resume must reach the safepoint it yielded at before anything else yields
 * or the kernel returns: only the safepoint's arrival label, in front of its
 * own loop, clears F->resume, and each dispatch level matches only the depth
 * the level above handed on. A missing or wrong case re-runs the
 * kernel from an earlier point instead, which silently recomputes, and under
 * forced yields restarts it at every yield so it never finishes.
 * Generated code checks F->resume only where it yields and after a resumed
 * run returns, never inside a loop. `at` is the safepoint that yielded
 * instead, or 0 if the kernel returned.
 */
__attribute__((cold, unused)) static void defk_lost_resume(defk_ctx *ctx, int from, int at) {
  ctx->err = DEFK_E_RESUME;
  if (at)
    snprintf(ctx->msg, sizeof ctx->msg,
             "defk bug: kernel resumed at safepoint %d but yielded at safepoint %d "
             "without reaching it (missing or wrong resume dispatch)", from, at);
  else
    snprintf(ctx->msg, sizeof ctx->msg,
             "defk bug: kernel resumed at safepoint %d but returned without reaching it "
             "(missing or wrong resume dispatch)", from);
}

static ERL_NIF_TERM defk_raise(ErlNifEnv *env, defk_ctx *ctx) {
  if (ctx->err == DEFK_E_CASE_I64 || ctx->err == DEFK_E_CASE_BOOL) {
    ERL_NIF_TERM term = ctx->err == DEFK_E_CASE_I64 ? enif_make_int64(env, ctx->err_index)
                        : enif_make_atom(env, ctx->err_index ? "true" : "false");
    ERL_NIF_TERM ks[3] = {enif_make_atom(env, "__struct__"), enif_make_atom(env, "__exception__"),
                          enif_make_atom(env, "term")};
    ERL_NIF_TERM vs[3] = {enif_make_atom(env, "Elixir.CaseClauseError"), enif_make_atom(env, "true"), term};
    ERL_NIF_TERM exc;
    enif_make_map_from_arrays(env, ks, vs, 3, &exc);
    return enif_raise_exception(env, exc);
  }
  if (ctx->err == DEFK_E_FUN_CLAUSE) {
    /* %FunctionClauseError{module:, function:, arity:}, the rest nil, as Elixir raises it */
    ERL_NIF_TERM mod, fun, nil = enif_make_atom(env, "nil");
    const char *name = ctx->umsg + ctx->ulen + 1;
    enif_make_new_atom_len(env, ctx->umsg, ctx->ulen, &mod, ERL_NIF_UTF8);
    enif_make_new_atom_len(env, name, strlen(name), &fun, ERL_NIF_UTF8);
    ERL_NIF_TERM ks[8] = {enif_make_atom(env, "__struct__"), enif_make_atom(env, "__exception__"),
                          enif_make_atom(env, "module"), enif_make_atom(env, "function"),
                          enif_make_atom(env, "arity"), enif_make_atom(env, "kind"),
                          enif_make_atom(env, "args"), enif_make_atom(env, "clauses")};
    ERL_NIF_TERM vs[8] = {enif_make_atom(env, "Elixir.FunctionClauseError"),
                          enif_make_atom(env, "true"), mod, fun,
                          enif_make_int64(env, ctx->err_index), nil, nil, nil};
    ERL_NIF_TERM exc;
    enif_make_map_from_arrays(env, ks, vs, 8, &exc);
    return enif_raise_exception(env, exc);
  }
  int user = ctx->err & DEFK_E_USER;
  int kind = ctx->err & ~DEFK_E_USER;
  const char *mod = kind == DEFK_E_ARITH    ? "Elixir.ArithmeticError"
                    : kind == DEFK_E_OOB    ? "Elixir.Enum.OutOfBoundsError"
                    : kind == DEFK_E_RESUME || kind == DEFK_E_RUNTIME || kind == DEFK_E_FAULT
                        ? "Elixir.RuntimeError"
                                                : "Elixir.ArgumentError";
  ERL_NIF_TERM msg;
  const char *text = user ? ctx->umsg : ctx->msg;
  size_t n = user ? ctx->ulen : strlen(ctx->msg);
  memcpy(enif_make_new_binary(env, n, &msg), text, n);
  ERL_NIF_TERM keys[5] = {enif_make_atom(env, "__struct__"), enif_make_atom(env, "__exception__"),
                          enif_make_atom(env, "message"), enif_make_atom(env, "index"),
                          enif_make_atom(env, "enumerable")};
  ERL_NIF_TERM vals[5] = {enif_make_atom(env, mod), enif_make_atom(env, "true"), msg,
                          ctx->err == DEFK_E_OOB ? enif_make_int64(env, ctx->err_index)
                                                 : enif_make_atom(env, "nil"),
                          enif_make_atom(env, "nil")};
  ERL_NIF_TERM map;
  enif_make_map_from_arrays(env, keys, vals, ctx->err == DEFK_E_OOB ? 5 : 3, &map);
  return enif_raise_exception(env, map);
}

/*
 * Frame entry check for step functions: one compare of the tag and
 * one of the size, once per resume, never per loop iteration. Returns the frame
 * or NULL after setting *exc to a clean ArgumentError; a frame that is not ours
 * is never read beyond its first two words.
 */
static inline void *defk_frame_of(ErlNifEnv *env, ERL_NIF_TERM t, size_t size, ERL_NIF_TERM *exc) {
  defk_ctx *ctx;
  if (DEFK_LIKELY(enif_get_resource(env, t, defk_frame_rt, (void **)&ctx) &&
                  ctx->layout_tag == DEFK_LAYOUT_TAG && ctx->frame_size == size))
    return ctx;
  ERL_NIF_TERM keys[3] = {enif_make_atom(env, "__struct__"), enif_make_atom(env, "__exception__"),
                          enif_make_atom(env, "message")};
  static const char text[] = "defk: suspended kernel frame has a foreign layout (layout tag mismatch)";
  ERL_NIF_TERM msg;
  memcpy(enif_make_new_binary(env, sizeof text - 1, &msg), text, sizeof text - 1);
  ERL_NIF_TERM vals[3] = {enif_make_atom(env, "Elixir.ArgumentError"), enif_make_atom(env, "true"), msg};
  ERL_NIF_TERM map;
  enif_make_map_from_arrays(env, keys, vals, 3, &map);
  *exc = enif_raise_exception(env, map);
  return NULL;
}

/* ---- fault containment --------------------------------------------------- */

/*
 * A kernel never faults by construction (every access is checked or proven,
 * the subset has no pointers), so a SIGSEGV, SIGBUS, SIGILL or SIGFPE inside
 * kernel code is a defk bug. Without this section it kills the node, as any
 * NIF crash does. With it, a fault is turned into a RuntimeError for the
 * calling process when, and only when, all of these hold:
 *
 *   - the signal is synchronous (si_code > 0: raised by the faulting
 *     instruction, not sent with kill), on the thread that runs the kernel;
 *   - a kernel call of this library is running on this thread
 *     (defk_cur_ctx, set by the generated guard_k* around run_k*);
 *   - the faulting PC is inside this library's own executable segment.
 *
 * Then the handler records the fault in the call's ctx and siglongjmps to
 * guard_k*'s sigsetjmp, exactly as a bounds check raises: the NIF releases
 * the call's owned buffers and raises. That is sound because kernel code
 * never touches the BEAM heap or holds a lock mid-compute: its only state is
 * registers, its C frame and ctx->owned, and terms are built only at return.
 *
 * Anything else is chained to the handler that was installed before this
 * library's (ERTS's own, another kernel library's, or the default action), so
 * a fault in ERTS, in libc called from a kernel (memcpy, libm: a longjmp out
 * of an allocator or a lock would corrupt it), in another NIF, or in this
 * library while no kernel runs kills the node as it did before. A wild write
 * that happens not to fault is not a fault and cannot be contained; the
 * verification tooling (verify/, DEFK_SANITIZE) is what finds those.
 *
 * ERTS coexistence (OTP PR #7174): a NIF may install its own handlers if it
 * behaves. The handler is installed once per library image at load (and
 * upgrade), with SA_ONSTACK (ERTS's scheduler threads run handlers on an
 * alternate stack and so must we), SA_SIGINFO and SA_NODEFER (sigsetjmp(jb, 0)
 * saves no mask, so the signal must not be blocked when we longjmp out). The
 * previous sigaction is saved and chained.
 *
 * Unmapping an image whose handler is still in the chain would leave a
 * dangling handler, so an image leaves the chain or stays mapped:
 *   - unload (the module was purged as old code, no new code took over; no
 *     kernel of the image runs any more): if its handler is the installed
 *     one, the saved previous handler is put back; otherwise a library loaded
 *     later holds a pointer to ours in its own saved "previous", so the image
 *     pins itself in memory (dlopen on itself with RTLD_NODELETE) and its
 *     handler, whose defk_cur_ctx is NULL forever, only chains on;
 *   - upgrade (new code of the same module loaded this image): ERTS never
 *     calls the old image's unload, and its suspended kernels keep running in
 *     it until the purge, so the new image pins the old one through the
 *     priv_data ERTS hands over (defk_fault_state, checked by a magic) and
 *     leaves its handler in the chain.
 * The pinned images cost their .so size each, only for modules that are
 * reloaded or purged: the price of never calling into an unmapped handler.
 *
 * Cost: two thread-local stores per call (guard_k*), nothing per iteration.
 * sigaction is process-wide, so one kernel library protects the kernels of
 * its own image only; the chain reaches every loaded library's handler.
 * Windows is not covered (no sigaction; a documented limitation).
 */

#define DEFK_FAULT_MAGIC 0x6b66616c75746431ULL /* "defk fault" state marker in priv_data */

typedef struct {
  uint64_t magic;
  void (*handler)(int, siginfo_t *, void *);
  struct sigaction prev[4];
  int installed;
} defk_fault_state;

static __thread defk_ctx *defk_cur_ctx = NULL; /* the call running on this thread */
static uintptr_t defk_text_lo = 0, defk_text_hi = 0; /* this image's executable range */
static const int defk_fault_sigs[4] = {SIGSEGV, SIGBUS, SIGILL, SIGFPE};
static void defk_fault_handler(int sig, siginfo_t *si, void *uc);
static defk_fault_state defk_fault = {DEFK_FAULT_MAGIC, defk_fault_handler, {{{0}}}, 0};

static int defk_fault_idx(int sig) {
  for (int i = 0; i < 4; i++)
    if (defk_fault_sigs[i] == sig) return i;
  return -1;
}

static const char *defk_fault_name(int sig) {
  return sig == SIGSEGV ? "segmentation fault" : sig == SIGBUS ? "bus error"
         : sig == SIGILL ? "illegal instruction" : sig == SIGFPE ? "arithmetic fault" : "fault";
}

#if defined(__APPLE__)
#include <mach-o/dyld.h>
#include <mach-o/getsect.h>
/* the __TEXT segment of the image that holds this code */
static void defk_text_range_init(void) {
  Dl_info info;
  if (!dladdr((void *)&defk_fault_handler, &info) || !info.dli_fbase) return;
  unsigned long size = 0;
  uint8_t *seg = getsegmentdata((const struct mach_header_64 *)info.dli_fbase, "__TEXT", &size);
  if (!seg || !size) return;
  defk_text_lo = (uintptr_t)seg;
  defk_text_hi = (uintptr_t)seg + size;
}
static uintptr_t defk_fault_pc(void *uc) {
  ucontext_t *u = (ucontext_t *)uc;
#if defined(__aarch64__)
  return (uintptr_t)u->uc_mcontext->__ss.__pc;
#elif defined(__x86_64__)
  return (uintptr_t)u->uc_mcontext->__ss.__rip;
#else
  (void)u;
  return 0;
#endif
}
#elif defined(__linux__)
#include <link.h>
#include <ucontext.h>
/* the executable PT_LOAD segment of the object that holds this code */
static int defk_phdr_cb(struct dl_phdr_info *info, size_t size, void *data) {
  (void)size;
  uintptr_t me = (uintptr_t)data;
  for (int i = 0; i < info->dlpi_phnum; i++) {
    const ElfW(Phdr) *ph = &info->dlpi_phdr[i];
    if (ph->p_type != PT_LOAD || !(ph->p_flags & PF_X)) continue;
    uintptr_t lo = info->dlpi_addr + ph->p_vaddr, hi = lo + ph->p_memsz;
    if (me >= lo && me < hi) {
      defk_text_lo = lo;
      defk_text_hi = hi;
      return 1;
    }
  }
  return 0;
}
static void defk_text_range_init(void) { dl_iterate_phdr(defk_phdr_cb, (void *)&defk_fault_handler); }
static uintptr_t defk_fault_pc(void *uc) {
  ucontext_t *u = (ucontext_t *)uc;
#if defined(__aarch64__)
  return (uintptr_t)u->uc_mcontext.pc;
#elif defined(__x86_64__)
  return (uintptr_t)u->uc_mcontext.gregs[REG_RIP];
#else
  (void)u;
  return 0;
#endif
}
#else
static void defk_text_range_init(void) {}
static uintptr_t defk_fault_pc(void *uc) { (void)uc; return 0; }
#endif

/* hand the signal to whatever was installed before this library's handler */
static void defk_fault_chain(int sig, siginfo_t *si, void *uc) {
  int i = defk_fault_idx(sig);
  struct sigaction *p = i >= 0 ? &defk_fault.prev[i] : NULL;
  if (p && (p->sa_flags & SA_SIGINFO) && p->sa_sigaction) {
    p->sa_sigaction(sig, si, uc);
    return;
  }
  if (p && !(p->sa_flags & SA_SIGINFO) && p->sa_handler != SIG_DFL && p->sa_handler != SIG_IGN) {
    p->sa_handler(sig);
    return;
  }
  /* the default action: put it back and return, so the faulting instruction
     re-executes and the process dies with the signal, as without fault containment */
  struct sigaction dfl;
  memset(&dfl, 0, sizeof dfl);
  dfl.sa_handler = SIG_DFL;
  sigemptyset(&dfl.sa_mask);
  sigaction(sig, &dfl, NULL);
}

static __thread int defk_in_fault_handler = 0;

static void defk_fault_handler(int sig, siginfo_t *si, void *uc) {
  /* Re-entered on the same thread: a fault inside a handler, or a cycle in
     the chain. Never loop or recurse: put the default action back and let
     the fault re-execute, so the node dies as it would without us. */
  if (defk_in_fault_handler) {
    struct sigaction dfl;
    memset(&dfl, 0, sizeof dfl);
    dfl.sa_handler = SIG_DFL;
    sigemptyset(&dfl.sa_mask);
    sigaction(sig, &dfl, NULL);
    return;
  }
  defk_in_fault_handler = 1;
  defk_ctx *ctx = defk_cur_ctx;
  uintptr_t pc = defk_fault_pc(uc);
  if (ctx && si && si->si_code > 0 && pc >= defk_text_lo && pc < defk_text_hi) {
    defk_in_fault_handler = 0;
    defk_cur_ctx = NULL;
    snprintf(ctx->msg, sizeof ctx->msg,
             "defk bug: %s inside kernel native code (signal %d, code %d, address %p, pc +0x%lx); "
             "the call was aborted and the node kept running",
             defk_fault_name(sig), sig, (int)si->si_code, si->si_addr,
             (unsigned long)(pc - defk_text_lo));
    ctx->err = DEFK_E_FAULT;
    siglongjmp(ctx->jb, 1); /* SA_NODEFER: the signal is not blocked here */
  }
  /* cleared before chaining: the next handler may longjmp away and never
     return here (another library containing its own kernel's fault) */
  defk_in_fault_handler = 0;
  defk_fault_chain(sig, si, uc);
}

static void defk_fault_install(void) {
  /* The same image loaded again (the same .so: ERTS dlopens it once more and
     gets the same statics, as a reloaded module with unchanged code does, or
     an image pinned in memory) is already in the chain. Installing it again
     would save its own handler, or a chain that leads back to it, as the
     "previous" one: a cycle that spins on the first fault. `installed`
     means "in the chain"; only a retire that put the previous handler back
     clears it. */
  if (defk_fault.installed) return;
  defk_text_range_init();
  if (defk_text_lo == defk_text_hi) return; /* no range: contain nothing, chain everything */
  for (int i = 0; i < 4; i++) {
    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sa.sa_sigaction = defk_fault_handler;
    sa.sa_flags = SA_SIGINFO | SA_ONSTACK | SA_NODEFER;
    sigemptyset(&sa.sa_mask);
    if (sigaction(defk_fault_sigs[i], &sa, &defk_fault.prev[i]) != 0)
      memset(&defk_fault.prev[i], 0, sizeof defk_fault.prev[i]);
  }
  defk_fault.installed = 1;
}

/* keep the image that holds `handler` mapped for the life of the process */
static void defk_fault_pin(void (*handler)(int, siginfo_t *, void *)) {
  Dl_info info;
  if (dladdr((void *)handler, &info) && info.dli_fname)
    dlopen(info.dli_fname, RTLD_NOW | RTLD_NOLOAD | RTLD_NODELETE);
}

/* unload: take this image's handler out of the chain if it is the head, else pin the image */
static void defk_fault_retire(void) {
  if (!defk_fault.installed) return;
  int pinned = 0;
  for (int i = 0; i < 4; i++) {
    struct sigaction cur;
    if (sigaction(defk_fault_sigs[i], NULL, &cur) != 0) continue;
    if ((cur.sa_flags & SA_SIGINFO) && cur.sa_sigaction == defk_fault_handler) {
      sigaction(defk_fault_sigs[i], &defk_fault.prev[i], NULL);
    } else if (!pinned) {
      defk_fault_pin(defk_fault_handler);
      pinned = 1;
    }
  }
  /* out of the chain only if nothing was left pointing at this handler */
  defk_fault.installed = pinned;
}

/* upgrade: the image this one replaces stays in the chain, so keep it mapped */
static void defk_fault_pin_old(void *old_priv) {
  defk_fault_state *old = (defk_fault_state *)old_priv;
  if (old && old->magic == DEFK_FAULT_MAGIC && old->installed && old->handler) defk_fault_pin(old->handler);
}

#ifdef DEFK_FAULT_HOOKS
/* testing: fault on purpose at a clock read (1 segv, 2 illegal instruction,
   3 integer division by zero, 4 segv inside libc: not contained), after
   letting `kind / 256` clock reads pass; a negative kind faults in the NIF
   itself, outside any kernel call: not contained */
__attribute__((noinline)) static void defk_inject_fault_now(int kind) {
  atomic_store(&defk_inject_fault, 0);
  volatile int *bad = (volatile int *)(uintptr_t)8;
  /* both volatile: with a constant dividend, 1 / zero compiles to a compare
   * and select (only 1 and -1 give a nonzero quotient), not an idiv */
  volatile int64_t one = 1, zero = 0;
  switch (kind) {
  case 1: *bad = 1; break;
#if defined(__aarch64__)
  case 2: __asm__ volatile(".inst 0x00000000"); break;
#elif defined(__x86_64__)
  case 2: __asm__ volatile("ud2"); break;
#else
  case 2: __builtin_trap(); break;
#endif
  case 3: zero = one / zero; break;
  case 4: memset((void *)(uintptr_t)8, 0, 64); break;
  default: break;
  }
}
static ERL_NIF_TERM defk_inject_fault_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  (void)argc;
  int kind;
  if (!enif_get_int(env, argv[0], &kind)) return enif_make_badarg(env);
  if (kind < 0) { /* fault right here, in this library but outside any kernel call: not contained */
    defk_inject_fault_now(-kind);
    return enif_make_atom(env, "survived");
  }
  atomic_store(&defk_inject_fault, kind);
  return enif_make_atom(env, "ok");
}
#endif

/* ---- stats + load hooks -------------------------------------------------- */

static ERL_NIF_TERM defk_stats_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  (void)argc;
  (void)argv;
  /* which crc32c this library picked at its first call */
  int crc = atomic_load(&defk_crc32c_state);
  const char *crc_impl = crc == 1 ? "instruction" : crc == 2 ? "table" : "not_called";
  ERL_NIF_TERM keys[5] = {enif_make_atom(env, "frames_live"), enif_make_atom(env, "promotions"),
                          enif_make_atom(env, "yields"), enif_make_atom(env, "crc32c"),
                          enif_make_atom(env, "max_owned_bytes")};
  ERL_NIF_TERM vals[5] = {enif_make_long(env, atomic_load(&defk_stat_frames_live)),
                          enif_make_long(env, atomic_load(&defk_stat_promotions)),
                          enif_make_long(env, atomic_load(&defk_stat_yields)),
                          enif_make_atom(env, crc_impl), enif_make_uint64(env, defk_max_owned)};
  ERL_NIF_TERM map;
  enif_make_map_from_arrays(env, keys, vals, 5, &map);
  return map;
}

// registered only when the module is compiled with fault hooks (MIX_ENV=test)
static __attribute__((unused)) ERL_NIF_TERM defk_corrupt_tags_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  (void)argc;
  atomic_store(&defk_corrupt_tags, enif_is_identical(argv[0], enif_make_atom(env, "true")));
  return enif_make_atom(env, "ok");
}

static ERL_NIF_TERM defk_force_yields_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  (void)argc;
  atomic_store(&defk_force_yields, enif_is_identical(argv[0], enif_make_atom(env, "true")));
  return enif_make_atom(env, "ok");
}

/*
 * Hot code upgrade. Each loaded library image gets its own frame
 * resource type, named after the address of one of its statics. A yielded
 * kernel's continuation (step_N, rescheduled with enif_schedule_nif) always
 * belongs to the library that started it, and ERTS keeps that library mapped
 * until the continuation returns. Taking over one shared "defk_frame" type
 * instead would hand the old library's frames to the new library's destructor
 * (and frames_live counter), which assumes the new defk_ctx layout.
 *
 * With a type per image, ERTS keeps an upgraded-away library loaded while any
 * of its frames exist and destroys them with its own destructor, so a
 * suspended kernel finishes in the code it started in. If the old module is
 * purged first (code:purge, or loading a third version), ERTS kills processes
 * still running its code, like any other old code, and the old library frees
 * the frames. A name can only exist already if the same image is loaded again
 * (same .so, same statics): the takeover then hands the frames to the same
 * destructor.
 */
static int defk_open_rt(ErlNifEnv *env, ErlNifResourceFlags flags) {
  char name[48];
  snprintf(name, sizeof name, "defk_frame_%" PRIxPTR, (uintptr_t)&defk_frame_rt);
  defk_frame_rt = enif_open_resource_type(env, NULL, name, defk_frame_dtor, flags, NULL);
  return defk_frame_rt ? 0 : 1;
}
static int defk_load(ErlNifEnv *env, void **priv, ERL_NIF_TERM info) {
  (void)info;
  defk_max_owned_init();
  defk_fault_install();
  *priv = &defk_fault;
  return defk_open_rt(env, ERL_NIF_RT_CREATE);
}
static int defk_upgrade(ErlNifEnv *env, void **priv, void **old, ERL_NIF_TERM info) {
  (void)info;
  defk_max_owned_init();
  defk_fault_pin_old(old ? *old : NULL);
  defk_fault_install();
  *priv = &defk_fault;
  return defk_open_rt(env, ERL_NIF_RT_CREATE | ERL_NIF_RT_TAKEOVER);
}
/* the module was purged as old code and no new code took it over (ERTS does
   not call this for an upgraded image); frames it still owns keep the image
   loaded until they are gone */
static void defk_unload(ErlNifEnv *env, void *priv) {
  (void)env;
  (void)priv;
  defk_fault_retire();
}

/*
 * A kernel starts on a stack frame (no allocation). Only if it has to yield is
 * the frame copied into a resource so it can outlive this NIF call.
 */
static void *defk_promote(ErlNifEnv *env, void *stack_frame, size_t size, ERL_NIF_TERM *term) {
  void *res = enif_alloc_resource(defk_frame_rt, size);
  memcpy(res, stack_frame, size);
  ((defk_ctx *)res)->is_resource = 1;
  ((defk_ctx *)res)->layout_tag = DEFK_LAYOUT_TAG ^ (uint64_t)atomic_load(&defk_corrupt_tags);
  ((defk_ctx *)res)->frame_size = size;
  *term = enif_make_resource(env, res);
  enif_release_resource(res); /* the term now keeps it alive */
  atomic_fetch_add(&defk_stat_frames_live, 1);
  atomic_fetch_add(&defk_stat_promotions, 1);
  return res;
}

#endif
