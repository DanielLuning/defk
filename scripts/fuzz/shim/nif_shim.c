/* The erl_nif shim; the interface and its limits are in nif_shim.h. */
#include "nif_shim.h"

#include <math.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* A binary the kernel asks for above this is refused (enif_alloc_binary
 * returns 0, as ERTS does when the allocator fails), so the runtime's
 * out-of-memory path is exercised instead of libFuzzer's malloc limit. */
#define SHIM_MAX_BIN ((size_t)256 << 20)
#define SHIM_MAX_SCHED_ARGS 16

typedef enum { T_INT, T_DBL, T_ATOM, T_BIN, T_TUPLE, T_MAP, T_RES } shim_kind;

struct enif_resource_type_t {
  char name[64];
  ErlNifResourceDtor *dtor;
};

typedef struct shim_res {
  ErlNifResourceType *type;
  long refc;
  _Alignas(max_align_t) unsigned char payload[];
} shim_res;

typedef struct shim_term {
  shim_kind k;
  union {
    struct { int64_t v; int big; } i; /* big: an unsigned value above INT64_MAX */
    double d;
    char *atom;
    struct { uint8_t *data; size_t size; } bin;
    struct { int n; ERL_NIF_TERM *e; } tup; /* a map: n keys then n values */
    shim_res *res;
  } u;
} shim_term;

struct enif_environment_t {
  shim_term **terms;
  size_t nterms, cap;
  int raised;
  ERL_NIF_TERM exception;
  shim_nif_fp sched_fp;
  int sched_argc;
  ERL_NIF_TERM sched_argv[SHIM_MAX_SCHED_ARGS];
};

static struct enif_environment_t the_env;
static long live_resources;
static int slow_clock;

/* the values a raising or rescheduling NIF returns (ERTS: THE_NON_VALUE) */
static shim_term raised_marker, scheduled_marker;
#define T(x) ((shim_term *)(uintptr_t)(x))
#define TERM(p) ((ERL_NIF_TERM)(uintptr_t)(p))

void shim_fail(const char *fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  fputs("defk-fuzz: ", stderr);
  vfprintf(stderr, fmt, ap);
  fputc('\n', stderr);
  va_end(ap);
  abort();
}

ErlNifEnv *shim_env(void) { return &the_env; }

static void check_env(ErlNifEnv *env) {
  if (env != &the_env) shim_fail("a NIF function was called with env %p, not the kernel's", (void *)env);
}

static shim_term *new_term(shim_kind k) {
  shim_term *t = calloc(1, sizeof *t);
  if (!t) shim_fail("out of memory for a term");
  t->k = k;
  if (the_env.nterms == the_env.cap) {
    the_env.cap = the_env.cap ? the_env.cap * 2 : 64;
    the_env.terms = realloc(the_env.terms, the_env.cap * sizeof *the_env.terms);
    if (!the_env.terms) shim_fail("out of memory for the term table");
  }
  the_env.terms[the_env.nterms++] = t;
  return t;
}

static shim_term *term_of(ERL_NIF_TERM x) {
  shim_term *t = T(x);
  if (!t) shim_fail("a NIF function was given the null term");
  if (t == &raised_marker || t == &scheduled_marker)
    shim_fail("a raised/scheduled marker was used as a term (a NIF passed on enif_raise_exception's result)");
  return t;
}

static void res_unref(shim_res *r) {
  if (--r->refc > 0) return;
  if (r->refc < 0) shim_fail("resource released more often than referenced");
  if (r->type->dtor) r->type->dtor(&the_env, r->payload);
  live_resources--;
  free(r);
}

void shim_reset(void) {
  for (size_t i = 0; i < the_env.nterms; i++) {
    shim_term *t = the_env.terms[i];
    switch (t->k) {
    case T_ATOM: free(t->u.atom); break;
    case T_BIN: free(t->u.bin.data); break;
    case T_TUPLE:
    case T_MAP: free(t->u.tup.e); break;
    case T_RES: res_unref(t->u.res); break;
    default: break;
    }
    free(t);
  }
  free(the_env.terms);
  the_env.terms = NULL;
  the_env.nterms = the_env.cap = 0;
  the_env.raised = 0;
  the_env.sched_fp = NULL;
}

