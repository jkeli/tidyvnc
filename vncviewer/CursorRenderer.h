/* Copyright 2026 TigerVNC contributors. Licensed under GPL-2.0-or-later. */
#ifndef TIGERVNC_CURSOR_RENDERER_H
#define TIGERVNC_CURSOR_RENDERER_H

#include "DesktopResampler.h"
#include <vector>

// Retains only the original cursor, never a full enlarged cursor raster.
// The caller requests visible tiles, in cursor backing-pixel coordinates.
class CursorRenderer {
public:
  CursorRenderer(const uint8_t* rgba, int width, int height, core::Point hotspot,
                 double scaleX, double scaleY, ScalingSettings::Quality quality);
  int width() const { return dw; }
  int height() const { return dh; }
  core::Point hotspot() const { return hot; }
  // Straight RGBA for Surface's image constructor; filtering is premultiplied.
  void render(uint8_t* rgba, size_t stride, const core::Rect& tile) const;
private:
  int sw, sh, dw, dh;
  core::Point hot;
  ScalingSettings::Quality quality;
  std::vector<uint8_t> source;
};
#endif
