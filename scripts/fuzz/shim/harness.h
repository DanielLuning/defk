/*
 * The libFuzzer harness shared by every target (harness.c). A target (one
 * file in scripts/fuzz/targets/) names the kernel's NIF, turns the fuzzer's
 * bytes into its arguments and checks a returned value; the harness does the
 * rest: load the library through its own nif_init(), call the NIF the way
 * the generated Elixir function does, follow enif_schedule_nif
 * continuations, and check what comes back.
 */
#ifndef DEFK_FUZZ_HARNESS_H
#define DEFK_FUZZ_HARNESS_H

#include "nif_shim.h"

typedef struct {
  /* the NIF as registered in the library's defk_funcs table, e.g.
     "__defk_native_lz4_block_decode__" (arity counts the run-queue hint a
     yielding kernel takes last) */
  const char *nif;
  unsigned arity;
  /* fill argv (shim_make_input_binary, enif_make_long(shim_env(), ...))
     from the input; return the argument count, or -1 to skip the input */
  int (*args)(const uint8_t *data, size_t size, ERL_NIF_TERM *argv);
  /* the exception structs the kernel may raise on bad input, NULL-ended;
     any other is a finding */
  const char *const *exceptions;
  /* check a returned value (call shim_fail on a wrong one); may be NULL */
  void (*check)(const uint8_t *data, size_t size, ERL_NIF_TERM result);
} fuzz_target;

extern const fuzz_target defk_fuzz_target;

#endif
