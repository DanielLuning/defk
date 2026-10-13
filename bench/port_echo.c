/*
 * The port program of bench/port_roundtrip.exs: {packet, 4} frames on stdin,
 * one frame back per frame received. `echo` sends the payload back, `ack`
 * sends 8 bytes. The floor of any out-of-process kernel design (a port
 * program or an erl_interface C node): two pipe transfers per call, before
 * any term encoding or work.
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static int read_full(int fd, uint8_t *p, size_t n) {
  while (n) {
    ssize_t r = read(fd, p, n);
    if (r <= 0) return 0;
    p += r;
    n -= (size_t)r;
  }
  return 1;
}

static int write_full(int fd, const uint8_t *p, size_t n) {
  while (n) {
    ssize_t w = write(fd, p, n);
    if (w <= 0) return 0;
    p += w;
    n -= (size_t)w;
  }
  return 1;
}

int main(int argc, char **argv) {
  int echo = argc > 1 && strcmp(argv[1], "echo") == 0;
  size_t cap = 1 << 20;
  uint8_t *buf = malloc(cap);
  uint8_t hdr[4], ack[12] = {0, 0, 0, 8, 'a', 'c', 'k', 'a', 'c', 'k', 'e', 'd'};
  for (;;) {
    if (!read_full(0, hdr, 4)) return 0;
    size_t n = ((size_t)hdr[0] << 24) | ((size_t)hdr[1] << 16) | ((size_t)hdr[2] << 8) | hdr[3];
    if (n > cap) {
      cap = n;
      buf = realloc(buf, cap);
    }
    if (!read_full(0, buf, n)) return 0;
    if (echo) {
      if (!write_full(1, hdr, 4) || !write_full(1, buf, n)) return 0;
    } else {
      if (!write_full(1, ack, 12)) return 0;
    }
  }
}
