/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
/* Measurement-only interposer for tests/perf/viewer-workloads.py --fltk-trace.
 * Loaded with DYLD_INSERT_LIBRARIES into a locally built (not hardened) FLTK
 * viewer; the viewer's source is unchanged. After every CGContextDrawImage call
 * it appends "<CLOCK_UPTIME_RAW ns> <width> <height>\n" (destination rectangle in
 * points) to the file named by TIDYVNC_DRAW_TRACE. */
#include <CoreGraphics/CoreGraphics.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include <unistd.h>

static int trace_fd = -2;

static void record(CGRect rect) {
  if (trace_fd == -2) {
    const char* path = getenv("TIDYVNC_DRAW_TRACE");
    trace_fd = path ? open(path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0600) : -1;
  }
  if (trace_fd < 0) return;
  char line[96];
  int length = snprintf(line, sizeof line, "%llu %.0f %.0f\n",
                        (unsigned long long)clock_gettime_nsec_np(CLOCK_UPTIME_RAW),
                        rect.size.width, rect.size.height);
  if (length > 0) (void)write(trace_fd, line, (size_t)length);
}

static void traced_draw_image(CGContextRef context, CGRect rect, CGImageRef image) {
  CGContextDrawImage(context, rect, image);
  record(rect);
}

__attribute__((used)) static const struct { const void* replacement; const void* replacee; }
  interposers[] __attribute__((section("__DATA,__interpose"))) = {
  { (const void*)traced_draw_image, (const void*)CGContextDrawImage },
};
