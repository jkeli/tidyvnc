/* Copyright 2026 TigerVNC contributors. Licensed under GPL-2.0-or-later. */
#include <gtest/gtest.h>
#include "DesktopTransform.h"
#include <limits>
#include <stdexcept>

TEST(DesktopTransform, Parsing)
{
  for (const char* value : {"100", "0.01", "137.5", "10000", "Auto", "FixedRatio", "FitWidth", "FitHeight", "800x600", "125%x80%"})
    EXPECT_EQ(value, ScalingSettings::parse(value).serialize());
  EXPECT_EQ("100", ScalingSettings::parse(" 100.00% ").serialize());
  EXPECT_EQ("100", ScalingSettings::parse("None").serialize());
  EXPECT_EQ("125%x80%", ScalingSettings::parse("125.00%X80.0%").serialize());
  EXPECT_EQ("FixedRatio", ScalingSettings::parse("fixedratio").serialize());
  for (const char* value : {"", " ", "0", "-1", ".5", "1.", "NaN", "inf", "1e2", "1.001", "10000.01", "1 x2", "1% x2%", "1%x2", "1x2%", "1x", "0x1", "65536x1", "1x2x3", "999999999999999999999"})
    EXPECT_THROW(ScalingSettings::parse(value), std::invalid_argument) << value;
}
TEST(DesktopTransform, PixelPolicies)
{
  for (double q : {1., 1.25, 1.5, 1.75, 2., 3.}) {
    DisplayMetrics m; m.pixelsPerUnitX = m.pixelsPerUnitY = q;
    DesktopTransform device(101, 77, 1000, 800, m, {}, ScalingSettings::Device);
    EXPECT_EQ(101, device.backingWidth); EXPECT_EQ(77, device.backingHeight);
    EXPECT_DOUBLE_EQ(101 / q, device.logicalWidth); EXPECT_TRUE(device.identity());
    DesktopTransform logical(100, 80, 1000, 800, m, {}, ScalingSettings::Logical);
    EXPECT_EQ(int(100*q), logical.backingWidth);
    EXPECT_DOUBLE_EQ(100, logical.logicalWidth);
    auto s = ScalingSettings::parse("125%x80%");
    DesktopTransform independent(1920,1080,1000,800,m,s,ScalingSettings::Device);
    EXPECT_EQ(2400, independent.backingWidth); EXPECT_EQ(864, independent.backingHeight);
    for (const char* fit : {"Auto", "FixedRatio", "FitWidth", "FitHeight"}) {
      auto settings = ScalingSettings::parse(fit);
      DesktopTransform a(1920,1080,1000,800,m,settings,ScalingSettings::Logical);
      DesktopTransform b(1920,1080,1000,800,m,settings,ScalingSettings::Device);
      EXPECT_EQ(a.backingWidth,b.backingWidth); EXPECT_EQ(a.backingHeight,b.backingHeight);
    }
  }
}
TEST(DesktopTransform, FitAndExact)
{
  DesktopTransform fit(1920,1080,1000,800,{},ScalingSettings::parse("FixedRatio"),ScalingSettings::Logical);
  EXPECT_EQ(1000,fit.backingWidth); EXPECT_EQ(562,fit.backingHeight);
  DisplayMetrics m; m.pixelsPerUnitX=m.pixelsPerUnitY=2;
  DesktopTransform exact(1920,1080,1000,800,m,ScalingSettings::parse("800x600"),ScalingSettings::Device);
  EXPECT_EQ(800,exact.backingWidth); EXPECT_DOUBLE_EQ(400,exact.logicalWidth);
}
TEST(DesktopTransform, InputAndDamage)
{
  DisplayMetrics m; m.pixelsPerUnitX=m.pixelsPerUnitY=1.5;
  DesktopTransform t(101,77,1000,800,m,{},ScalingSettings::Device,-10,4);
  EXPECT_EQ(core::Point(0,0), t.remotePoint(-100,-100));
  EXPECT_EQ(core::Point(100,76), t.remotePoint(10000,10000));
  for(int x=0;x<101;x++)
    EXPECT_EQ(x,t.remotePoint((t.originBX+x+.5)/1.5,4).x);
  core::Rect r=t.logicalDamage({0,0,101,77},ScalingSettings::Bilinear);
  EXPECT_EQ(-10,r.tl.x); EXPECT_EQ(4,r.tl.y); EXPECT_EQ(58,r.br.x); EXPECT_EQ(56,r.br.y);
}
TEST(DesktopTransform, InvalidAndEmpty)
{
  EXPECT_TRUE(DesktopTransform(0,1,1,1,{}, {},ScalingSettings::Device).empty());
  EXPECT_TRUE(DesktopTransform(1,1,0,1,{}, {},ScalingSettings::Device).empty());
  DisplayMetrics m; m.pixelsPerUnitX=0;
  EXPECT_THROW(DesktopTransform(1,1,1,1,m,{},ScalingSettings::Device),std::invalid_argument);
  m.pixelsPerUnitX=1e-300;
  EXPECT_FALSE(m.valid());
  m.pixelsPerUnitX=std::numeric_limits<double>::infinity();
  EXPECT_FALSE(m.valid());
  EXPECT_THROW(DesktopTransform(65535,1,100,100,{},ScalingSettings::parse("200"),ScalingSettings::Device),std::overflow_error);
}

