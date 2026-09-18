/* Copyright 2026 TigerVNC contributors. Licensed under GPL-2.0-or-later. */
#include "DesktopTileCache.h"
#include <algorithm>
#include <cmath>
#include <cstring>
#include <new>
#include <stdexcept>

void DesktopTileCache::clear()
{
  entries.clear();
  used = 0;
}

void DesktopTileCache::setBudget(size_t bytes)
{
  budget=bytes;
  while(used>budget) {
    used-=entries.back().pixels.size();
    entries.pop_back();
  }
}

void DesktopTileCache::configure(int sourceW, int sourceH, int destW, int destH,
                                ScalingSettings::Quality q, unsigned long g)
{
  if (sw != sourceW || sh != sourceH || dw != destW || dh != destH ||
      quality != q || generation != g) {
    clear();
    sw = sourceW; sh = sourceH; dw = destW; dh = destH;
    quality = q; generation = g;
  }
}

void DesktopTileCache::invalidate(const core::Rect& damage)
{
  if (damage.is_empty() || entries.empty()) return;
  int halo = quality == ScalingSettings::Nearest ? 0 : 1;
  core::Rect affected(int(std::floor(std::max(0, damage.tl.x-halo)*double(dw)/sw)),
                      int(std::floor(std::max(0, damage.tl.y-halo)*double(dh)/sh)),
                      int(std::ceil(std::min(sw, damage.br.x+halo)*double(dw)/sw)),
                      int(std::ceil(std::min(sh, damage.br.y+halo)*double(dh)/sh)));
  for (auto it = entries.begin(); it != entries.end();) {
    if (!it->rect.intersect(affected).is_empty()) {
      used -= it->pixels.size();
      it = entries.erase(it);
    } else ++it;
  }
}

bool DesktopTileCache::render(const uint8_t* source, size_t sourceStride,
                             uint8_t* output, size_t outputStride,
                             const core::Rect& tile)
{
  if (tile.is_empty() || tile.tl.x < 0 || tile.tl.y < 0 ||
      tile.br.x > dw || tile.br.y > dh || tile.width() > 256 || tile.height() > 256 ||
      !output || outputStride < size_t(tile.width())*4)
    throw std::invalid_argument("Invalid cached desktop tile");
  size_t row = size_t(tile.width())*4;
  for (auto it = entries.begin(); it != entries.end(); ++it) {
    if (it->rect == tile) {
      for (int y = 0; y < tile.height(); ++y)
        memcpy(output+y*outputStride, it->pixels.data()+y*row, row);
      entries.splice(entries.begin(), entries, it);
      return true;
    }
  }
  resampleDesktop(source, sw, sh, sourceStride, output, outputStride, dw, dh, tile, quality);
  size_t size = row*tile.height();
  if (size > budget) return false;
  while (used > budget-size) {
    used -= entries.back().pixels.size();
    entries.pop_back();
  }
  try {
    Entry entry{tile, std::vector<uint8_t>(size)};
    for (int y = 0; y < tile.height(); ++y)
      memcpy(entry.pixels.data()+y*row, output+y*outputStride, row);
    entries.push_front(std::move(entry));
    used += size;
  } catch (const std::bad_alloc&) {
    clear();
  }
  return false;
}
