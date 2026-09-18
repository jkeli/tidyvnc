/* Copyright 2026 TigerVNC contributors. Licensed under GPL-2.0-or-later. */
#include "DesktopLayout.h"
#include <algorithm>
#include <limits>
#include <stdexcept>

DesktopLayout::DesktopLayout(const std::vector<DesktopMonitor>& monitors,
                             ScalingSettings::Units units)
{
  if(monitors.empty() || monitors.size()>255)
    throw std::invalid_argument("Invalid fullscreen monitor count");
  std::set<uint32_t> ids;
  int minX=monitors.front().logical.tl.x, minY=monitors.front().logical.tl.y;
  for(const auto& m : monitors) {
    if(std::abs(static_cast<long long>(m.logical.tl.x))>1000000 ||
       std::abs(static_cast<long long>(m.logical.tl.y))>1000000 ||
       std::abs(static_cast<long long>(m.logical.br.x))>1000000 ||
       std::abs(static_cast<long long>(m.logical.br.y))>1000000 || m.logical.is_empty() || m.backingWidth<=0 || m.backingHeight<=0 ||
       m.logical.width()>65535 || m.logical.height()>65535 ||
       m.backingWidth>65535 || m.backingHeight>65535 || !ids.insert(m.id).second)
      throw std::invalid_argument("Invalid fullscreen monitor geometry or identity");
    minX=std::min(minX,m.logical.tl.x); minY=std::min(minY,m.logical.tl.y);
    for(const auto& other : monitors)
      if(m.id!=other.id && !m.logical.intersect(other.logical).is_empty())
        throw std::invalid_argument("Overlapping or mirrored fullscreen monitors");
  }
  for(const auto& m : monitors) {
    long long x=static_cast<long long>(m.logical.tl.x)-minX;
    long long y=static_cast<long long>(m.logical.tl.y)-minY;
    int w=units==ScalingSettings::Device?m.backingWidth:m.logical.width();
    int h=units==ScalingSettings::Device?m.backingHeight:m.logical.height();
    if(x+w>65535 || y+h>65535) throw std::overflow_error("Fullscreen canvas exceeds RFB dimensions");
    regions.push_back({m,{int(x),int(y),int(x)+w,int(y)+h}});
  }
  if(units==ScalingSettings::Device) {
    // Independent acyclic constraints preserve left/right and above/below
    // relationships. Move only far enough to retain each required edge/gap.
    // Never multiply a global screen origin by one monitor's density.
    for(int axis=0;axis<2;++axis) {
      std::sort(regions.begin(),regions.end(),[axis](const DesktopRegion& a,const DesktopRegion& b) {
        int av=axis?a.monitor.logical.tl.y:a.monitor.logical.tl.x;
        int bv=axis?b.monitor.logical.tl.y:b.monitor.logical.tl.x;
        return av==bv?a.monitor.id<b.monitor.id:av<bv;
      });
      for(size_t i=0;i<regions.size();++i) {
        auto& current=regions[i];
        for(size_t j=0;j<i;++j) {
          const auto& previous=regions[j];
          int gap=axis?current.monitor.logical.tl.y-previous.monitor.logical.br.y:
                       current.monitor.logical.tl.x-previous.monitor.logical.br.x;
          if(gap<0) continue;
          int minimum=(axis?previous.canvas.br.y:previous.canvas.br.x)+gap;
          int origin=axis?current.canvas.tl.y:current.canvas.tl.x;
          int shift=std::max(0,minimum-origin);
          if(shift) {
            normalized=true;
            if(axis) { current.canvas.tl.y+=shift; current.canvas.br.y+=shift; }
            else { current.canvas.tl.x+=shift; current.canvas.br.x+=shift; }
          }
        }
      }
    }
  }
  std::sort(regions.begin(),regions.end(),[](const DesktopRegion& a,const DesktopRegion& b) {
    return a.monitor.id<b.monitor.id;
  });
  for(const auto& r : regions) {
    width=std::max(width,r.canvas.br.x); height=std::max(height,r.canvas.br.y);
    for(const auto& other : regions)
      if(r.monitor.id!=other.monitor.id && !r.canvas.intersect(other.canvas).is_empty())
        throw std::invalid_argument("Overlapping fullscreen canvas regions");
  }
  if(width>65535 || height>65535 || !screens().validate(width,height))
    throw std::overflow_error("Fullscreen canvas exceeds RFB dimensions");
}

rfb::ScreenSet DesktopLayout::screens() const
{
  rfb::ScreenSet result;
  for(const auto& r : regions)
    result.add_screen(rfb::Screen(r.monitor.id,r.canvas.tl.x,r.canvas.tl.y,
                                 r.canvas.width(),r.canvas.height(),0));
  return result;
}