ERL_NIF_TERM shim_make_input_binary(const uint8_t *data, size_t size) {
  shim_term *t = new_term(T_BIN);
  t->u.bin.data = malloc(size);
  if (size && !t->u.bin.data) shim_fail("out of memory for an input binary");
  if (size) memcpy(t->u.bin.data, data, size);
  t->u.bin.size = size;
  return TERM(t);
}

void shim_move_binary(ERL_NIF_TERM x) {
  shim_term *t = term_of(x);
  if (t->k != T_BIN) return;
  uint8_t *moved = malloc(t->u.bin.size);
  if (t->u.bin.size) memcpy(moved, t->u.bin.data, t->u.bin.size);
  free(t->u.bin.data);
  t->u.bin.data = moved;
}

int shim_take_exception(ERL_NIF_TERM *reason) {
  if (!the_env.raised) return 0;
  the_env.raised = 0;
  *reason = the_env.exception;
  return 1;
}

int shim_take_scheduled(shim_nif_fp *fp, int *argc, ERL_NIF_TERM *argv, int max) {
  if (!the_env.sched_fp) return 0;
  if (the_env.sched_argc > max) shim_fail("scheduled NIF has %d arguments", the_env.sched_argc);
  *fp = the_env.sched_fp;
  *argc = the_env.sched_argc;
  memcpy(argv, the_env.sched_argv, sizeof(ERL_NIF_TERM) * (size_t)the_env.sched_argc);
  the_env.sched_fp = NULL;
  return 1;
}

long shim_live_resources(void) { return live_resources; }

/* ---- inspecting ---------------------------------------------------------- */

int shim_equal(ERL_NIF_TERM xa, ERL_NIF_TERM xb) {
  shim_term *a = term_of(xa), *b = term_of(xb);
  if (a->k != b->k) return 0;
  switch (a->k) {
  case T_INT: return a->u.i.v == b->u.i.v && a->u.i.big == b->u.i.big;
  case T_DBL: return a->u.d == b->u.d;
  case T_ATOM: return strcmp(a->u.atom, b->u.atom) == 0;
  case T_BIN:
    return a->u.bin.size == b->u.bin.size &&
           (a->u.bin.size == 0 || memcmp(a->u.bin.data, b->u.bin.data, a->u.bin.size) == 0);
  case T_TUPLE:
  case T_MAP: {
    int n = a->k == T_MAP ? 2 * a->u.tup.n : a->u.tup.n;
    if (a->u.tup.n != b->u.tup.n) return 0;
    for (int i = 0; i < n; i++)
      if (!shim_equal(a->u.tup.e[i], b->u.tup.e[i])) return 0;
    return 1;
  }
  case T_RES: return a->u.res == b->u.res;
  }
  return 0;
}

void shim_print(ERL_NIF_TERM x) {
  shim_term *t = term_of(x);
  switch (t->k) {
  case T_INT:
    if (t->u.i.big) fprintf(stderr, "%llu", (unsigned long long)t->u.i.v);
    else fprintf(stderr, "%lld", (long long)t->u.i.v);
    break;
  case T_DBL: fprintf(stderr, "%.17g", t->u.d); break;
  case T_ATOM: fprintf(stderr, "%s", t->u.atom); break;
  case T_BIN: {
    size_t n = t->u.bin.size, shown = n > 64 ? 64 : n;
    fprintf(stderr, "<<");
    for (size_t i = 0; i < shown; i++) fprintf(stderr, i ? ",%u" : "%u", t->u.bin.data[i]);
    if (shown < n) fprintf(stderr, ",... (%zu bytes)", n);
    fprintf(stderr, ">>");
    break;
  }
  case T_TUPLE:
    fprintf(stderr, "{");
    for (int i = 0; i < t->u.tup.n; i++) {
      if (i) fprintf(stderr, ", ");
      shim_print(t->u.tup.e[i]);
    }
    fprintf(stderr, "}");
    break;
  case T_MAP:
    fprintf(stderr, "#{");
    for (int i = 0; i < t->u.tup.n; i++) {
      if (i) fprintf(stderr, ", ");
      shim_print(t->u.tup.e[i]);
      fprintf(stderr, " => ");
      shim_print(t->u.tup.e[t->u.tup.n + i]);
    }
    fprintf(stderr, "}");
    break;
  case T_RES: fprintf(stderr, "#Ref<%p>", (void *)t->u.res); break;
  }
}

