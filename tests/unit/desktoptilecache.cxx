/* Copyright 2026 TigerVNC contributors. Licensed under GPL-2.0-or-later. */
#include <gtest/gtest.h>
#include "DesktopTileCache.h"
#include <algorithm>

TEST(DesktopTileCache, IncrementalMatchesFreshRendering)
{
  // Updates at source edges and either side of a tile boundary exercise the
  // filter halo. Both shrink/enlarge axes are present in this matrix.
  for(auto q : {ScalingSettings::Nearest,ScalingSettings::Bilinear,ScalingSettings::Area})
    for(auto size : {core::Point(701,503),core::Point(261,127),core::Point(711,131)}) {
      const int sw=517, sh=277;
      std::vector<uint8_t> source(sw*sh*4), cached(size.x*size.y*4), fresh(cached.size());
      for(size_t i=0;i<source.size();++i) source[i]=uint8_t(i*37);
      DesktopTileCache cache;
      cache.configure(sw,sh,size.x,size.y,q,1);
      for(int iteration=0;iteration<8;++iteration) {
        core::Rect damage(iteration ? iteration*71%(sw-1) : 0,iteration*41%(sh-1),
                          iteration ? iteration*71%(sw-1)+1 : 1,iteration*41%(sh-1)+1);
        for(int c=0;c<4;++c) source[(damage.tl.y*sw+damage.tl.x)*4+c]^=255;
        cache.invalidate(damage);
        for(int y=0;y<size.y;y+=256) for(int x=0;x<size.x;x+=256) {
          core::Rect tile(x,y,std::min(x+256,size.x),std::min(y+256,size.y));
          size_t offset=(size_t(y)*size.x+x)*4;
          cache.render(source.data(),sw*4,cached.data()+offset,size.x*4,tile);
          resampleDesktop(source.data(),sw,sh,sw*4,fresh.data()+offset,size.x*4,size.x,size.y,tile,q);
        }
        EXPECT_EQ(fresh,cached) << iteration << ' ' << q;
      }
    }
}

TEST(DesktopTileCache, BudgetEvictionAndGeneration)
{
  std::vector<uint8_t> source(512*256*4,77), out(256*256*4);
  DesktopTileCache cache(out.size());
  cache.configure(512,256,512,256,ScalingSettings::Nearest,1);
  auto render=[&](int x) { return cache.render(source.data(),512*4,out.data(),256*4,{x,0,x+256,256}); };
  EXPECT_FALSE(render(0)); EXPECT_TRUE(render(0));
  EXPECT_FALSE(render(256)); EXPECT_EQ(out.size(),cache.bytes());
  EXPECT_FALSE(render(0));
  cache.configure(512,256,512,256,ScalingSettings::Nearest,2);
  EXPECT_EQ(0u,cache.bytes()); EXPECT_FALSE(render(0));
  cache.configure(512,256,512,256,ScalingSettings::Area,2);
  EXPECT_FALSE(render(0));
  DesktopTileCache disabled(0);
  disabled.configure(512,256,512,256,ScalingSettings::Nearest,0);
  EXPECT_FALSE(disabled.render(source.data(),512*4,out.data(),256*4,{0,0,256,256}));
  EXPECT_EQ(77,out[0]); EXPECT_EQ(255,out[3]); EXPECT_EQ(0u,disabled.bytes());
}
