/* Copyright 2026 TigerVNC contributors. Licensed under GPL-2.0-or-later. */
#include <viewer/core/DesktopResampler.h>
#include <viewer/core/DesktopTileCache.h>
#include <algorithm>
#include <chrono>
#include <cstdio>
#include <vector>

int main()
{
  const int sw=1920,sh=1080,dw=3840,dh=2160;
  std::vector<uint8_t> source(size_t(sw)*sh*4),tile(256*256*4);
  for(size_t i=0;i<source.size();i++) source[i]=uint8_t(i*31);
  for(auto quality : {ScalingSettings::Nearest,ScalingSettings::Bilinear,ScalingSettings::Area}) {
    std::vector<double> times;
    for(int run=0;run<7;run++) {
      auto start=std::chrono::steady_clock::now();
      for(int y=0;y<dh;y+=256) for(int x=0;x<dw;x+=256)
        resampleDesktop(source.data(),sw,sh,sw*4,tile.data(),256*4,dw,dh,
          {x,y,std::min(dw,x+256),std::min(dh,y+256)},quality);
      double ms=std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-start).count();
      if(run) times.push_back(ms);
    }
    std::sort(times.begin(),times.end());
    std::printf("1920x1080 -> 3840x2160, quality %d: median %.2f ms, max %.2f ms (6 runs after warmup)\n",
      int(quality),times[times.size()/2],times.back());
  }
  for(auto quality : {ScalingSettings::Nearest,ScalingSettings::Bilinear,ScalingSettings::Area}) {
    DesktopTileCache cache;
    cache.configure(sw,sh,dw,dh,quality,1);
    for(int variant=0;variant<3;++variant) {
      std::vector<double> times;
      for(int run=0;run<7;++run) {
        if(variant==1) cache.invalidate({500,500,501,501});
        if(variant==2) cache.invalidate({0,0,sw,sh});
        auto start=std::chrono::steady_clock::now();
        for(int y=0;y<dh;y+=256) for(int x=0;x<dw;x+=256)
          cache.render(source.data(),sw*4,tile.data(),256*4,
            {x,y,std::min(dw,x+256),std::min(dh,y+256)});
        double ms=std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-start).count();
        if(run) times.push_back(ms);
      }
      std::sort(times.begin(),times.end());
      std::printf("4K cache quality %d, %s: median %.2f ms, max %.2f ms, %.2f MiB retained\n",
        int(quality),variant==0?"expose":variant==1?"sparse damage":"full damage",
        times[times.size()/2],times.back(),cache.bytes()/1048576.);
    }
  }

}
