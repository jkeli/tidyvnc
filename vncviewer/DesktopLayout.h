/* Copyright 2026 TigerVNC contributors. Licensed under GPL-2.0-or-later. */
#ifndef TIDYVNC_DESKTOP_LAYOUT_H
#define TIDYVNC_DESKTOP_LAYOUT_H
#include "DesktopTransform.h"
#include <rfb/ScreenSet.h>
#include <vector>

struct DesktopMonitor {
  uint32_t id;
  int screen;
  core::Rect logical;
  int backingWidth, backingHeight;
};
struct DesktopRegion {
  DesktopMonitor monitor;
  core::Rect canvas;
};
struct DesktopLayout {
  explicit DesktopLayout(const std::vector<DesktopMonitor>& monitors,
                         ScalingSettings::Units units);
  std::vector<DesktopRegion> regions;
  int width=0, height=0;
  bool normalized=false;
  rfb::ScreenSet screens() const;
};
#endif