TEST(DesktopTransform, FractionalPanRetainsBackingAlignment)
{
  for(double q : {1.25,1.5,1.75,2.,3.}) {
    DisplayMetrics m; m.pixelsPerUnitX=m.pixelsPerUnitY=q;
    for(int pan=0;pan<29;++pan) {
      DesktopTransform t(101,77,40,30,m,{},ScalingSettings::Device,-pan/q,3/q);
      EXPECT_EQ(-pan,t.originBX); EXPECT_EQ(3,t.originBY);
      EXPECT_TRUE(t.identity());
      EXPECT_EQ(core::Point(pan,0),t.remotePoint(.5/q,3.5/q));
      auto damage=t.logicalDamage({0,0,101,77},ScalingSettings::Nearest);
      EXPECT_LE(damage.tl.x*q,t.originBX);
      EXPECT_GE(damage.br.x*q,t.originBX+101);
    }
  }
}

#include <fstream>
#include <sstream>
#include "ScalingParameter.h"
TEST(DesktopTransform, SharedContractFixtures)
{
  std::ifstream input(DESKTOP_SCALING_FIXTURES);
  ASSERT_TRUE(input.good());
  std::string line;
  unsigned count=0;
  while(std::getline(input,line)) {
    if(line.empty() || line[0]=='#') continue;
    std::istringstream row(line);
    std::string mode,units;
    int rw,rh,aw,ah,bw,bh;
    DisplayMetrics m;
    ASSERT_TRUE(bool(row>>mode>>units>>rw>>rh>>aw>>ah>>m.pixelsPerUnitX>>m.pixelsPerUnitY>>bw>>bh));
    DesktopTransform t(rw,rh,aw,ah,m,ScalingSettings::parse(mode),
      units=="Device"?ScalingSettings::Device:ScalingSettings::Logical);
    EXPECT_EQ(bw,t.backingWidth)<<line;
    EXPECT_EQ(bh,t.backingHeight)<<line;
    ++count;
  }
  EXPECT_EQ(18u,count);
}
TEST(DesktopTransform, ParameterValidationIsAtomic)
{
  ScalingParameter parameter("TestDesktopScaling", "Test parameter");
  ASSERT_TRUE(parameter.setParam("125.50%"));
  EXPECT_EQ("125.5",parameter.getValueStr());
  EXPECT_FALSE(parameter.setParam("1e5"));
  EXPECT_EQ("125.5",parameter.getValueStr());
}