int shim_is_atom(ERL_NIF_TERM x, const char *name) {
  shim_term *t = term_of(x);
  return t->k == T_ATOM && strcmp(t->u.atom, name) == 0;
}

int shim_get_bin(ERL_NIF_TERM x, const uint8_t **data, size_t *size) {
  shim_term *t = term_of(x);
  if (t->k != T_BIN) return 0;
  *data = t->u.bin.data;
  *size = t->u.bin.size;
  return 1;
}

int shim_get_int(ERL_NIF_TERM x, int64_t *v) {
  shim_term *t = term_of(x);
  if (t->k != T_INT || t->u.i.big) return 0;
  *v = t->u.i.v;
  return 1;
}

int shim_get_tuple(ERL_NIF_TERM x, int *arity, const ERL_NIF_TERM **elems) {
  shim_term *t = term_of(x);
  if (t->k != T_TUPLE) return 0;
  *arity = t->u.tup.n;
  *elems = t->u.tup.e;
  return 1;
}

int shim_map_get(ERL_NIF_TERM x, const char *key, ERL_NIF_TERM *value) {
  shim_term *t = term_of(x);
  if (t->k != T_MAP) return 0;
  for (int i = 0; i < t->u.tup.n; i++)
    if (shim_is_atom(t->u.tup.e[i], key)) {
      *value = t->u.tup.e[t->u.tup.n + i];
      return 1;
    }
  return 0;
}

/* ---- the enif_* API ------------------------------------------------------ */

void *enif_alloc(size_t n) { return malloc(n); }
void *enif_realloc(void *p, size_t n) { return realloc(p, n); }
void enif_free(void *p) { free(p); }

int enif_alloc_binary(size_t n, ErlNifBinary *b) {
  memset(b, 0, sizeof *b);
  if (n > SHIM_MAX_BIN) return 0;
  b->data = malloc(n); /* exact size: no slack for an overrun to hide in */
  if (!b->data) return 0;
  b->size = n;
  b->ref_bin = b->data;
  return 1;
}

int enif_realloc_binary(ErlNifBinary *b, size_t n) {
  if (n > SHIM_MAX_BIN) return 0;
  uint8_t *p = malloc(n); /* always moves, as ERTS may */
  if (!p) return 0;
  memcpy(p, b->data, b->size < n ? b->size : n);
  free(b->data);
  b->data = p;
  b->size = n;
  b->ref_bin = p;
  return 1;
}

void enif_release_binary(ErlNifBinary *b) {
  free(b->data);
  b->data = NULL;
  b->ref_bin = NULL;
}

int enif_inspect_binary(ErlNifEnv *env, ERL_NIF_TERM x, ErlNifBinary *b) {
  check_env(env);
  shim_term *t = term_of(x);
  if (t->k != T_BIN) return 0;
  memset(b, 0, sizeof *b);
  b->data = t->u.bin.data;
  b->size = t->u.bin.size;
  return 1;
}

ERL_NIF_TERM enif_make_binary(ErlNifEnv *env, ErlNifBinary *b) {
  check_env(env);
  shim_term *t = new_term(T_BIN);
  t->u.bin.data = b->data; /* the term owns it now */
  t->u.bin.size = b->size;
  b->data = NULL;
  b->ref_bin = NULL;
  return TERM(t);
}

unsigned char *enif_make_new_binary(ErlNifEnv *env, size_t n, ERL_NIF_TERM *x) {
  check_env(env);
  shim_term *t = new_term(T_BIN);
  t->u.bin.data = malloc(n);
  if (n && !t->u.bin.data) shim_fail("out of memory in enif_make_new_binary(%zu)", n);
  t->u.bin.size = n;
  *x = TERM(t);
  return t->u.bin.data;
}

int enif_get_long(ErlNifEnv *env, ERL_NIF_TERM x, long *v) {
  check_env(env);
  shim_term *t = term_of(x);
  if (t->k != T_INT || t->u.i.big) return 0;
  *v = (long)t->u.i.v;
  return 1;
}

