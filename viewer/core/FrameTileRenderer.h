/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
#ifndef TIDYVNC_FRAME_TILE_RENDERER_H
#define TIDYVNC_FRAME_TILE_RENDERER_H
#include "DesktopTileCache.h"
#include "FramePublisher.h"

namespace viewer {
// One caller/executor at a time. Retains only bounded cache pixels and metadata,
// never a framebuffer lease. The caller supplies an immutable frame for each
// synchronous tile render. Source IDs must uniquely identify a publication stream.
class FrameTileRenderer {
public:
  explicit FrameTileRenderer(size_t cacheBytes);
  void clear();
  // Damage is relative to previousSequence in this stream. If the renderer did
  // not consume that frame, discard the cache instead of trusting partial damage.
  // All tiles for one frame must carry the same damage/previousSequence contract.
  // Output is tightly packed opaque BGRA, <=256x256; false means a cache miss.
  bool render(uint64_t source, const FrameLease& frame, uint64_t previousSequence,
              const Damage& damage, int width, int height, ScalingSettings::Quality quality,
              const core::Rect& tile, uint8_t* output, size_t length);
  size_t bytes() const { return cache.bytes(); }
private:
  DesktopTileCache cache;
  uint64_t source = 0, generation = 0, sizeGeneration = 0, sequence = 0;
};
}
#endif
