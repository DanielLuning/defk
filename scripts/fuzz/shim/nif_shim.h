/*
 * A small erl_nif implementation for running a defk kernel library outside
 * the VM (libFuzzer). Implements the enif_* functions the generated C and
 * priv/defk_runtime.h call, over malloc, with real terms: integers, floats,
 * atoms, binaries, tuples, maps and resources (reference counted; the
 * destructor runs when the last term holding one is dropped). Every term and
 * every binary is its own malloc block, so ASan sees an access past a binary
 * or to a term after its environment was reset.
 *
 * Not modelled: processes, messages, GC (beyond moving input binaries
 * between calls, shim_move_binary), dirty schedulers, iolists, bignums.
 * See scripts/fuzz/README.md.
 */
#ifndef DEFK_NIF_SHIM_H
#define DEFK_NIF_SHIM_H

#include <erl_nif.h>
#include <stddef.h>
#include <stdint.h>

/* The single environment the kernels run in. */
ErlNifEnv *shim_env(void);

/* Drop every term made since the last reset (and with them the references
 * they hold on resources and the binaries they own). */
void shim_reset(void);

/* An input binary: its own exact-size copy of `data` (so a read one byte
 * past it, or before it, is an ASan report). */
ERL_NIF_TERM shim_make_input_binary(const uint8_t *data, size_t size);

/* Emulate the GC moving a binary between two calls of a yielding kernel:
 * the data gets a new address and the old block is freed, so a kernel that
 * kept a pointer across a yield reads freed memory (ASan: use-after-free). */
void shim_move_binary(ERL_NIF_TERM t);

/* After a NIF call returns: did it raise (and with what), or schedule a
 * continuation (and which)? Each getter clears what it reports. */
int shim_take_exception(ERL_NIF_TERM *reason);
typedef ERL_NIF_TERM (*shim_nif_fp)(ErlNifEnv *, int, const ERL_NIF_TERM[]);
int shim_take_scheduled(shim_nif_fp *fp, int *argc, ERL_NIF_TERM *argv, int max);

/* The clock. Off (the default), no time passes, so a kernel never yields.
 * On, every enif_monotonic_time read is 1 ms after the previous one and
 * enif_consume_timeslice reports the slice used up: the kernel yields at
 * every clock read, and its adaptive budget shrinks to its floor (16
 * back-edges), so it reads the clock, and yields, as often as it can. */
void shim_set_slow_clock(int on);

/* Inspecting terms (for the harness and the targets' oracles). */
int shim_equal(ERL_NIF_TERM a, ERL_NIF_TERM b);
void shim_print(ERL_NIF_TERM t); /* to stderr, Erlang-ish syntax */
int shim_is_atom(ERL_NIF_TERM t, const char *name);
int shim_get_bin(ERL_NIF_TERM t, const uint8_t **data, size_t *size);
int shim_get_int(ERL_NIF_TERM t, int64_t *v);
int shim_get_tuple(ERL_NIF_TERM t, int *arity, const ERL_NIF_TERM **elems);
int shim_map_get(ERL_NIF_TERM map, const char *atom_key, ERL_NIF_TERM *value);

/* Live resources (alloc_resource minus destroyed): 0 once nothing holds one. */
long shim_live_resources(void);

/* Print a message and abort: a finding (libFuzzer saves the input). */
__attribute__((noreturn, format(printf, 1, 2))) void shim_fail(const char *fmt, ...);

#endif