int enif_get_ulong(ErlNifEnv *env, ERL_NIF_TERM x, unsigned long *v) {
  check_env(env);
  shim_term *t = term_of(x);
  if (t->k != T_INT || (!t->u.i.big && t->u.i.v < 0)) return 0;
  *v = (unsigned long)t->u.i.v;
  return 1;
}

int enif_get_double(ErlNifEnv *env, ERL_NIF_TERM x, double *d) {
  check_env(env);
  shim_term *t = term_of(x);
  if (t->k != T_DBL) return 0;
  *d = t->u.d;
  return 1;
}

int enif_get_atom(ErlNifEnv *env, ERL_NIF_TERM x, char *buf, unsigned len, ErlNifCharEncoding enc) {
  check_env(env);
  (void)enc;
  shim_term *t = term_of(x);
  if (t->k != T_ATOM) return 0;
  size_t n = strlen(t->u.atom);
  if (n + 1 > len) return 0;
  memcpy(buf, t->u.atom, n + 1);
  return (int)(n + 1);
}

ERL_NIF_TERM enif_make_long(ErlNifEnv *env, long v) {
  check_env(env);
  shim_term *t = new_term(T_INT);
  t->u.i.v = v;
  return TERM(t);
}

ERL_NIF_TERM enif_make_ulong(ErlNifEnv *env, unsigned long v) {
  check_env(env);
  shim_term *t = new_term(T_INT);
  t->u.i.v = (int64_t)v;
  t->u.i.big = v > (unsigned long)INT64_MAX;
  return TERM(t);
}

ERL_NIF_TERM enif_make_double(ErlNifEnv *env, double d) {
  check_env(env);
  /* ERTS raises badarg for a non-finite float; the runtime promises never to
     hand one over (defk_make_f64), so here it is a finding */
  if (!isfinite(d)) shim_fail("enif_make_double(%g): a kernel produced a non-finite float", d);
  shim_term *t = new_term(T_DBL);
  t->u.d = d;
  return TERM(t);
}

static ERL_NIF_TERM make_atom_len(const char *name, size_t len) {
  shim_term *t = new_term(T_ATOM);
  t->u.atom = malloc(len + 1);
  memcpy(t->u.atom, name, len);
  t->u.atom[len] = 0;
  return TERM(t);
}

ERL_NIF_TERM enif_make_atom(ErlNifEnv *env, const char *name) {
  check_env(env);
  size_t len = strlen(name);
  if (len > 255) shim_fail("enif_make_atom: atom longer than 255 characters");
  return make_atom_len(name, len);
}

int enif_make_new_atom_len(ErlNifEnv *env, const char *name, size_t len, ERL_NIF_TERM *atom,
                           ErlNifCharEncoding enc) {
  check_env(env);
  (void)enc;
  if (len > 255) return 0;
  *atom = make_atom_len(name, len);
  return 1;
}

int enif_is_identical(ERL_NIF_TERM a, ERL_NIF_TERM b) { return shim_equal(a, b); }

ERL_NIF_TERM enif_make_tuple(ErlNifEnv *env, unsigned cnt, ...) {
  check_env(env);
  shim_term *t = new_term(T_TUPLE);
  t->u.tup.n = (int)cnt;
  t->u.tup.e = malloc(sizeof(ERL_NIF_TERM) * (cnt ? cnt : 1));
  va_list ap;
  va_start(ap, cnt);
  for (unsigned i = 0; i < cnt; i++) t->u.tup.e[i] = TERM(term_of(va_arg(ap, ERL_NIF_TERM)));
  va_end(ap);
  return TERM(t);
}

int enif_make_map_from_arrays(ErlNifEnv *env, ERL_NIF_TERM keys[], ERL_NIF_TERM values[], size_t cnt,
                              ERL_NIF_TERM *map) {
  check_env(env);
  for (size_t i = 0; i < cnt; i++)
    for (size_t j = i + 1; j < cnt; j++)
      if (shim_equal(keys[i], keys[j])) return 0; /* duplicate key, as ERTS */
  shim_term *t = new_term(T_MAP);
  t->u.tup.n = (int)cnt;
  t->u.tup.e = malloc(sizeof(ERL_NIF_TERM) * (cnt ? 2 * cnt : 1));
  for (size_t i = 0; i < cnt; i++) {
    t->u.tup.e[i] = TERM(term_of(keys[i]));
    t->u.tup.e[cnt + i] = TERM(term_of(values[i]));
  }
  *map = TERM(t);
  return 1;
}

