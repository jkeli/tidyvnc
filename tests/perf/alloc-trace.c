/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
/* Measurement-only allocation counter for tests/perf/viewer-workloads.py
 * --alloc-trace, loaded with DYLD_INSERT_LIBRARIES into local, non-hardened
 * viewer builds (FLTK or native); the viewers are unchanged. It counts
 * allocation calls and requested bytes through the malloc, zone and typed-malloc
 * entry points used by C, C++, Objective-C and Swift code outside libmalloc.
 * On each SIGUSR1 it appends "<allocations> <bytes>\n" to the file named by
 * TIDYVNC_ALLOC_TRACE, using only async-signal-safe calls. */
#include <fcntl.h>
#include <malloc/malloc.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static _Atomic uint64_t allocations, bytes;
static int trace_fd = -1;

static void count(size_t size) {
  atomic_fetch_add_explicit(&allocations, 1, memory_order_relaxed);
  atomic_fetch_add_explicit(&bytes, size, memory_order_relaxed);
}

static size_t format(char* out, uint64_t value) {
  char digits[24];
  size_t length = 0;
  do { digits[length++] = (char)('0' + value % 10); value /= 10; } while (value);
  for (size_t i = 0; i < length; i++) out[i] = digits[length - 1 - i];
  return length;
}

static void snapshot(int signal) {
  (void)signal;
  if (trace_fd < 0) return;
  char line[64];
  size_t length = format(line, atomic_load(&allocations));
  line[length++] = ' ';
  length += format(line + length, atomic_load(&bytes));
  line[length++] = '\n';
  (void)write(trace_fd, line, length);
}

__attribute__((constructor)) static void start(void) {
  const char* path = getenv("TIDYVNC_ALLOC_TRACE");
  if (!path) return;
  trace_fd = open(path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0600);
  struct sigaction action;
  memset(&action, 0, sizeof(action));
  action.sa_handler = snapshot;
  action.sa_flags = SA_RESTART;
  sigaction(SIGUSR1, &action, NULL);
}

#define WRAP(ret, name, params, args, size)                    \
  static ret traced_##name params {                            \
    count(size);                                               \
    return name args;                                          \
  }

WRAP(void*, malloc, (size_t s), (s), s)
WRAP(void*, calloc, (size_t n, size_t s), (n, s), n * s)
WRAP(void*, realloc, (void* p, size_t s), (p, s), s)
WRAP(void*, valloc, (size_t s), (s), s)
WRAP(void*, aligned_alloc, (size_t a, size_t s), (a, s), s)
WRAP(int, posix_memalign, (void** p, size_t a, size_t s), (p, a, s), s)
WRAP(void*, malloc_zone_malloc, (malloc_zone_t* z, size_t s), (z, s), s)
WRAP(void*, malloc_zone_calloc, (malloc_zone_t* z, size_t n, size_t s), (z, n, s), n * s)
WRAP(void*, malloc_zone_realloc, (malloc_zone_t* z, void* p, size_t s), (z, p, s), s)
WRAP(void*, malloc_zone_memalign, (malloc_zone_t* z, size_t a, size_t s), (z, a, s), s)
WRAP(void*, malloc_type_malloc, (size_t s, malloc_type_id_t t), (s, t), s)
WRAP(void*, malloc_type_calloc, (size_t n, size_t s, malloc_type_id_t t), (n, s, t), n * s)
WRAP(void*, malloc_type_realloc, (void* p, size_t s, malloc_type_id_t t), (p, s, t), s)
WRAP(void*, malloc_type_aligned_alloc, (size_t a, size_t s, malloc_type_id_t t), (a, s, t), s)
WRAP(int, malloc_type_posix_memalign, (void** p, size_t a, size_t s, malloc_type_id_t t), (p, a, s, t), s)
WRAP(void*, malloc_type_zone_malloc, (malloc_zone_t* z, size_t s, malloc_type_id_t t), (z, s, t), s)
WRAP(void*, malloc_type_zone_calloc, (malloc_zone_t* z, size_t n, size_t s, malloc_type_id_t t), (z, n, s, t), n * s)
WRAP(void*, malloc_type_zone_realloc, (malloc_zone_t* z, void* p, size_t s, malloc_type_id_t t), (z, p, s, t), s)

#define INTERPOSE(name) { (const void*)traced_##name, (const void*)name }
__attribute__((used)) static const struct { const void* replacement; const void* replacee; }
  interposers[] __attribute__((section("__DATA,__interpose"))) = {
  INTERPOSE(malloc), INTERPOSE(calloc), INTERPOSE(realloc), INTERPOSE(valloc), INTERPOSE(aligned_alloc),
  INTERPOSE(posix_memalign), INTERPOSE(malloc_zone_malloc), INTERPOSE(malloc_zone_calloc),
  INTERPOSE(malloc_zone_realloc), INTERPOSE(malloc_zone_memalign), INTERPOSE(malloc_type_malloc),
  INTERPOSE(malloc_type_calloc), INTERPOSE(malloc_type_realloc), INTERPOSE(malloc_type_aligned_alloc),
  INTERPOSE(malloc_type_posix_memalign), INTERPOSE(malloc_type_zone_malloc), INTERPOSE(malloc_type_zone_calloc),
  INTERPOSE(malloc_type_zone_realloc),
};
