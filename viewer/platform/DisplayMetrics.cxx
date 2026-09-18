/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
#include "DisplayMetrics.h"
#include <cmath>

bool DisplayMetrics::valid() const
{
  return std::isfinite(pixelsPerUnitX) && std::isfinite(pixelsPerUnitY) &&
         pixelsPerUnitX >= 1.0/16 && pixelsPerUnitY >= 1.0/16 &&
         pixelsPerUnitX <= 16 && pixelsPerUnitY <= 16;
}