ERL_NIF_TERM enif_raise_exception(ErlNifEnv *env, ERL_NIF_TERM reason) {
  check_env(env);
  if (env->raised) shim_fail("enif_raise_exception called twice in one NIF call");
  env->raised = 1;
  env->exception = TERM(term_of(reason));
  return TERM(&raised_marker);
}

ERL_NIF_TERM enif_schedule_nif(ErlNifEnv *env, const char *name, int flags, shim_nif_fp fp, int argc,
                               const ERL_NIF_TERM argv[]) {
  check_env(env);
  if (!name || !fp) shim_fail("enif_schedule_nif without a name or function");
  if (flags != 0) shim_fail("enif_schedule_nif with flags %d (dirty scheduling is not modelled)", flags);
  if (argc < 0 || argc > SHIM_MAX_SCHED_ARGS) shim_fail("enif_schedule_nif with %d arguments", argc);
  if (env->sched_fp) shim_fail("enif_schedule_nif called twice in one NIF call");
  env->sched_fp = fp;
  env->sched_argc = argc;
  for (int i = 0; i < argc; i++) env->sched_argv[i] = TERM(term_of(argv[i]));
  return TERM(&scheduled_marker);
}

void shim_set_slow_clock(int on) { slow_clock = on; }

ErlNifTime enif_monotonic_time(ErlNifTimeUnit unit) {
  static ErlNifTime now;
  if (unit != ERL_NIF_USEC) shim_fail("enif_monotonic_time: only microseconds are modelled");
  if (slow_clock) now += 1000;
  return now;
}

int enif_consume_timeslice(ErlNifEnv *env, int percent) {
  check_env(env);
  if (percent < 1 || percent > 100) shim_fail("enif_consume_timeslice(%d): outside 1..100", percent);
  return slow_clock; /* the slice is used up: yield */
}

int enif_getenv(const char *key, char *value, size_t *size) {
  const char *v = getenv(key);
  if (!v) return -1;
  size_t n = strlen(v);
  if (n + 1 > *size) {
    *size = n + 1;
    return 1;
  }
  memcpy(value, v, n + 1);
  *size = n;
  return 0;
}

ErlNifResourceType *enif_open_resource_type(ErlNifEnv *env, const char *module_str, const char *name,
                                            ErlNifResourceDtor *dtor, ErlNifResourceFlags flags,
                                            ErlNifResourceFlags *tried) {
  (void)env;
  (void)module_str;
  (void)flags;
  static struct enif_resource_type_t types[8];
  static int ntypes;
  if (ntypes == 8) shim_fail("more than 8 resource types");
  ErlNifResourceType *rt = &types[ntypes++];
  snprintf(rt->name, sizeof rt->name, "%s", name);
  rt->dtor = dtor;
  if (tried) *tried = ERL_NIF_RT_CREATE;
  return rt;
}

void *enif_alloc_resource(ErlNifResourceType *type, size_t size) {
  if (!type) shim_fail("enif_alloc_resource with a null type (the library was not loaded)");
  shim_res *r = malloc(sizeof *r + size);
  if (!r) shim_fail("out of memory for a resource");
  r->type = type;
  r->refc = 1;
  live_resources++;
  return r->payload;
}

static shim_res *res_of(void *obj) { return (shim_res *)((unsigned char *)obj - offsetof(shim_res, payload)); }

void enif_release_resource(void *obj) { res_unref(res_of(obj)); }

ERL_NIF_TERM enif_make_resource(ErlNifEnv *env, void *obj) {
  check_env(env);
  shim_res *r = res_of(obj);
  r->refc++;
  shim_term *t = new_term(T_RES);
  t->u.res = r;
  return TERM(t);
}

int enif_get_resource(ErlNifEnv *env, ERL_NIF_TERM x, ErlNifResourceType *type, void **objp) {
  check_env(env);
  shim_term *t = term_of(x);
  if (t->k != T_RES || t->u.res->type != type) return 0;
  *objp = t->u.res->payload;
  return 1;
}
