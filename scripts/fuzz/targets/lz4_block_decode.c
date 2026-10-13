/*
 * LzSnappy.Kernels.lz4_block_decode/2 (examples/lz4_snappy_decode.exs).
 * Input: two bytes little-endian u16, max_out = that - 16 (so -16..65519: a
 * negative bound must raise), then the LZ4 block.
 * On success it returns {buffer, len} with byte_size(buffer) == max_out and
 * 0 <= len <= max_out.
 */
#include "../shim/harness.h"

static int args(const uint8_t *d, size_t n, ERL_NIF_TERM *argv) {
  if (n < 2) return -1;
  long max_out = (long)(d[0] | (d[1] << 8)) - 16;
  argv[0] = shim_make_input_binary(d + 2, n - 2);
  argv[1] = enif_make_long(shim_env(), max_out);
  argv[2] = enif_make_long(shim_env(), 0); /* run-queue hint: none waiting */
  return 3;
}

static void check(const uint8_t *d, size_t n, ERL_NIF_TERM result) {
  (void)n;
  long max_out = (long)(d[0] | (d[1] << 8)) - 16;
  int arity;
  const ERL_NIF_TERM *e;
  const uint8_t *buf;
  size_t size;
  int64_t len;
  if (!shim_get_tuple(result, &arity, &e) || arity != 2 || !shim_get_bin(e[0], &buf, &size) ||
      !shim_get_int(e[1], &len))
    shim_fail("lz4_block_decode did not return {binary, integer}");
  if ((long)size != max_out || len < 0 || len > max_out)
    shim_fail("lz4_block_decode returned a %zu-byte buffer and length %lld for max_out %ld", size,
              (long long)len, max_out);
}

static const char *const exceptions[] = {"Elixir.ArgumentError", NULL};

const fuzz_target defk_fuzz_target = {
    .nif = "__defk_native_lz4_block_decode__",
    .arity = 3,
    .args = args,
    .exceptions = exceptions,
    .check = check,
};
