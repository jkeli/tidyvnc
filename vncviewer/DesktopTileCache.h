/* Copyright 2026 TigerVNC contributors. Licensed under GPL-2.0-or-later. */
#ifndef TIDYVNC_DESKTOP_TILE_CACHE_H
#define TIDYVNC_DESKTOP_TILE_CACHE_H

#include "DesktopResampler.h"
#include <list>
#include <vector>

// CPU copies only: native upload/composition storage is separately bounded.
// Tiles use a fixed grid in the output image, so scrolling reuses samples.
// The viewer source format is fixed opaque BGRA. Sampling origin is always
// (0,0) in the full output raster; window position is only a blit offset.
class DesktopTileCache {
public:
  explicit DesktopTileCache(size_t budget = 32 * 1024 * 1024) : budget(budget) {}
  void clear();
  void setBudget(size_t bytes);
  void configure(int sw, int sh, int dw, int dh,
                 ScalingSettings::Quality quality, unsigned long generation);
  void invalidate(const core::Rect& sourceDamage);
  // Returns true on a cache hit. A cache allocation failure drops the cache;
  // output is already rendered into the caller's bounded scratch buffer.
  bool render(const uint8_t* source, size_t sourceStride, uint8_t* output,
              size_t outputStride, const core::Rect& tile);
  size_t bytes() const { return used; }
private:
  struct Entry { core::Rect rect; std::vector<uint8_t> pixels; };
  std::list<Entry> entries;
  size_t budget, used = 0;
  int sw = 0, sh = 0, dw = 0, dh = 0;
  ScalingSettings::Quality quality = ScalingSettings::Nearest;
  unsigned long generation = 0;
};
#endif
