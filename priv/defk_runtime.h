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

#include <erl_nif.h>
#include <inttypes.h>
#include <limits.h>
#include <math.h>
#include <setjmp.h>
#include <stdarg.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#define DEFK_DONE 0
#define DEFK_YIELD 1
#define DEFK_ERR 2

#define DEFK_E_ARG 1
#define DEFK_E_ARITH 2
#define DEFK_E_OOB 3
#define DEFK_E_CASE_I64 4  /* CaseClauseError; the term is err_index */
#define DEFK_E_CASE_BOOL 5
#define DEFK_E_RESUME 6    /* a resume missed its safepoint (a defk bug); RuntimeError */

#define DEFK_LIKELY(x) __builtin_expect(!!(x), 1)
#define DEFK_UNLIKELY(x) __builtin_expect(!!(x), 0)

/* ---- packed arrays ------------------------------------------------------ */

typedef struct { double *data; int64_t len; } defk_arr_f64;
typedef struct { int64_t *data; int64_t len; } defk_arr_i64;
typedef struct { uint8_t *data; int64_t len; } defk_arr_u8;

/* ---- per-call context (first member of every frame) --------------------- */

typedef struct {
  sigjmp_buf jb; /* sigsetjmp(jb, 0): plain setjmp saves the signal mask on macOS = a syscall per call */
  int err;
  int64_t err_index; /* for out-of-bounds */
  char msg[200];
  ErlNifBinary *owned; /* binaries we allocated (outputs, aligned copies) */
  int nowned, cap;
  int finished;
  int is_resource;
} defk_ctx;

static ErlNifResourceType *defk_frame_rt;
static _Atomic long defk_stat_frames_live = 0;
static _Atomic long defk_stat_promotions = 0;
static _Atomic long defk_stat_yields = 0;
/* testing: yield at every clock read, so every safepoint's resume path runs */
static _Atomic int defk_force_yields = 0;

__attribute__((noreturn, cold, format(printf, 3, 4))) static void
defk_fail(defk_ctx *ctx, int kind, const char *fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  vsnprintf(ctx->msg, sizeof ctx->msg, fmt, ap);
  va_end(ap);
  ctx->err = kind;
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
  defk_finish(ctx); /* process died mid-kernel: free what it allocated */
  atomic_fetch_sub(&defk_stat_frames_live, 1);
}

/* Owned binary: off-heap, stable address across yields and GC. */
static int defk_own(defk_ctx *ctx, size_t bytes) {
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
  memset(b->data, 0, bytes);
  return ctx->nowned++;
}

/*
 * Largest array alloc/2 makes, in bytes: 2^48 (256 TiB), the user address
 * space of 64-bit platforms, so no allocator can serve more. Elixir mode
 * applies the same limit (Defk.ElixirMode.Ops.alloc/2), where asking the VM
 * for a binary that large aborts it; the two modes agree on it. The check also keeps n * sizeof(T) from wrapping: unchecked, alloc(f64, 2^61)
 * was a 0-byte buffer of length 2^61, and an in-bounds write crashed the VM
 * (defk-gtv). A size under the limit that the allocator cannot provide raises
 * "out of memory" (defk_own). It also bounds every array length below 2^61,
 * which the compiler relies on (range_limit: a range ending at len/1 cannot
 * step past the i64 limit).
 */
#if UINTPTR_MAX > 0xFFFFFFFFu
#define DEFK_ALLOC_MAX_BYTES ((uint64_t)1 << 48)
#else
#define DEFK_ALLOC_MAX_BYTES ((uint64_t)1 << 29)
#endif

#define DEFK_ALLOC_FN(T, CT)                                                     \
  static inline defk_arr_##T defk_alloc_##T(defk_ctx *ctx, int64_t n) {          \
    if (n < 0) defk_fail(ctx, DEFK_E_ARG, "alloc/2: negative length %lld", (long long)n); \
    uint64_t bytes;                                                              \
    if (DEFK_UNLIKELY(__builtin_mul_overflow((uint64_t)n, (uint64_t)sizeof(CT), &bytes) || \
                      bytes > DEFK_ALLOC_MAX_BYTES))                             \
      defk_fail(ctx, DEFK_E_ARG, "alloc/2: length too large");                   \
    int slot = defk_own(ctx, (size_t)bytes);                                     \
    defk_arr_##T a = {(CT *)ctx->owned[slot].data, n};                           \
    return a;                                                                    \
  }
