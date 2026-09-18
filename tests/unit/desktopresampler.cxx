/* Copyright 2026 TigerVNC contributors. Licensed under GPL-2.0-or-later. */
#include <gtest/gtest.h>
#include "DesktopResampler.h"
#include <vector>
#include <stdexcept>
TEST(DesktopResampler, IdentityAndTiles)
{
  std::vector<uint8_t> source(17*13*4);
  for(size_t i=0;i<source.size();i++) source[i]=uint8_t(i*37);
  for(auto quality : {ScalingSettings::Nearest,ScalingSettings::Bilinear,ScalingSettings::Area}) {
    for(auto size : {core::Point(17,13),core::Point(43,29),core::Point(7,5),core::Point(31,5)}) {
      std::vector<uint8_t> full(size.x*size.y*4), tiled(full.size());
      resampleDesktop(source.data(),17,13,17*4,full.data(),size.x*4,size.x,size.y,{0,0,size.x,size.y},quality,true);
      for(int y=0;y<size.y;y+=3) for(int x=0;x<size.x;x+=3) {
        core::Rect tile(x,y,std::min(x+3,size.x),std::min(y+3,size.y));
        resampleDesktop(source.data(),17,13,17*4,tiled.data()+(y*size.x+x)*4,size.x*4,size.x,size.y,tile,quality,true);
      }
      EXPECT_EQ(full,tiled);
      if(size==core::Point(17,13)) EXPECT_EQ(full,source);
    }
  }
}
TEST(DesktopResampler, AreaAveragesAndLinearCenters)
{
  const uint8_t src[]={0,0,0,0, 255,255,255,255, 0,0,0,0, 255,255,255,255};
  uint8_t out[16]={};
  resampleDesktop(src,4,1,16,out,4,1,1,{0,0,1,1},ScalingSettings::Area,true);
  for(int c=0;c<4;c++) EXPECT_EQ(128,out[c]);
  resampleDesktop(src,2,1,8,out,16,4,1,{0,0,4,1},ScalingSettings::Bilinear,true);
  EXPECT_EQ(0,out[0]); EXPECT_EQ(64,out[4]); EXPECT_EQ(191,out[8]); EXPECT_EQ(255,out[12]);
}
TEST(DesktopResampler, InvalidTile)
{
  uint8_t p[4]={};
  EXPECT_THROW(resampleDesktop(p,1,1,4,p,4,1,1,{-1,0,1,1},ScalingSettings::Area),std::invalid_argument);
  EXPECT_THROW(resampleDesktop(p,1,1,4,p,4,300,1,{0,0,300,1},ScalingSettings::Area),std::invalid_argument);
}
