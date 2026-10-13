/*
 * LzSnappy.Kernels.snappy_decode/1 (examples/lz4_snappy_decode.exs).
 * Input: the Snappy block itself.
 * On success it returns a binary exactly as long as the varint length
 * preamble says.
 */
#include "../shim/harness.h"

static int args(const uint8_t *d, size_t n, ERL_NIF_TERM *argv) {
  argv[0] = shim_make_input_binary(d, n);
  argv[1] = enif_make_long(shim_env(), 0); /* run-queue hint: none waiting */
  return 2;
}

static void check(const uint8_t *d, size_t n, ERL_NIF_TERM result) {
  uint64_t ulen = 0;
  size_t i = 0;
  for (; i < n && i < 5; i++) {
    ulen |= (uint64_t)(d[i] & 127) << (7 * i);
    if (d[i] < 128) break;
  }
  if (i == n || i == 5) shim_fail("snappy_decode accepted a block without a complete length preamble");
  const uint8_t *buf;
  size_t size;
  if (!shim_get_bin(result, &buf, &size)) shim_fail("snappy_decode did not return a binary");
  if (size != ulen) shim_fail("snappy_decode returned %zu bytes, the preamble says %llu", size, (unsigned long long)ulen);
}

static const char *const exceptions[] = {"Elixir.ArgumentError", NULL};

const fuzz_target defk_fuzz_target = {
    .nif = "__defk_native_snappy_decode__",
    .arity = 2,
    .args = args,
    .exceptions = exceptions,
    .check = check,
};