DEFK_ALLOC_FN(f64, double)
DEFK_ALLOC_FN(i64, int64_t)
DEFK_ALLOC_FN(u8, uint8_t)

/* Hand an owned array back to the BEAM as a binary (ownership transfers). */
static ERL_NIF_TERM defk_make_arr(ErlNifEnv *env, defk_ctx *ctx, void *data) {
  for (int i = 0; i < ctx->nowned; i++) {
    if (ctx->owned[i].data == data) {
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
    int slot = defk_own(ctx, bin.size);
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
  /* BEAM floats cannot be inf/nan: raise like Elixir arithmetic would */
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
static inline double defk_fdiv(defk_ctx *ctx, double a, double b) {
  if (DEFK_UNLIKELY(b == 0.0)) defk_fail(ctx, DEFK_E_ARITH, "bad argument in arithmetic expression: division by zero");
  return a / b;
}
static inline double defk_sqrt(defk_ctx *ctx, double a) {
  if (DEFK_UNLIKELY(a < 0.0)) defk_fail(ctx, DEFK_E_ARITH, "sqrt of negative number %g", a);
  return sqrt(a);
}
static inline double defk_log(defk_ctx *ctx, double a) {
  if (DEFK_UNLIKELY(a <= 0.0)) defk_fail(ctx, DEFK_E_ARITH, "log of non-positive number %g", a);
  return log(a);
}
static inline int64_t defk_trunc(defk_ctx *ctx, double a) {
  if (DEFK_UNLIKELY(!(a > -9.2233720368547758e18 && a < 9.2233720368547758e18)))
    defk_fail(ctx, DEFK_E_ARITH, "trunc/1: %g does not fit in i64", a);
  return (int64_t)a;
}
static inline int64_t defk_round(defk_ctx *ctx, double a) { return defk_trunc(ctx, round(a)); }
static inline int64_t defk_min_i64(int64_t a, int64_t b) { return a < b ? a : b; }
static inline int64_t defk_max_i64(int64_t a, int64_t b) { return a > b ? a : b; }
static inline double defk_min_f64(double a, double b) { return a < b ? a : b; }
static inline double defk_max_f64(double a, double b) { return a > b ? a : b; }

/* ---- bounds-checked element access --------------------------------------- */

#define DEFK_ACCESS_FN(T, CT)                                                       \
  static inline CT defk_get_##T(defk_ctx *ctx, defk_arr_##T a, int64_t i) {         \
    if (DEFK_UNLIKELY((uint64_t)i >= (uint64_t)a.len)) defk_oob(ctx, i, a.len);     \
    return a.data[i];                                                               \
  }                                                                                 \
  static inline void defk_put_##T(defk_ctx *ctx, defk_arr_##T a, int64_t i, CT v) { \
    if (DEFK_UNLIKELY((uint64_t)i >= (uint64_t)a.len)) defk_oob(ctx, i, a.len);     \
    a.data[i] = v;                                                                  \
  }
DEFK_ACCESS_FN(f64, double)
DEFK_ACCESS_FN(i64, int64_t)
DEFK_ACCESS_FN(u8, uint8_t)

static inline uint8_t defk_to_u8(defk_ctx *ctx, int64_t v) {
  if (DEFK_UNLIKELY(v < 0 || v > 255)) defk_fail(ctx, DEFK_E_ARG, "value %lld does not fit in u8", (long long)v);
  return (uint8_t)v;
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
} defk_clock;

#define DEFK_BUDGET0 256

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
 * slower than yield: false; at 2048 it is within 1% (defk-jaj). */
#ifndef DEFK_STRIP
#define DEFK_STRIP 2048
#endif

static void defk_clock_init(defk_clock *c) {
  c->last = enif_monotonic_time(ERL_NIF_USEC);
  c->unreported = 0;
}

__attribute__((noinline)) static int64_t defk_tick(ErlNifEnv *env, defk_clock *c, int64_t budget) {
  c->budget = budget;
  if (atomic_load_explicit(&defk_force_yields, memory_order_relaxed)) return 0;
  ErlNifTime now = enif_monotonic_time(ERL_NIF_USEC);
  ErlNifTime dt = now - c->last;
  c->last = now;
  if (dt < DEFK_SLICE_US / 10 && budget < (1 << 24)) budget *= 2;
  else if (dt > DEFK_SLICE_US / 4 && budget > 16) budget /= 2;
  c->budget = budget;
  c->unreported += dt * 100;
  long pct = (long)(c->unreported / DEFK_SLICE_US);
  if (pct >= 1) {
    c->unreported -= pct * DEFK_SLICE_US;
    if (enif_consume_timeslice(env, pct > 100 ? 100 : (int)pct)) return 0;
  }
  return budget;
}

/* ---- exceptions ---------------------------------------------------------- */

/*
 * A resume must reach the safepoint it yielded at before anything else yields
 * or the kernel returns: the dispatch case that gets there clears F->resume.
 * A missing or wrong case re-runs the kernel from an earlier point instead,
 * which silently recomputes, and under forced yields restarts it at every
 * yield so it never finishes (defk-juw). Generated code checks F->resume only
 * where it yields and after a resumed run returns, never inside a loop. `at`
 * is the safepoint that yielded instead, or 0 if the kernel returned.
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
  const char *mod = ctx->err == DEFK_E_ARITH    ? "Elixir.ArithmeticError"
                    : ctx->err == DEFK_E_OOB    ? "Elixir.Enum.OutOfBoundsError"
                    : ctx->err == DEFK_E_RESUME ? "Elixir.RuntimeError"
                                                : "Elixir.ArgumentError";
  ERL_NIF_TERM msg;
  size_t n = strlen(ctx->msg);
  memcpy(enif_make_new_binary(env, n, &msg), ctx->msg, n);
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

/* ---- stats + load hooks -------------------------------------------------- */

static ERL_NIF_TERM defk_stats_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  (void)argc;
  (void)argv;
  ERL_NIF_TERM keys[3] = {enif_make_atom(env, "frames_live"), enif_make_atom(env, "promotions"),
                          enif_make_atom(env, "yields")};
  ERL_NIF_TERM vals[3] = {enif_make_long(env, atomic_load(&defk_stat_frames_live)),
                          enif_make_long(env, atomic_load(&defk_stat_promotions)),
                          enif_make_long(env, atomic_load(&defk_stat_yields))};
  ERL_NIF_TERM map;
  enif_make_map_from_arrays(env, keys, vals, 3, &map);
  return map;
}

