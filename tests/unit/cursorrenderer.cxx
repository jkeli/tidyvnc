/* Copyright 2026 TigerVNC contributors. Licensed under GPL-2.0-or-later. */
#include <gtest/gtest.h>
#include "CursorRenderer.h"
#include <limits>
#include <stdexcept>

TEST(CursorRenderer, OversizedVisibleTilesAndHotspot)
{
  uint8_t source[]={255,0,0,255, 0,255,0,255, 0,0,255,255, 255,255,255,255};
  CursorRenderer cursor(source,2,2,{1,1},50000,1000,ScalingSettings::Nearest);
  EXPECT_EQ(100000,cursor.width()); EXPECT_EQ(2000,cursor.height());
  EXPECT_EQ(core::Point(50000,1000),cursor.hotspot());
  uint8_t out[16];
  cursor.render(out,8,{49999,999,50001,1001});
  EXPECT_EQ(std::vector<uint8_t>(source,source+16),std::vector<uint8_t>(out,out+16));
}
TEST(CursorRenderer, TransparentEdgesRemainPremultiplied)
{
  uint8_t source[]={255,0,0,0, 0,255,0,128};
  CursorRenderer cursor(source,2,1,{1,0},2,1,ScalingSettings::Bilinear);
  uint8_t out[16]; cursor.render(out,16,{0,0,4,1});
  EXPECT_EQ(core::Point(2,0),cursor.hotspot());
  EXPECT_EQ(0,out[4]); EXPECT_EQ(255,out[5]); EXPECT_EQ(32,out[7]);
  EXPECT_EQ(0,out[8]); EXPECT_EQ(255,out[9]); EXPECT_EQ(96,out[11]);
}
TEST(CursorRenderer, RejectInvalidTransforms)
{
  uint8_t source[4]={};
  EXPECT_THROW(CursorRenderer(source,1,1,{},0,1,ScalingSettings::Area),std::invalid_argument);
  EXPECT_THROW(CursorRenderer(source,1,1,{},std::numeric_limits<double>::infinity(),1,ScalingSettings::Area),std::invalid_argument);
}
