/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
#ifndef TIDYVNC_PLATFORM_DISPLAY_METRICS_H
#define TIDYVNC_PLATFORM_DISPLAY_METRICS_H

// Value snapshot supplied by the host display adapter. Logical units are
// defined by that host; no window, screen handle or UI toolkit crosses here.
struct DisplayMetrics {
  double pixelsPerUnitX = 1, pixelsPerUnitY = 1;
  int screen = 0;
  unsigned long generation = 0;
  bool valid() const;
};

#endif
