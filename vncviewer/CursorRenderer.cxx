/* Copyright 2026 TigerVNC contributors. Licensed under GPL-2.0-or-later. */
#include "CursorRenderer.h"
#include <algorithm>
#include <cmath>
#include <limits>
#include <stdexcept>

CursorRenderer::CursorRenderer(const uint8_t* rgba, int w, int h, core::Point hotspot,
                               double sx, double sy, ScalingSettings::Quality q)
  : sw(w), sh(h), quality(q)
{
  double width = std::max(1., std::floor(w*sx+.5));
  double height = std::max(1., std::floor(h*sy+.5));
  if (!rgba || w <= 0 || h <= 0 || w > 65535 || h > 65535 ||
      !std::isfinite(sx) || !std::isfinite(sy) || sx <= 0 || sy <= 0 ||
      width > std::numeric_limits<int>::max()/4 || height > std::numeric_limits<int>::max()/4)
    throw std::invalid_argument("Invalid cursor transform");
  dw = int(width); dh = int(height);
  hot = {int(std::floor(std::max(0,std::min(w-1,hotspot.x))*sx+.5)),
         int(std::floor(std::max(0,std::min(h-1,hotspot.y))*sy+.5))};
  hot.x = std::min(dw-1,hot.x); hot.y = std::min(dh-1,hot.y);
  source.resize(size_t(w)*h*4);
  for (size_t i=0; i<source.size(); i+=4) {
    for (int c=0; c<3; ++c) source[i+c] = unsigned(rgba[i+c])*rgba[i+3]/255;
    source[i+3] = rgba[i+3];
  }
}

void CursorRenderer::render(uint8_t* rgba, size_t stride, const core::Rect& tile) const
{
  resampleDesktop(source.data(), sw, sh, size_t(sw)*4, rgba, stride,
                  dw, dh, tile, quality, true);
  // Round upward so Surface's integer premultiplication reconstructs the
  // filtered premultiplied value exactly, including faint cursor edges.
  for (int y=0; y<tile.height(); ++y) for (int x=0; x<tile.width(); ++x) {
    uint8_t* pixel = rgba+y*stride+x*4;
    if (pixel[3]) for (int c=0; c<3; ++c)
      pixel[c] = std::min(255u,(unsigned(pixel[c])*255+pixel[3]-1)/pixel[3]);
  }
}
