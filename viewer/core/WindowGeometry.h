/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
#ifndef TIDYVNC_WINDOW_GEOMETRY_H
#define TIDYVNC_WINDOW_GEOMETRY_H
#include <cstdint>
#include <string>
namespace viewer {
struct WindowGeometry {
  bool hasSize = false, hasPosition = false;
  int32_t width = 0, height = 0, x = 0, y = 0;
  // Retained sscanf forms with checked integer arithmetic. Empty means no
  // override. Coordinates are signed absolute offsets, not right/bottom offsets.
  // Trailing text and two/four-conversion dimension forms remain compatible.
  static WindowGeometry parse(const std::string& value);
};
}
#endif
