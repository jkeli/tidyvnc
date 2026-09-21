/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
#include "FrameTileRenderer.h"
#include <stdexcept>

namespace viewer {
FrameTileRenderer::FrameTileRenderer(size_t bytes) : cache(bytes) {
  if (bytes > 32*1024*1024) throw std::invalid_argument("Invalid tile cache budget");
}
void FrameTileRenderer::clear() {
  cache.clear(); source = generation = sizeGeneration = sequence = 0;
}
bool FrameTileRenderer::render(uint64_t sourceID, const FrameLease& frame, uint64_t previous,
    const Damage& damage, int width, int height, ScalingSettings::Quality quality,
    const core::Rect& tile, uint8_t* output, size_t length) {
  if (!sourceID || !frame || !output || width < 1 || height < 1 || width > 65535 || height > 65535 ||
      quality < ScalingSettings::Nearest || quality > ScalingSettings::Area ||
      tile.is_empty() || tile.tl.x < 0 || tile.tl.y < 0 || tile.br.x > width || tile.br.y > height ||
      tile.width() > 256 || tile.height() > 256 || length < size_t(tile.width())*tile.height()*4)
    throw std::invalid_argument("Invalid frame tile request");
  const auto& pixels = frame->pixels;
  if (pixels.format() != PixelFormat::BGRA8 || pixels.alpha() != AlphaMode::Opaque ||
      damage.x > pixels.width() || damage.y > pixels.height() ||
      damage.width > pixels.width()-damage.x || damage.height > pixels.height()-damage.y)
    throw std::invalid_argument("Invalid frame tile source");
  if (source != sourceID || generation != frame->generation || sizeGeneration != frame->sizeGeneration ||
      (sequence != frame->sequence && sequence != previous)) cache.clear();
  cache.configure(pixels.width(),pixels.height(),width,height,quality,0);
  if (sequence != frame->sequence)
    cache.invalidate({int(damage.x),int(damage.y),int(damage.x+damage.width),int(damage.y+damage.height)});
  source = sourceID; generation = frame->generation; sizeGeneration = frame->sizeGeneration; sequence = frame->sequence;
  return cache.render(pixels.data(),pixels.stride(),output,size_t(tile.width())*4,tile);
}
}
