/* The floor under a kernel call, as plain NIFs: what the BEAM charges for a
 * NIF call before defk's entry code runs, and what each clock read costs.
 * Built and loaded by bench/call_cost.exs; docs/performance.md 5.1. */
#include <erl_nif.h>
#include <setjmp.h>
#include <stdint.h>
#include <string.h>
#include <time.h>
#if defined(__APPLE__)
#include <mach/mach_time.h>
#endif

/* the bare NIF call: the term goes straight back */
static ERL_NIF_TERM bare(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  (void)env;
  (void)argc;
  return argv[0];
}

/* decode two i64 arguments, encode one: the terms of add/2 */
static ERL_NIF_TERM add2(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  (void)argc;
  ErlNifSInt64 a, b;
  if (!enif_get_int64(env, argv[0], &a) || !enif_get_int64(env, argv[1], &b))
    return enif_make_badarg(env);
  return enif_make_int64(env, a + b);
}

/* add2 plus a sigsetjmp(jb, 0) on the stack, as the generated guard does */
static ERL_NIF_TERM add2_jmp(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  sigjmp_buf jb;
  if (sigsetjmp(jb, 0)) return enif_make_badarg(env);
  return add2(env, argc, argv);
}

/* add2 plus one monotonic clock read, as a yielding kernel's entry does */
static ERL_NIF_TERM add2_clock(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  volatile ErlNifTime t = enif_monotonic_time(ERL_NIF_USEC);
  (void)t;
  return add2(env, argc, argv);
}

/* the clock primitives alone, each on top of the bare call */
static ERL_NIF_TERM clock_enif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  (void)argc;
  volatile ErlNifTime t = enif_monotonic_time(ERL_NIF_USEC);
  (void)t;
  return argv[0];
}

static ERL_NIF_TERM clock_posix(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  (void)env;
  (void)argc;
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  volatile long t = ts.tv_nsec;
  (void)t;
  return argv[0];
}

static ERL_NIF_TERM clock_fast(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  (void)env;
  (void)argc;
#if defined(__APPLE__)
  volatile uint64_t t = mach_absolute_time();
#elif defined(__aarch64__)
  uint64_t v;
  __asm__ volatile("mrs %0, cntvct_el0" : "=r"(v));
  volatile uint64_t t = v;
#elif defined(__x86_64__)
  volatile uint64_t t = __builtin_ia32_rdtsc();
#else
  volatile uint64_t t = 0;
#endif
  (void)t;
  return argv[0];
}

static ErlNifFunc funcs[] = {
    {"bare", 1, bare, 0},
    {"add2", 2, add2, 0},
    {"add2_jmp", 2, add2_jmp, 0},
    {"add2_clock", 2, add2_clock, 0},
    {"clock_enif", 1, clock_enif, 0},
    {"clock_posix", 1, clock_posix, 0},
    {"clock_fast", 1, clock_fast, 0},
};

ERL_NIF_INIT(Elixir.CallCost.Floor, funcs, NULL, NULL, NULL, NULL)
