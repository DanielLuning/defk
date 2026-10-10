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
#define DEFK_E_RUNTIME 7   /* RuntimeError: a kernel's raise "msg" */
#define DEFK_E_USER 16     /* flag on a kind: a kernel's own raise, message in umsg/ulen */

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
  const char *umsg; /* a kernel's raise: its literal message (static), ulen bytes */
  size_t ulen;
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

/* Owned binary: off-heap, stable address across yields and GC; uninitialised. */
static int defk_own_raw(defk_ctx *ctx, size_t bytes) {
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

/*
 * Array value semantics (defk-auo): a copy of `src` in a new owned binary,
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
  /* BEAM floats cannot be inf/nan. Every operation that could make one
     already raised (defk-i00); this stays as defence in depth. */
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
  return n >= 64 ? (a < 0 ? -1 : 0) : a >> n;
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

/* ---- float arithmetic Elixir's way (defk-i00, decided in defk-q1c) -------
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
 * their cost (README "Known limitations") and is not a user option.
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
static inline double defk_sqrt(defk_ctx *ctx, double a) {
  if (DEFK_UNLIKELY(a < 0.0)) defk_fail(ctx, DEFK_E_ARITH, "sqrt of negative number %g", a);
  return sqrt(a);
}
static inline double defk_log(defk_ctx *ctx, double a) {
  if (DEFK_UNLIKELY(a <= 0.0)) defk_fail(ctx, DEFK_E_ARITH, "log of non-positive number %g", a);
  return log(a);
}
static inline int64_t defk_trunc(defk_ctx *ctx, double a) {
  if (DEFK_UNLIKELY(!(a >= -0x1p63 && a < 0x1p63)))
    defk_fail(ctx, DEFK_E_ARITH, "trunc/1: %g does not fit in i64", a);
  return (int64_t)a;
}
static inline int64_t defk_round(defk_ctx *ctx, double a) { return defk_trunc(ctx, round(a)); }
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
 * Kernel floats are never NaN (every operation that could make one raises,
 * defk-i00); one would compare below every integer. */
static inline int defk_cmp_i64_f64(int64_t i, double f) {
  if (f >= 0x1p63) return -1;           /* above every i64 */
  if (!(f >= -0x1p63)) return 1;        /* below every i64 (or NaN) */
  int64_t t = (int64_t)f;               /* f's integer part, exact here */
  if (i != t) return i < t ? -1 : 1;
  double frac = f - (double)t;          /* exact: t is f truncated */
  return frac > 0.0 ? -1 : frac < 0.0 ? 1 : 0;
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
  }
DEFK_ACCESS_FN(f64, double)
DEFK_ACCESS_FN(i64, int64_t)
DEFK_ACCESS_FN(u8, uint8_t)

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
 * count (defk-q1c). Arrays from alloc/2 hold only finite values, so their
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
 * Flat strips (defk-6tt). A branch per float operation stops clang from
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
/* sqrt and log of a finite argument are inf or NaN exactly where the checked
   forms raise (a < 0.0, a <= 0.0) */
#define DEFK_NF_sqrt(C, A) defk_nf_r(&defk_nf, sqrt(A))
#define DEFK_NF_log(C, A) defk_nf_r(&defk_nf, log(A))
#define DEFK_NF_exp(C, A) defk_nf_r(&defk_nf, exp(A))
#define DEFK_NF_pow(C, A, B) defk_nf_r(&defk_nf, pow((A), (B)))
/* a float expression's single check (float_tree in the compiler): raise
   through its replay, or in a flagged strip, flag and skip the replay */
#define DEFK_FCHECK(B) if (DEFK_UNLIKELY(B))
#define DEFK_NF_FCHECK(B) defk_nf |= (B); if (0)

static inline uint8_t defk_to_u8(defk_ctx *ctx, int64_t v) {
  if (DEFK_UNLIKELY(v < 0 || v > 255)) defk_fail(ctx, DEFK_E_ARG, "value %lld does not fit in u8", (long long)v);
  return (uint8_t)v;
}

/*
 * The bitstring accumulator (defk-cmr): acc = <<acc::bitstring, v::size(n)>>.
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
    if (!enif_realloc_binary(bin, cap))
      defk_fail(ctx, DEFK_E_ARG, "out of memory (allocating %zu bytes)", cap);
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

__attribute__((noreturn, cold, unused)) static void defk_bits_fail(defk_ctx *ctx, int64_t v, int64_t n) {
  if (n < 0 || n > 64)
    defk_fail(ctx, DEFK_E_ARG, "bitstring segment size %lld is outside 0..64", (long long)n);
  defk_fail(ctx, DEFK_E_ARG, "bitstring segment value %lld does not fit in %lld bits",
            (long long)v, (long long)n);
}

/* <<b::bitstring, v::size(n)>>, unsigned: v must be in 0..2^n - 1 (Elixir
   would keep the low n bits; a limit, like an array write) and n in 0..64 */
static inline defk_bits defk_bits_put(defk_ctx *ctx, defk_bits b, int64_t v, int64_t n) {
  if (DEFK_UNLIKELY((uint64_t)n > 64 || (n < 64 ? ((uint64_t)v >> n) != 0 : v < 0)))
    defk_bits_fail(ctx, v, n);
  if (n == 0) return b;
  if (DEFK_UNLIKELY(!b.slot1 || defk_bits_end(ctx, b) != (uint64_t)b.nbits ||
                    ((uint64_t)b.nbits + (uint64_t)n + 7) / 8 + 8 + DEFK_BITS_HDR >
                        ctx->owned[b.slot1 - 1].size))
    b = defk_bits_reserve(ctx, b, n);
  uint8_t *p = ctx->owned[b.slot1 - 1].data;
  uint64_t pos = (uint64_t)b.nbits;
  if (n > 56) {
    defk_bits_or(p + DEFK_BITS_HDR, pos, (uint64_t)v >> 32, n - 32);
    defk_bits_or(p + DEFK_BITS_HDR, pos + (uint64_t)(n - 32), (uint64_t)v & 0xFFFFFFFFu, 32);
  } else {
    defk_bits_or(p + DEFK_BITS_HDR, pos, (uint64_t)v, n);
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
  int user = ctx->err & DEFK_E_USER;
  int kind = ctx->err & ~DEFK_E_USER;
  const char *mod = kind == DEFK_E_ARITH    ? "Elixir.ArithmeticError"
                    : kind == DEFK_E_OOB    ? "Elixir.Enum.OutOfBoundsError"
                    : kind == DEFK_E_RESUME || kind == DEFK_E_RUNTIME ? "Elixir.RuntimeError"
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
