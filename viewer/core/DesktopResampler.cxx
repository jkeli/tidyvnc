/* Copyright 2026 TigerVNC contributors. Licensed under GPL-2.0-or-later. */
#include "DesktopResampler.h"
#include <algorithm>
#include <cmath>
#include <cstring>
#include <limits>
#include <stdexcept>

namespace {
struct Kernel {
  int first, last;
  double start, end;
  bool area;
  Kernel(int destination, int sourceSize, int destinationSize, ScalingSettings::Quality quality)
  {
    double scale = double(sourceSize) / destinationSize;
    area = quality == ScalingSettings::Area && sourceSize > destinationSize;
    if (quality == ScalingSettings::Nearest) {
      first = last = std::min(sourceSize - 1, int((destination + .5) * scale));
      start = first; end = first + 1;
    } else if (area) {
      start = destination * scale; end = (destination + 1) * scale;
      first = std::max(0, int(std::floor(start)));
      last = std::min(sourceSize - 1, int(std::ceil(end)) - 1);
    } else {
      start = std::max(0., std::min(double(sourceSize - 1), (destination + .5) * scale - .5));
      end = start + 1;
      first = int(std::floor(start)); last = std::min(sourceSize - 1, first + 1);
    }
  }
  double weight(int i) const {
    if (first == last) return 1;
    if (area) return std::max(0., std::min(end, i + 1.) - std::max(start, double(i))) / (end - start);
    return i == first ? 1 - (start - first) : start - first;
  }
};
}
void resampleDesktop(const uint8_t* src, int sw, int sh, size_t ss,
                     uint8_t* dst, size_t ds, int dw, int dh,
                     const core::Rect& tile, ScalingSettings::Quality quality, bool alpha)
{
  if (!src || !dst || sw <= 0 || sh <= 0 || dw <= 0 || dh <= 0 ||
      sw > 65535 || sh > 65535 ||
      dw > std::numeric_limits<int>::max()/4 || dh > std::numeric_limits<int>::max()/4 ||
      tile.tl.x < 0 || tile.tl.y < 0 || tile.br.x > dw || tile.br.y > dh ||
      tile.is_empty() || tile.width() > 256 || tile.height() > 256 ||
      ss < size_t(sw)*4 || ds < size_t(tile.width())*4)
    throw std::invalid_argument("Invalid desktop resampling tile");
  if (sw == dw && sh == dh) {
    for (int y=0;y<tile.height();y++) {
      uint8_t* row = dst+size_t(y)*ds;
      std::memcpy(row, src+size_t(y+tile.tl.y)*ss+size_t(tile.tl.x)*4, size_t(tile.width())*4);
      if (!alpha) for (int x=0;x<tile.width();x++) row[x*4+3]=255;
    }
    return;
  }
  if (quality == ScalingSettings::Nearest) {
    int columns[256];
    for(int x=0;x<tile.width();x++)
      columns[x]=std::min(sw-1,int((x+tile.tl.x+.5)*sw/dw));
    for(int y=tile.tl.y;y<tile.br.y;y++) {
      int sy=std::min(sh-1,int((y+.5)*sh/dh));
      const uint8_t* row=src+size_t(sy)*ss;
      uint8_t* output=dst+size_t(y-tile.tl.y)*ds;
      for(int x=0;x<tile.width();x++) {
        std::memcpy(output+x*4,row+size_t(columns[x])*4,4);
        if(!alpha) output[x*4+3]=255;
      }
    }
    return;
  }
  if(quality == ScalingSettings::Bilinear || (sw<=dw && sh<=dh)) {
    int first[256],second[256];
    double fraction[256];
    for(int x=0;x<tile.width();x++) {
      double sample=std::max(0.,std::min(double(sw-1),(x+tile.tl.x+.5)*sw/dw-.5));
      first[x]=int(sample); second[x]=std::min(sw-1,first[x]+1);
      fraction[x]=sample-first[x];
    }
    for(int y=tile.tl.y;y<tile.br.y;y++) {
      double sample=std::max(0.,std::min(double(sh-1),(y+.5)*sh/dh-.5));
      int y0=int(sample),y1=std::min(sh-1,y0+1);
      double fy=sample-y0;
      const uint8_t* row0=src+size_t(y0)*ss;
      const uint8_t* row1=src+size_t(y1)*ss;
      uint8_t* output=dst+size_t(y-tile.tl.y)*ds;
      for(int x=0;x<tile.width();x++) {
        double fx=fraction[x];
        const uint8_t* a=row0+size_t(first[x])*4;
        const uint8_t* b=row0+size_t(second[x])*4;
        const uint8_t* c=row1+size_t(first[x])*4;
        const uint8_t* d=row1+size_t(second[x])*4;
        for(int channel=0;channel<4;channel++) {
          double top=a[channel]*(1-fx)+b[channel]*fx;
          double bottom=c[channel]*(1-fx)+d[channel]*fx;
          output[x*4+channel]=uint8_t(std::floor(top*(1-fy)+bottom*fy+.5));
        }
        if(!alpha) output[x*4+3]=255;
      }
    }
    return;
  }
  for (int y=tile.tl.y;y<tile.br.y;y++) {
    Kernel ky(y,sh,dh,quality);
    for (int x=tile.tl.x;x<tile.br.x;x++) {
      Kernel kx(x,sw,dw,quality);
      double sum[4] = {};
      for (int sy=ky.first;sy<=ky.last;sy++) {
        double wy=ky.weight(sy);
        for (int sx=kx.first;sx<=kx.last;sx++) {
          double weight=wy*kx.weight(sx);
          const uint8_t* p=src+size_t(sy)*ss+size_t(sx)*4;
          for (int c=0;c<(alpha?4:3);c++) sum[c]+=p[c]*weight;
        }
      }
      uint8_t* p=dst+size_t(y-tile.tl.y)*ds+size_t(x-tile.tl.x)*4;
      for (int c=0;c<3;c++) p[c]=uint8_t(std::max(0.,std::min(255.,std::floor(sum[c]+.5))));
      p[3]=alpha?uint8_t(std::max(0.,std::min(255.,std::floor(sum[3]+.5)))):255;
    }
  }
}
