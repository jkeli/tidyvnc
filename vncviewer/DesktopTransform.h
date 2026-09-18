/* Copyright 2026 TigerVNC contributors. Licensed under GPL-2.0-or-later. */
#ifndef TIDYVNC_DESKTOP_TRANSFORM_H
#define TIDYVNC_DESKTOP_TRANSFORM_H

#include <string>
#include <core/Rect.h>

// R: remote pixels, L: FLTK logical units, B: window backing pixels.
// Native screen coordinates are deliberately absent from this model.
struct ScalingSettings {
  enum Mode { Unscaled, Auto, FixedRatio, FitWidth, FitHeight, Exact, Percent, Independent };
  enum Units { Logical, Device };
  enum Quality { Nearest, Bilinear, Area };
  Mode mode = Unscaled;
  unsigned x = 10000, y = 10000; // hundredths of a percent, or exact pixels
  static ScalingSettings parse(const std::string& value);
  std::string serialize() const;
  bool fits() const;
};

struct DisplayMetrics {
  double pixelsPerUnitX = 1, pixelsPerUnitY = 1;
  int screen = 0;
  unsigned long generation = 0;
  bool valid() const;
};

class DesktopTransform {
public:
  // Available dimensions and image origin are logical; results are backing
  // pixels. Positive image dimensions are limited to 65535 on each axis.
  DesktopTransform(int remoteWidth, int remoteHeight,
                   double availableWidth, double availableHeight,
                   const DisplayMetrics& metrics,
                   const ScalingSettings& settings, ScalingSettings::Units units,
                   double originX = 0, double originY = 0);
  int remoteWidth, remoteHeight;
  int backingWidth, backingHeight;
  double logicalWidth, logicalHeight;
  int originBX, originBY;
  DisplayMetrics metrics;
  bool empty() const { return backingWidth == 0 || backingHeight == 0; }
  bool identity() const;
  void placeOnCanvas(int width, int height, const core::Rect& region,
                     ScalingSettings::Units units, double panX = 0, double panY = 0);
  core::Point remotePoint(double logicalX, double logicalY) const;
  core::Rect logicalDamage(const core::Rect& remote, ScalingSettings::Quality quality) const;
};
#endif