static ERL_NIF_TERM defk_force_yields_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  (void)argc;
  atomic_store(&defk_force_yields, enif_is_identical(argv[0], enif_make_atom(env, "true")));
  return enif_make_atom(env, "ok");
}

/*
 * Hot code upgrade (defk-nbl). Each loaded library image gets its own frame
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
  (void)priv;
  (void)info;
  return defk_open_rt(env, ERL_NIF_RT_CREATE);
}
static int defk_upgrade(ErlNifEnv *env, void **priv, void **old, ERL_NIF_TERM info) {
  (void)priv;
  (void)old;
  (void)info;
  return defk_open_rt(env, ERL_NIF_RT_CREATE | ERL_NIF_RT_TAKEOVER);
}

/*
 * A kernel starts on a stack frame (no allocation). Only if it has to yield is
 * the frame copied into a resource so it can outlive this NIF call.
 */
static void *defk_promote(ErlNifEnv *env, void *stack_frame, size_t size, ERL_NIF_TERM *term) {
  void *res = enif_alloc_resource(defk_frame_rt, size);
  memcpy(res, stack_frame, size);
  ((defk_ctx *)res)->is_resource = 1;
  *term = enif_make_resource(env, res);
  enif_release_resource(res); /* the term now keeps it alive */
  atomic_fetch_add(&defk_stat_frames_live, 1);
  atomic_fetch_add(&defk_stat_promotions, 1);
  return res;
}

#endif
