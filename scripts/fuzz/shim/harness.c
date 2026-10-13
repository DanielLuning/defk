/*
 * libFuzzer entry points for one defk kernel (harness.h). Each input runs
 * twice through the NIF the generated Elixir function calls:
 *   1. straight: the shim's clock stands still, so the kernel never yields;
 *   2. yielding: the clock jumps 1 ms per read (shim_set_slow_clock), so the
 *      kernel yields at every clock read with its budget at the floor; every
 *      resume runs from the frame promoted to a resource, through the step
 *      function enif_schedule_nif was given, after the input binaries were
 *      moved to new addresses (as a GC between two calls may move them).
 * Findings, besides what ASan and UBSan report:
 *   - the two runs disagree (value, or exception and message)
 *   - an exception the target does not allow (e.g. Enum.OutOfBoundsError or
 *     ArithmeticError from a decoder whose own checks raise ArgumentError)
 *   - the target's check rejects a returned value
 *   - a frame resource, or a frame __defk_stats__ counts, outlives the call
 *   - more than STEP_LIMIT yields (no progress)
 * Leaked owned buffers are LeakSanitizer's (libFuzzer's -detect_leaks).
 */
#include "harness.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define STEP_LIMIT 10000000L
#define MAX_ARGS 16

ErlNifEntry *nif_init(void);

static ErlNifFunc *kernel, *stats;
static int verbose; /* DEFK_FUZZ_VERBOSE=1: print both outcomes of every input */

static ErlNifFunc *find_nif(ErlNifEntry *e, const char *name, unsigned arity) {
  for (int i = 0; i < e->num_of_funcs; i++)
    if (strcmp(e->funcs[i].name, name) == 0 && e->funcs[i].arity == arity) return &e->funcs[i];
  return NULL;
}

int LLVMFuzzerInitialize(int *argc, char ***argv) {
  (void)argc;
  (void)argv;
  const char *v = getenv("DEFK_FUZZ_VERBOSE");
  verbose = v && *v && strcmp(v, "0") != 0;
  ErlNifEntry *e = nif_init();
  void *priv = NULL;
  if (e->load && e->load(shim_env(), &priv, enif_make_atom(shim_env(), "nil")) != 0)
    shim_fail("the library's load callback failed");
  kernel = find_nif(e, defk_fuzz_target.nif, defk_fuzz_target.arity);
  stats = find_nif(e, "__defk_stats__", 0);
  if (!kernel) shim_fail("%s has no NIF %s/%u", e->name, defk_fuzz_target.nif, defk_fuzz_target.arity);
  if (kernel->flags) shim_fail("%s/%u is a dirty NIF (not modelled)", kernel->name, kernel->arity);
  if (!stats) shim_fail("%s has no __defk_stats__/0", e->name);
  shim_reset();
  return 0;
}

typedef struct {
  int raised;
  ERL_NIF_TERM term;
  long yields;
} outcome;

static int run(const uint8_t *data, size_t size, int yielding, outcome *out) {
  ERL_NIF_TERM argv[MAX_ARGS], sargv[MAX_ARGS], reason;
  int argc = defk_fuzz_target.args(data, size, argv);
  if (argc < 0) return 0;
  if ((unsigned)argc != defk_fuzz_target.arity)
    shim_fail("target made %d arguments for arity %u", argc, defk_fuzz_target.arity);
  shim_set_slow_clock(yielding);
  shim_nif_fp fp;
  int sargc;
  ERL_NIF_TERM r = kernel->fptr(shim_env(), argc, argv);
  out->yields = 0;
  for (;;) {
    if (shim_take_exception(&reason)) {
      out->raised = 1;
      out->term = reason;
      break;
    }
    if (!shim_take_scheduled(&fp, &sargc, sargv, MAX_ARGS)) {
      out->raised = 0;
      out->term = r;
      break;
    }
    if (++out->yields > STEP_LIMIT) shim_fail("no progress: more than %ld yields", STEP_LIMIT);
    for (int i = 0; i < argc; i++) shim_move_binary(argv[i]);
    r = fp(shim_env(), sargc, sargv);
  }
  shim_set_slow_clock(0);
  return 1;
}

static void dump(const char *what, const outcome *o) {
  fprintf(stderr, "  %s (%ld yields): %s ", what, o->yields, o->raised ? "raised" : "returned");
  shim_print(o->term);
  fputc('\n', stderr);
}

static void check_exception(const outcome *o) {
  ERL_NIF_TERM mod, exc, msg;
  const uint8_t *m;
  size_t mlen;
  if (!shim_map_get(o->term, "__struct__", &mod) || !shim_map_get(o->term, "__exception__", &exc) ||
      !shim_is_atom(exc, "true") || !shim_map_get(o->term, "message", &msg) || !shim_get_bin(msg, &m, &mlen)) {
    dump("straight", o);
    shim_fail("raised a term that is not an exception struct with a message");
  }
  for (const char *const *ok = defk_fuzz_target.exceptions; *ok; ok++)
    if (shim_is_atom(mod, *ok)) return;
  dump("straight", o);
  shim_fail("raised an exception the target does not allow");
}

static long frames_live(void) {
  ERL_NIF_TERM map = stats->fptr(shim_env(), 0, NULL), v;
  int64_t n;
  if (!shim_map_get(map, "frames_live", &v) || !shim_get_int(v, &n)) shim_fail("__defk_stats__ has no frames_live");
  return (long)n;
}

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
  outcome straight, yielding;
  if (!run(data, size, 0, &straight)) return -1; /* rejected: keep it out of the corpus */
  run(data, size, 1, &yielding);
  if (verbose) {
    fprintf(stderr, "input of %zu bytes\n", size);
    dump("straight", &straight);
    dump("yielding", &yielding);
  }
  if (straight.raised != yielding.raised || !shim_equal(straight.term, yielding.term)) {
    dump("straight", &straight);
    dump("yielding", &yielding);
    shim_fail("the yielding run disagrees with the straight run");
  }
  if (straight.raised) check_exception(&straight);
  else if (defk_fuzz_target.check) defk_fuzz_target.check(data, size, straight.term);
  shim_reset();
  if (shim_live_resources() != 0) shim_fail("%ld frame resource(s) outlived the call", shim_live_resources());
  long live = frames_live();
  shim_reset();
  if (live != 0) shim_fail("__defk_stats__ counts %ld live frame(s) after the call", live);
  return 0;
}
