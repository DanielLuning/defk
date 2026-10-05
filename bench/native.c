/* Baseline: the same algorithms as Examples.Kernels in plain C,
 * built with the same flags (-O3), no BEAM involved.
 * usage: native N PRIMES_N   -> prints "sum_ns dot_ns primes_ms primes_early_ms" */
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

static double now_ns(void) {
  struct timespec t;
  clock_gettime(CLOCK_MONOTONIC, &t);
  return t.tv_sec * 1e9 + t.tv_nsec;
}

__attribute__((noinline)) static double sum(const double *a, int64_t n) {
  double acc = 0.0;
  for (int64_t i = 0; i < n; i++) acc += a[i];
  return acc;
}

__attribute__((noinline)) static double dot(const double *a, const double *b, int64_t n) {
  double acc = 0.0;
  for (int64_t i = 0; i < n; i++) acc += a[i] * b[i];
  return acc;
}

static int prime(int64_t x) {
  int64_t limit = (int64_t)sqrt((double)x);
  int p = 1;
  for (int64_t d = 2; d <= limit; d++) p = p && (x % d != 0);
  return p;
}

__attribute__((noinline)) static int64_t count_primes(int64_t n) {
  int64_t c = 0;
  for (int64_t i = 2; i <= n; i++) c += prime(i);
  return c;
}

/* count_primes_early: trial division stops at the first divisor */
static int prime_early(int64_t x) {
  int64_t limit = (int64_t)sqrt((double)x);
  for (int64_t d = 2; d <= limit; d++)
    if (x % d == 0) return 0;
  return 1;
}

__attribute__((noinline)) static int64_t count_primes_early(int64_t n) {
  int64_t c = 0;
  for (int64_t i = 2; i <= n; i++) c += prime_early(i);
  return c;
}

int main(int argc, char **argv) {
  int64_t n = atoll(argv[1]), pn = atoll(argv[2]);
  double *a = malloc(n * sizeof(double)), *b = malloc(n * sizeof(double));
  for (int64_t i = 0; i < n; i++) a[i] = b[i] = (double)((i + 1) % 1000) / 1000.0;

  double best_sum = 1e30, best_dot = 1e30, chk = 0;
  for (int r = 0; r < 5; r++) {
    /* barrier: stop clang reusing the (pure) result across repetitions */
    __asm__ volatile("" : : "r"(a), "r"(b) : "memory");
    double t = now_ns();
    chk += sum(a, n);
    double s = (now_ns() - t) / n;
    __asm__ volatile("" : : "r"(a), "r"(b) : "memory");
    t = now_ns();
    chk += dot(a, b, n);
    double d = (now_ns() - t) / n;
    if (s < best_sum) best_sum = s;
    if (d < best_dot) best_dot = d;
  }
  double t = now_ns();
  int64_t primes = count_primes(pn);
  double pm = (now_ns() - t) / 1e6;
  double pe = 1e30;
  int64_t primes_e = 0;
  for (int r = 0; r < 3; r++) {
    /* barriers: keep the (pure) call inside the timed region, once per rep */
    __asm__ volatile("" : "+r"(pn) : : "memory");
    t = now_ns();
    primes_e = count_primes_early(pn);
    __asm__ volatile("" : : "r"(primes_e) : "memory");
    double e = (now_ns() - t) / 1e6;
    if (e < pe) pe = e;
  }
  fprintf(stderr, "checksum %f primes %lld %lld\n", chk, (long long)primes, (long long)primes_e);
  printf("%f %f %f %f\n", best_sum, best_dot, pm, pe);
  return 0;
}
